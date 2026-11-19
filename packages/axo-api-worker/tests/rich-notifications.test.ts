import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash, generateKeyPairSync } from "node:crypto";
import { harness, signIn, signInNative } from "./harness";
import { connectHost, pairHost } from "./account-support";
import { ApnsRequestNotice } from "../src/push/apns";
import { notificationContentSchema, notifyInputSchema } from "../src/push/content";
import { notificationTextInput, textInputDigest } from "../src/push/text-input";
import { elicitationSchema } from "@axo/protocol";

async function eventually(predicate: () => boolean) {
  for (let n = 0; n < 150; n++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail("Expected mock notification did not arrive");
}

async function fixture(t: { after(fn: () => unknown): void }) {
  const sent: any[] = [];
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const h = await harness({ bindings: { APNS_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    APNS_TEAM_ID: "TESTTEAM01", APNS_KEY_ID: "TESTKEY001" }, outbound: async request => {
    if (!request.url.startsWith("https://api.sandbox.push.apple.com/")) return undefined;
    sent.push(await request.json()); return new Response(null, { status: 200 });
  } });
  t.after(() => h.close());
  const native = await signInNative(h, "rich-person"), web = await signIn(h, "rich-person");
  const host = await pairHost(h, web), daemon = await connectHost(h, web, host);
  t.after(() => daemon.close());
  const sessionId = crypto.randomUUID();
  const post = (path: string, body: unknown, headers = native.headers) => fetch(new URL(path, h.url), {
    method: "POST", headers, body: JSON.stringify(body),
  });
  const enable = await post("api/v1/account/push", { action: "enable", installationId: crypto.randomUUID(), revision: 1,
    previews: "message", destination: { topic: "dev.leostera.axo", environment: "sandbox", token: "aabb" } });
  assert.equal(enable.status, 200);
  return { h, sent, native, web, host, daemon, sessionId, post };
}

const question = (sessionId: string, message = "Install the tested development build?") => ({
  id: crypto.randomUUID(), sessionId, kind: "confirm", askedBy: "agent", message,
  createdAt: Date.now(), expiresAt: Date.now() + 60_000,
});

test("new updates are concise without invalidating retained notification content", () => {
  assert.ok(notifyInputSchema.safeParse({ title: "Build ready", message: "🦎".repeat(140) }).success);
  assert.equal(notifyInputSchema.safeParse({ title: "Build ready", message: "x".repeat(141) }).success, false);
  assert.equal(notifyInputSchema.safeParse({ title: "x".repeat(49), message: "Ready" }).success, false);
  assert.ok(notificationContentSchema.safeParse({ title: "Old update", message: "x".repeat(240) }).success);
});

test("short complete questions carry authenticated-action metadata; truncated questions never do", async () => {
  const route = { accountId: crypto.randomUUID(), hostId: crypto.randomUUID(), sessionId: crypto.randomUUID(), requestId: crypto.randomUUID() };
  for (const message of ["Approve the harmless test?", "🦎".repeat(140)]) {
    const body = JSON.parse((await ApnsRequestNotice.withQuestion(route, Date.now() + 60_000, message, "Release approval")).body);
    assert.equal(body.aps.alert.title, "Release approval");
    assert.equal(body.aps.alert.body, message);
    assert.equal(body.aps.category, "AXO_CONFIRM_V1");
    assert.equal(body.axoRequest.digest, createHash("sha256").update(message).digest("hex"));
    assert.deepEqual(Object.keys(body.axo).sort(), ["accountId", "hostId", "requestId", "sessionId", "version"]);
  }
  const long = JSON.parse((await ApnsRequestNotice.withQuestion(route, Date.now() + 60_000, "a".repeat(141))).body);
  assert.equal(long.aps.category, "AXO_REVIEW_V1");
  assert.equal(Array.from(long.aps.alert.body).length, 140);
  assert.equal(long.axoRequest, undefined);
});

test("current confirm-only content is immutable and signed-in native clients answer without device enrollment", async t => {
  const { sent, native, host, daemon, sessionId, post } = await fixture(t);
  const asked = { ...question(sessionId), title: "Release approval" };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: asked });
  await eventually(() => sent.length === 1);
  assert.equal(sent[0].aps.alert.title, asked.title);
  assert.equal(sent[0].aps.alert.body, asked.message);
  const read = { operation: "read", hostId: host.hostId, requestId: asked.id };
  assert.equal((await post("api/v1/account/push/request", read, {})).status, 401);
  const current = await post("api/v1/account/push/request", read);
  assert.equal(current.status, 200);
  assert.equal(((await current.json()) as any).elicitation.message, asked.message);
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: { ...asked, message: "Changed operation" } });
  await new Promise(resolve => setTimeout(resolve, 30));
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: { ...asked, title: "Changed heading" } });
  await new Promise(resolve => setTimeout(resolve, 30));
  const unchanged = await post("api/v1/account/push/request", read);
  const retained = ((await unchanged.json()) as any).elicitation;
  assert.equal(retained.message, asked.message);
  assert.equal(retained.title, asked.title);
  const answer = { operation: "answer", hostId: host.hostId, requestId: asked.id, action: "accept",
    digest: sent[0].axoRequest.digest, expiresAt: asked.expiresAt };
  assert.equal((await post("api/v1/account/push/request", { ...answer, digest: "0".repeat(64) })).status, 409);
  // The account session authorizes this human action; the host still settles the live request.
  const answering = post("api/v1/account/push/request", answer);
  for (;;) {
    const frame = await daemon.next() as any;
    if (frame.method !== "axo.elicitation.resolve") continue;
    assert.equal(frame.params.device, undefined);
    daemon.send({ jsonrpc: "2.0", id: frame.id, result: { resolved: true } });
    break;
  }
  assert.equal((await answering).status, 200);
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.resolved", params: { id: asked.id, sessionId, action: "accept" } });
  await eventually(() => sent.some(value => value.axoResolution?.version === 1));
  const cleanup = sent.find(value => value.axoResolution?.version === 1);
  assert.equal(cleanup.axo.requestId, asked.id);
  assert.equal(cleanup.axo.sessionId, sessionId);
  assert.deepEqual(cleanup.aps, { "content-available": 1 });
  assert.equal((await post("api/v1/account/push/request", answer)).status, 409);
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: asked });
  await new Promise(resolve => setTimeout(resolve, 50));
  assert.equal((await post("api/v1/account/push/request", read)).status, 409, "a late replay cannot resurrect a settled request");
});

