import { test } from "node:test";
import assert from "node:assert/strict";
import { paneMethods, paneMutationMethods, paneReceiptSchema, localMethods, remoteMethods, workResults, createProfileServer, serveProfileMessage, type AxoClient } from "@axo/protocol";
const target = { machineId: crypto.randomUUID(), hostGeneration: crypto.randomUUID(), workspaceId: crypto.randomUUID(), sessionId: crypto.randomUUID() };
const paneId = crypto.randomUUID();
const runtime = { host_generation: target.hostGeneration, target: { session_id: target.sessionId, pane_id: paneId }, runtime_generation: crypto.randomUUID() };
test("pane add/remove are local-only, captured operations without geometry, arbitrary argv or an implicit start", () => {
  const add = { target, commandId: crypto.randomUUID(), profileId: "shell" };
  assert.ok(paneMethods["axo.session.pane.add"].safeParse(add).success);
  for (const patch of [{ direction: "right" }, { argv: ["/bin/sh"] }, { cwd: "/tmp" }, { profileId: "../shell" }, { target: { ...target, sessionId: undefined } }]) assert.equal(paneMethods["axo.session.pane.add"].safeParse({ ...add, ...patch }).success, false);
  const remove = { target, commandId: crypto.randomUUID(), paneId, runtime };
  assert.ok(paneMethods["axo.session.pane.remove"].safeParse(remove).success);
  assert.ok(paneMethods["axo.session.pane.remove"].safeParse({ ...remove, runtime: null }).success);
  assert.equal(paneMethods["axo.session.pane.remove"].safeParse({ ...remove, runtime: undefined }).success, false);
  for (const method of paneMutationMethods) { assert.ok(method in localMethods); assert.equal(method in remoteMethods, false); }
});
test("pane command reconciliation exposes original disposition and identities, not a fabricated screen", () => {
  const receipt = { commandId: crypto.randomUUID(), intent: { operation: "addPane", target, profileId: "shell" }, paneId, runtime, disposition: { kind: "added" } };
  assert.ok(paneReceiptSchema.safeParse(receipt).success);
  assert.ok(workResults["axo.command.get"].safeParse({ hostGeneration: target.hostGeneration, receipt: { kind: "pane", receipt } }).success);
  for (const extra of [{ argv: ["/bin/sh"] }, { screen: "private" }, { terminalBytes: "private" }, { direction: "down" }]) assert.equal(paneReceiptSchema.safeParse({ ...receipt, ...extra }).success, false);
});
test("pane mutation notifications never invoke handlers", async () => {
  const server = createProfileServer(); let executions = 0;
  for (const method of paneMutationMethods) {
    server.addMethod(method, () => { executions++; return {}; });
    assert.equal(await serveProfileMessage(server, JSON.stringify({ jsonrpc: "2.0", method, params: {} }), undefined), null);
  }
  assert.equal(executions, 0);
});
function typedPane(client: AxoClient) {
  client.request("axo.session.pane.add", { target, commandId: crypto.randomUUID(), profileId: "shell" });
  client.request("axo.session.pane.remove", { target, commandId: crypto.randomUUID(), paneId, runtime });
  // @ts-expect-error removal must capture runtime, including explicit null for a proven unlaunched pane
  client.request("axo.session.pane.remove", { target, commandId: crypto.randomUUID(), paneId });
  // @ts-expect-error split geometry is native-local, not an RPC argument
  client.request("axo.session.pane.add", { target, commandId: crypto.randomUUID(), profileId: "shell", direction: "right" });
}
void typedPane;
