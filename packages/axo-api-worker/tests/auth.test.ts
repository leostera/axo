import assert from "node:assert/strict";
import { test } from "node:test";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import WebSocket from "ws";
import { constantTimeEqual, hmac, randomToken, sha256 } from "../src/auth/crypto";
import { parseAccessConfiguration, verifyAccessIdentity } from "../src/auth/access-identity";
import { isCrossSiteRequest } from "../src/auth/account-access";
import { APP_ORIGIN, harness, issuer, signIn } from "./harness";

const secret = "test-session-secret-with-at-least-32-bytes";
const configuration = parseAccessConfiguration({
  ACCESS_TEAM_DOMAIN: "https://axo-test.cloudflareaccess.com",
  ACCESS_AUD: "audience-tag",
} as Env)!;

async function signer() {
  const keys = await generateKeyPair("RS256", { extractable: true });
  const keySet = createLocalJWKSet({ keys: [{ ...(await exportJWK(keys.publicKey)), kid: "k1", alg: "RS256" }] });
  const sign = (claims: Record<string, unknown>, options: { issuer?: string; audience?: string; expiration?: string | number; kid?: string } = {}) =>
    new SignJWT({ type: "app", sub: "person-subject", email: "person@example.test", ...claims })
      .setProtectedHeader({ alg: "RS256", kid: options.kid ?? "k1" })
      .setIssuer(options.issuer ?? configuration.issuer)
      .setAudience(options.audience ?? "audience-tag")
      .setExpirationTime(options.expiration ?? "5m")
      .sign(keys.privateKey);
  return { keySet, sign };
}

function withAssertion(assertion: string): Request {
  return new Request("https://axo.leostera.dev/api/auth/me", { headers: { "Cf-Access-Jwt-Assertion": assertion } });
}

test("Access configuration accepts only a team domain and audience tags", () => {
  assert.deepEqual(configuration.audiences, ["audience-tag"]);
  assert.equal(configuration.certsUrl.href, "https://axo-test.cloudflareaccess.com/cdn-cgi/access/certs");
  assert.deepEqual(
    parseAccessConfiguration({ ACCESS_TEAM_DOMAIN: "https://axo-test.cloudflareaccess.com/", ACCESS_AUD: "a, b" } as Env)?.audiences,
    ["a", "b"],
  );
  for (const [team, audience] of [
    ["", "audience-tag"],
    ["https://axo-test.cloudflareaccess.com", ""],
    ["http://axo-test.cloudflareaccess.com", "audience-tag"],
    ["https://cloudflareaccess.com.evil.test", "audience-tag"],
    ["https://axo-test.cloudflareaccess.com/path", "audience-tag"],
    ["https://axo-test.cloudflareaccess.com", "bad audience"],
  ]) {
    assert.equal(parseAccessConfiguration({ ACCESS_TEAM_DOMAIN: team, ACCESS_AUD: audience } as Env), null, `${team} ${audience}`);
  }
});

test("only a valid Access assertion for a person yields an identity", async () => {
  const { keySet, sign } = await signer();
  const identity = await verifyAccessIdentity(withAssertion(await sign({})), configuration, keySet);
  assert.equal(identity?.subject, "person-subject");
  assert.equal(identity?.email, "person@example.test");
  assert.equal(identity?.issuer, configuration.issuer);
  assert.ok(identity && identity.expiresAt > Date.now());

  const forger = await signer();
  const refused: Array<[string, string]> = [
    ["forged with another key", await forger.sign({})],
    ["expired", await sign({}, { expiration: Math.floor(Date.now() / 1000) - 60 })],
    ["wrong audience", await sign({}, { audience: "another-application" })],
    ["wrong issuer", await sign({}, { issuer: "https://other-team.cloudflareaccess.com" })],
    ["service token", await sign({ sub: "", common_name: "client-id.access", email: undefined })],
    ["not an application token", await sign({ type: "org" })],
    ["not a JWT", "header.payload.signature"],
    ["oversized", "x".repeat(8193)],
  ];
  for (const [reason, assertion] of refused) {
    assert.equal(await verifyAccessIdentity(withAssertion(assertion), configuration, keySet), null, reason);
  }
  assert.equal(await verifyAccessIdentity(new Request("https://axo.leostera.dev/"), configuration, keySet), null, "no assertion");
});

