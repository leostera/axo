import { createHash, createHmac } from "node:crypto";
import assert from "node:assert/strict";
import { test } from "node:test";
import { appMacSignInSchema, appSignInSchema } from "@axo/protocol";
import { AppAccountRefused, BuiltinApps, type MacSignInCallback } from "../src/apps/builtin";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, Kraken's sign-in on the person's Mac: kraken-cli's public client redirects only to
 * localhost, so axod waits on the redirect port and this Durable Object, which keeps the PKCE
 * verifier, redeems the code and creates a Fast API key with only the permissions chosen.
 */

const CLIENT_ID = "230dc4f672711a31e0ae01db611cf68c";
const b64url = (bytes: Buffer) => bytes.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Kraken's OAuth, Fast API key and private API, checking what Kraken checks. */
class FakeKraken {
  challenges = new Map<string, { challenge: string; scope: string; redirectUri: string }>();
  keys = new Map<string, { key: string; secret: string; permissions: Record<string, boolean>; validUntil: number }>();
  deleted: string[] = [];
  grantScope: ((asked: string) => string) | null = null;
  accessTokens = new Set<string>();
  refreshed = 0;
  /** Every request's URL, headers and body, to check no secret leaks. */
  seen: Array<{ url: string; body: string }> = [];

  /** What the person's browser does at Kraken's sign-in page: approve, and be sent to the redirect. */
  approve(authorizeUrl: string, redirectUri: string): string {
    const url = new URL(authorizeUrl);
    assert.equal(url.origin + url.pathname, "https://www.kraken.com/oauth/authorize");
    assert.equal(url.searchParams.get("client_id"), CLIENT_ID);
    assert.equal(url.searchParams.get("response_type"), "code");
    assert.equal(url.searchParams.get("code_challenge_method"), "S256");
    assert.equal(url.searchParams.get("redirect_uri"), null, "axod adds the redirect for the port it got");
    const code = `code-${crypto.randomUUID()}`;
    this.challenges.set(code, { challenge: url.searchParams.get("code_challenge")!, scope: url.searchParams.get("scope")!, redirectUri });
    return code;
  }

  fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const body = request.body ? await request.text() : "";
    this.seen.push({ url: request.url, body });
    const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
    if (url.href === "https://api.kraken.com/oauth/token") {
      const form = new URLSearchParams(body);
      assert.equal(form.get("client_id"), CLIENT_ID);
      assert.equal(request.headers.get("Authorization"), null, "a public client sends no secret");
      if (form.get("grant_type") === "refresh_token") {
        if (form.get("refresh_token") !== "refresh-1") return json({ error: "invalid_grant" }, 400);
        this.refreshed++;
        this.accessTokens.add("access-2");
        return json({ access_token: "access-2", token_type: "Bearer", expires_in: 14400, refresh_token: "refresh-2" });
      }
      const flow = this.challenges.get(form.get("code") ?? "");
      if (!flow) return json({ error: "invalid_grant" }, 400);
      this.challenges.delete(form.get("code")!);
      const proof = b64url(createHash("sha256").update(form.get("code_verifier") ?? "").digest());
      if (proof !== flow.challenge || form.get("redirect_uri") !== flow.redirectUri) return json({ error: "invalid_grant", error_description: "PKCE or redirect mismatch" }, 400);
      this.accessTokens.add("access-1");
      return json({ access_token: "access-1", token_type: "Bearer", expires_in: 14400, refresh_token: "refresh-1", scope: this.grantScope ? this.grantScope(flow.scope) : flow.scope });
    }
    if (url.href === "https://api.kraken.com/oauth/fast-api-key") {
      const token = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
      if (!this.accessTokens.has(token)) return json({ error: ["EOAuth:Invalid token"] }, 401);
      const sent = JSON.parse(body) as { api_key_name: string; permissions?: Record<string, boolean>; valid_until?: number };
      if (request.method === "DELETE") {
        this.deleted.push(sent.api_key_name);
        this.keys.delete(sent.api_key_name);
        return json({ error: [], result: { count: 1 } });
      }
      const key = { key: `key-${sent.api_key_name}`, secret: Buffer.from(`secret-of-${sent.api_key_name}`).toString("base64"), permissions: sent.permissions ?? {}, validUntil: sent.valid_until! };
      this.keys.set(sent.api_key_name, key);
      return json({ error: [], result: { api_key_name: sent.api_key_name, api_key: key.key, secret: key.secret, permissions: key.permissions, valid_until: key.validUntil } });
    }
    if (url.pathname.startsWith("/0/private/")) {
      const form = new URLSearchParams(body);
      const key = [...this.keys.values()].find((k) => k.key === request.headers.get("API-Key"));
      const expected = key && createHmac("sha512", Buffer.from(key.secret, "base64"))
        .update(Buffer.concat([Buffer.from(url.pathname), createHash("sha256").update(form.get("nonce") + body).digest()])).digest("base64");
      if (!key || request.headers.get("API-Sign") !== expected) return json({ error: ["EAPI:Invalid key"] });
      if (url.pathname === "/0/private/BalanceEx") return json({ error: [], result: { ZEUR: { balance: "120.50" } } });
    }
    return json({ error: ["EGeneral:Unknown method"] }, 404);
  }) as typeof fetch;
}

