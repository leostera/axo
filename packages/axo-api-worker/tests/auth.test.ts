import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { after, before, test } from "node:test";
import WebSocket from "ws";
import { parseAuthConfiguration } from "../src/auth/config";
import { seal, unseal } from "../src/auth/crypto";
import { formatSessionToken, newSessionToken, parseSessionToken } from "../src/auth/session";
import {
  APP_ORIGIN,
  cookiePair,
  finishLogin,
  harness,
  newSource,
  signIn,
  signInNative,
  startLogin,
  testSessionSecret,
  type Harness,
} from "./harness";

const sha256 = (text: string) => createHash("sha256").update(text).digest("base64url");
const challengeFor = (verifier: string) => sha256(verifier);
const newVerifier = () => randomBytes(32).toString("base64url");

let h: Harness;
before(async () => {
  h = await harness();
});
after(async () => {
  await h.close();
});

/** Every call comes from a source of its own unless it says otherwise, so one test's attempts do not count against another's. */
const call = (path: string, init: RequestInit & { headers?: Record<string, string> } = {}, harnessUrl = () => h.url) =>
  fetch(new URL(path, harnessUrl()), { ...init, headers: { ...newSource(), ...init.headers } });
const get = (path: string, headers: Record<string, string> = {}) => call(path, { headers });
const me = (headers: Record<string, string>) => get("api/auth/me", headers);

// ---- the building blocks ----

test("a session token round-trips and only canonical tokens parse", () => {
  const token = newSessionToken(crypto.randomUUID());
  assert.deepEqual(parseSessionToken(formatSessionToken(token)), token);
  const text = formatSessionToken(token);
  for (const bad of [
    "",
    "axo1",
    `axo2.${token.accountId}.${token.secret}`,
    `axo1.not-a-uuid.${token.secret}`,
    `axo1.${token.accountId}.${token.secret.slice(1)}`,
    `axo1.${token.accountId}.${token.secret}.extra`,
    `axo1.${token.accountId}.${"A".repeat(42)}B`,
    text.toUpperCase(),
  ]) {
    assert.equal(parseSessionToken(bad), null, bad);
  }
});

test("sealed values open only with the same key and purpose, and never after a change", async () => {
  const sealed = await seal(testSessionSecret, "purpose-a", { a: 1 });
  assert.deepEqual(await unseal(testSessionSecret, "purpose-a", sealed), { a: 1 });
  assert.equal(await unseal(testSessionSecret, "purpose-b", sealed), null);
  assert.equal(await unseal("another-secret-that-is-at-least-32-bytes", "purpose-a", sealed), null);
  const parts = sealed.split(".");
  parts[2] = parts[2]!.slice(0, -2) + (parts[2]!.endsWith("AA") ? "BB" : "AA");
  assert.equal(await unseal(testSessionSecret, "purpose-a", parts.join(".")), null);
  assert.equal(await unseal(testSessionSecret, "purpose-a", "garbage"), null);
});

test("sign-in is configured only with an OAuth client and a long enough secret", () => {
  const ok = { OAUTH_CLIENT_ID: "id", OAUTH_CLIENT_SECRET: "s", SESSION_SECRET: testSessionSecret } as Env;
  assert.equal(parseAuthConfiguration(ok)?.clientId, "id");
  assert.equal(parseAuthConfiguration({ ...ok, OAUTH_CLIENT_SECRET: undefined } as Env)?.clientSecret, null);
  assert.equal(parseAuthConfiguration({ ...ok, OAUTH_CLIENT_ID: "" } as Env), null);
  assert.equal(parseAuthConfiguration({ ...ok, SESSION_SECRET: "short" } as Env), null);
  assert.equal(parseAuthConfiguration({ ...ok, SESSION_SECRET: undefined } as Env), null);
});

// ---- signing in on the web ----

