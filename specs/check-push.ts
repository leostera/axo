import assert from "node:assert/strict";
import spec from "./elicitations/push.ts";

// The pinned Feynman version exposes its checker internally; keep that dependency here alone.
const checker = new URL("../check/index.ts", import.meta.resolve("@leostera/feynman"));
const { check } = await import(checker.href);
const report = await check(spec, { maxStates: 100_000, timeLimit: 20_000, walks: 0 });
assert.deepEqual(report.errors, []);
assert.equal(report.exhaustive, true, "the finite admission model must be exhausted, not merely sampled");
for (const property of report.properties) {
  assert.equal(property.holds, true, property.id);
  assert.notEqual(property.unfinished, true, property.id);
}
console.log(`push admission: ${report.states} states, ${report.properties.length} properties`);
