import { test } from "node:test";
import assert from "node:assert/strict";
import { localMethods, remoteMethods, results, type AxoClient } from "@axo/protocol";

const target = { machineId: crypto.randomUUID(), hostGeneration: crypto.randomUUID() };
const sessions = [{ workspaceId: null, sessionId: crypto.randomUUID() }];

test("retired Delete and keep-alive negotiation have no request or result contract", () => {
  for (const method of ["axo.session.delete", "axo.host.lifecycle"]) {
    assert.equal(method in localMethods, false);
    assert.equal(method in remoteMethods, false);
    assert.equal(method in results, false);
  }
});

function retiredCalls(client: AxoClient) {
  // @ts-expect-error Delete needs the central completion-proven contract, not the old work store
  client.request("axo.session.delete", { target, commandId: crypto.randomUUID(), sessions, expectedRevision: 0 });
  // @ts-expect-error central lifecycle ownership is not an optional negotiated keep-alive boolean
  client.request("axo.host.lifecycle", { target });
}
void retiredCalls;