test("starting sign-in sends the person to Cloudflare with PKCE, a sealed state and a flow cookie", async () => {
  const response = await call("api/auth/cloudflare/start", { redirect: "manual" });
  assert.equal(response.status, 302);
  const location = new URL(response.headers.get("location")!);
  assert.equal(`${location.origin}${location.pathname}`, "https://dash.cloudflare.com/oauth2/auth");
  assert.equal(location.searchParams.get("client_id"), "test-client");
  assert.equal(location.searchParams.get("response_type"), "code");
  assert.equal(location.searchParams.get("scope"), "user-details.read");
  assert.equal(location.searchParams.get("redirect_uri"), "https://axo.leostera.dev/api/auth/cloudflare/callback");
  assert.equal(location.searchParams.get("code_challenge_method"), "S256");
  assert.match(location.searchParams.get("code_challenge")!, /^[A-Za-z0-9_-]{43}$/);
  assert.ok(location.searchParams.get("state")!.startsWith("v1."), "state is sealed, not guessable or forgeable");
  const cookie = response.headers.getSetCookie().find((value) => value.startsWith("__Host-axo_login="))!;
  for (const attribute of ["Secure", "HttpOnly", "SameSite=Lax", "Path=/"]) assert.ok(cookie.includes(attribute), attribute);
  assert.ok(!cookie.includes("Domain="), "a __Host- cookie has no Domain");
});

test("finishing sign-in sets a session cookie and the app knows who signed in", async () => {
  const started = await startLogin(h);
  const response = await finishLogin(h, started, { sub: "web-person", email: "web@example.test", name: "Web Person" });
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), `${APP_ORIGIN}/app`);
  const set = response.headers.getSetCookie();
  const session = set.find((value) => value.startsWith("__Host-axo_session="))!;
  for (const attribute of ["Secure", "HttpOnly", "SameSite=Lax", "Path=/"]) assert.ok(session.includes(attribute), attribute);
  assert.ok(set.some((value) => value.startsWith("__Host-axo_login=;") && value.includes("Max-Age=0")), "the flow cookie is cleared");

  // Cloudflare was asked the way the client registration requires, proving possession of the verifier.
  const tokenRequest = h.provider.tokenRequests.at(-1)!;
  assert.equal(tokenRequest.authorization, `Basic ${Buffer.from("test-client:test-secret").toString("base64")}`);
  assert.equal(tokenRequest.form.get("grant_type"), "authorization_code");
  assert.equal(sha256(tokenRequest.form.get("code_verifier")!), started.challenge);

  const response2 = await me({ Cookie: cookiePair(response, "__Host-axo_session")! });
  assert.equal(response2.status, 200);
  const body = (await response2.json()) as { authenticated: boolean; accountId: string; profile: unknown };
  assert.equal(body.authenticated, true);
  assert.deepEqual(body.profile, { email: "web@example.test", name: "Web Person" });
});

test("an account belongs to the provider's subject, not to an email", async () => {
  const first = await signIn(h, "subject-one");
  const again = await signIn(h, "subject-one");
  const other = await signIn(h, "subject-two");
  assert.equal(again.accountId, first.accountId);
  assert.notEqual(other.accountId, first.accountId);

  // The same email on a different subject is a different person; a new email on the same one is not.
  const sameEmail = await finishLogin(h, await startLogin(h), { sub: "subject-three", email: "subject-one@example.test" });
  const third = (await (await me({ Cookie: cookiePair(sameEmail, "__Host-axo_session")! })).json()) as { accountId: string };
  assert.notEqual(third.accountId, first.accountId);
  const renamed = await finishLogin(h, await startLogin(h), { sub: "subject-one", email: "new@example.test" });
  const renamedMe = (await (await me({ Cookie: cookiePair(renamed, "__Host-axo_session")! })).json()) as {
    accountId: string;
    profile: { email: string };
  };
  assert.equal(renamedMe.accountId, first.accountId);
  assert.equal(renamedMe.profile.email, "new@example.test");
});

// ---- a sign-in that must fail ----

async function assertNoSession(response: Response, status: number) {
  assert.equal(response.status, status);
  assert.equal(cookiePair(response, "__Host-axo_session"), null, "no session may be set");
}

