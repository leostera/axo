import assert from "node:assert/strict";
import test from "node:test";
import { atMost, defineActor, defineProperty, defineSpec, defineZone } from "@leostera/feynman";
import restart from "./setup/restart-continuation.ts";
import pins from "./setup/pinned-sessions.ts";
// The same pinned checker used by linux-sudo-input.test.ts, without Bun or a daemon.
import { check } from "../node_modules/@leostera/feynman/src/check/explore.ts";

// Admission only: this does not claim exactly-once delivery across process/network crashes.
const options = { maxStates: 100_000, timeLimit: 20_000, walks: 0 };
console.log(`recovery checker: Node ${process.versions.node}; ${process.platform}/${process.arch}; exhaustive bounded models, no sampled walks`);
for (const [name, spec, properties] of [
  ["restart continuation", restart, ["oneResumePerIntent", "newPromptWins"]],
  ["pinned process admission", pins, ["oneProcess", "closeWins", "launchWaitsForExit"]],
] as const) {
  test(`${name}: every state of the bounded model preserves admission`, async () => {
    const report = await check(spec, options);
    assert.deepEqual(report.errors, []);
    assert.equal(report.exhaustive, true, `model truncated: ${report.stoppedBy}, ${report.states} states`);
    assert.equal(report.cutAtDepth, undefined);
    assert.ok(report.states > 0);
    assert.deepEqual(report.properties.map(property => property.id).sort(), [...properties].sort());
    for (const property of report.properties) assert.equal(property.holds, true, JSON.stringify(property));
    console.log(`${name}: ${report.states} states; ${report.properties.length} properties`);
  });
}

for (const [name, property] of [
  ["unconsumed resume intent", "oneResumePerIntent"],
  ["replacement launched before old writer exits", "oneProcess"],
] as const) {
  test(`negative control: ${name} has a counterexample`, async () => {
    // Minimal unsafe variants: a second connection/launch increments without
    // consuming the intent or retiring the old process. The checker must reject them.
    const unsafe = defineActor({
      name, singleton: true, zone: defineZone({ name: "owned negative control", place: { column: 0 } }),
      initialState: () => ({ count: property === "oneProcess" ? 1 : 0 }),
      actions: { repeat: { label: "Unsafe repeated admission", with: [atMost(2)], run(state) { state.count++; } } },
    });
    const spec = defineSpec({
      name, actors: [unsafe],
      properties: [defineProperty(property, { description: "Unsafe repetition must violate the one-intent/one-writer bound.", always: world => world.the(unsafe).state.count <= 1 })],
    });
    const report = await check(spec, options);
    assert.deepEqual(report.errors, []);
    assert.equal(report.properties.find(result => result.id === property)?.holds, false);
  });
}
