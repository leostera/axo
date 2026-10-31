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
async function signInLink(h: Harness, session: AccountSession, app = "apps.gmail"): Promise<string> {
  const response = await fetch(new URL(`api/v1/account/connections/${app}/sign-in`, h.url), { method: "POST", headers: { ...session.headers, Origin: "https://axo.leostera.dev" } });
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
  const gmailTools = ["get_profile", "search_messages", "get_message", "get_thread", "list_labels", "send_message", "create_draft", "modify_message", "trash_message", "delete_message",
    "list_filters", "create_filter", "delete_filter", "get_vacation", "set_vacation", "list_send_as", "request"];
  const gmail = listed.connections.find((c) => c.kind === "app");
  assert.deepEqual({ ...gmail, description: undefined, permissions: undefined }, {
    kind: "app", name: "apps.gmail", title: "Gmail", description: undefined, provider: "Google", category: "communication", permissions: undefined, signIn: { kind: "oauth" }, state: "needsSignIn", accounts: [], tools: gmailTools, lastError: null,
  });
  assert.ok(gmail?.kind === "app" && gmail.description && gmail.permissions.length >= 3, "an app says what it is for and what it may do");
  const tools = result(await call("axo.connections.search", { code: `async () => codemode.tools().filter((t) => t.service === "apps.gmail").map((t) => [t.call, t.inputSchema.required])` })).result;
  assert.deepEqual(tools.map(([c]: [string]) => c), gmailTools.map((t) => `codemode.apps.gmail.${t}`));
  assert.ok(tools.every(([, required]: [string, string[]]) => required[0] === "account"), "every tool needs an account");

  const early = failure(await execute(`async () => codemode.apps.gmail.get_profile({ account: "ada@example.com", account: "ada@example.com" })`));
  const link = /https:\/\/axo\.leostera\.dev\/api\/v1\/connections\/oauth\/start\?flow=[0-9a-f-]+/.exec(early)?.[0];
  assert.ok(link, early);

  const landed = await signInThroughBrowser(h, google, session, link);
  assert.equal(landed.pathname, "/app/settings/apps/gmail");
  assert.equal(landed.searchParams.get("signedIn"), "apps.gmail");
  const ready = connectionsResults["axo.connections.list"].parse(result(await call("axo.connections.list"))).connections.find((c) => c.kind === "app");
  assert.deepEqual([ready?.state, ready?.kind === "app" && ready.accounts], ["ready", [{ account: "ada@example.com", state: "ready", lastError: null }]]);
  const described = result(await call("axo.connections.search", { code: `async () => codemode.tools().find((t) => t.name === "search_messages").description` })).result;
  assert.match(described, /Signed-in accounts: ada@example\.com\./);

  const found = result(await execute(`async () => {
    const unread = await codemode.apps.gmail.search_messages({ account: "ada@example.com", query: "is:unread" });
    const message = await codemode.apps.gmail.get_message({ account: "ada@example.com", id: unread.messages[0].id });
    const html = await codemode.apps.gmail.get_message({ account: "ada@example.com", id: "m2" });
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
    await codemode.apps.gmail.send_message({ account: "ada@example.com", to: "Grace Hopper <grace@example.com>, alan@example.com", subject: "Größe", text: "Hi ✓" }),
    await codemode.apps.gmail.send_message({ account: "ada@example.com", replyToMessageId: "m1", to: "grace@example.com", text: "Yes", html: "<b>Yes</b>" }),
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

  const smuggled = failure(await execute(`async () => codemode.apps.gmail.send_message({ account: "ada@example.com", to: "a@example.com", subject: "x\\r\\nBcc: eve@example.com", text: "" })`));
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
  const lost = failure(await execute(`async () => codemode.apps.gmail.send_message({ account: "ada@example.com", to: "a@example.com", subject: "s", text: "t" })`));
  assert.match(lost, /may have run/);
  const archived = result(await execute(`async () => codemode.apps.gmail.modify_message({ account: "ada@example.com", id: "m1", removeLabelIds: ["INBOX", "UNREAD"], addLabelIds: ["STARRED"] })`)).result;
  assert.deepEqual(archived, { id: "m1", threadId: "t1", labelIds: ["STARRED"] });
  const missing = failure(await execute(`async () => codemode.apps.gmail.get_message({ account: "ada@example.com", id: "nope" })`));
  assert.match(missing, /Gmail: Requested entity was not found/);
  const records = result(await call("axo.connections.log")).records as Array<{ tool: string; outcome: string }>;
  assert.deepEqual(records.slice(0, 3).map((r) => [r.tool, r.outcome]), [["get_message", "error"], ["modify_message", "ok"], ["send_message", "unknown"]]);
});

test("a rejected access token is renewed once and the call sent again; a refused renewal asks for sign-in", async (t) => {
  const { google, call, execute } = await signedIn(t);
  google.expireAccessTokens();
  assert.equal(result(await execute(`async () => (await codemode.apps.gmail.get_profile({ account: "ada@example.com", account: "ada@example.com" })).emailAddress`)).result, "ada@example.com");
  assert.equal(google.tokenRequests.filter((f) => f.get("grant_type") === "refresh_token").length, 1);

  google.expireAccessTokens();
  google.refuseRefresh = true;
  assert.match(failure(await execute(`async () => codemode.apps.gmail.get_profile({ account: "ada@example.com", account: "ada@example.com" })`)), /needs sign-in/);
  const app = result(await call("axo.connections.list")).connections.find((c: { kind: string }) => c.kind === "app");
  assert.equal(app.state, "needsSignIn");
  assert.deepEqual(app.accounts, [{ account: "ada@example.com", state: "needsSignIn", lastError: "Google refused to renew the grant" }], "the account stays listed, to sign in to again");
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
  assert.match(failure(await call("axo.connections.remove", { name: "apps.gmail" })), /name the account/);
  assert.deepEqual(result(await call("axo.connections.remove", { name: "apps.gmail", account: "ada@example.com" })), { removed: true });
  app = result(await call("axo.connections.list")).connections.find((c: { kind: string }) => c.kind === "app");
  assert.deepEqual([app.state, app.accounts], ["needsSignIn", []]);
  for (let i = 0; i < 20 && google.revoked.length < 2; i++) await new Promise((r) => setTimeout(r, 25));
  assert.equal(google.revoked.length, 2);
  assert.match(failure(await call("axo.connections.remove", { name: "apps.gmail", account: "ada@example.com" })), /not signed in/);
});

test("apps is a reserved name, and a deployment without a Google client lists no Google apps", async (t) => {
  const { call } = await fixture(t);
  assert.match(failure(await call("axo.connections.add", { name: "apps", url: "https://mcp.example.test/mcp" })), /reserved/);

  const bare = await harness();
  t.after(() => bare.close());
  const session = await signIn(bare);
  const daemon = await connectHost(bare, session, await pairHost(bare, session, "Studio"));
  t.after(() => daemon.close());
  const listed = (await daemon.call("axo.connections.list", { sessionId: crypto.randomUUID() })) as Reply;
  // Token apps need no client of Axo's: the person brings the token.
  assert.deepEqual(result(listed).connections.map((c: { name: string }) => c.name), ["studio", "apps.hetzner", "apps.chatgpt", "apps.onepassword", "apps.octopus", "apps.wise", "apps.telegram", "apps.kraken"]);
});

test("several Google accounts sign in to Gmail; each call acts as the account it names, and no call guesses one", async (t) => {
  const { google, h, session, call, execute } = await signedIn(t);
  google.email = "Grace@Example.com";
  await signInThroughBrowser(h, google, session, await signInLink(h, session));
  const app = result(await call("axo.connections.list")).connections.find((c: { kind: string }) => c.kind === "app");
  assert.deepEqual(app.accounts.map((a: { account: string }) => a.account), ["ada@example.com", "grace@example.com"]);

  const profiles = result(await execute(`async () => Promise.all(["ada@example.com", "GRACE@example.com"].map(async (account) =>
    (await codemode.apps.gmail.get_profile({ account })).emailAddress))`)).result;
  assert.deepEqual(profiles, ["ada@example.com", "Grace@Example.com"], "each call used its own account's grant");

  assert.match(failure(await execute(`async () => codemode.apps.gmail.get_profile({})`)), /account/);
  assert.match(failure(await execute(`async () => codemode.apps.gmail.get_profile({ account: "eve@example.com" })`)), /no Gmail account eve@example\.com; signed in: ada@example\.com, grace@example\.com/);

  // Signing in again to an account replaces its grant rather than adding a second one.
  google.email = "ada@example.com";
  await signInThroughBrowser(h, google, session, await signInLink(h, session));
  const again = result(await call("axo.connections.list")).connections.find((c: { kind: string }) => c.kind === "app");
  assert.equal(again.accounts.length, 2);

  // Signing one out leaves the other.
  result(await call("axo.connections.remove", { name: "apps.gmail", account: "grace@example.com" }));
  assert.match(failure(await execute(`async () => codemode.apps.gmail.get_profile({ account: "grace@example.com" })`)), /signed in: ada@example\.com\n/);
  assert.equal(result(await execute(`async () => (await codemode.apps.gmail.get_profile({ account: "ada@example.com" })).emailAddress`)).result, "ada@example.com");
});

test("delete_message deletes a message for good", async (t) => {
  const { google, execute } = await signedIn(t);
  assert.deepEqual(result(await execute(`async () => codemode.apps.gmail.delete_message({ account: "ada@example.com", id: "m2" })`)).result, { deleted: true });
  assert.equal(google.messages.has("m2"), false);
});

test("a grant stored when Gmail held one account carries over as that account", async (t) => {
  const { h, session } = await signedIn(t);
  const { DatabaseSync } = await import("node:sqlite");
  const { readdir } = await import("node:fs/promises");
  const { join } = await import("node:path");
  await h.restart(async () => {
    // The account's Durable Object is the one whose SQLite holds the app's row.
    const files = (await readdir(h.storagePath, { recursive: true })).filter((f) => f.endsWith(".sqlite")).map((f) => join(h.storagePath, f));
    let migrated = 0;
    for (const file of files) {
      const db = new DatabaseSync(file);
      const has = db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = 'app_accounts'").get() as { n: number };
      if (has.n) {
        const row = db.prepare("SELECT grant_sealed, grant_generation FROM app_accounts WHERE app = 'gmail'").get() as { grant_sealed: string; grant_generation: number };
        db.exec("DELETE FROM app_accounts; DELETE FROM app_grants");
        db.prepare("INSERT INTO app_grants (app, grant_sealed, grant_generation, account, last_error) VALUES ('gmail', ?, ?, 'Ada@Example.com', NULL)").run(row.grant_sealed, row.grant_generation);
        migrated += 1;
      }
      db.close();
    }
    assert.equal(migrated, 1);
  });
  const after = await fetch(new URL("api/v1/account/connections", h.url), { headers: session.headers });
  const app = ((await after.json()) as { connections: Array<{ kind: string; accounts: Array<{ account: string; state: string }> }> }).connections.find((c) => c.kind === "app");
  assert.deepEqual(app?.accounts.map((a) => [a.account, a.state]), [["ada@example.com", "ready"]]);
});

/** Signs ada@example.com in to one Workspace app, through the browser. */
async function workspace(t: { after(fn: () => unknown): void }, app: string) {
  const f = await fixture(t);
  const start = await fetch(new URL((await signInLink(f.h, f.session, app)).replace("https://axo.leostera.dev/", ""), f.h.url), { headers: { Cookie: f.session.headers.Cookie! }, redirect: "manual" });
  const asked = new URL(start.headers.get("location")!).searchParams.get("scope");
  const landed = await signInThroughBrowser(f.h, f.google, f.session, await signInLink(f.h, f.session, app));
  assert.equal(landed.searchParams.get("signedIn"), app, landed.toString());
  const run = async (code: string) => result(await f.execute(code)).result;
  return { ...f, asked, run, calls: () => f.google.workspaceCalls.map((c) => c.call) };
}

test("every Workspace app is listed, signs in with full access to its own service only, and keeps its own accounts", async (t) => {
  const { google, h, session, call } = await signedIn(t);
  const listed = result(await call("axo.connections.list")).connections.filter((c: { kind: string }) => c.kind === "app");
  assert.deepEqual(listed.map((c: { name: string; accounts: unknown[] }) => [c.name, c.accounts.length]), [
    ["apps.gmail", 1], ["apps.calendar", 0], ["apps.drive", 0], ["apps.docs", 0], ["apps.sheets", 0], ["apps.slides", 0],
    ["apps.contacts", 0], ["apps.tasks", 0], ["apps.meet", 0], ["apps.cloud", 0], ["apps.hetzner", 0], ["apps.chatgpt", 0], ["apps.onepassword", 1], ["apps.octopus", 0], ["apps.wise", 0], ["apps.telegram", 0], ["apps.kraken", 0],
  ]);
  const scopes: Record<string, string> = {};
  for (const app of ["apps.gmail", "apps.calendar", "apps.drive", "apps.docs", "apps.sheets", "apps.slides", "apps.contacts", "apps.tasks", "apps.meet", "apps.cloud"]) {
    const start = await fetch(new URL((await signInLink(h, session, app)).replace("https://axo.leostera.dev/", ""), h.url), { headers: { Cookie: session.headers.Cookie! }, redirect: "manual" });
    scopes[app] = new URL(start.headers.get("location")!).searchParams.get("scope")!;
  }
  const g = (...s: string[]) => ["openid", "email", ...s.map((x) => x.startsWith("https:") ? x : `https://www.googleapis.com/auth/${x}`)].join(" ");
  assert.deepEqual(scopes, {
    "apps.gmail": g("https://mail.google.com/", "gmail.settings.basic", "gmail.settings.sharing"),
    "apps.calendar": g("calendar"),
    "apps.drive": g("drive"),
    "apps.docs": g("documents"),
    "apps.sheets": g("spreadsheets"),
    "apps.slides": g("presentations"),
    "apps.contacts": g("contacts", "contacts.other.readonly", "directory.readonly"),
    "apps.tasks": g("tasks"),
    "apps.meet": g("meetings.space.created", "meetings.space.readonly"),
    "apps.cloud": g("cloud-platform"),
  });
  void google;
});

test("Calendar lists calendars and events, creates one with a Meet link, changes and deletes it, and reads free/busy", async (t) => {
  const { run, google } = await workspace(t, "apps.calendar");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    const calendars = await codemode.apps.calendar.list_calendars(a);
    const events = await codemode.apps.calendar.list_events({ ...a, timeMin: "2026-11-02T00:00:00Z", timeMax: "2026-11-03T00:00:00Z" });
    const created = await codemode.apps.calendar.create_event({ ...a, summary: "Review", start: "2026-11-03T10:00:00+00:00", end: "2026-11-03", attendees: ["grace@example.com"], addMeet: true });
    const moved = await codemode.apps.calendar.update_event({ ...a, eventId: "e2", start: "2026-11-04T10:00:00Z", timeZone: "Europe/London" });
    const deleted = await codemode.apps.calendar.delete_event({ ...a, eventId: "e2", sendUpdates: "all" });
    const busy = await codemode.apps.calendar.free_busy({ ...a, timeMin: "2026-11-02T00:00:00Z", timeMax: "2026-11-03T00:00:00Z", calendars: ["grace@example.com"] });
    return { calendars, events, created, moved, deleted, busy };
  }`);
  assert.deepEqual(out.calendars.calendars[1], { id: "team@group.calendar.google.com", summary: "Team (mine)", primary: false, accessRole: "reader", timeZone: null });
  assert.deepEqual(out.events.events[0], { id: "e1", summary: "Standup", start: "2026-11-02T09:00:00Z", end: "2026-11-02T09:15:00Z", allDay: false, location: null, attendees: [{ email: "grace@example.com", responseStatus: "accepted" }], organizer: null, status: "confirmed", htmlLink: null, meetLink: "https://meet.google.com/x", recurringEventId: null });
  assert.equal(out.created.summary, "Review");
  assert.equal(out.deleted.deleted, true);
  assert.deepEqual(out.busy, { calendars: { "grace@example.com": [{ start: "2026-11-02T09:00:00Z", end: "2026-11-02T10:00:00Z" }] } });
  const [listCalendars, listEvents, create, patch, del] = google.workspaceCalls;
  assert.equal(listCalendars!.call, "GET www/calendar/v3/users/me/calendarList");
  assert.equal(listEvents!.call, "GET www/calendar/v3/calendars/primary/events");
  assert.equal(listEvents!.query.get("singleEvents"), "true");
  assert.deepEqual(JSON.parse(create!.body).start, { dateTime: "2026-11-03T10:00:00+00:00" });
  assert.deepEqual(JSON.parse(create!.body).end, { date: "2026-11-03" }, "a date is an all-day time");
  assert.equal(JSON.parse(create!.body).conferenceData.createRequest.conferenceSolutionKey.type, "hangoutsMeet");
  assert.equal(create!.query.get("conferenceDataVersion"), "1");
  assert.equal(create!.query.get("sendUpdates"), "none", "guests are not emailed unless asked");
  assert.deepEqual(JSON.parse(patch!.body), { start: { dateTime: "2026-11-04T10:00:00Z", timeZone: "Europe/London" } }, "an update sends only what changes");
  assert.equal(del!.query.get("sendUpdates"), "all");
});

test("Drive searches, reads Docs as text, refuses binary reads, uploads, moves, shares, trashes and deletes", async (t) => {
  const { run, google, execute } = await workspace(t, "apps.drive");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    const found = await codemode.apps.drive.search_files({ ...a, text: "plan's", folderId: "root" });
    const doc = await codemode.apps.drive.read_file({ ...a, id: "doc1" });
    const pdf = await codemode.apps.drive.download_file({ ...a, id: "pdf1" });
    const up = await codemode.apps.drive.upload_file({ ...a, name: "rows.csv", text: "a,b\\n1,2", mimeType: "text/csv", convertTo: "spreadsheet", folderId: "f1" });
    const folder = await codemode.apps.drive.update_file({ ...a, id: up.id, name: "Rows", folderId: "f2" });
    const shared = await codemode.apps.drive.share_file({ ...a, id: up.id, email: "grace@example.com", role: "writer", notify: false });
    const trashed = await codemode.apps.drive.trash_file({ ...a, id: "doc1" });
    const deleted = await codemode.apps.drive.delete_file({ ...a, id: "pdf1" });
    return { found, doc, pdf, up, folder, shared, trashed, deleted };
  }`);
  const search = google.workspaceCalls[0]!;
  assert.equal(search.query.get("q"), "fullText contains 'plan\\'s' and 'root' in parents and trashed = false");
  assert.equal(search.query.get("orderBy"), null, "Drive cannot order a full-text search");
  assert.deepEqual(out.found.files.map((f: { id: string }) => f.id), ["doc1", "pdf1"]);
  assert.deepEqual([out.doc.text, out.doc.truncated], ["The plan.", false]);
  assert.ok(google.workspaceCalls.some((c) => c.call === "GET www/drive/v3/files/doc1/export" && c.query.get("mimeType") === "text/plain"));
  assert.equal(Buffer.from(out.pdf.dataBase64, "base64").toString(), "%PDF-1.4");
  assert.equal(google.files.get(out.up.id)!.mimeType, "application/vnd.google-apps.spreadsheet");
  assert.equal(google.files.get(out.up.id)!.content, "a,b\n1,2");
  assert.deepEqual([out.folder.name, out.folder.parents], ["Rows", ["f2"]], "moved out of f1 into f2");
  assert.deepEqual(out.shared, { permissionId: "perm1", role: "writer" });
  assert.equal(out.trashed.trashed, true);
  assert.equal(google.files.has("pdf1"), false);
  google.files.set("bin1", { name: "photo.png", mimeType: "image/png", content: "png", parents: [], trashed: false });
  assert.match(failure(await execute(`async () => codemode.apps.drive.read_file({ account: "ada@example.com", id: "bin1" })`)), /not text; use download_file/);
});

