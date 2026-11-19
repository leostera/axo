import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { test } from "node:test";
import { harness, signInNative, signIn } from "./harness";
import { pairHost, connectHost } from "./account-support";

function candidate(accountId: string) {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const value = { accountId, id: crypto.randomUUID(), expiresAt: Date.now() + 290_000,
    key: publicKey.export({ type: "spki", format: "der" }).subarray(-65).toString("base64"), name: "New iPad", signature: "" };
  const message = `axo-link-recipient/v1\n${value.accountId}\n${value.id}\n${value.expiresAt}\n${value.key}\n${Buffer.from(value.name).toString("base64")}`;
  value.signature = sign("sha256", Buffer.from(message), { key: privateKey, dsaEncoding: "ieee-p1363" }).toString("base64");
  return value;
}

test("a blind linking mailbox is account/session scoped, terminal and never grants authority", { timeout: 20_000 }, async t => {
  const h = await harness(); t.after(() => h.close());
  const target = await signInNative(h, "link-person");
  const hub = await signInNative(h, "link-person");
  const stranger = await signInNative(h, "other-person");
  const web = await signIn(h, "link-person");
  const me = await fetch(new URL("api/auth/me", h.url), { headers: target.headers });
  const accountId = ((await me.json()) as any).accountId;
  const request = candidate(accountId);
  const post = (body: unknown, headers = target.headers) => fetch(new URL("api/v1/account/devices/pairings", h.url), {
    method: "POST", headers, body: JSON.stringify(body),
  });
  assert.equal((await post({ operation: "create", candidate: request }, web.headers)).status, 403);
  assert.equal((await post({ operation: "create", candidate: { ...request, name: "Forged name" } })).status, 400);
  assert.equal((await post({ operation: "create", candidate: request })).status, 200);
  assert.equal((await post({ operation: "create", candidate: request })).status, 200, "same request is idempotent");
  assert.equal((await post({ operation: "create", candidate: { ...request, secret: "not allowed" } })).status, 400);
  assert.deepEqual(await (await post({ operation: "poll", id: request.id })).json(), { state: "waiting" });
  assert.equal((await post({ operation: "poll", id: request.id }, hub.headers)).status, 404);
  const box = Buffer.alloc(100, 1).toString("base64"); // Opaque to the cloud, not a valid client-side trust grant.
  assert.equal((await post({ operation: "complete", id: request.id, box })).status, 403, "a candidate cannot settle its own mailbox");
  assert.equal((await post({ operation: "complete", id: request.id, box }, stranger.headers)).status, 404);
  assert.equal((await post({ operation: "complete", id: request.id, box }, hub.headers)).status, 200);
  assert.equal((await post({ operation: "complete", id: request.id, box }, hub.headers)).status, 200);
  assert.equal((await post({ operation: "complete", id: request.id, box: Buffer.alloc(100, 2).toString("base64") }, hub.headers)).status, 409);
  assert.deepEqual(await (await post({ operation: "poll", id: request.id })).json(), { state: "complete", box });
  assert.equal((await post({ operation: "cancel", id: request.id })).status, 409, "a settled request cannot be rewritten");
});

test("native device-link transport forwards a bound proof, never a QR capability or local management call", { timeout: 20_000 }, async t => {
  const h = await harness(); t.after(() => h.close());
  const native = await signInNative(h, "link-owner"), web = await signIn(h, "link-owner");
  const host = await pairHost(h, web), daemon = await connectHost(h, web, host);
  t.after(() => daemon.close());
  const me = await fetch(new URL("api/auth/me", h.url), { headers: native.headers });
  const accountId = ((await me.json()) as any).accountId;
  const target = candidate(accountId);
  const claim = { id: target.id, accountId, hostId: host.hostId, key: target.key,
    name: target.name, signature: target.signature, proof: target.signature };
  const post = (body: unknown, headers = native.headers) => fetch(new URL("api/v1/account/devices/link", h.url), {
    method: "POST", headers, body: JSON.stringify(body),
  });
  assert.equal((await post({ operation: "redeem", claim }, web.headers)).status, 403);
  assert.equal((await post({ operation: "redeem", claim: { ...claim, secret: "never crosses the relay" } })).status, 400);
  assert.equal((await post({ operation: "redeem", claim: { ...claim, accountId: crypto.randomUUID() } })).status, 403);
  const forwarding = post({ operation: "redeem", claim });
  for (;;) {
    const frame = await daemon.next() as any;
    if (frame.method !== "axo.remote.device.pairing.redeem") continue;
    assert.deepEqual(frame.params, claim);
    daemon.send({ jsonrpc: "2.0", id: frame.id, result: { paired: true, signature: claim.proof } });
    break;
  }
  assert.equal((await forwarding).status, 200);
});
