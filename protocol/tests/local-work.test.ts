import assert from "node:assert/strict";
import test from "node:test";
import { localMethods, remoteMethods, results } from "@axo/protocol";

const uuid = "00000000-0000-4000-8000-000000000001";
const params = { target: { machineId: uuid, hostGeneration: uuid }, commandId: uuid,
  expectedRevision: 0, name: "Project", directoryPath: "/tmp/project" };

test("folder-selected workspace creation is local-only, closed and bounded", () => {
  assert.equal("axo.workspace.createLocal" in remoteMethods, false);
  const schema = localMethods["axo.workspace.createLocal"];
  assert.ok(schema.safeParse(params).success);
  for (const directoryPath of ["relative", "", "/bad\0path", "/" + "x".repeat(16384)]) {
    assert.equal(schema.safeParse({ ...params, directoryPath }).success, false);
  }
  assert.equal(schema.safeParse({ ...params, directoryId: "profile" }).success, false);
  assert.ok(results["axo.workspace.createLocal"].safeParse({ hostGeneration: uuid, revision: 1,
    workspace: { workspaceId: uuid, name: "Project", directoryId: "local_" + uuid } }).success);
});
