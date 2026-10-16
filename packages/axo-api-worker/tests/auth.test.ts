import assert from "node:assert/strict";
import { test } from "node:test";
import { constantTimeEqual, hmac, openCookie, randomToken, sealCookie, sha256 } from "../src/auth/crypto";
import { loadCloudflareProfile, OAuthProviderFailure } from "../src/auth/provider";
import { authExports, completeCloudflareLogin, currentAxoSession, logoutAxoSession, startCloudflareLogin } from "../src/auth/cloudflare";
import { harness } from "./harness";

const secret = "test-session-secret-with-at-least-32-bytes";

test("Cloudflare OAuth exchange uses PKCE and resolves identity only from userinfo subject", async () => {
  const requests: Array<{ url: string; init: RequestInit }> = [];
  const profile = await loadCloudflareProfile(
    "authorization-code",
    "pkce-verifier",
    { OAUTH_CLIENT_ID: "public-client-id" },
    async (input, init = {}) => {
      requests.push({ url: String(input), init });
      if (String(input) === "https://dash.cloudflare.com/oauth2/token") {
        return Response.json({ access_token: "provider-access-token", token_type: "Bearer" });
      }
      return Response.json({ sub: "stable-user-subject", email: "user@example.test", name: "Test User" });
    },
  );

  assert.deepEqual(profile, {
    subject: "stable-user-subject",
    email: "user@example.test",
    name: "Test User",
  });
  assert.equal(requests.length, 2);
  assert.equal(requests[0].init.method, "POST");
  assert.equal(requests[0].init.redirect, "manual");
  const tokenForm = new URLSearchParams(String(requests[0].init.body));
  assert.equal(tokenForm.get("client_id"), "public-client-id");
  assert.equal(tokenForm.get("code_verifier"), "pkce-verifier");
  assert.equal(tokenForm.get("redirect_uri"), "https://axo.leostera.dev/api/auth/cloudflare/callback");
  assert.equal(requests[1].url, "https://dash.cloudflare.com/oauth2/userinfo");
  assert.equal(new Headers(requests[1].init.headers).get("Authorization"), "Bearer provider-access-token");
  assert.ok(!JSON.stringify(profile).includes("provider-access-token"));
});

test("OAuth adapts callable Cloudflare Durable Object namespaces", async () => {
  const identityNamespace = Object.assign(() => undefined, {
    getByName: () => ({ resolveAccount: async () => "account-123" }),
  });
  const accountNamespace = Object.assign(() => undefined, {
    getByName: () => ({
      establishSession: async () => undefined,
      sessionProfile: async () => null,
      revokeSession: async () => undefined,
    }),
  });
  const namespaces = authExports({
    AxoIdentityIndex: identityNamespace,
    AxoAccountDirectory: accountNamespace,
  });

  assert.equal(await namespaces.AxoIdentityIndex?.getByName("identity").resolveAccount(), "account-123");
  assert.ok(namespaces.AxoAccountDirectory?.getByName("account"));
});

test("Cloudflare OAuth confidential exchange keeps client secret in Basic auth", async () => {
  const requests: Request[] = [];
  await loadCloudflareProfile(
    "authorization-code",
    "pkce-verifier",
    { OAUTH_CLIENT_ID: "confidential-client", OAUTH_CLIENT_SECRET: "worker-only-secret" },
    async (input, init = {}) => {
      requests.push(new Request(input, init));
      return requests.length === 1
        ? Response.json({ access_token: "provider-access-token", token_type: "bearer" })
        : Response.json({ sub: "subject" });
    },
  );
  assert.equal(requests.length, 2);
  assert.equal(requests[0].headers.get("Authorization"), `Basic ${btoa("confidential-client:worker-only-secret")}`);
  assert.equal(new URLSearchParams(await requests[0].clone().text()).has("client_secret"), false);
});

test("OAuth token and userinfo responses are validated and bounded", async () => {
  await assert.rejects(loadCloudflareProfile(
    "code",
    "verifier",
    { OAUTH_CLIENT_ID: "client" },
    async () => Response.json({ access_token: "token", token_type: "mac" }),
  ), /Invalid OAuth token response/);
  await assert.rejects(loadCloudflareProfile(
    "code",
    "verifier",
    { OAUTH_CLIENT_ID: "client" },
    async (_input, init) => init?.method === "POST"
      ? Response.json({ access_token: "token", token_type: "bearer" })
      : Response.json({ email: "missing-subject@example.test" }),
  ), /Invalid OAuth userinfo response/);
  await assert.rejects(loadCloudflareProfile(
    "code",
    "verifier",
    { OAUTH_CLIENT_ID: "client" },
    async () => new Response("x".repeat(16_385), { headers: { "Content-Length": "16385" } }),
  ), /OAuth response too large/);
});