test("a callback that does not belong to this browser's sign-in is refused", async () => {
  const mine = await startLogin(h);
  const theirs = await startLogin(h);
  const identity = { sub: "victim" };
  // Login CSRF: an attacker's callback link, opened in the victim's browser, must not sign them in as the attacker.
  await assertNoSession(await finishLogin(h, theirs, identity, { cookie: mine.loginCookie }), 400);
  await assertNoSession(await finishLogin(h, mine, identity, { cookie: null }), 400);
  await assertNoSession(await finishLogin(h, mine, identity, { cookie: "__Host-axo_login=wrong" }), 400);
  await assertNoSession(await finishLogin(h, mine, identity, { state: `${mine.state}x` }), 400);
  await assertNoSession(await finishLogin(h, mine, identity, { state: "v1.AAAA.BBBB" }), 400);
  await assertNoSession(await finishLogin(h, mine, identity, { state: "" }), 400);
});

test("an old sign-in flow, or one sealed for another purpose, is refused", async () => {
  const started = await startLogin(h);
  const nonce = started.loginCookie.split("=")[1]!;
  const flow = { nonce, verifier: "v".repeat(48), expiresAt: Date.now() - 1000, client: { kind: "web" } };
  const expired = await seal(testSessionSecret, "oauth-flow", flow);
  await assertNoSession(await finishLogin(h, started, { sub: "late" }, { state: expired }), 400);
  const wrongPurpose = await seal(testSessionSecret, "something-else", { ...flow, expiresAt: Date.now() + 60_000 });
  await assertNoSession(await finishLogin(h, started, { sub: "late" }, { state: wrongPurpose }), 400);
  const farFuture = await seal(testSessionSecret, "oauth-flow", { ...flow, expiresAt: Date.now() + 10 * 3600_000 });
  await assertNoSession(await finishLogin(h, started, { sub: "late" }, { state: farFuture }), 400);
});

test("a code can be used once, and a code Cloudflare did not issue is refused", async () => {
  const started = await startLogin(h);
  const code = h.provider.approve({ sub: "once" }, started.challenge);
  assert.equal((await finishLogin(h, started, { sub: "once" }, { code })).status, 302);
  await assertNoSession(await finishLogin(h, started, { sub: "once" }, { code }), 503);
  await assertNoSession(await finishLogin(h, started, { sub: "once" }, { code: "never-issued" }), 503);
});

test("a code approved for another sign-in does not work with this one's verifier", async () => {
  const mine = await startLogin(h);
  const theirs = await startLogin(h);
  const code = h.provider.approve({ sub: "someone" }, theirs.challenge);
  await assertNoSession(await finishLogin(h, mine, { sub: "someone" }, { code }), 503);
});

test("Cloudflare failing or refusing never makes a session and leaks nothing", async () => {
  for (const stage of ["token", "profile"] as const) {
    h.provider.failNext(stage);
    const started = await startLogin(h);
    const response = await finishLogin(h, started, { sub: "unlucky" });
    await assertNoSession(response, 503);
    const text = await response.text();
    assert.ok(!text.includes(started.state) && !text.includes("test-secret"), text);
  }
  const started = await startLogin(h);
  const denied = await call(`api/auth/cloudflare/callback?error=access_denied&state=${encodeURIComponent(started.state)}`,
    { redirect: "manual", headers: { Cookie: started.loginCookie } },
  );
  assert.equal(denied.status, 302);
  assert.equal(denied.headers.get("location"), `${APP_ORIGIN}/app?signin=cancelled`);
  assert.equal(cookiePair(denied, "__Host-axo_session"), null);
});

// ---- signing in from the phone ----

