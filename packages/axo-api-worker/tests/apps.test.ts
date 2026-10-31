import assert from "node:assert/strict";
import { test } from "node:test";
import { connectionsResults } from "@axo/protocol";
import { cookiePair, harness, signIn, type AccountSession, type Harness } from "./harness";
import { connectHost, pairHost } from "./account-support";
import { FakeGoogle } from "./fake-google";

/**
 * RFD0016, apps: Gmail is a service Axo provides itself. The person signs in to Google with Axo's
 * own client from the Connections page, or from a link an agent got when a call needed it, and
 * scripts call `codemode.apps.gmail.*` from the cloud with a grant that never leaves the account.
 */

type Reply = { result: unknown } | { error: { code: number; message: string } };

async function fixture(t: { after(fn: () => unknown): void }) {
  const google = new FakeGoogle();
  const h = await harness({
    bindings: { GOOGLE_CLIENT_ID: google.clientId, GOOGLE_CLIENT_SECRET: google.clientSecret },
    outbound: (request) => google.handle(request),
  });
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session, "Studio");
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const sessionId = crypto.randomUUID();
  const call = (method: string, params: Record<string, unknown> = {}) => daemon.call(method, { sessionId, ...params }) as Promise<Reply>;
  const execute = (code: string) => call("axo.connections.execute", { code });
  return { google, h, session, call, execute };
}

function result(reply: Reply): any {
  assert.ok("result" in reply, JSON.stringify(reply));
  return reply.result;
}

function failure(reply: Reply): string {
  assert.ok("error" in reply, JSON.stringify(reply));
  return reply.error.message;
}

/** The Connections page's Sign in button for Gmail: a sign-in link from the account's API. */
async function signInLink(h: Harness, session: AccountSession): Promise<string> {
  const response = await fetch(new URL("api/v1/account/connections/apps.gmail/sign-in", h.url), { method: "POST", headers: { ...session.headers, Origin: "https://axo.leostera.dev" } });
  assert.equal(response.status, 200, await response.clone().text());
  return ((await response.json()) as { signInUrl: string }).signInUrl;
}

async function signInThroughBrowser(h: Harness, google: FakeGoogle, session: AccountSession, signInUrl: string): Promise<URL> {
  const start = await fetch(new URL(signInUrl.replace("https://axo.leostera.dev/", ""), h.url), { headers: { Cookie: session.headers.Cookie! }, redirect: "manual" });
  assert.equal(start.status, 302, await start.text());
  const flowCookie = cookiePair(start, "__Host-axo_connection");
  assert.ok(flowCookie);
  const back = google.approve(start.headers.get("location")!);
  const callback = await fetch(new URL(`${back.pathname.slice(1)}${back.search}`, h.url), { headers: { Cookie: `${session.headers.Cookie}; ${flowCookie}` }, redirect: "manual" });
  assert.equal(callback.status, 302);
  return new URL(callback.headers.get("location")!);
}

async function signedIn(t: { after(fn: () => unknown): void }) {
  const f = await fixture(t);
  const landed = await signInThroughBrowser(f.h, f.google, f.session, await signInLink(f.h, f.session));
  assert.equal(landed.searchParams.get("signedIn"), "apps.gmail", landed.toString());
  return f;
}

