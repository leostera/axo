import { test } from "node:test";
import assert from "node:assert/strict";
import { localMethods, remoteMethods, results, type AxoClient } from "@axo/protocol";

const target = { machineId: crypto.randomUUID(), hostGeneration: crypto.randomUUID(), workspaceId: null, sessionId: crypto.randomUUID() };

test("retired pane mutations and completion have no local, remote or result contract", () => {
  for (const method of ["axo.session.pane.add", "axo.session.pane.remove", "axo.session.completion"]) {
    assert.equal(method in localMethods, false);
    assert.equal(method in remoteMethods, false);
    assert.equal(method in results, false);
  }
});

function retiredCalls(client: AxoClient) {
  // @ts-expect-error pane admission belongs to central desired intent
  client.request("axo.session.pane.add", { target, commandId: crypto.randomUUID() });
  // @ts-expect-error central removal does not accept the retired launch receipt contract
  client.request("axo.session.pane.remove", { target, commandId: crypto.randomUUID(), paneId: crypto.randomUUID(), runtime: null });
  // @ts-expect-error central completion is source/store fenced, not the retired work-store method
  client.request("axo.session.completion", { target, runtimes: [] });
}
void retiredCalls;