test("the app's sign-in needs a well-formed challenge and has no redirect of its own to choose", async () => {
  for (const query of [
    "?client=native",
    "?client=native&challenge=short",
    `?client=native&challenge=${"A".repeat(44)}`,
    `?client=web&challenge=${"A".repeat(43)}`,
    `?client=other&challenge=${"A".repeat(43)}`,
    `?client=native&challenge=${"A".repeat(43)}&redirect=https://evil.test`,
  ].slice(0, 5)) {
    const response = await call(`api/auth/cloudflare/start${query}`, { redirect: "manual" });
    assert.equal(response.status, 400, query);
  }
  // An unknown `redirect` is ignored: the app always returns to its own link.
  const odd = await call(`api/auth/cloudflare/start?client=native&challenge=${"A".repeat(43)}&redirect=https://evil.test`,
    { redirect: "manual" },
  );
  assert.equal(odd.status, 302);
  assert.ok(!odd.headers.get("location")!.includes("evil.test"));
});

test("the app gets a one-time code on its own link, never a token, and trades it for a session", async () => {
  const verifier = newVerifier();
  const started = await startLogin(h, `?client=native&challenge=${challengeFor(verifier)}`);
  const callback = await finishLogin(h, started, { sub: "phone-person", email: "phone@example.test" });
  assert.equal(callback.status, 302);
  const location = new URL(callback.headers.get("location")!);
  assert.equal(`${location.protocol}//${location.host}${location.pathname}`, "axo://auth/callback");
  assert.equal(cookiePair(callback, "__Host-axo_session"), null, "the app gets no cookie");
  const code = location.searchParams.get("code")!;
  assert.ok(![...location.searchParams.keys()].includes("token") && !location.search.includes("axo1."));

  const exchange = await call("api/auth/token", { method: "POST", body: JSON.stringify({ code, verifier }) });
  assert.equal(exchange.status, 200);
  assert.equal(exchange.headers.get("cache-control"), "private, no-store");
  const session = (await exchange.json()) as { token: string; accountId: string; profile: { email: string }; expiresAt: string };
  assert.ok(session.token.startsWith("axo1."));
  assert.equal(session.profile.email, "phone@example.test");
  assert.ok(Date.parse(session.expiresAt) > Date.now() + 80 * 24 * 3600_000, "the app stays signed in for months");

  const meResponse = await me({ Authorization: `Bearer ${session.token}` });
  assert.equal(meResponse.status, 200);
  assert.equal(((await meResponse.json()) as { accountId: string }).accountId, session.accountId);
  const hosts = await get("api/v1/account/hosts", { Authorization: `Bearer ${session.token}` });
  assert.equal(hosts.status, 200);
});

test("a login code is worthless without the secret the app kept, and one wrong guess burns it", async () => {
  const verifier = newVerifier();
  const started = await startLogin(h, `?client=native&challenge=${challengeFor(verifier)}`);
  const code = new URL((await finishLogin(h, started, { sub: "careful" })).headers.get("location")!).searchParams.get("code")!;
  const exchange = (body: unknown) => call("api/auth/token", { method: "POST", body: JSON.stringify(body) });

  assert.equal((await exchange({ code, verifier: newVerifier() })).status, 400, "a stolen code with a guessed secret");
  assert.equal((await exchange({ code, verifier })).status, 400, "and the right secret is too late: the code is gone");

  const second = await startLogin(h, `?client=native&challenge=${challengeFor(verifier)}`);
  const code2 = new URL((await finishLogin(h, second, { sub: "careful" })).headers.get("location")!).searchParams.get("code")!;
  assert.equal((await exchange({ code: code2, verifier })).status, 200);
  assert.equal((await exchange({ code: code2, verifier })).status, 400, "a code works once");
});

test("malformed or foreign login codes and bodies are refused alike", async () => {
  const exchange = (body: string) => call("api/auth/token", { method: "POST", body });
  const verifier = newVerifier();
  for (const body of [
    "",
    "not json",
    "{}",
    JSON.stringify({ code: "x", verifier }),
    JSON.stringify({ code: `${crypto.randomUUID()}.abc`, verifier }),
    JSON.stringify({ code: `${crypto.randomUUID()}.abc`, verifier: "short" }),
    JSON.stringify({ code: `${crypto.randomUUID()}.abc`, verifier, extra: true }),
    JSON.stringify({ code: "a".repeat(5000), verifier }),
    "x".repeat(2000),
  ]) {
    const response = await exchange(body);
    assert.ok([400].includes(response.status), `${body.slice(0, 40)} -> ${response.status}`);
  }
  assert.equal((await call("api/auth/token")).status, 405);
});

