import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPair, exportJWK, createLocalJWKSet, SignJWT } from "jose";
import { authorize } from "../service/src/access";

const policy = {
  ACCESS_TEAM_URL: "https://test.cloudflareaccess.com", ACCESS_AUD: "axo-audience",
  ACCESS_USER_EMAIL: "me@example.com", ACCESS_HOST_CLIENT_ID: "service-identity.access",
};

test("Access validates signature, issuer, audience, expiry, and role identity", async () => {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const keys = createLocalJWKSet({ keys: [await exportJWK(publicKey)] });
  async function request(changes: Record<string, unknown> = {}) {
    const token = await new SignJWT({ type: "app", email: policy.ACCESS_USER_EMAIL, sub: "user-identity", iss: policy.ACCESS_TEAM_URL, aud: policy.ACCESS_AUD, exp: Math.floor(Date.now() / 1000) + 60, ...changes })
      .setProtectedHeader({ alg: "RS256" }).sign(privateKey);
    return new Request("https://example.com", { headers: { "Cf-Access-Jwt-Assertion": token } });
  }
  assert.equal((await authorize(await request(), "phone", policy, keys)).role, "phone");
  assert.equal((await authorize(await request({ sub: "", email: undefined, common_name: "service-identity.access" }), "host", policy, keys)).role, "host");
  await assert.rejects(authorize(await request(), "host", policy, keys));
  for (const change of [{ type: "org" }, { iss: "https://attacker.example" }, { aud: "other-app" }, { exp: 1 }, { email: "other@example.com" }]) {
    await assert.rejects(authorize(await request(change), "phone", policy, keys));
  }
  const otherKeys = createLocalJWKSet({ keys: [await exportJWK((await generateKeyPair("RS256")).publicKey)] });
  await assert.rejects(authorize(await request(), "phone", policy, otherKeys));
});
