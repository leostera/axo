import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { harness, signIn, signInNative, type Harness } from "./harness";
import { connectClient, connectHost, pairHost } from "./account-support";

const destination = { topic: "dev.leostera.axo", environment: "sandbox", token: "aabbccdd" };
const enable = (installationId = crypto.randomUUID(), revision = 1) => ({ action: "enable", installationId, revision, destination });
const enroll = (h: Harness, session: { headers: Record<string, string> }, body: unknown) => fetch(new URL("api/v1/account/push", h.url), {
  method: "POST", headers: session.headers, body: JSON.stringify(body),
});

async function settled<T>(read: () => T, predicate: (value: T) => boolean): Promise<T> {
  for (let n = 0; n < 100; n++) {
    const value = read();
    if (predicate(value)) return value;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail("Push did not settle");
}

test("only native person sessions enroll; bounded schema rejects production and old topics", async t => {
  const h = await harness(); t.after(() => h.close());
  const web = await signIn(h);
  assert.equal((await enroll(h, { headers: {} }, enable())).status, 401);
  assert.equal((await enroll(h, web, enable())).status, 403);
  const native = await signInNative(h);
  for (const invalid of [
    { ...enable(), destination: { ...destination, topic: "dev.leostera.axo.phone" } },
    { ...enable(), destination: { ...destination, environment: "production" } },
    { ...enable(), destination: { ...destination, token: "not a token" } },
    { ...enable(), revision: -1 },
    { ...enable(), unexpected: "x".repeat(9000) },
  ]) assert.equal((await enroll(h, native, invalid)).status, 400);
  const response = await enroll(h, native, enable());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { revision: 1 });
});

test("rotation, disable, account switches and restarts fence older requests", async t => {
  const h = await harness(); t.after(() => h.close());
  const a = await signInNative(h), b = await signInNative(h);
  const command = enable();
  assert.equal((await enroll(h, a, command)).status, 200);
  assert.equal((await enroll(h, b, enable())).status, 409, "another install cannot steal a token");
  assert.equal((await enroll(h, b, { ...command, revision: 3 })).status, 200);
  assert.equal((await enroll(h, a, { ...command, revision: 2 })).status, 409);
  assert.equal((await enroll(h, b, { action: "disable", installationId: command.installationId, revision: 4 })).status, 200);
  await h.restart();
  assert.equal((await enroll(h, a, { ...command, revision: 3 })).status, 409);
  assert.equal((await enroll(h, b, { ...command, revision: 5 })).status, 200);
  const ended = await fetch(new URL("api/auth/logout", h.url), { method: "POST", headers: b.headers });
  assert.equal(ended.status, 204);
  assert.equal((await enroll(h, b, { ...command, revision: 6 })).status, 401);
});

test("authoritative pending requests dispatch generic APNs once; revocation stops future dispatch", async t => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const sent: { url: string; body: unknown }[] = [];
  const h = await harness({ bindings: {
    APNS_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    APNS_TEAM_ID: "TESTTEAM01", APNS_KEY_ID: "TESTKEY001",
  }, outbound: async request => {
    if (!request.url.startsWith("https://api.sandbox.push.apple.com/")) return undefined;
    sent.push({ url: request.url, body: await request.json() });
    return new Response(null, { status: 200 });
  } }); t.after(() => h.close());
  const native = await signInNative(h, "push-person");
  const web = await signIn(h, "push-person");
  const host = await pairHost(h, web);
  const daemon = await connectHost(h, web, host); t.after(() => daemon.close());
  const { client } = await connectClient(h, web); t.after(() => client.close());
  assert.equal((await enroll(h, native, enable())).status, 200);
  const request = { id: crypto.randomUUID(), sessionId: crypto.randomUUID(), kind: "confirm", askedBy: "agent",
    message: "PRIVATE QUESTION MUST NOT ENTER APNS", createdAt: Date.now(), expiresAt: Date.now() + 60_000 };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: request });
  await settled(() => sent, value => value.length === 1);
  assert.equal(sent[0]!.url, "https://api.sandbox.push.apple.com/3/device/aabbccdd");
  const payload = JSON.stringify(sent[0]!.body);
  assert.equal(payload.includes(request.message), false);
  assert.equal(payload.includes("approve"), false);
  assert.equal(payload.includes(request.id), true);
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: request });
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(sent.length, 1, "a host replay never re-arms dispatch");
  await h.restart();
  const resumed = await connectHost(h, web, host); t.after(() => resumed.close());
  resumed.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: request });
  await new Promise(resolve => setTimeout(resolve, 150));
  assert.equal(sent.length, 1, "a durable claim survives worker restart and host replay");
  await fetch(new URL("api/auth/logout", h.url), { method: "POST", headers: native.headers });
  resumed.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: { ...request, id: crypto.randomUUID() } });
  await new Promise(resolve => setTimeout(resolve, 150));
  assert.equal(sent.length, 1);
});