test("a login code that was not used in time is refused", async () => {
  const verifier = newVerifier();
  const started = await startLogin(h, `?client=native&challenge=${challengeFor(verifier)}`);
  const code = new URL((await finishLogin(h, started, { sub: "slow" })).headers.get("location")!).searchParams.get("code")!;
  const accountId = code.split(".")[0]!;
  const storage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoAccountDirectory", { name: accountId });
  await storage.exec("UPDATE login_codes SET expires_at = ?", Date.now() - 1);
  const exchange = await call("api/auth/token", { method: "POST", body: JSON.stringify({ code, verifier }) });
  assert.equal(exchange.status, 400);
});

test("the app is told when sign-in was cancelled, without an account", async () => {
  const started = await startLogin(h, `?client=native&challenge=${challengeFor(newVerifier())}`);
  const denied = await call(`api/auth/cloudflare/callback?error=access_denied&state=${encodeURIComponent(started.state)}`,
    { redirect: "manual", headers: { Cookie: started.loginCookie } },
  );
  assert.equal(denied.status, 302);
  assert.equal(denied.headers.get("location"), "axo://auth/callback?error=cancelled");
});

// ---- which requests are who ----

test("a request with no credentials, or a bad one, is signed out", async () => {
  assert.equal((await me({})).status, 401);
  const phone = await signInNative(h);
  const parsed = parseSessionToken(phone.token)!;
  const tampered = formatSessionToken({ ...parsed, secret: parsed.secret.slice(0, -1) + (parsed.secret.endsWith("A") ? "B" : "A") });
  const foreign = formatSessionToken({ accountId: crypto.randomUUID(), secret: parsed.secret });
  for (const header of ["Bearer nonsense", `Bearer ${tampered}`, `Bearer ${foreign}`, `Basic ${phone.token}`, `Bearer`, `Bearer ${phone.token} extra`]) {
    assert.equal((await me({ Authorization: header })).status, 401, header);
  }
  assert.equal((await me({ Cookie: "__Host-axo_session=nonsense" })).status, 401);
  assert.equal((await me({ Cookie: `__Host-axo_session=${tampered}` })).status, 401);
});

test("a bad Authorization header is never quietly replaced by a cookie", async () => {
  const web = await signIn(h);
  for (const header of ["Bearer nonsense", "Bearer", "Basic abc", "bearer lower"]) {
    assert.equal((await me({ ...web.headers, Authorization: header })).status, 401, header);
  }
  assert.equal((await me(web.headers)).status, 200);
});

test("a cookie may only change things from the app's own origin, and a bearer token needs no origin", async () => {
  const web = await signIn(h);
  const phone = await signInNative(h);
  const post = (headers: Record<string, string>) =>
    call("api/v1/account/host-pairings", { method: "POST", headers });

  assert.equal((await post({ Cookie: web.headers.Cookie! })).status, 403, "a cookie with no Origin");
  assert.equal((await post({ ...web.headers, Origin: "https://evil.test" })).status, 403, "a cookie from another site");
  assert.equal((await post(web.headers)).status, 200, "a cookie from the app");
  assert.equal((await post(phone.headers)).status, 200, "a bearer token, as the app sends it");
  assert.equal((await post({ ...phone.headers, Origin: "https://evil.test" })).status, 200, "a token is not ambient, so origin is moot");
  // Reading is allowed cross-site (the browser keeps the answer from the page), changing is not.
  assert.equal((await get("api/v1/account/hosts", { Cookie: web.headers.Cookie!, Origin: "https://evil.test" })).status, 200);
});