function fixture(options: { macAnswer?: (request: { authorizeUrl: string; ports: readonly number[]; path: string; state: string }) => MacSignInCallback | Promise<MacSignInCallback> } = {}) {
  const kraken = new FakeKraken();
  const background: Promise<unknown>[] = [];
  let now = Date.parse("2026-05-01T12:00:00Z");
  const macRequests: Array<{ mac: string; authorizeUrl: string; ports: readonly number[]; path: string; state: string; timeoutMs: number }> = [];
  const apps = new BuiltinApps({
    sql: sqlStorage(),
    secret: "test-secret-of-at-least-thirty-two-bytes",
    accountId: crypto.randomUUID(),
    fetcher: kraken.fetch,
    waitUntil: (promise) => background.push(promise),
    now: () => now,
    macs: () => ["studio"],
    // axod: the person approves in the browser, and the first free port gets the redirect.
    signInOnMac: async (mac, request) => {
      macRequests.push({ mac, ...request });
      if (options.macAnswer) return options.macAnswer(request);
      const redirectUri = `http://localhost:${request.ports[0]}${request.path}`;
      return { redirectUri, code: kraken.approve(request.authorizeUrl, redirectUri) };
    },
  });
  const settle = async () => {
    while (background.length) await background.shift();
  };
  return { apps, kraken, macRequests, settle, advance: (ms: number) => (now += ms), now: () => now };
}

test("Kraken offers a sign-in on a Mac beside pasting a key, with read-only and trading choices", () => {
  const { apps } = fixture();
  const kraken = apps.list().find((c) => c.name === "apps.kraken");
  assert.equal(kraken?.kind, "app");
  const signIn = appSignInSchema.parse(kraken?.kind === "app" ? kraken.signIn : null);
  assert.equal(signIn.kind, "token");
  assert.deepEqual(signIn.kind === "token" && signIn.mac?.presets.map((p) => p.id), ["read", "trade"]);
});

test("signing in on a Mac creates a key with only the permissions chosen, for 90 days, and its calls are signed with it", async () => {
  const { apps, kraken, macRequests, settle } = fixture();
  const started = await apps.startMacSignIn("kraken", "studio", "read", "Main");
  assert.equal(started.state, "pending");
  await settle();
  // The Mac waits on kraken-cli's registered ports, and only ever sees the authorize URL.
  assert.deepEqual(macRequests[0].ports, [27461, 27462, 27463]);
  assert.equal(macRequests[0].path, "/callback");
  assert.match(macRequests[0].authorizeUrl, new RegExp(`state=${macRequests[0].state}`));
  const done = appMacSignInSchema.parse(apps.pollMacSignIn("kraken", started.flow));
  assert.deepEqual(done, { state: "done", account: "main", expiresAt: "2026-07-30T12:00:00.000Z" });
  const [key] = [...kraken.keys.values()];
  assert.deepEqual(key.permissions, { funds_query: true, trades_query_open: true, trades_query_closed: true, ledger_query: true, export_data: true });
  assert.equal(Object.keys(key.permissions).some((p) => p.startsWith("withdraw")), false);
  assert.deepEqual(await apps.call("kraken", "get_balance", { account: "main" }), { ZEUR: { balance: "120.50" } });
  // The scope Kraken was asked for names exactly the key's permissions.
  const asked = new URL(macRequests[0].authorizeUrl).searchParams.get("scope")!.split(" ");
  assert.deepEqual(asked, ["account.fast-api-key:write", "account.fast-api-key:funds-query", "account.fast-api-key:trades-query-open",
    "account.fast-api-key:trades-query-closed", "account.fast-api-key:ledger-query", "account.fast-api-key:export-data"]);
});