test("Docs reads a document as text, tables tab-separated, and creates, appends to and replaces text in documents", async (t) => {
  const { run, google } = await workspace(t, "apps.docs");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    return {
      doc: await codemode.apps.docs.get_document({ ...a, id: "doc1" }),
      created: await codemode.apps.docs.create_document({ ...a, title: "Notes", text: "Hello" }),
      appended: await codemode.apps.docs.append_text({ ...a, id: "doc2", text: "\\nMore" }),
      replaced: await codemode.apps.docs.replace_text({ ...a, id: "doc2", find: "Hello", replace: "Hi" }),
    };
  }`);
  assert.deepEqual([out.doc.title, out.doc.text], ["Plan", "Goals\na\tb\n"]);
  assert.deepEqual(out.created, { id: "doc2", title: "Notes", url: "https://docs.google.com/document/d/doc2/edit" });
  assert.equal(out.replaced.replaced, 3);
  const updates = google.workspaceCalls.filter((c) => c.call.endsWith(":batchUpdate")).map((c) => JSON.parse(c.body).requests[0]);
  assert.deepEqual(updates, [
    { insertText: { location: { index: 1 }, text: "Hello" } },
    { insertText: { endOfSegmentLocation: {}, text: "\nMore" } },
    { replaceAllText: { containsText: { text: "Hello", matchCase: true }, replaceText: "Hi" } },
  ]);
});

test("Sheets reads, writes as if typed, appends rows, and creates spreadsheets", async (t) => {
  const { run, google } = await workspace(t, "apps.sheets");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    return {
      read: await codemode.apps.sheets.read_range({ ...a, id: "s1", range: "Sheet1!A1:B2" }),
      written: await codemode.apps.sheets.write_range({ ...a, id: "s1", range: "Sheet1!A2", values: [["grace", "=1+1"]] }),
      appended: await codemode.apps.sheets.append_rows({ ...a, id: "s1", range: "Sheet1", values: [["alan", 3]], raw: true }),
      created: await codemode.apps.sheets.create_spreadsheet({ ...a, title: "Budget", sheets: ["2026"] }),
    };
  }`);
  assert.deepEqual(out.read.values, [["name", "n"], ["ada", "1"]]);
  assert.deepEqual(out.written, { updatedRange: "Sheet1!A2", updatedCells: 2 });
  assert.deepEqual(out.appended, { updatedRange: "Sheet1!A3:B3", updatedRows: 1 });
  assert.deepEqual(out.created, { id: "s2", title: "Budget", url: "https://docs.google.com/spreadsheets/d/s2", sheets: ["2026"] });
  const write = google.workspaceCalls.find((c) => c.call.startsWith("PUT"))!;
  assert.equal(write.call, "PUT sheets/v4/spreadsheets/s1/values/Sheet1!A2");
  assert.equal(write.query.get("valueInputOption"), "USER_ENTERED");
  assert.equal(google.workspaceCalls.find((c) => c.call.endsWith(":append"))!.query.get("valueInputOption"), "RAW");
});

