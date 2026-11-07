import assert from "node:assert/strict";
import { test } from "node:test";
import { appsResults } from "@axo/protocol";
import { cookiePair, harness, signIn, type AccountSession, type Harness } from "./harness";
import { connectHost, pairHost } from "./account-support";
import { FakeMcp } from "./fake-mcp";
import { iconsIn } from "../src/apps/site-icon";

/**
 * RFD0016, third-party apps: an agent adds a remote MCP server, the person signs in to it
 * in a browser signed in to their Axo account, and scripts call its tools from the cloud with a
 * grant that never leaves the account's Durable Object.
 */

type Reply = { result: unknown } | { error: { code: number; message: string } };

async function fixture(t: { after(fn: () => unknown): void }) {
  const server = new FakeMcp();
  const h = await harness({ outbound: (request) => server.handle(request) });
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session, "Studio");
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const sessionId = crypto.randomUUID();
  const call = (method: string, params: Record<string, unknown> = {}) => daemon.call(method, { sessionId, ...params }) as Promise<Reply>;
  return { server, h, session, call };
}

function result(reply: Reply): any {
  assert.ok("result" in reply, JSON.stringify(reply));
  return reply.result;
}

/** What a browser signed in as `session` does with a sign-in link: returns the provider's redirect back. */
async function signInThroughBrowser(h: Harness, server: FakeMcp, session: AccountSession, signInUrl: string) {
  const start = await fetch(new URL(signInUrl.replace("https://axo.leostera.dev/", ""), h.url), { headers: { Cookie: session.headers.Cookie! }, redirect: "manual" });
  assert.equal(start.status, 302, await start.text());
  const flowCookie = cookiePair(start, "__Host-axo_connection");
  assert.ok(flowCookie);
  const back = server.approve(start.headers.get("location")!);
  const callback = await fetch(new URL(`${back.pathname.slice(1)}${back.search}`, h.url), {
    headers: { Cookie: `${session.headers.Cookie}; ${flowCookie}` },
    redirect: "manual",
  });
  assert.equal(callback.status, 302);
  return new URL(callback.headers.get("location")!);
}

test("an agent adds a server that needs sign-in, the person signs in, and a script calls its tools with the grant", async (t) => {
  const { server, h, session, call } = await fixture(t);
  const added = appsResults["axo.apps.add"].parse(result(await call("axo.apps.add", { name: "linear", url: server.url })));
  assert.equal(added.connection.state, "needsSignIn");
  assert.match(added.signInUrl!, /^https:\/\/axo\.leostera\.dev\/api\/v1\/connections\/oauth\/start\?flow=/);
  assert.equal(server.clients.size, 1, "Axo registered itself as a client");

  const landed = await signInThroughBrowser(h, server, session, added.signInUrl!);
  assert.equal(landed.pathname, "/app/settings/apps/mcp");
  assert.equal(landed.searchParams.get("signedIn"), "linear", landed.toString());

  // Tools are listed after sign-in; names become identifiers, and keep their upstream title.
  const found = await waitForTools(call);
  assert.deepEqual(found, [
    { service: "hosts", name: "list" },
    { service: "bash", name: "run" },
    { service: "computer", name: "run" },
    { service: "linear", name: "list_issues", title: "list-issues" },
    { service: "linear", name: "create_issue", title: "create_issue" },
  ]);

  const executed = result(await call("axo.apps.run", { code: `async () => codemode.linear.list_issues({ team: "AXO" })` }));
  assert.deepEqual(executed.result, { tool: "list-issues", args: { team: "AXO" } });
  assert.equal(server.calls.length, 1);
  assert.ok(server.calls[0]!.token, "the call carried the account's grant");

  // The grant stays in the cloud: nothing a Mac or the web reads contains it.
  const listed = await fetch(new URL("api/v1/account/apps", h.url), { headers: session.headers });
  const listedText = await listed.text();
  const logText = JSON.stringify(result(await call("axo.apps.log")));
  for (const text of [listedText, logText, JSON.stringify(executed), JSON.stringify(result(await call("axo.apps.list")))])
    assert.equal(server.leaks(text), false);
  assert.deepEqual(JSON.parse(listedText).apps.filter((c: { kind: string }) => c.kind !== "app").map((c: { name: string; state: string }) => [c.name, c.state]), [["studio", "online"], ["linear", "ready"]]);
  assert.match(logText, /"service":"linear","tool":"list_issues"/);
});

