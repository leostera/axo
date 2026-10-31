import assert from "node:assert/strict";
import { test } from "node:test";
import { connectionSchema, type AppName } from "@axo/protocol";
import { AppConnections } from "../src/connections/apps";
import type { OAuthClients } from "../src/connections/apps/oauth-provider";
import { appClients } from "../src/connections/apps/providers";
import type { FakeOAuth } from "./fake-oauth";
import { FakeGitHub } from "./fake-github";
import { sqlStorage } from "./sql-storage";

/**
 * RFD0016, OAuth apps of providers other than Google: each signs in with Axo's own client for its
 * provider (set on the Worker), through the same flow as Google's. Each provider's quirks are in
 * its config: how it authenticates the token request, reads its answer, rotates refresh tokens and
 * names the account. The HTTP side of the flow (start page, cookie, callback) is Google's, tested
 * in apps.test.ts; here the flow is driven on AppConnections itself.
 */

type Fake = { oauth: FakeOAuth; handle(request: Request): Promise<Response | undefined> };

function fixture<F extends Fake>(fake: F, provider: keyof OAuthClients) {
  let clock = Date.parse("2026-10-31T12:00:00Z");
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const answer = await fake.handle(request);
    if (!answer) throw new Error(`unexpected request to ${request.url}`);
    return answer;
  }) as typeof fetch;
  const background: Promise<unknown>[] = [];
  const apps = new AppConnections({
    sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(),
    clients: { [provider]: { clientId: fake.oauth.clientId, clientSecret: fake.oauth.clientSecret } }, fetcher, waitUntil: (p) => background.push(p), now: () => clock,
  });
  /** The person adds an account: Axo's link, the provider's consent page, and back to the callback. */
  const signIn = async (app: AppName, person = "ada") => {
    const link = new URL(await apps.signInLink(app));
    const nonce = link.searchParams.get("flow")!;
    const opened = await apps.openFlow(nonce);
    assert.ok(opened);
    fake.oauth.person = person;
    const back = fake.oauth.approve(opened.authorizeUrl);
    return apps.completeFlow(nonce, back.searchParams.get("code")!);
  };
  return { fake, apps, signIn, tick: (ms: number) => { clock += ms; }, settled: () => Promise.all(background) };
}

async function refused(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    return (error as Error).message;
  }
  assert.fail("expected a refusal");
}

test("each provider's client comes from its own Worker variables, and an app is listed only with its provider's", () => {
  assert.deepEqual(appClients({ GITHUB_CLIENT_ID: "id", GITHUB_CLIENT_SECRET: "secret", GOOGLE_CLIENT_ID: "g" }), { github: { clientId: "id", clientSecret: "secret" } });
  const { apps } = fixture(new FakeGitHub(), "github");
  const names = apps.list().map((c) => c.name);
  assert.ok(names.includes("apps.github"));
  assert.ok(!names.includes("apps.gmail"), "Google's apps need Google's client");
  const bare = new AppConnections({ sql: sqlStorage(), secret: "test-secret-of-at-least-thirty-two-bytes", accountId: crypto.randomUUID(), clients: {}, fetcher: fetch, waitUntil: () => undefined });
  assert.ok(!bare.list().some((c) => c.name === "apps.github"), "without GitHub's client, GitHub is not listed");
});

