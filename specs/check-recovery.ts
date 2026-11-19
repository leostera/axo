import assert from "node:assert/strict";
import restart from "./setup/restart-continuation.ts";
import pins from "./setup/pinned-sessions.ts";

// Admission is independent of the SDK wake mechanism: RFD0081 preserves these invariants.
const checker = new URL("../check/index.ts", import.meta.resolve("@leostera/feynman"));
const { check } = await import(checker.href);
for (const spec of [restart, pins]) {
  const report = await check(spec, { maxStates: 100_000, timeLimit: 20_000, walks: 100 });
  assert.deepEqual(report.errors, []);
  for (const property of report.properties) assert.equal(property.holds, true, property.id);
  console.log(`lifecycle admission: ${report.states} states; ${report.properties.length} properties`);
}