test("Contacts searches after warming Google's cache, creates contacts, and updates one with its etag", async (t) => {
  const { run, google } = await workspace(t, "apps.contacts");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    return {
      found: await codemode.apps.contacts.search_contacts({ ...a, query: "grace" }),
      created: await codemode.apps.contacts.create_contact({ ...a, name: "Alan Turing", emails: ["alan@example.com"] }),
      updated: await codemode.apps.contacts.update_contact({ ...a, resourceName: "people/c1", phones: ["+44 20 0000 0000"] }),
    };
  }`);
  assert.deepEqual(out.found.contacts, [{ resourceName: "people/c1", name: "Grace Hopper", emails: ["grace@example.com"], phones: [], organization: "Navy", title: "Rear Admiral" }]);
  assert.deepEqual(google.workspaceCalls.slice(0, 2).map((c) => c.query.get("query")), ["", "grace"]);
  assert.deepEqual([out.created.resourceName, out.created.name, out.created.emails], ["people/c2", "Alan Turing", ["alan@example.com"]]);
  const patch = google.workspaceCalls.find((c) => c.call.startsWith("PATCH"))!;
  assert.equal(patch.query.get("updatePersonFields"), "phoneNumbers");
  assert.deepEqual(JSON.parse(patch.body), { phoneNumbers: [{ value: "+44 20 0000 0000" }], etag: "etag-1" });
});

test("Slides reads a deck as text with notes, creates one, adds a slide and replaces text", async (t) => {
  const { run, calls } = await workspace(t, "apps.slides");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    return {
      deck: await codemode.apps.slides.get_presentation({ ...a, id: "p1" }),
      created: await codemode.apps.slides.create_presentation({ ...a, title: "Q4" }),
      slide: await codemode.apps.slides.add_slide({ ...a, id: "p2", title: "Why", body: "Because" }),
      replaced: await codemode.apps.slides.replace_text({ ...a, id: "p1", find: "Hello", replace: "Hi" }),
    };
  }`);
  assert.deepEqual(out.deck.slides, [{ id: "s1", index: 0, text: "Hello", notes: "Say hi" }]);
  assert.deepEqual(out.created, { id: "p2", title: "Q4", url: "https://docs.google.com/presentation/d/p2/edit" });
  assert.match(out.slide.id, /^axo_[0-9a-f]{32}$/);
  assert.equal(out.replaced.replaced, 2);
  assert.deepEqual(calls(), ["GET slides/v1/presentations/p1", "POST slides/v1/presentations", "POST slides/v1/presentations/p2:batchUpdate", "POST slides/v1/presentations/p1:batchUpdate"]);
});