test("state-changing requests must come from the app or from a client without cookies", () => {
  const request = (headers: Record<string, string>) => new Request("https://axo.leostera.dev/api/v1/x", { method: "POST", headers });
  assert.equal(isCrossSiteRequest(request({ Origin: APP_ORIGIN, Cookie: "CF_Authorization=x" })), false, "the web app");
  assert.equal(isCrossSiteRequest(request({})), false, "a native client");
  assert.equal(isCrossSiteRequest(request({ Origin: "https://evil.test", Cookie: "CF_Authorization=x" })), true);
  assert.equal(isCrossSiteRequest(request({ Origin: "https://evil.test" })), true);
  assert.equal(isCrossSiteRequest(request({ Origin: "null" })), true);
  assert.equal(isCrossSiteRequest(request({ Cookie: "CF_Authorization=x" })), true, "cookies need a known origin");
});

test("HMAC verifiers are keyed and the comparator handles unequal lengths", async () => {
  const token = randomToken();
  assert.equal(await hmac(secret, `pairing-code\0${token}`), await hmac(secret, `pairing-code\0${token}`));
  assert.notEqual(await hmac(secret, token), await hmac("other-session-secret-with-32-bytes", token));
  assert.equal(constantTimeEqual("same", "same"), true);
  assert.equal(constantTimeEqual("same", "same-longer"), false);
  assert.match(await sha256("issuer\0subject"), /^[A-Za-z0-9_-]{43}$/);
});

test("the Worker maps each Access subject to one stable account and refuses everyone else", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const me = (headers: Record<string, string>) => fetch(new URL("api/auth/me", h.url), { headers });

  assert.equal((await me({})).status, 401, "anonymous");
  assert.equal((await me({ "Cf-Access-Jwt-Assertion": await h.token("daemon") })).status, 401, "service token");
  assert.equal((await me({ "Cf-Access-Jwt-Assertion": await h.token("client", {}, Math.floor(Date.now() / 1000) - 60) })).status, 401, "expired");

  const first = await signIn(h, "subject-one");
  const again = await signIn(h, "subject-one");
  const other = await signIn(h, "subject-two");
  assert.equal(first.accountId, again.accountId, "the same person always has the same account");
  assert.notEqual(first.accountId, other.accountId);
  const profile = await (await me(first.headers)).json() as { profile: { email: string } };
  assert.equal(profile.profile.email, "subject-one@example.test");

  const pairings = new URL("api/v1/account/host-pairings", h.url);
  const assertion = first.headers["Cf-Access-Jwt-Assertion"]!;
  assert.equal((await fetch(pairings, { method: "POST", headers: { "Cf-Access-Jwt-Assertion": assertion, Origin: "https://evil.test" } })).status, 403);
  assert.equal((await fetch(pairings, { method: "POST", headers: { "Cf-Access-Jwt-Assertion": assertion, Cookie: "CF_Authorization=x" } })).status, 403);
  assert.equal((await fetch(pairings, { method: "POST", headers: { "Cf-Access-Jwt-Assertion": assertion } })).status, 200, "native clients send no Origin");
  assert.equal((await fetch(pairings, { method: "POST", headers: first.headers })).status, 200, "the web app");
  assert.equal((await fetch(pairings, { method: "POST", headers: { Origin: APP_ORIGIN } })).status, 401);
});

test("client relay upgrades follow the same origin rule", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const person = await signIn(h);
  const assertion = person.headers["Cf-Access-Jwt-Assertion"]!;
  const upgrade = (headers: Record<string, string>) => new Promise<number>((resolveStatus) => {
    const socket = new WebSocket(new URL(`api/v1/account/hosts/${crypto.randomUUID()}/client`, h.url.replace("http", "ws")), { headers });
    socket.on("unexpected-response", (_request, response) => { resolveStatus(response.statusCode ?? 0); socket.terminate(); });
    socket.on("open", () => { resolveStatus(101); socket.close(); });
    socket.on("error", () => resolveStatus(-1));
  });
  assert.equal(await upgrade({ "Cf-Access-Jwt-Assertion": assertion, Origin: "https://evil.test" }), 403);
  assert.equal(await upgrade({ Origin: APP_ORIGIN }), 401);
  // An authenticated client still needs a host its account owns.
  assert.equal(await upgrade({ "Cf-Access-Jwt-Assertion": assertion }), 403);
  assert.equal(await upgrade(person.headers), 403);
});

test("sign-in fails closed until Access is configured", async (t) => {
  const h = await harness({ bindings: { ACCESS_AUD: "" } });
  t.after(() => h.close());
  const response = await fetch(new URL("api/auth/me", h.url), {
    headers: { "Cf-Access-Jwt-Assertion": await h.token("client"), Origin: APP_ORIGIN },
  });
  assert.equal(response.status, 503);
  assert.equal(issuer.endsWith(".cloudflareaccess.com"), true);
});
