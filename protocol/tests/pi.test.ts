import { test } from "node:test";
import assert from "node:assert/strict";
import { localMethods, remoteMethods, piMethods, piMutationMethods, piResults, piReceiptSchema, workResults, createProfileServer, serveProfileMessage, type AxoClient } from "@axo/protocol";

const session = { machineId: crypto.randomUUID(), hostGeneration: crypto.randomUUID(), workspaceId: crypto.randomUUID(), sessionId: crypto.randomUUID(), paneId: crypto.randomUUID() };
const chat = { ...session, runtimeHostGeneration: session.hostGeneration, runtimeGeneration: crypto.randomUUID(), chatId: crypto.randomUUID() };
const runtime = { host_generation: chat.runtimeHostGeneration, runtime_generation: chat.runtimeGeneration, target: { session_id: chat.sessionId, pane_id: chat.paneId } };

test("retired Pi admission has no request, result, mutation or receipt contract", () => {
  assert.equal("axo.session.start" in localMethods, false);
  assert.equal("axo.session.start" in remoteMethods, false);
  assert.equal("axo.session.start" in piResults, false);
  assert.equal(piMutationMethods.some(method => String(method) === "axo.session.start"), false);
  const receipt = { commandId: crypto.randomUUID(), intent: { kind: "start", target: session, persistence: { kind: "fresh" } }, disposition: { kind: "prepared" }, runtime: null };
  assert.equal(piReceiptSchema.safeParse(receipt).success, false);
});

test("chat mutations require complete captured destinations and explicit intent", () => {
  const send = { target: chat, commandId: crypto.randomUUID(), text: "Actual message λ 界" };
  assert.ok(piMethods["axo.chat.sendMessage"].safeParse(send).success);
  for (const text of ["", "\u0085", " /model", "\u0085/cmd", "\ud800", "x".repeat(48*1024+1)]) assert.equal(piMethods["axo.chat.sendMessage"].safeParse({ ...send, text }).success, false);
  assert.equal(piMethods["axo.chat.sendSteeringMessage"].safeParse(send).success, false);
  assert.ok(piMethods["axo.chat.sendSteeringMessage"].safeParse({ ...send, interactionId: crypto.randomUUID() }).success);
  assert.equal(piMethods["axo.chat.cancelTurn"].safeParse({ target: chat, commandId: send.commandId }).success, false);
  assert.equal(piMethods["axo.chat.answerQuestion"].safeParse({ target: chat, commandId: send.commandId, questionId: crypto.randomUUID(), optionId: crypto.randomUUID() }).success, false);
});

test("Pi receipts disclose normalized metadata, never message hashes, bodies or canonical paths", () => {
  const receipt = { commandId: crypto.randomUUID(), intent: { kind: "chat", target: chat, operation: "sendMessage" }, disposition: { kind: "dispatched" }, runtime };
  assert.ok(piReceiptSchema.safeParse(receipt).success);
  assert.ok(workResults["axo.command.get"].safeParse({ hostGeneration: session.hostGeneration, receipt: { kind: "pi", receipt } }).success);
  for (const extra of [{ text: "private" }, { preparationHash: "secret" }, { fingerprint: "private" }, { file: "/private/canonical.jsonl" }]) assert.equal(piReceiptSchema.safeParse({ ...receipt, ...extra }).success, false);
  assert.ok(piResults["axo.chat.sendMessage"].safeParse({ hostGeneration: session.hostGeneration, receipt: { ...receipt, disposition: { kind: "prepared" }, runtime: null } }).success);
  assert.equal(piResults["axo.chat.sendMessage"].safeParse({ hostGeneration: session.hostGeneration, executed: true, receipt }).success, false);
});

test("canonical cursors, recorded tool offsets and viewing leases are explicitly bounded", () => {
  const history = { target: chat, readMode: "stopped", limit: 1, cursor: { target: chat, readMode: "stopped", leafId: "recorded-leaf", after: "recorded-entry" } };
  assert.ok(piMethods["axo.chat.history"].safeParse(history).success);
  for (const patch of [{ cursor: null }, { readMode: null }, { limit: 51 }, { cursor: { ...history.cursor, after: "界".repeat(43) } }, { cursor: { ...history.cursor, after: "bad\nidentity" } }]) assert.equal(piMethods["axo.chat.history"].safeParse({ ...history, ...patch }).success, false);
  const detail = { target: chat, entryId: "recorded-entry", toolCallId: "recorded-call", offset: 0, limit: 8192 };
  assert.ok(piMethods["axo.chat.getToolOutput"].safeParse(detail).success);
  for (const patch of [{ path: "/tmp/caller" }, { offset: -1 }, { offset: Number.MAX_SAFE_INTEGER+1 }, { limit: 8193 }, { toolCallId: "" }]) assert.equal(piMethods["axo.chat.getToolOutput"].safeParse({ ...detail, ...patch }).success, false);
  const view = { target: chat, commandId: crypto.randomUUID(), leaseId: crypto.randomUUID(), viewing: true, ttlSeconds: 120 };
  assert.ok(piMethods["axo.chat.setViewing"].safeParse(view).success);
  assert.equal(piMethods["axo.chat.setViewing"].safeParse({ ...view, ttlSeconds: 121 }).success, false);
});

test("every managed Pi mutation notification is non-executing", async () => {
  const server = createProfileServer(); let executions = 0;
  for (const method of piMutationMethods) {
    server.addMethod(method, () => { executions++; return {}; });
    assert.equal(await serveProfileMessage(server, JSON.stringify({ jsonrpc: "2.0", method, params: {} }), undefined), null);
  }
  assert.equal(executions, 0);
});

function typedChat(client: AxoClient) {
  // @ts-expect-error clients cannot admit Pi through the retired start method
  client.request("axo.session.start", { target: session, commandId: crypto.randomUUID(), persistence: { kind: "fresh" } });
  client.request("axo.chat.sendMessage", { target: chat, commandId: crypto.randomUUID(), text: "Explicit normal intent" });
  // @ts-expect-error chat mutations cannot infer a work session/pane/runtime
  client.request("axo.chat.sendMessage", { target: session, commandId: crypto.randomUUID(), text: "Missing captured chat" });
  // @ts-expect-error a steering intent cannot become a fresh interaction
  client.request("axo.chat.sendSteeringMessage", { target: chat, commandId: crypto.randomUUID(), text: "Missing captured interaction" });
}
void typedChat;
