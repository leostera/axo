import assert from "node:assert/strict";
import { test } from "node:test";
import { z } from "zod";
import { aiInputs, aiRequest, aiResults } from "../src/ai.ts";
import { RESERVED_NAMES } from "../src/apps.ts";

const model = "hf:someone/model:Q4_K_M@abcdef";
test("model selection is generic and prompt is normalized only at the public boundary", () => {
  assert.deepEqual(aiRequest("run", { model, prompt: "hello" }), { host: "self", request: { op: "run", model, task: "generate", input: "hello", maxTokens: 512 } });
  assert.deepEqual(aiRequest("run", { model, input: "hello" }), { host: "self", request: { op: "run", model, task: "generate", input: "hello", maxTokens: 512 } });
  for (const reference of ["hf:ggml-org/Clef-Flash-GGUF", "hf:mlx-community/clef-omni-4bit", "hf:somewhere/not-yet-seen"]) assert.equal(aiInputs.info.safeParse({ model: reference }).success, true);
  assert.ok(RESERVED_NAMES.includes("ai"));
  assert.equal(z.toJSONSchema(aiInputs.capabilities, { io: "input" }).required, undefined, "default host must not be advertised as required");
});
test("request kinds preserve task-specific inputs and prohibit executable/URL parameters", () => {
  assert.deepEqual(aiRequest("run", { model, task: "embed", input: { text: "hello" } }).request, { op: "run", model, task: "embed", input: { text: "hello" } });
  const input = { state: "hello", questions: { good: { type: "noul", instructions: "Is it good?" } } };
  assert.deepEqual(aiRequest("run", { model, task: "classify", input }).request, { op: "run", model, task: "classify", input });
  for (const input of [
    { model: "https://example.com/model", input: "x" },
    { model, input: "x", flags: ["--tools", "all"] },
    { model, input: "x", maxTokens: 4097 },
    { model, input: "" },
    { model, task: "embed", input: "x", maxTokens: 8 },
    { model, input: { text: "x", images: ["file:///private.png"] } },
  ]) assert.equal(aiInputs.run.safeParse(input).success, false);
  assert.equal(aiInputs.info.safeParse({ model, file: "../bad.gguf" }).success, false);
  assert.throws(() => aiRequest("run", { model, input: "💛".repeat(9000) }), /UTF-8/);
});
test("results require immutable artifact provenance and validated task-specific outputs", () => {
  assert.equal(aiResults.run.safeParse({ model, task: "generate", text: "hello" }).success, false);
  assert.equal(aiResults.load.safeParse({ model, status: "loaded", task: "generate" }).success, false);
  assert.equal(aiResults.run.safeParse({ model, task: "embed", embedding: [Infinity] }).success, false);
});