test("a cookie cannot open a relay from another site", async () => {
  const web = await signIn(h);
  const refusal = (headers: Record<string, string>) => new Promise<number>((resolve, reject) => {
    const socket = new WebSocket(
      new URL(`api/v1/account/hosts/${crypto.randomUUID()}/client`, h.url.replace("http", "ws")),
      { headers: { ...newSource(), ...headers } },
    );
    socket.once("unexpected-response", (_request, response) => resolve(response.statusCode ?? 0));
    socket.once("open", () => reject(new Error("the relay opened")));
    socket.once("error", () => {});
  });
  assert.equal(await refusal({ Cookie: web.headers.Cookie!, Origin: "https://evil.test" }), 403);
  assert.equal(await refusal({ Cookie: web.headers.Cookie! }), 403, "a cookie with no Origin");
});

// ---- ending a sign-in ----

test("signing out ends that sign-in and no other", async () => {
  const first = await signIn(h, "two-devices");
  const second = await signIn(h, "two-devices");
  const phone = await signInNative(h, "two-devices");
  assert.equal(first.accountId, second.accountId);

  const response = await call("api/auth/logout", { method: "POST", headers: first.headers });
  assert.equal(response.status, 204);
  assert.ok(response.headers.getSetCookie().some((c) => c.startsWith("__Host-axo_session=;") && c.includes("Max-Age=0")));
  assert.equal((await me(first.headers)).status, 401, "this sign-in is over");
  assert.equal((await me(second.headers)).status, 200, "the browser's other sign-in stays");
  assert.equal((await me(phone.headers)).status, 200, "and so does the phone");
  assert.equal((await call("api/auth/logout", { method: "POST", headers: first.headers })).status, 401);

  // The phone signs itself out with its token; no origin involved.
  assert.equal((await call("api/auth/logout", { method: "POST", headers: phone.headers })).status, 204);
  assert.equal((await me(phone.headers)).status, 401);
  // Signing out from another site is refused.
  assert.equal(
    (await call("api/auth/logout", { method: "POST", headers: { ...second.headers, Origin: "https://evil.test" } })).status,
    403,
  );
  assert.equal((await me(second.headers)).status, 200);
});

test("an expired sign-in is signed out, and an account keeps at most twenty", async () => {
  const web = await signIn(h, "expiring");
  const storage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoAccountDirectory", { name: web.accountId });
  await storage.exec("UPDATE sessions SET expires_at = ?", Date.now() - 1);
  assert.equal((await me(web.headers)).status, 401);

  const sessions = [];
  for (let i = 0; i < 21; i++) sessions.push(await signIn(h, "many-devices"));
  assert.equal((await me(sessions[0]!.headers)).status, 401, "the oldest sign-in made room");
  assert.equal((await me(sessions[1]!.headers)).status, 200);
  assert.equal((await me(sessions[20]!.headers)).status, 200);
});

// ---- not set up, and too many attempts ----

test("sign-in answers 503 until it is configured", async () => {
  const bare = await harness({ bindings: { OAUTH_CLIENT_ID: "", SESSION_SECRET: "" } });
  try {
    for (const path of ["api/auth/cloudflare/start", "api/auth/me"]) {
      const response = await fetch(new URL(path, bare.url), { redirect: "manual", headers: newSource() });
      assert.equal(response.status, 503, path);
    }
    assert.equal((await fetch(new URL("api/auth/token", bare.url), { method: "POST", body: "{}", headers: newSource() })).status, 503);
  } finally {
    await bare.close();
  }
});

test("too many sign-in starts from one place are slowed down", async () => {
  const headers = { "CF-Connecting-IP": "203.0.113.9" };
  const statuses = [];
  for (let i = 0; i < 25; i++) {
    statuses.push((await call("api/auth/cloudflare/start", { redirect: "manual", headers })).status);
  }
  assert.ok(statuses.slice(0, 20).every((status) => status === 302), statuses.join());
  assert.ok(statuses.slice(20).every((status) => status === 429), statuses.join());
  const other = await call("api/auth/cloudflare/start", { redirect: "manual", headers: { "CF-Connecting-IP": "203.0.113.10" } });
  assert.equal(other.status, 302, "another place is not affected");
});