test("Gmail is listed needing sign-in; a call before it hands the agent a sign-in link, and after it the tools work", async (t) => {
  const { google, h, session, call, execute } = await fixture(t);
  const listed = connectionsResults["axo.connections.list"].parse(result(await call("axo.connections.list")));
  assert.deepEqual(listed.connections.find((c) => c.kind === "app"), {
    kind: "app", name: "apps.gmail", title: "Gmail", state: "needsSignIn", account: null, tools: 9, lastError: null,
  });
  const tools = result(await call("axo.connections.search", { code: `async () => codemode.tools().filter((t) => t.service === "apps.gmail").map((t) => t.name)` })).result;
  assert.deepEqual(tools, ["get_profile", "search_messages", "get_message", "get_thread", "list_labels", "send_message", "create_draft", "modify_message", "trash_message"]);

  const early = failure(await execute(`async () => codemode.apps.gmail.get_profile()`));
  const link = /https:\/\/axo\.leostera\.dev\/api\/v1\/connections\/oauth\/start\?flow=[0-9a-f-]+/.exec(early)?.[0];
  assert.ok(link, early);

  const landed = await signInThroughBrowser(h, google, session, link);
  assert.equal(landed.pathname, "/app/connections");
  assert.equal(landed.searchParams.get("signedIn"), "apps.gmail");
  const ready = connectionsResults["axo.connections.list"].parse(result(await call("axo.connections.list"))).connections.find((c) => c.kind === "app");
  assert.deepEqual([ready?.state, ready?.kind === "app" && ready.account], ["ready", "ada@example.com"]);

  const found = result(await execute(`async () => {
    const unread = await codemode.apps.gmail.search_messages({ query: "is:unread" });
    const message = await codemode.apps.gmail.get_message({ id: unread.messages[0].id });
    const html = await codemode.apps.gmail.get_message({ id: "m2" });
    return { unread, message, html: html.text };
  }`)).result;
  assert.deepEqual(found.unread, {
    messages: [{ id: "m1", threadId: "t1", from: "Grace <grace@example.com>", to: "ada@example.com", subject: "Compilers", date: "Fri, 30 Oct 2026 10:00:00 +0000", snippet: "Shall we meet?", labelIds: ["INBOX", "UNREAD"] }],
    nextPageToken: null,
    resultSizeEstimate: 1,
  });
  assert.equal(found.message.text, "Shall we meet?");
  assert.equal(found.message.messageId, "<m1@example.com>");
  assert.deepEqual(found.message.attachments, [{ filename: "notes.pdf", mimeType: "application/pdf", size: 1234 }]);
  assert.equal(found.html, "Hello & welcome", "a message with no plain text reads as its HTML, as text");

  // The grant stays in the cloud.
  const page = await (await fetch(new URL("api/v1/account/connections", h.url), { headers: session.headers })).text();
  for (const text of [page, JSON.stringify(found), JSON.stringify(result(await call("axo.connections.log")))]) assert.equal(google.leaks(text), false);
});

