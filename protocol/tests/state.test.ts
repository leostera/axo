import test from "node:test";
import assert from "node:assert/strict";
import { localMethods, remoteMethods, results, createProfileServer, serveProfileMessage } from "../src/index.js";
const id = (n: number) => `00000000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
const target = { machineId: id(1), hostGeneration: id(2), storeGeneration: id(3) };
const session = { sessionId: id(4), workspaceId: id(5), name: "Session", manualName: false, lifecycle: "open", configRevision: 1 };
const pane = { paneId: id(6), sessionId: session.sessionId, role: { kind: "pi" }, present: true, ordinal: 0, configRevision: 1 };
const shell = { ...pane, paneId: id(7), role: { kind: "accountShell" }, ordinal: 1 };
const observed = { session, panes: [pane, shell].map(desired => ({ desired, availability: "materializing", lastRuntime: null, terminal: null })), readiness: "materializing" };
const envelope = { hostGeneration: target.hostGeneration, storeGeneration: target.storeGeneration, revision: 1 };
test("central commands require store generation, explicit workspace scope and no arbitrary launch fields", () => {
  const request = { target, commandId: id(8), expectedRevision: 0, workspaceId: null, name: "Session" };
  assert.ok(remoteMethods["axo.state.session.create"].safeParse(request).success);
  assert.equal(remoteMethods["axo.state.session.create"].safeParse({ ...request, workspaceId: undefined }).success, false);
  assert.equal(remoteMethods["axo.state.session.create"].safeParse({ ...request, target: { ...target, storeGeneration: undefined } }).success, false);
  assert.equal(remoteMethods["axo.state.session.create"].safeParse({ ...request, argv: ["zsh"] }).success, false);
  assert.ok(remoteMethods["axo.state.workspace.rename"].safeParse({ target, commandId: id(9), expectedRevision: 1, workspaceId: id(5), name: "Renamed" }).success);
  assert.equal(remoteMethods["axo.state.workspace.rename"].safeParse({ target, commandId: id(9), expectedRevision: 1, workspaceId: id(5), name: "  " }).success, false);
  assert.ok(remoteMethods["axo.state.session.rename"].safeParse({ target: { ...target, workspaceId: id(5), sessionId: id(4) }, commandId: id(10), expectedRevision: 1, name: "Manual" }).success);
  assert.equal(Object.hasOwn(remoteMethods, "axo.state.workspace.create"), false);
  assert.ok(localMethods["axo.state.workspace.create"].safeParse({ target, commandId: id(8), expectedRevision: 0, name: "Workspace", directoryPath: "/approved" }).success);
  assert.equal(localMethods["axo.state.workspace.list"].safeParse({ target, cursor: null }).success, false);
});
test("central graph observations cannot claim ready without every desired terminal", () => {
  assert.ok(results["axo.state.session.get"].safeParse({ ...envelope, value: observed }).success);
  assert.equal(results["axo.state.session.get"].safeParse({ ...envelope, value: { ...observed, readiness: "ready" } }).success, false);
  assert.equal(results["axo.state.session.get"].safeParse({ ...envelope, value: { ...observed, panes: [observed.panes[0], observed.panes[0]] } }).success, false);
});
test("original graph result is separate from current availability", () => {
  const operation = { kind: "createWorkspace", accepted: { commandId: id(8), revision: 1, graph: { workspace: { workspaceId: id(5), name: "Workspace", directory: "/approved", lifecycle: "open", configRevision: 1 }, initialSession: { session, panes: [pane, shell] } } } };
  assert.ok(results["axo.state.workspace.create"].safeParse({ ...envelope, value: { operation, session: observed } }).success);
  const manualSession = { ...session, name: "Manual", manualName: true, configRevision: 2 };
  const renamed = { kind: "renameSession", accepted: { commandId: id(10), revision: 2, graph: manualSession } };
  assert.ok(results["axo.state.session.rename"].safeParse({ ...envelope, revision: 2, value: { operation: renamed, session: { ...observed, session: manualSession } } }).success);
  assert.equal(results["axo.state.session.rename"].safeParse({ ...envelope, revision: 2, value: { operation: { ...renamed, accepted: { ...renamed.accepted, graph: { ...manualSession, manualName: false } } }, session: observed } }).success, false);
});
test("central mutation notifications never invoke registered effects", async () => {
  const server = createProfileServer<void>(); let effects = 0;
  server.addMethod("axo.state.session.create", () => { effects++; return {}; });
  assert.equal(await serveProfileMessage(server, JSON.stringify({ jsonrpc: "2.0", method: "axo.state.session.create", params: {} }), undefined), null);
  assert.equal(effects, 0);
});
