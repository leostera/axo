import assert from "node:assert/strict";
import test from "node:test";
import { localMethods, remoteMethods, results, commandReceiptSchema } from "@axo/protocol";

const id = (n: number) => `00000000-0000-4000-8000-${n.toString().padStart(12, "0")}`;
const target = { machineId: id(1), hostGeneration: id(2) };
const sessions = [{ workspaceId: null, sessionId: id(3) }, { workspaceId: id(4), sessionId: id(5) }];
const parameters = { target, commandId: id(6), sessions, expectedRevision: 7 };
const receipt = { commandId: parameters.commandId, intent: { target, sessions, expectedRevision: 7 }, runtimes: [], revision: 8 };

test("session deletion is closed, local-only, unique and bounded", () => {
  assert.equal("axo.session.delete" in remoteMethods, false);
  const schema = localMethods["axo.session.delete"];
  assert.ok(schema.safeParse(parameters).success);
  for (const invalid of [
    { ...parameters, sessions: [] }, { ...parameters, sessions: [sessions[0], sessions[0]] },
    { ...parameters, sessions: [{ sessionId: id(3) }] }, { ...parameters, argv: ["/bin/sh"] },
    { ...parameters, sessions: Array.from({ length: 33 }, (_, i) => ({ workspaceId: null, sessionId: id(i + 20) })) },
    { ...parameters, expectedRevision: Number.MAX_SAFE_INTEGER },
  ]) assert.equal(schema.safeParse(invalid).success, false);
});
test("prepared deletion is not committed and original receipts retain strict completion shape", () => {
  const schema = results["axo.session.delete"];
  assert.ok(schema.safeParse({ hostGeneration: id(2), receipt }).success);
  assert.ok(schema.safeParse({ hostGeneration: id(2), receipt: { ...receipt, revision: null } }).success);
  assert.ok(commandReceiptSchema.safeParse({ kind: "deletion", receipt }).success);
  assert.equal(schema.safeParse({ hostGeneration: id(2), receipt: { ...receipt, revision: 9 } }).success, false);
  const runtime = { host_generation: id(2), runtime_generation: id(7), target: { session_id: id(3), pane_id: id(8) } };
  assert.equal(schema.safeParse({ hostGeneration: id(2), receipt: { ...receipt, runtimes: [runtime, runtime] } }).success, false);
  assert.equal(schema.safeParse({ hostGeneration: id(2), receipt: { ...receipt, runtimes: [{ ...runtime, target: { ...runtime.target, session_id: id(9) } }] } }).success, false);
});