test("send_message builds the MIME message, threads a reply, and is logged under apps.gmail", async (t) => {
  const { google, call, execute } = await signedIn(t);
  const sent = result(await execute(`async () => [
    await codemode.apps.gmail.send_message({ to: "Grace Hopper <grace@example.com>, alan@example.com", subject: "Größe", text: "Hi ✓" }),
    await codemode.apps.gmail.send_message({ replyToMessageId: "m1", to: "grace@example.com", text: "Yes", html: "<b>Yes</b>" }),
  ]`)).result;
  assert.deepEqual(sent.map((s: { labelIds: string[] }) => s.labelIds), [["SENT"], ["SENT"]]);

  const [first, reply] = google.sent;
  assert.match(first!.raw, /^To: "Grace Hopper" <grace@example\.com>, alan@example\.com\r\n/);
  assert.match(first!.raw, /\r\nSubject: =\?UTF-8\?B\?R3LDtsOfZQ==\?=\r\n/);
  assert.match(first!.raw, /\r\nContent-Type: text\/plain; charset="UTF-8"\r\nContent-Transfer-Encoding: base64\r\n\r\nSGkg4pyT/);
  assert.equal(first!.threadId, null);
  assert.equal(reply!.threadId, "t1");
  assert.match(reply!.raw, /\r\nIn-Reply-To: <m1@example\.com>\r\nReferences: <m1@example\.com>\r\n/);
  assert.match(reply!.raw, /\r\nSubject: Re: Compilers\r\n/);
  assert.match(reply!.raw, /Content-Type: multipart\/alternative; boundary="axo-/);

  const smuggled = failure(await execute(`async () => codemode.apps.gmail.send_message({ to: "a@example.com", subject: "x\\r\\nBcc: eve@example.com", text: "" })`));
  assert.match(smuggled, /line breaks/);
  assert.equal(google.sent.length, 2);

  const records = result(await call("axo.connections.log")).records as Array<{ service: string; tool: string; outcome: string }>;
  assert.deepEqual(records.slice(0, 3).map((r) => [r.service, r.tool, r.outcome]), [
    ["apps.gmail", "send_message", "error"],
    ["apps.gmail", "send_message", "ok"],
    ["apps.gmail", "send_message", "ok"],
  ]);
});

test("a send that fails on Google's side is logged as may-have-run; labels change idempotently", async (t) => {
  const { google, call, execute } = await signedIn(t);
  google.failNextSend = 503;
  const lost = failure(await execute(`async () => codemode.apps.gmail.send_message({ to: "a@example.com", subject: "s", text: "t" })`));
  assert.match(lost, /may have run/);
  const archived = result(await execute(`async () => codemode.apps.gmail.modify_message({ id: "m1", removeLabelIds: ["INBOX", "UNREAD"], addLabelIds: ["STARRED"] })`)).result;
  assert.deepEqual(archived, { id: "m1", threadId: "t1", labelIds: ["STARRED"] });
  const missing = failure(await execute(`async () => codemode.apps.gmail.get_message({ id: "nope" })`));
  assert.match(missing, /Gmail: Requested entity was not found/);
  const records = result(await call("axo.connections.log")).records as Array<{ tool: string; outcome: string }>;
  assert.deepEqual(records.slice(0, 3).map((r) => [r.tool, r.outcome]), [["get_message", "error"], ["modify_message", "ok"], ["send_message", "unknown"]]);
});

test("a rejected access token is renewed once and the call sent again; a refused renewal asks for sign-in", async (t) => {
  const { google, call, execute } = await signedIn(t);
  google.expireAccessTokens();
  assert.equal(result(await execute(`async () => (await codemode.apps.gmail.get_profile()).emailAddress`)).result, "ada@example.com");
  assert.equal(google.tokenRequests.filter((f) => f.get("grant_type") === "refresh_token").length, 1);

  google.expireAccessTokens();
  google.refuseRefresh = true;
  assert.match(failure(await execute(`async () => codemode.apps.gmail.get_profile()`)), /needs sign-in/);
  const app = result(await call("axo.connections.list")).connections.find((c: { kind: string }) => c.kind === "app");
  assert.equal(app.state, "needsSignIn");
});

test("a sign-in without Gmail access does not land, and signing out revokes the grant", async (t) => {
  const { google, h, session, call } = await fixture(t);
  google.grantScopes = ["openid", "email"];
  const refused = await signInThroughBrowser(h, google, session, await signInLink(h, session));
  assert.match(refused.searchParams.get("error") ?? "", /did not grant Gmail access/);
  assert.equal(google.revoked.length, 1, "the useless grant is revoked");
  let app = result(await call("axo.connections.list")).connections.find((c: { kind: string }) => c.kind === "app");
  assert.equal(app.state, "needsSignIn");

  google.grantScopes = null;
  await signInThroughBrowser(h, google, session, await signInLink(h, session));
  assert.deepEqual(result(await call("axo.connections.remove", { name: "apps.gmail" })), { removed: true });
  app = result(await call("axo.connections.list")).connections.find((c: { kind: string }) => c.kind === "app");
  assert.equal(app.state, "needsSignIn");
  for (let i = 0; i < 20 && google.revoked.length < 2; i++) await new Promise((r) => setTimeout(r, 25));
  assert.equal(google.revoked.length, 2);
  assert.match(failure(await call("axo.connections.remove", { name: "apps.gmail" })), /not signed in/);
});

test("apps is a reserved name, and a deployment without a Google client lists no apps", async (t) => {
  const { call } = await fixture(t);
  assert.match(failure(await call("axo.connections.add", { name: "apps", url: "https://mcp.example.test/mcp" })), /reserved/);

  const bare = await harness();
  t.after(() => bare.close());
  const session = await signIn(bare);
  const daemon = await connectHost(bare, session, await pairHost(bare, session, "Studio"));
  t.after(() => daemon.close());
  const listed = (await daemon.call("axo.connections.list", { sessionId: crypto.randomUUID() })) as Reply;
  assert.deepEqual(result(listed).connections.map((c: { kind: string }) => c.kind), ["host"]);
});