test("Tasks lists lists and tasks, adds a dated task and completes it", async (t) => {
  const { run, google } = await workspace(t, "apps.tasks");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    return {
      lists: await codemode.apps.tasks.list_tasklists(a),
      tasks: await codemode.apps.tasks.list_tasks(a),
      created: await codemode.apps.tasks.create_task({ ...a, title: "Ship", due: "2026-11-04" }),
      done: await codemode.apps.tasks.update_task({ ...a, id: "k1", done: true }),
    };
  }`);
  assert.deepEqual(out.lists.tasklists, [{ id: "MDEy", title: "My Tasks", updated: "2026-10-30T10:00:00Z" }]);
  assert.equal(out.tasks.tasks[0].due, "2026-11-03");
  assert.deepEqual([out.created.title, out.created.due], ["Ship", "2026-11-04"]);
  assert.equal(out.done.status, "completed");
  const create = google.workspaceCalls.find((c) => c.call.startsWith("POST"))!;
  assert.equal(create.call, "POST tasks/tasks/v1/lists/@default/tasks");
  assert.equal(JSON.parse(create.body).due, "2026-11-04T00:00:00.000Z");
});

test("Meet creates a meeting, lists past ones, and reads a transcript with names", async (t) => {
  const { run } = await workspace(t, "apps.meet");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    return {
      created: await codemode.apps.meet.create_meeting({ ...a, accessType: "OPEN" }),
      meetings: await codemode.apps.meet.list_meetings({ ...a, meetingCode: "abc-mnop-xyz" }),
      transcript: await codemode.apps.meet.get_transcript({ ...a, meeting: "conferenceRecords/r1" }),
    };
  }`);
  assert.deepEqual([out.created.meetingUri, out.created.config], ["https://meet.google.com/abc-mnop-xyz", { accessType: "OPEN" }]);
  assert.equal(out.meetings.meetings[0].name, "conferenceRecords/r1");
  assert.deepEqual(out.transcript.transcripts, [{ name: "conferenceRecords/r1/transcripts/x1", state: "FILE_GENERATED", driveDocId: "doc9", text: "Grace: Shall we ship?\n", truncated: false }]);
});