test("sensitive input stays generic even with rich previews enabled", async t => {
  const { sent, daemon, sessionId, host, post } = await fixture(t);
  const asked = { ...question(sessionId, "Private input fixture"), kind: "input", input: {
    app: "Fixture", window: "Private window", fields: [{ id: "f0", label: "Password", kind: "password" }],
    key: Buffer.alloc(65, 1).toString("base64"),
  } };
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: asked });
  await eventually(() => sent.length === 1);
  assert.equal(sent[0].aps.alert.body, "A request needs your attention.");
  assert.equal(sent[0].axoRequest, undefined);
  assert.equal(JSON.stringify(sent[0]).includes("Private"), false);
  assert.equal((await post("api/v1/account/push/request", { operation: "read", hostId: host.hostId, requestId: asked.id })).status, 409);
});

test("inline text replies bind the full target, stay encrypted, and settle through the existing daemon", async t => {
  const { sent, host, daemon, sessionId, post, web } = await fixture(t);
  const asked = { ...question(sessionId, "Name 🦎?"), kind: "input", askedBy: "computerUse", input: {
    app: "Fixture", window: "Reply", origin: "https://example.test",
    fields: [{ id: "f0", label: "Reply", kind: "text" }], submit: "Save", key: Buffer.alloc(65, 1).toString("base64"),
  } };
  const eligible = notificationTextInput(elicitationSchema.parse(asked))!;
  assert.ok(eligible);
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: asked });
  await eventually(() => sent.length === 1);
  assert.equal(sent[0].aps.category, "AXO_INPUT_TEXT_V1");
  assert.equal(sent[0].aps.alert.body, eligible.body);
  assert.equal(sent[0].axoRequest, undefined);
  assert.equal(sent[0].axoInput.digest, await textInputDigest(eligible));
  const common = { hostId: host.hostId, requestId: asked.id };
  const current = await post("api/v1/account/push/request", { ...common, operation: "read" });
  assert.equal(current.status, 200);
  assert.deepEqual((await current.json() as any).elicitation.input, asked.input);
  const reply = { ...common, operation: "reply", digest: sent[0].axoInput.digest, expiresAt: asked.expiresAt,
    sealed: { enc: Buffer.alloc(65, 2).toString("base64"), ciphertext: "AAAA" } };
  assert.equal((await post("api/v1/account/push/request", reply, web.headers)).status, 403);
  assert.equal((await post("api/v1/account/push/request", { ...reply, text: "never plaintext" })).status, 400);
  assert.equal((await post("api/v1/account/push/request", { ...reply, digest: "0".repeat(64) })).status, 409);
  assert.equal((await post("api/v1/account/push/request", { ...reply, expiresAt: asked.expiresAt + 1 })).status, 409);
  assert.equal((await post("api/v1/account/push/request", { ...common, operation: "answer", action: "accept",
    digest: sent[0].axoInput.digest, expiresAt: asked.expiresAt })).status, 409, "Yes/No cannot submit input");
  const answering = post("api/v1/account/push/request", reply);
  for (;;) {
    const frame = await daemon.next() as any;
    if (frame.method !== "axo.elicitation.resolve") continue;
    assert.deepEqual(frame.params.sealed, reply.sealed);
    assert.equal(frame.params.action, "accept");
    assert.equal(frame.params.elicitationId, asked.id);
    assert.equal(frame.params.values, undefined);
    assert.equal(frame.params.device, undefined);
    daemon.send({ jsonrpc: "2.0", id: frame.id, result: { resolved: true } });
    break;
  }
  assert.equal((await answering).status, 200);
  daemon.send({ jsonrpc: "2.0", method: "axo.elicitation.resolved", params: { id: asked.id, sessionId, action: "accept" } });
  await eventually(() => sent.some(value => value.axoResolution?.version === 1));
  assert.equal((await post("api/v1/account/push/request", reply)).status, 409);
});

