import test from "node:test";
import assert from "node:assert/strict";
import { remoteMethods, results } from "../src/index.js";
const id = (n: number) => `00000000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
const source = { machineId: id(1), hostGeneration: id(2), storeGeneration: id(3) };
const scope = { ...source, workspaceId: null, sessionId: id(4) };
const target = { ...scope, paneId: id(5), chatId: id(6), runtime: { host_generation: id(2), runtime_generation: id(7), target: { session_id: id(4), pane_id: id(5) } } };
const state = { title: "Observed title", leafId: null, busy: false, interactionId: null, uiWaits: 0, question: null, pending: false, recovery: false };
const envelope = (value: unknown) => ({ hostGeneration: source.hostGeneration, storeGeneration: source.storeGeneration, revision: 1, value });
const result = results["axo.state.chat.observe"];
test("central Pi observation is a closed scoped read, not admission or a launch contract", () => {
  const request = remoteMethods["axo.state.chat.observe"];
  assert.ok(request.safeParse({ target: scope }).success);
  for (const key of ["workspaceId", "storeGeneration"]) assert.equal(request.safeParse({ target: { ...scope, [key]: undefined } }).success, false);
  assert.equal(request.safeParse({ target: scope, commandId: id(8) }).success, false);
  assert.ok(result.safeParse(envelope({ kind: "notAdmitted" })).success);
  assert.equal(result.safeParse(envelope({ kind: "notAdmitted", target })).success, false);
});
test("live/stopped alternatives preserve exact identities and do not carry canonical/process paths", () => {
  assert.ok(result.safeParse(envelope({ kind: "live", target, state })).success);
  assert.ok(result.safeParse(envelope({ kind: "stopped", target })).success);
  assert.equal(result.safeParse(envelope({ kind: "stopped", target, state })).success, false);
  for (const key of ["file", "cwd", "pid", "argv"]) assert.equal(result.safeParse(envelope({ kind: "live", target, state: { ...state, [key]: "forbidden" } })).success, false);
  for (const [key, value] of [["sessionId", id(20)], ["paneId", id(20)], ["hostGeneration", id(20)], ["storeGeneration", id(20)]] as const) assert.equal(result.safeParse(envelope({ kind: "live", target: { ...target, [key]: value }, state })).success, false);
  const historical = { ...target, runtime: { ...target.runtime, host_generation: id(8) } };
  assert.equal(result.safeParse(envelope({ kind: "live", target: historical, state })).success, false);
  assert.ok(result.safeParse(envelope({ kind: "stopped", target: historical })).success);
  assert.equal(result.safeParse(envelope({ kind: "live", target, state: { ...state, leafId: "é".repeat(65) } })).success, false);
});
test("exact snapshot contract requires binding identities and returns live state only", () => {
  const request = remoteMethods["axo.state.chat.get"];
  const result = results["axo.state.chat.get"];
  assert.ok(request.safeParse({ target }).success);
  assert.equal(request.safeParse({ target: scope }).success, false);
  assert.equal(request.safeParse({ target: { ...target, runtime: { ...target.runtime, host_generation: id(20) } } }).success, false);
  assert.equal(request.safeParse({ target: { ...target, runtime: { ...target.runtime, target: { ...target.runtime.target, pane_id: id(20) } } } }).success, false);
  assert.ok(result.safeParse(envelope({ kind: "live", target, state })).success);
  assert.equal(result.safeParse(envelope({ kind: "stopped", target })).success, false);
  assert.equal(result.safeParse(envelope({ kind: "notAdmitted" })).success, false);
});
test("questions keep distinct options, active interaction and exact UTF-16 bounds", () => {
  const options = [{ id: id(10), label: "First" }, { id: id(11), label: "Second" }];
  const question = { id: id(9), interactionId: id(12), title: "😀".repeat(1000), options };
  const waiting = { ...state, interactionId: id(12), uiWaits: 1, question };
  assert.ok(result.safeParse(envelope({ kind: "live", target, state: waiting })).success);
  for (const invalid of [
    { ...waiting, interactionId: null }, { ...waiting, uiWaits: 0 },
    { ...waiting, question: { ...question, options: [options[0], options[0]] } },
    { ...waiting, question: { ...question, title: "😀".repeat(1001) } },
    { ...waiting, question: { ...question, options: [{ ...options[0], label: "\0" }, options[1]] } },
  ]) assert.equal(result.safeParse(envelope({ kind: "live", target, state: invalid })).success, false);
});