test("Google Cloud lists projects and queries BigQuery billed to the project named", async (t) => {
  const { run, google } = await workspace(t, "apps.cloud");
  const out = await run(`async () => {
    const a = { account: "ada@example.com" };
    return {
      projects: await codemode.apps.cloud.list_projects(a),
      query: await codemode.apps.cloud.query_bigquery({ ...a, project: "axo-dev", sql: "select 7" }),
    };
  }`);
  assert.deepEqual(out.projects.projects, [{ projectId: "axo-dev", displayName: "Axo", number: "42", state: "ACTIVE", parent: null }]);
  assert.deepEqual(out.query.rows, [{ n: 7, who: { name: "ada" }, tags: ["a", "b"] }]);
  const query = google.workspaceCalls.find((c) => c.call.startsWith("POST bigquery"))!;
  assert.equal(query.headers.get("x-goog-user-project"), "axo-dev");
  assert.equal(JSON.parse(query.body).useLegacySql, false);
});

test("every app's request tool reaches any endpoint of its own API, and only its own", async (t) => {
  const { run, execute, google, call } = await workspace(t, "apps.tasks");
  const listed = await run(`async () => codemode.apps.tasks.request({ account: "ada@example.com", method: "GET", path: "/tasks/v1/users/@me/lists", query: { maxResults: "5" } })`);
  assert.deepEqual(listed, { status: 200, contentType: "application/json", json: { items: [{ id: "MDEy", title: "My Tasks", updated: "2026-10-30T10:00:00Z" }] }, truncated: false });
  assert.equal(google.workspaceCalls.at(-1)!.query.get("maxResults"), "5");
  for (const path of ["https://example.com/steal", "https://gmail.googleapis.com/gmail/v1/users/me/profile", "http://tasks.googleapis.com/tasks/v1/users/@me/lists", "https://tasks.googleapis.com.example.com/x"]) {
    const refused = failure(await execute(`async () => codemode.apps.tasks.request({ account: "ada@example.com", method: "GET", path: ${JSON.stringify(path)} })`));
    assert.match(refused, /calls only reach tasks\.googleapis\.com/, path);
  }
  const header = failure(await execute(`async () => codemode.apps.tasks.request({ account: "ada@example.com", method: "GET", path: "/x", headers: { Authorization: "Bearer mine" } })`));
  assert.match(header, /set by Axo/);
  assert.equal(google.workspaceCalls.length, 1, "nothing refused went out");

  // Each app's activity is its own.
  const log = async (service?: string) => result(await call("axo.connections.log", service ? { service } : {}));
  const tasks = (await log("apps.tasks")).records as Array<{ service: string }>;
  assert.ok(tasks.length >= 1 && tasks.every((r) => r.service === "apps.tasks"));
  assert.deepEqual((await log("apps.gmail")).records, []);
});

