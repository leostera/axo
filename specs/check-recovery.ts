import assert from "node:assert/strict";
import spec from "./setup/restart-continuation.ts";

// Admission is independent of the SDK wake mechanism: RFD0081 preserves these invariants.
const checker = new URL("../check/index.ts", import.meta.resolve("@leostera/feynman"));
const { check } = await import(checker.href);
const report = await check(spec, { maxStates: 100_000, timeLimit: 20_000, walks: 100 });
assert.deepEqual(report.errors, []);
for (const property of report.properties) assert.equal(property.holds, true, property.id);
console.log(`restart admission: ${report.states} states; ${report.properties.length} properties`);
