import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { harness, signIn, signInNative } from "./harness";
import { connectHost, pairHost } from "./account-support";

async function eventually(predicate: () => boolean) {
  for (let n = 0; n < 150; n++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail("Mock APNs attempt did not arrive");
}

test("in-flight claims cannot duplicate, and old feedback cannot erase a refreshed registration", async t => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const sent: string[] = [];
  const h = await harness({ bindings: {
    APNS_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    APNS_TEAM_ID: "TESTTEAM01", APNS_KEY_ID: "TESTKEY001",
  }, outbound: async request => {
    if (!request.url.startsWith("https://api.sandbox.push.apple.com/")) return undefined;
    sent.push(request.url);
    const attempt = sent.length;
    if (attempt === 1) await gate;
    if (attempt <= 2) return new Response(JSON.stringify({ reason: "Unregistered", timestamp: attempt === 1 ? Date.now() : 1 }), { status: 410 });
    return new Response(null, { status: 200 });
  } });
  t.after(() => { release(); return h.close(); });
  const native = await signInNative(h, "feedback-person"), web = await signIn(h, "feedback-person");
  const host = await pairHost(h, web), daemon = await connectHost(h, web, host);
  t.after(() => daemon.close());
  const installationId = crypto.randomUUID();
  const enroll = (revision: number) => fetch(new URL("api/v1/account/push", h.url), {
    method: "POST", headers: native.headers, body: JSON.stringify({ action: "enable", installationId, revision,
      destination: { topic: "dev.leostera.axo", environment: "sandbox", token: "aabb" } }),
  });
  assert.equal((await enroll(1)).status, 200);
  const question = () => ({ id: crypto.randomUUID(), sessionId: crypto.randomUUID(), kind: "confirm", askedBy: "agent",
    message: "Synthetic question", createdAt: Date.now(), expiresAt: Date.now() + 60_000 });
  const first = question();
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: first });
  await eventually(() => sent.length === 1);
  const ns = await h.mf.getDurableObjectNamespace("TEST_PUSH") as unknown as {
    idFromName(name: string): unknown; get(id: unknown): { dispatch(route: unknown): Promise<unknown> };
  };
  const registry = ns.get(ns.idFromName("sandbox-v1"));
  await Promise.all(Array.from({ length: 4 }, () => registry.dispatch({ accountId: native.accountId,
    hostId: host.hostId, sessionId: first.sessionId, requestId: first.id, expiresAt: first.expiresAt })));
  assert.equal(sent.length, 1);
  assert.equal((await enroll(2)).status, 200);
  release();
  await new Promise(resolve => setTimeout(resolve, 60));
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: question() });
  await eventually(() => sent.length === 2);
  await new Promise(resolve => setTimeout(resolve, 60));
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: question() });
  await eventually(() => sent.length === 3);
  assert.ok(sent.every(url => url.endsWith("/3/device/aabb")));
});