test("the call log is a hash chain: it verifies as written, and an edited, removed or added call breaks it", async (t) => {
  const { h, session, execute } = await signedIn(t);
  for (const id of ["m1", "m2"]) await execute(`async () => codemode.apps.gmail.get_message({ account: "ada@example.com", id: "${id}" })`);
  await execute(`async () => codemode.apps.gmail.get_message({ account: "nobody@example.com", id: "m1" })`).catch(() => undefined);
  const integrity = async () => (await (await fetch(new URL("api/v1/account/connections/log/integrity", h.url), { headers: session.headers })).json()) as
    { verified: boolean; events: number; head: string | null; reason: string | null };
  const clean = await integrity();
  assert.equal(clean.verified, true, clean.reason ?? "");
  assert.equal(clean.events, 6, "a start and a finish for each of three calls");
  assert.match(clean.head!, /^[0-9a-f]{64}$/);

  const { DatabaseSync } = await import("node:sqlite");
  const { readdir } = await import("node:fs/promises");
  const { join } = await import("node:path");
  const tamper = (sql: string) => h.restart(async () => {
    const files = (await readdir(h.storagePath, { recursive: true })).filter((f) => f.endsWith(".sqlite")).map((f) => join(h.storagePath, f));
    let touched = 0;
    for (const file of files) {
      const db = new DatabaseSync(file);
      const has = db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = 'call_chain'").get() as { n: number };
      if (has.n) {
        db.exec(sql);
        touched++;
      }
      db.close();
    }
    assert.equal(touched, 1);
  });

  // Changing what a call did, in the log, no longer matches its finish.
  await tamper("UPDATE connection_calls SET outcome = 'ok', error = NULL WHERE outcome = 'error'");
  assert.deepEqual([(await integrity()).verified, (await integrity()).reason?.includes("outcome was changed")], [false, true]);
  await tamper("UPDATE connection_calls SET outcome = 'error', error = (SELECT json_extract(body, '$.error') FROM call_chain WHERE json_extract(body, '$.outcome') = 'error') WHERE call_id = (SELECT call_id FROM call_chain WHERE json_extract(body, '$.outcome') = 'error')");
  assert.equal((await integrity()).verified, true, "put back, it verifies again");

  // Rewriting an event's contents breaks its hash; dropping one breaks the sequence.
  await tamper("UPDATE call_chain SET body = replace(body, '\"tool\":\"get_message\"', '\"tool\":\"get_profile\"') WHERE seq = 3");
  assert.deepEqual([(await integrity()).verified, (await integrity()).reason], [false, "its contents were changed"]);
  await tamper("DELETE FROM call_chain WHERE seq = 3");
  assert.deepEqual([(await integrity()).verified, (await integrity()).reason], [false, "event 3 is missing"]);
});