test("OAuth provider failures expose only a bounded stage and HTTP status", async () => {
  await assert.rejects(
    loadCloudflareProfile("invalid-code", "verifier", { OAUTH_CLIENT_ID: "client" }, async () =>
      Response.json({ error: "invalid_client", error_description: "sensitive provider detail" }, { status: 401 }),
    ),
    error => error instanceof OAuthProviderFailure &&
      error.stage === "token_exchange" && error.reason === "http" && error.status === 401 &&
      error.providerCode === "invalid_client" && !error.message.includes("sensitive provider detail"),
  );
  await assert.rejects(
    loadCloudflareProfile("code", "verifier", { OAUTH_CLIENT_ID: "client" }, async () => {
      throw new Error("sensitive transport detail");
    }),
    error => error instanceof OAuthProviderFailure &&
      error.stage === "token_exchange" && error.reason === "network" &&
      !error.message.includes("sensitive transport detail"),
  );
});

test("OAuth flow/session cookies are authenticated, purpose-separated, and opaque", async () => {
  const payload = { accountId: "random-account-id", sessionId: randomToken(), expiresAt: Date.now() + 60_000 };
  const cookie = await sealCookie(secret, "web-session", payload);
  assert.notEqual(cookie, JSON.stringify(payload));
  assert.deepEqual(await openCookie(secret, "web-session", cookie), payload);
  assert.equal(await openCookie(secret, "oauth-flow", cookie), null);
  assert.equal(await openCookie("another-session-secret-with-over-32-bytes", "web-session", cookie), null);
  const tampered = `${cookie.slice(0, -1)}${cookie.endsWith("A") ? "B" : "A"}`;
  assert.equal(await openCookie(secret, "web-session", tampered), null);
});

test("session digests are keyed and constant-time comparator handles unequal lengths", async () => {
  const token = randomToken();
  assert.equal(await hmac(secret, `session\0${token}`), await hmac(secret, `session\0${token}`));
  assert.notEqual(await hmac(secret, token), await hmac("other-session-secret-with-32-bytes", token));
  assert.equal(constantTimeEqual("same", "same"), true);
  assert.equal(constantTimeEqual("same", "same-longer"), false);
  assert.match(await sha256("issuer\0subject"), /^[A-Za-z0-9_-]{43}$/);
});

test("OAuth callback creates an account-scoped Axo session and logout revokes it", async () => {
  const env = { OAUTH_CLIENT_ID: "public-client", SESSION_SECRET: secret };
  const start = await startCloudflareLogin(new Request("https://axo.leostera.dev/api/auth/cloudflare/start"), env);
  const authorization = new URL(start.headers.get("Location")!);
  const state = authorization.searchParams.get("state")!;
  const flowCookie = start.headers.get("Set-Cookie")!.split(";", 1)[0];
  const observedIdentityNames: string[] = [];
  let sessionDigest = "";
  let revoked = false;
  const exports = {
    AxoIdentityIndex: {
      getByName(name: string) {
        observedIdentityNames.push(name);
        return { resolveAccount: async () => "account-123" };
      },
    },
    AxoAccountDirectory: {
      getByName(accountId: string) {
        assert.equal(accountId, "account-123");
        return {
          establishSession: async (digest: string) => { sessionDigest = digest; },
          sessionProfile: async (digest: string) =>
            !revoked && digest === sessionDigest ? { email: "user@example.test", name: "Test User" } : null,
          revokeSession: async (digest: string) => { if (digest === sessionDigest) revoked = true; },
        };
      },
    },
  };
  let calls = 0;
  const callback = await completeCloudflareLogin(
    new Request(`https://axo.leostera.dev/api/auth/cloudflare/callback?code=one-time-code&state=${encodeURIComponent(state)}`, {
      headers: { Cookie: flowCookie },
    }),
    env,
    exports,
    async () => {
      calls++;
      return calls === 1
        ? Response.json({ access_token: "provider-token", token_type: "bearer" })
        : Response.json({ sub: "stable-cloudflare-subject", email: "user@example.test", name: "Test User" });
    },
  );
  assert.equal(callback.status, 302);
  assert.equal(callback.headers.get("Location"), "https://axo.leostera.dev/app");
  assert.equal(calls, 2);
  assert.equal(observedIdentityNames[0], await sha256("https://dash.cloudflare.com\0stable-cloudflare-subject"));
  const sessionCookie = callback.headers.get("Set-Cookie")!.split(", ").find((value) => value.startsWith("__Host-axo_session="))!;
  const cookiePair = sessionCookie.split(";", 1)[0];
  const current = await currentAxoSession(new Request("https://axo.leostera.dev/api/auth/me", {
    headers: { Cookie: cookiePair },
  }), env, exports);
  const currentBody = await current.json() as { authenticated: boolean; csrfToken: string };
  assert.equal(currentBody.authenticated, true);
  const logout = await logoutAxoSession(new Request("https://axo.leostera.dev/api/auth/logout", {
    method: "POST",
    headers: { Origin: "https://axo.leostera.dev", Cookie: cookiePair, "X-Axo-CSRF": currentBody.csrfToken },
  }), env, exports);
  assert.equal(logout.status, 204);
  assert.equal(revoked, true);
  const afterLogout = await currentAxoSession(new Request("https://axo.leostera.dev/api/auth/me", {
    headers: { Cookie: cookiePair },
  }), env, exports);
  assert.deepEqual(await afterLogout.json(), { authenticated: false });
});

