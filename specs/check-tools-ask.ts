import assert from "node:assert/strict";
import spec from "./elicitations/tools-ask.ts";

// The pinned Feynman version exposes its checker internally; keep that dependency here alone.
const checker = new URL("../check/index.ts", import.meta.resolve("@leostera/feynman"));
const { check, checkRules } = await import(checker.href);
const bounds = { maxStates: 200_000, timeLimit: 60_000, walks: 0 };
// The bounded search does not exhaust the agent's choices, so liveness may stay unfinished; no
// safety property may break within the bound.
const report = await check(spec, bounds);
assert.deepEqual(report.errors, []);
for (const property of report.properties) assert.equal(property.holds, true, property.id);
// RFD0070: without the script gate, a script pays without Leo.
const rules = await checkRules(spec, bounds);
const script = rules.find((rule: { name: string }) => rule.name === "scriptActionsGated");
assert.ok(script, "scriptActionsGated is claimed by a property");
for (const needed of script.neededBy) assert.equal(needed.verdict, "breaks", `${needed.property} without scriptActionsGated`);
console.log(`tools ask: ${report.states} states; scriptActionsGated needed by ${script.neededBy.map((n: { property: string }) => n.property).join(", ")}`);