test("a call logged while the chain is cut past 30 days still verifies from the anchor", async (t) => {
  const { h, session, execute } = await signedIn(t);
  await execute(`async () => codemode.apps.gmail.get_profile({ account: "ada@example.com" })`);
  const { DatabaseSync } = await import("node:sqlite");
  const { readdir } = await import("node:fs/promises");
  const { join } = await import("node:path");
  await h.restart(async () => {
    for (const file of (await readdir(h.storagePath, { recursive: true })).filter((f) => f.endsWith(".sqlite")).map((f) => join(h.storagePath, f))) {
      const db = new DatabaseSync(file);
      const has = db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = 'call_chain'").get() as { n: number };
      // As if the first call was made 31 days ago: its events' times are part of their hashes, so the chain is rebuilt as it would have been.
      if (has.n) db.exec("UPDATE connection_calls SET at = at - 31 * 86400000; DELETE FROM call_chain;");
      db.close();
    }
  });
  await execute(`async () => codemode.apps.gmail.get_profile({ account: "ada@example.com" })`);
  const check = (await (await fetch(new URL("api/v1/account/connections/log/integrity", h.url), { headers: session.headers })).json()) as { verified: boolean; events: number; reason: string | null };
  assert.deepEqual([check.verified, check.events], [true, 2], check.reason ?? "");
});