test("input notification eligibility excludes secrets, forms, and incomplete target previews", async () => {
  const base = elicitationSchema.parse({ ...question(crypto.randomUUID(), "Name 🦎?"), kind: "input", input: {
    app: "Fixture", window: "Reply", origin: "https://example.test",
    fields: [{ id: "f0", label: "Reply", kind: "text" }], submit: "Save", key: Buffer.alloc(65, 1).toString("base64"),
  } });
  const eligible = notificationTextInput(base)!;
  assert.equal(await textInputDigest(eligible), "785ea9e95e570d37352fe211463caa65d2b2d6c883d9e8a32f5926b88fabdcf4");
  for (const kind of ["password", "code", "email", "username"] as const) {
    assert.equal(notificationTextInput({ ...base, input: { ...base.input!, fields: [{ ...base.input!.fields[0]!, kind }] } }), null);
  }
  assert.equal(notificationTextInput({ ...base, input: { ...base.input!, fields: [...base.input!.fields, { id: "f1", kind: "text", label: "Second" }] } }), null);
  assert.equal(notificationTextInput({ ...base, message: "x".repeat(141) }), null);
  for (const change of [{ app: "Other" }, { window: "Other" }, { origin: "https://other.test" }, { submit: "Send" },
    { key: Buffer.alloc(65, 2).toString("base64") }, { fields: [{ id: "f1", label: "Reply", kind: "text" as const }] }]) {
    const changed = notificationTextInput({ ...base, input: { ...base.input!, ...change } })!;
    assert.notEqual(await textInputDigest(changed), await textInputDigest(eligible));
  }
});

test("codemode.notify queues account-bound informational updates once and exposes private history", async t => {
  const { h, sent, daemon, sessionId, native, host } = await fixture(t);
  const command = { title: "Build ready", message: "The tested build is ready to install.", idempotencyKey: crypto.randomUUID() };
  const code = `async () => Promise.all([codemode.notify(${JSON.stringify(command)}), codemode.notify(${JSON.stringify(command)})])`;
  const outcome = await daemon.call("axo.apps.run", { sessionId, code }) as any;
  assert.ok(outcome.result, JSON.stringify(outcome));
  assert.equal(outcome.result.result[0].queued, true);
  assert.equal(outcome.result.result[0].id, outcome.result.result[1].id);
  await eventually(() => sent.length === 1);
  assert.equal(sent[0].aps.alert.body, command.message);
  assert.equal(sent[0].aps.category, undefined);
  assert.equal(sent[0].axoRequest, undefined);
  assert.equal(sent[0].axoNotice.kind, "information");
  const history = await fetch(new URL("api/v1/account/notifications", h.url), { headers: native.headers });
  const list = (await history.json()) as any;
  assert.equal(list.notifications.length, 1);
  assert.equal(list.notifications[0].hostId, host.hostId);
  assert.equal(list.notifications[0].sessionId, sessionId);
  const other = await signInNative(h);
  const privateHistory = await fetch(new URL("api/v1/account/notifications", h.url), { headers: other.headers });
  assert.deepEqual((await privateHistory.json() as any).notifications, []);
  const changed = await daemon.call("axo.apps.run", { sessionId,
    code: `async () => codemode.notify(${JSON.stringify({ ...command, message: "Different" })})` }) as any;
  assert.ok(changed.error);
  const malformed = await daemon.call("axo.apps.run", { sessionId,
    code: 'async () => codemode.notify({title:"Not an approval",message:"Fixture",action:"accept"})' }) as any;
  assert.ok(malformed.error);
});
