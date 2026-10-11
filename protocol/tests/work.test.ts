import { test } from "node:test";
import assert from "node:assert/strict";
import {
  workMethods, workMutationMethods, workNameSchema, workResults,
  createProfileServer, serveProfileMessage, type AxoClient,
} from "@axo/protocol";

const target = { machineId: crypto.randomUUID(), hostGeneration: crypto.randomUUID() };
test("work schemas require explicit scopes, safe revisions and approved directory identities", () => {
  const create = { target, commandId: crypto.randomUUID(), expectedRevision: 0, directoryId: "approved", name: "Manual 😃" };
  assert.ok(workMethods["axo.workspace.create"].safeParse(create).success);
  for (const changes of [
    { target: { selected: true } }, { expectedRevision: -1 },
    { expectedRevision: Number.MAX_SAFE_INTEGER + 1 }, { directoryId: "/tmp/raw" },
    { argv: ["/bin/sh"] }, { cwd: "/tmp/raw" }, { name: " leading" },
    { name: "line\nbreak" }, { name: "\u0085" }, { name: "\ud800" },
  ]) assert.equal(workMethods["axo.workspace.create"].safeParse({ ...create, ...changes }).success, false);
  assert.equal(workNameSchema.safeParse("😃".repeat(80)).success, true);
  assert.equal(workNameSchema.safeParse("😃".repeat(81)).success, false);
  assert.equal(workMethods["axo.session.get"].safeParse({ target }).success, false);
  assert.equal(workMethods["axo.session.list"].safeParse({ target, limit: 51 }).success, false);
});

test("manual name protection is a closed optional boolean, not Pi title mutation", () => {
  const session = { sessionId: crypto.randomUUID(), workspaceId: null, name: "Daily work", nameSource: "manual",
    pi: { paneId: crypto.randomUUID(), chatId: null, admission: "notAdmitted", title: "A later Pi title" }, runtime: null };
  const result = { hostGeneration: target.hostGeneration, revision: 1, session };
  const schema = workResults["axo.session.get"];
  assert.ok(schema.safeParse(result).success);
  for (const manualName of [false, true]) assert.ok(schema.safeParse({ ...result, session: { ...session, manualName } }).success);
  for (const manualName of [null, "true", 1]) assert.equal(schema.safeParse({ ...result, session: { ...session, manualName } }).success, false);
});

test("every work-mutation notification is blocked before handler dispatch", async () => {
  const server = createProfileServer(); let mutations = 0;
  for (const method of workMutationMethods) server.addMethod(method, () => { mutations++; return {}; });
  for (const method of workMutationMethods) {
    assert.equal(await serveProfileMessage(server, JSON.stringify({ jsonrpc: "2.0", method, params: {} }), undefined), null);
  }
  assert.equal(mutations, 0);
});

test("work pages are bounded, source-qualified and reject history or path payloads", () => {
  const record = { workspaceId: crypto.randomUUID(), name: '界"\\'.repeat(20), directoryId: "approved" };
  const result = { hostGeneration: target.hostGeneration, revision: 50, workspaces: Array.from({ length: 50 }, () => ({ ...record, workspaceId: crypto.randomUUID() })), next: null };
  assert.ok(workResults["axo.workspace.list"].safeParse(result).success);
  assert.ok(Buffer.byteLength(JSON.stringify(result)) < 65536);
  assert.equal(workResults["axo.workspace.list"].safeParse({ ...result, workspaces: [...result.workspaces, record] }).success, false);
  assert.equal(workResults["axo.workspace.list"].safeParse({ ...result, workspaces: [{ ...record, directory: "/private/path" }] }).success, false);
  assert.equal(workResults["axo.session.get"].safeParse({ hostGeneration: target.hostGeneration, revision: 0, session: { messages: [] } }).success, false);
  assert.ok(workResults["axo.command.get"].safeParse({ hostGeneration: target.hostGeneration, receipt: null }).success);
});

function typedWork(client: AxoClient) {
  client.request("axo.workspace.create", { target, commandId: crypto.randomUUID(), expectedRevision: 0, directoryId: "approved", name: "Workspace" });
  // @ts-expect-error a work session is not the machine or ambient UI selection
  client.request("axo.session.get", { target });
  // @ts-expect-error creating records cannot supply executable arguments
  client.request("axo.workspace.create", { target, commandId: crypto.randomUUID(), expectedRevision: 0, directoryId: "approved", name: "Workspace", argv: ["/bin/sh"] });
}
void typedWork;