test("OAuth callback reports a bounded provider diagnostic without provider details", async () => {
  const env = { OAUTH_CLIENT_ID: "public-client", SESSION_SECRET: secret };
  const start = await startCloudflareLogin(new Request("https://axo.leostera.dev/api/auth/cloudflare/start"), env);
  const state = new URL(start.headers.get("Location")!).searchParams.get("state")!;
  const flowCookie = start.headers.get("Set-Cookie")!.split(";", 1)[0];
  const response = await completeCloudflareLogin(
    new Request(`https://axo.leostera.dev/api/auth/cloudflare/callback?code=one-time-code&state=${state}`, {
      headers: { Cookie: flowCookie },
    }),
    env,
    {
      AxoIdentityIndex: { getByName: () => ({ resolveAccount: async () => "account" }) },
      AxoAccountDirectory: { getByName: () => ({
        establishSession: async () => undefined,
        sessionProfile: async () => null,
        revokeSession: async () => undefined,
      }) },
    },
    async () => Response.json({
      error: "invalid_client",
      error_description: "sensitive provider detail",
    }, { status: 401 }),
  );
  const body = await response.json() as { error: string; diagnostic: string };
  assert.equal(response.status, 503);
  assert.equal(body.diagnostic, "oauth_token_exchange_http_401_invalid_client");
  assert.equal(JSON.stringify(body).includes("sensitive provider detail"), false);
});

test("OAuth routes fail closed until Worker secrets and client id are configured", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const start = await fetch(`${h.url}api/auth/cloudflare/start`, { redirect: "manual" });
  assert.equal(start.status, 503);
  assert.equal(start.headers.get("Cache-Control"), "private, no-store");
  const current = await fetch(`${h.url}api/auth/me`);
  assert.equal(current.status, 200);
  assert.deepEqual(await current.json(), { authenticated: false });
});

test("Worker OAuth callback recognizes exported Durable Object namespaces", async (t) => {
  const h = await harness({ bindings: {
    OAUTH_CLIENT_ID: "isolated-public-client",
    SESSION_SECRET: secret,
  } });
  t.after(() => h.close());

  const response = await fetch(`${h.url}api/auth/cloudflare/callback`);
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "Cloudflare sign-in could not be completed" });
});

test("OAuth start emits a fixed Cloudflare authorization URL and protected flow cookie", async (t) => {
  const h = await harness({ bindings: {
    OAUTH_CLIENT_ID: "isolated-public-client",
    SESSION_SECRET: secret,
  } });
  t.after(() => h.close());
  const response = await fetch(`${h.url}api/auth/cloudflare/start`, { redirect: "manual" });
  assert.equal(response.status, 302);
  const location = new URL(response.headers.get("Location")!);
  assert.equal(location.origin, "https://dash.cloudflare.com");
  assert.equal(location.pathname, "/oauth2/auth");
  assert.equal(location.searchParams.get("client_id"), "isolated-public-client");
  assert.equal(location.searchParams.get("redirect_uri"), "https://axo.leostera.dev/api/auth/cloudflare/callback");
  assert.equal(location.searchParams.get("scope"), "user-details.read");
  assert.equal(location.searchParams.get("code_challenge_method"), "S256");
  const cookie = response.headers.get("Set-Cookie")!;
  assert.match(cookie, /^__Host-axo_oauth=/);
  assert.match(cookie, /; Secure; HttpOnly; SameSite=Lax$/);
});