test("GitHub signs in with Axo's OAuth app, is named by the login, and its tools all need an account", async () => {
  const { apps, fake, signIn } = fixture(new FakeGitHub(), "github");
  const github = connectionSchema.parse(apps.list().find((c) => c.name === "apps.github"));
  assert.ok(github.kind === "app");
  assert.deepEqual([github.provider, github.signIn, github.state], ["GitHub", { kind: "oauth" }, "needsSignIn"]);
  assert.deepEqual(github.tools, ["get_me", "list_repos", "search", "list_issues", "get_issue", "create_issue", "comment", "get_pull", "get_file", "list_notifications", "request"]);
  assert.ok(apps.tools().filter((t) => t.service === "apps.github").every((t) => (t.inputSchema.required as string[])[0] === "account"));
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /^needs sign-in: https:\/\/axo\.leostera\.dev\/api\/v1\/connections\/oauth\/start\?flow=/);

  assert.deepEqual(await signIn("github"), { name: "apps.github" });
  const asked = fake.oauth.authorizeUrls[0]!;
  assert.equal(asked.searchParams.get("scope"), "repo read:org notifications", "only what its tools use");
  assert.equal(asked.searchParams.get("prompt"), "select_account", "a second account can be picked");
  const redeemed = fake.oauth.tokenRequests[0]!;
  assert.equal(redeemed.headers.get("accept"), "application/json");
  assert.equal(redeemed.form.get("client_secret"), fake.oauth.clientSecret, "GitHub takes the client in the form");
  assert.deepEqual(apps.accounts("github"), [{ account: "ada", state: "ready", lastError: null }]);

  assert.deepEqual(await apps.call("github", "get_issue", { account: "ada", owner: "ada", repo: "engine", number: 3 }), {
    number: 3, title: "Bug", state: "open", author: "bob", pullRequest: false, labels: ["bug"], comments: [{ author: "ada", body: "On it", created: "d" }],
    created: "c", updated: "u", url: "https://github.com/ada/engine/issues/3", body: "It breaks",
  });
  assert.deepEqual(await apps.call("github", "get_file", { account: "ada", owner: "ada", repo: "engine", path: "src/main.rs" }), { path: "src/main.rs", sha: "s", size: 12, text: "fn main() {}" });
  assert.equal(fake.apiCalls.at(-1)!.headers.get("user-agent"), "Axo");
  assert.match(await refused(apps.call("github", "get_issue", { account: "ada", owner: "ada", repo: "secret", number: 1 })), /GitHub: Not Found/);
  assert.equal(fake.oauth.leaks(JSON.stringify([apps.list(), apps.tools()])), false);

  assert.deepEqual(await signIn("github", "grace"), { name: "apps.github" });
  assert.deepEqual(apps.accounts("github").map((a) => a.account), ["ada", "grace"]);
  assert.deepEqual((await apps.call("github", "list_notifications", { account: "grace" }) as { notifications: unknown[] }).notifications.length, 1);
  assert.equal(fake.apiCalls.at(-1)!.as, "grace", "each call acts as the account it names");
});

test("GitHub's eight-hour token renews before a call, spending the refresh token; a refused renewal asks for sign-in", async () => {
  const { apps, fake, signIn, tick } = fixture(new FakeGitHub(), "github");
  await signIn("github");
  const first = fake.oauth.tokenRequests[0]!;
  assert.equal(first.form.get("grant_type"), "authorization_code");
  tick(8 * 3600_000);
  await apps.call("github", "get_me", { account: "ada" });
  const renewal = fake.oauth.tokenRequests.at(-1)!;
  assert.equal(renewal.form.get("grant_type"), "refresh_token");
  assert.equal(fake.oauth.refreshable(renewal.form.get("refresh_token")!), false, "the old refresh token is spent");
  // An access token GitHub stopped taking is renewed once, and the call sent again.
  fake.oauth.expireAccessTokens();
  assert.equal(((await apps.call("github", "get_me", { account: "ada" })) as { login: string }).login, "Ada");
  // GitHub refuses with HTTP 200 and { error }.
  fake.oauth.refuseRefresh = true;
  fake.oauth.expireAccessTokens();
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /needs sign-in/);
  assert.deepEqual(apps.accounts("github"), [{ account: "ada", state: "needsSignIn", lastError: "GitHub refused to renew the grant" }]);
});

test("a GitHub renewal that got no answer may have spent the refresh token: the account needs sign-in", async () => {
  const { apps, fake, signIn, tick } = fixture(new FakeGitHub(), "github");
  await signIn("github");
  tick(8 * 3600_000);
  fake.oauth.dropNextToken = true;
  assert.match(await refused(apps.call("github", "get_me", { account: "ada" })), /needs sign-in/);
  assert.deepEqual(apps.accounts("github"), [{ account: "ada", state: "needsSignIn", lastError: "renewing the sign-in got no answer" }]);
});

test("a GitHub code is redeemed once, and signing out deletes Axo's authorization at GitHub", async () => {
  const { apps, fake, settled } = fixture(new FakeGitHub(), "github");
  const link = new URL(await apps.signInLink("github"));
  const nonce = link.searchParams.get("flow")!;
  const back = fake.oauth.approve((await apps.openFlow(nonce))!.authorizeUrl);
  const code = back.searchParams.get("code")!;
  assert.deepEqual(await apps.completeFlow(nonce, code), { name: "apps.github" });
  assert.deepEqual(await apps.completeFlow(nonce, code), { error: "this sign-in link was already used or has expired" });
  // GitHub refuses a spent code with HTTP 200: the sign-in does not land.
  const again = new URL(await apps.signInLink("github")).searchParams.get("flow")!;
  await apps.openFlow(again);
  assert.deepEqual(await apps.completeFlow(again, code), { error: "GitHub did not accept the sign-in" });

  assert.equal(await apps.disconnect("github", "ada"), true);
  await settled();
  assert.equal(fake.revoked.length, 1);
  assert.equal(fake.revoked[0]!.authorization, `Basic ${btoa(`${fake.oauth.clientId}:${fake.oauth.clientSecret}`)}`);
  assert.match(fake.revoked[0]!.accessToken, /^at-/);
  assert.deepEqual(apps.accounts("github"), []);
});
