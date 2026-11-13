import assert from "node:assert/strict";
import { test } from "node:test";
import { AI_MODEL, aiInputs, aiResults } from "../src/ai.ts";
import { RESERVED_NAMES } from "../src/apps.ts";

test("local AI inputs default host and output limit, but reject arbitrary models and runtime options", () => {
  assert.deepEqual(aiInputs.run.parse({ model: AI_MODEL, prompt: "hello" }), { host: "self", model: AI_MODEL, prompt: "hello", maxTokens: 512 });
  assert.deepEqual(aiInputs.list.parse({}), { host: "self" });
  for (const input of [
    { model: "hf:someone/anything", prompt: "x" },
    { model: AI_MODEL, prompt: "x", flags: ["--tools", "all"] },
    { model: AI_MODEL, prompt: "x", maxTokens: 4097 },
    { model: AI_MODEL, prompt: "" },
  ]) assert.equal(aiInputs.run.safeParse(input).success, false);
  assert.ok(RESERVED_NAMES.includes("ai"));
});

test("AI results require immutable source provenance and a finish reason", () => {
  assert.equal(aiResults.run.safeParse({ model: AI_MODEL, text: "hello" }).success, false);
  assert.equal(aiResults.load.safeParse({ model: AI_MODEL, status: "loaded" }).success, false);
});