test("a sign-in link works once, only in a browser signed in to the same account, and only with its flow cookie", async (t) => {
  const { server, h, session, call } = await fixture(t);
  const added = result(await call("axo.apps.add", { name: "linear", url: server.url }));
  const path = added.signInUrl.replace("https://axo.leostera.dev/", "");

  // Not signed in to Axo: nothing happens.
  const anonymous = await fetch(new URL(path, h.url), { redirect: "manual" });
  assert.equal(anonymous.status, 401);
  // Signed in to another account: the link is not theirs.
  const stranger = await signIn(h, "a-stranger");
  const theirs = await fetch(new URL(path, h.url), { headers: { Cookie: stranger.headers.Cookie! }, redirect: "manual" });
  assert.equal(theirs.status, 410);

  // The right browser starts; a callback without its flow cookie is refused.
  const start = await fetch(new URL(path, h.url), { headers: { Cookie: session.headers.Cookie! }, redirect: "manual" });
  assert.equal(start.status, 302);
  const back = server.approve(start.headers.get("location")!);
  const noCookie = await fetch(new URL(`${back.pathname.slice(1)}${back.search}`, h.url), { headers: { Cookie: session.headers.Cookie! }, redirect: "manual" });
  assert.ok(new URL(noCookie.headers.get("location")!).searchParams.get("error"));
  // The code was not spent by the refused callback, but the link itself is used up.
  const again = await fetch(new URL(path, h.url), { headers: { Cookie: session.headers.Cookie! }, redirect: "manual" });
  assert.equal(again.status, 410);
  assert.equal(server.tokenRequests.length, 0);
});

test("a grant about to expire is renewed before the call, and the rotated refresh token is used once", async (t) => {
  const { server, h, session, call } = await fixture(t);
  server.tokenLifetime = 30; // inside the renewal margin
  const added = result(await call("axo.apps.add", { name: "linear", url: server.url }));
  await signInThroughBrowser(h, server, session, added.signInUrl);
  await waitForTools(call);
  const before = server.tokenRequests.filter((f) => f.get("grant_type") === "refresh_token").length;
  result(await call("axo.apps.run", { code: `async () => codemode.linear.create_issue({ title: "a" })` }));
  const refreshes = server.tokenRequests.filter((f) => f.get("grant_type") === "refresh_token").length;
  assert.ok(refreshes > before, "the grant was renewed");
  assert.equal(server.calls.length, 1);
});

test("a server that needs no sign-in is ready at once; a Mac's name is free for a server, the namespaces are not", async (t) => {
  const { server, call } = await fixture(t);
  server.requireAuth = false;
  const added = result(await call("axo.apps.add", { name: "docs", url: server.url }));
  assert.deepEqual([added.connection.state, added.signInUrl, added.connection.tools], ["ready", null, 2]);
  const taken = await call("axo.apps.add", { name: "computer", url: server.url });
  assert.ok("error" in taken && taken.error.code === -32022, JSON.stringify(taken));
  // Macs are reached as bash.run({ host }), not by name, so a server may be called "studio".
  const studio = result(await call("axo.apps.add", { name: "studio", url: server.url }));
  assert.equal(studio.connection.name, "studio");
  assert.deepEqual(result(await call("axo.apps.remove", { name: "studio" })), { removed: true });
  assert.deepEqual(result(await call("axo.apps.remove", { name: "docs" })), { removed: true });
  const gone = await call("axo.apps.run", { code: `async () => codemode.docs.list_issues({})` });
  assert.ok("error" in gone && /no connection named docs/.test(gone.error.message), JSON.stringify(gone));
});

test("a server is added under any name, reached by its slug, and may be added again under another, each signing in on its own", async (t) => {
  const { server, h, session, call } = await fixture(t);
  const first = result(await call("axo.apps.add", { name: "emdash: leostera.com", url: server.url }));
  assert.deepEqual([first.connection.name, first.connection.title], ["emdash_leostera_com", "emdash: leostera.com"]);
  const second = result(await call("axo.apps.add", { name: "Emdash — ocaml.ai", url: server.url }));
  assert.deepEqual([second.connection.name, second.connection.title], ["emdash_ocaml_ai", "Emdash — ocaml.ai"]);
  assert.notEqual(first.signInUrl, second.signInUrl, "each has its own sign-in");
  assert.equal(server.clients.size, 2, "and its own client");
  const taken = await call("axo.apps.add", { name: "Emdash: leostera.com!", url: server.url });
  assert.ok("error" in taken && /emdash_leostera_com already exists \(the name of "Emdash: leostera.com!"\); choose another name/.test(taken.error.message), JSON.stringify(taken));
  const empty = await call("axo.apps.add", { name: " — ", url: server.url });
  assert.ok("error" in empty && /a letter or a digit/.test(empty.error.message), JSON.stringify(empty));
  const plain = result(await call("axo.apps.add", { name: "linear", url: server.url }));
  assert.deepEqual([plain.connection.name, plain.connection.title], ["linear", null], "a name that is already its slug keeps no title");

  await signInThroughBrowser(h, server, session, first.signInUrl);
  await waitForTools(call);
  const executed = result(await call("axo.apps.run", { code: `async () => (await codemode.emdash_leostera_com.list_issues({ team: "AXO" })).tool` }));
  assert.equal(executed.result, "list-issues");
  const listed = result(await call("axo.apps.list")).apps.filter((c: { kind: string }) => c.kind === "thirdParty").map((c: { name: string; state: string }) => [c.name, c.state]);
  assert.deepEqual(listed, [["emdash_leostera_com", "ready"], ["emdash_ocaml_ai", "needsSignIn"], ["linear", "needsSignIn"]]);
});