test("the trading choice adds order permissions, and the key expires with Kraken's 90-day limit", async () => {
  const { apps, kraken, settle, advance } = fixture();
  const started = await apps.startMacSignIn("kraken", "studio", "trade", "trading");
  await settle();
  assert.equal(apps.pollMacSignIn("kraken", started.flow).state, "done");
  const [key] = [...kraken.keys.values()];
  assert.equal(key.permissions.trades_modify, true);
  assert.equal(key.permissions.trades_close, true);
  advance(91 * 86_400_000);
  await assert.rejects(apps.call("kraken", "get_balance", { account: "trading" }), /key expired on 2026-07-30; sign in again/);
});

test("a declined sign-in, or one Kraken granted other permissions for, keeps nothing and creates no key", async () => {
  const declined = fixture({ macAnswer: (r) => ({ redirectUri: `http://localhost:${r.ports[0]}${r.path}`, error: "access_denied" }) });
  const started = await declined.apps.startMacSignIn("kraken", "studio", "read", "main");
  await declined.settle();
  assert.deepEqual(declined.apps.pollMacSignIn("kraken", started.flow), { state: "failed", error: "The sign-in was declined at Kraken." });

  const narrowed = fixture();
  narrowed.kraken.grantScope = (asked) => asked.replace(" account.fast-api-key:export-data", "");
  const flow = await narrowed.apps.startMacSignIn("kraken", "studio", "read", "main");
  await narrowed.settle();
  const outcome = narrowed.apps.pollMacSignIn("kraken", flow.flow);
  assert.equal(outcome.state, "failed");
  assert.match(outcome.state === "failed" ? outcome.error : "", /missing account\.fast-api-key:export-data/);
  assert.equal(narrowed.kraken.keys.size, 0);
  assert.deepEqual(narrowed.apps.accounts("kraken"), []);
});

test("removing the account deletes its key at Kraken, renewing the OAuth token once it has expired", async () => {
  const { apps, kraken, settle, advance } = fixture();
  await apps.startMacSignIn("kraken", "studio", "read", "main");
  await settle();
  const [name] = [...kraken.keys.keys()];
  advance(5 * 3600_000);
  assert.equal(await apps.disconnect("kraken", "main"), true);
  await settle();
  assert.equal(kraken.refreshed, 1);
  assert.deepEqual(kraken.deleted, [name]);
  // Nothing secret went in a URL.
  assert.ok(kraken.seen.every((s) => !/secret|code-|access-/.test(new URL(s.url).search)));
});

test("a sign-in on a Mac is refused for an unknown Mac or choice, a missing name, and a second one at once", async () => {
  const { apps } = fixture({ macAnswer: () => new Promise<MacSignInCallback>(() => undefined) });
  await assert.rejects(apps.startMacSignIn("kraken", "laptop", "read", "main"), AppAccountRefused);
  await assert.rejects(apps.startMacSignIn("kraken", "studio", "withdraw", "main"), /no choice named withdraw/);
  await assert.rejects(apps.startMacSignIn("kraken", "studio", "read", null), /Name this account/);
  await assert.rejects(apps.startMacSignIn("hetzner", "studio", "read", "main"), /does not sign in on a Mac/);
  await apps.startMacSignIn("kraken", "studio", "read", "main");
  await assert.rejects(apps.startMacSignIn("kraken", "studio", "read", "other"), /already waiting on studio/);
});
