import assert from "node:assert/strict";
import { test } from "node:test";
import { hmac, seal } from "../src/auth/crypto";
import { Keyring } from "../src/auth/keys";
import { harness, signIn, testSessionSecret } from "./harness";
import { connectHost, pairHost } from "./account-support";
import { objectRows } from "./storage";

/** RFD0076: the Worker's keys, each used per purpose, and rotated without signing anyone out at once. */

const KEY_1 = "the-first-rotated-key-of-at-least-32-bytes";
const KEY_2 = "the-second-rotated-key-of-at-least-32-bytes";
const secretKeys = (current: { id: number; secret?: string }, previous: { id: number; secret?: string } | null) =>
  JSON.stringify({ current, previous });
const ring = (current: { id: number; secret?: string }, previous: { id: number; secret?: string } | null) =>
  Keyring.parse({ SESSION_SECRET: testSessionSecret, SECRET_KEYS: secretKeys(current, previous) })!;

const legacy = Keyring.legacy(testSessionSecret);
const rotating = ring({ id: 1, secret: KEY_1 }, { id: 0 });
const rotated = ring({ id: 2, secret: KEY_2 }, { id: 1, secret: KEY_1 });

test("key 0 is SESSION_SECRET, used as it always was", async () => {
  assert.equal(await legacy.hash("host-credential", "abc"), await hmac(testSessionSecret, "host-credential\0abc"));
  const sealed = await seal(testSessionSecret, "oauth-flow", { a: 1 });
  assert.deepEqual(await legacy.unseal("oauth-flow", sealed), { a: 1 });
  assert.match(await legacy.seal("oauth-flow", { a: 1 }), /^v1\./);
  assert.deepEqual(Keyring.parse({ SESSION_SECRET: testSessionSecret }), legacy, "without SECRET_KEYS, key 0 is the only key");
});

test("SECRET_KEYS is refused unless every key in it is sound", () => {
  for (const SECRET_KEYS of [
    "not json",
    secretKeys({ id: 0, secret: KEY_1 }, null),
    secretKeys({ id: 1, secret: KEY_1 }, { id: 1, secret: KEY_2 }),
    secretKeys({ id: 1, secret: "short" }, null),
    secretKeys({ id: 1 }, null),
    secretKeys({ id: -1, secret: KEY_1 }, null),
    JSON.stringify({ current: { id: 1, secret: KEY_1 }, extra: true }),
  ]) assert.equal(Keyring.parse({ SESSION_SECRET: testSessionSecret, SECRET_KEYS }), null, SECRET_KEYS);
  assert.equal(Keyring.parse({ SECRET_KEYS: secretKeys({ id: 1, secret: KEY_1 }, { id: 0 }) }), null, "key 0 needs SESSION_SECRET");
  assert.ok(Keyring.parse({ SECRET_KEYS: secretKeys({ id: 1, secret: KEY_1 }, null) }), "a keyed ring needs no SESSION_SECRET");
});

test("a hash names its key, and verifies while that key is current or previous", async () => {
  const old = await legacy.hash("host-credential", "abc");
  const now = await rotating.hash("host-credential", "abc");
  assert.match(now, /^k1\.[A-Za-z0-9_-]{43}$/);
  assert.notEqual(now, await rotating.hash("session", "abc"), "each purpose has a key of its own");
  assert.equal(await rotating.verify("host-credential", "abc", now), "current");
  assert.equal(await rotating.verify("host-credential", "abc", old), "previous");
  assert.equal(await rotating.verify("host-credential", "abd", old), false);
  assert.equal(await rotating.verify("session", "abc", now), false, "nor under another purpose");
  assert.equal(await rotated.verify("host-credential", "abc", now), "previous");
  assert.equal(await rotated.verify("host-credential", "abc", old), false, "a dropped key verifies nothing");
  assert.deepEqual(await rotating.hashes("host-credential", "abc"), [now, old]);
});

test("a seal names its key, and opens while that key is configured", async () => {
  const old = await legacy.seal("apps-grant", { token: "t" });
  const now = await rotating.seal("apps-grant", { token: "t" });
  assert.match(now, /^v2\.1\./);
  assert.deepEqual(await rotating.unseal("apps-grant", old), { token: "t" });
  assert.deepEqual(await rotating.unseal("apps-grant", now), { token: "t" });
  assert.equal(await rotating.unseal("apps-client", now), null, "nor under another purpose");
  assert.deepEqual(await rotated.unseal("apps-grant", now), { token: "t" });
  assert.equal(await rotated.unseal("apps-grant", old), null, "a dropped key opens nothing");
  assert.equal(await legacy.unseal("apps-grant", now), null, "nor does a key that was never configured");
});

test("rotating keys signs no one out at once, and moves each Mac's credential to the current key", async (t) => {
  const h = await harness();
  t.after(() => h.close());
  const me = (session: { headers: Record<string, string> }) => fetch(new URL("api/auth/me", h.url), { headers: session.headers }).then((r) => r.status);
  const verifier = (hostId: string) =>
    objectRows<{ credential_verifier: string }>(h, "AxoAccountDirectory", `SELECT credential_verifier FROM account_hosts WHERE host_id = '${hostId}'`)[0]!.credential_verifier;
  const subject = crypto.randomUUID();
  const before = await signIn(h, subject);
  const mac = await pairHost(h, before, "Studio");
  assert.doesNotMatch(verifier(mac.hostId), /^k/, "made with key 0");

  await h.restart(undefined, { SECRET_KEYS: secretKeys({ id: 1, secret: KEY_1 }, { id: 0 }) });
  assert.equal(await me(before), 200, "a session made with the previous key is still signed in");
  const during = await signIn(h, subject);
  assert.equal(await me(during), 200);
  const daemon = await connectHost(h, before, mac);
  daemon.close();
  assert.match(verifier(mac.hostId), /^k1\./, "the Mac's credential is kept with the current key once it signs in");
  const newMac = await pairHost(h, during, "Laptop");
  assert.match(verifier(newMac.hostId), /^k1\./, "a new Mac's with the current key");

  await h.restart(undefined, { SECRET_KEYS: secretKeys({ id: 2, secret: KEY_2 }, { id: 1, secret: KEY_1 }) });
  assert.equal(await me(before), 401, "a session of the dropped key is signed out");
  assert.equal(await me(during), 200);
  const again = await connectHost(h, during, mac);
  again.close();
  assert.match(verifier(mac.hostId), /^k2\./, "and the Mac signs in still, without pairing again");
});