test("a server whose tools answer 401 says so on its page and to the agent, until a call works again", async (t) => {
  const { server, call } = await fixture(t);
  server.requireAuth = false;
  result(await call("axo.apps.add", { name: "paypal", url: server.url }));
  const state = async () => {
    const listed = result(await call("axo.apps.list")).apps.find((c: { name: string }) => c.name === "paypal");
    return [listed.state, listed.lastError];
  };
  server.upstreamRefuses = true;
  const refused = await call("axo.apps.run", { code: `async () => codemode.paypal.list_issues({})` });
  assert.ok("error" in refused, JSON.stringify(refused));
  assert.match(refused.error.message, /401 Unauthorized/);
  assert.match(refused.error.message, /signs in to paypal again: remove it at https:\/\/axo\.leostera\.dev\/app\/settings\/apps\/mcp and add it back/);
  assert.deepEqual(await state(), ["ready", "its tools answered Unauthorized: Failed to fetch transactions: 401 Unauthorized"]);
  server.upstreamRefuses = false;
  result(await call("axo.apps.run", { code: `async () => codemode.paypal.list_issues({})` }));
  assert.deepEqual(await state(), ["ready", null], "a call that works clears it");
});

async function waitForTools(call: (method: string, params?: Record<string, unknown>) => Promise<Reply>) {
  for (let i = 0; i < 50; i++) {
    const found = result(await call("axo.apps.search", {
      // Apps that need no client of Axo's (Hetzner) are always listed; these tests are about servers.
      code: `async () => codemode.tools().filter((t) => !t.service.startsWith("apps.")).map((t) => ["hosts", "bash", "computer"].includes(t.service) ? { service: t.service, name: t.name } : { service: t.service, name: t.name, title: t.title })`,
    })).result as Array<{ service: string }>;
    if (found.some((t) => !["hosts", "bash", "computer"].includes(t.service))) return found;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error("the tool list never arrived");
}

test("a server's tile shows the icon it names for itself, or else the one its site declares", async (t) => {
  const named = new FakeMcp("mcp.linear.test");
  named.requireAuth = false;
  named.serverIcons = [{ src: "https://linear.test/icon.svg", mimeType: "image/svg+xml" }];
  const plain = new FakeMcp("mcp.notion.test");
  plain.requireAuth = false;
  const sites: string[] = [];
  const h = await harness({
    outbound: async (request) => {
      const url = new URL(request.url);
      if (url.hostname === "notion.test") {
        sites.push(url.pathname);
        if (url.pathname === "/") return new Response(`<html><head><link rel="icon" href="/front-static/favicon.ico"><link rel="apple-touch-icon" href="/front-static/logo-ios.png"></head></html>`, { headers: { "Content-Type": "text/html; charset=utf-8" } });
        return new Response("not found", { status: 404 });
      }
      if (url.hostname === "linear.test") sites.push(`linear${url.pathname}`);
      return (await named.handle(request)) ?? plain.handle(request);
    },
  });
  t.after(() => h.close());
  const session = await signIn(h);
  const host = await pairHost(h, session, "Studio");
  const daemon = await connectHost(h, session, host);
  t.after(() => daemon.close());
  const call = (method: string, params: Record<string, unknown> = {}) => daemon.call(method, { sessionId: crypto.randomUUID(), ...params }) as Promise<Reply>;
  result(await call("axo.apps.add", { name: "linear", url: named.url }));
  result(await call("axo.apps.add", { name: "notion", url: plain.url }));
  let icons: Record<string, string | null> = {};
  for (let i = 0; i < 50; i++) {
    const listed = appsResults["axo.apps.list"].parse(result(await call("axo.apps.list"))).apps;
    icons = Object.fromEntries(listed.flatMap((c) => (c.kind === "thirdParty" ? [[c.name, c.icon]] : [])));
    if (icons.linear && icons.notion) break;
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.deepEqual(icons, { linear: "https://linear.test/icon.svg", notion: "https://notion.test/front-static/logo-ios.png" });
  assert.ok(!sites.some((s) => s.startsWith("linear")), "a server that names its icon is not asked for its site");
});

test("a page's icons: an Apple touch icon first, then SVG, then PNG, then any; only https", () => {
  const base = "https://example.test/start";
  assert.equal(iconsIn(`<link rel="icon" href="/a.ico"><link rel="icon" type="image/png" href="b.png"><link rel="icon" href='/c.svg'>`, base), "https://example.test/c.svg");
  assert.equal(iconsIn(`<link href="/x.png" rel="apple-touch-icon" sizes="180x180"><link rel="icon" href="/c.svg">`, base), "https://example.test/x.png");
  assert.equal(iconsIn(`<link rel="shortcut icon" href="/f.ico?v=1&amp;x=2">`, base), "https://example.test/f.ico?v=1&x=2");
  assert.equal(iconsIn(`<link rel="icon" href="http://insecure.test/i.png"><link rel="stylesheet" href="/s.css">`, base), null);
  assert.equal(iconsIn(`<link rel="icon" href="javascript:alert(1)">`, base), null);
});
