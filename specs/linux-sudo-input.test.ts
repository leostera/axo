import assert from "node:assert/strict";
import test from "node:test";
import spec from "./elicitations/linux-sudo-input.ts";
// Feynman 0.16 exposes the checker through its Bun CLI, not a package subpath.
// Use that same pinned engine under Bazel’s Node/tsx runner, without running a server.
import { check } from "../node_modules/@leostera/feynman/src/check/explore.ts";

test("sudo consent and one-shot binding hold for every state of the bounded model", async () => {
  const report = await check(spec, { walks: 0, maxStates: 100_000, timeLimit: 20_000 });
  assert.deepEqual(report.errors, []);
  assert.equal(report.exhaustive, true, `model truncated: ${report.stoppedBy}, ${report.states} states`);
  assert.equal(report.cutAtDepth, undefined);
  for (const property of report.properties) assert.equal(property.holds, true, JSON.stringify(property));
});

for (const [rule, property] of [["oneShot", "oneValuePerInvocation"], ["boundHelper", "foreignHelperNeverReceivesValue"]]) {
  test(`negative control: removing ${rule} breaks ${property}`, async () => {
    const report = await check(spec.withoutRules([rule]), { walks: 0, maxStates: 100_000, timeLimit: 20_000 });
    assert.deepEqual(report.errors, []);
    assert.equal(report.properties.find(p => p.id === property)?.holds, false);
  });
}
