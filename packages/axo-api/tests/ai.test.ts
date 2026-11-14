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

test("MLX backend selection is explicit or omitted, never injected as a cache-changing default", () => {
  const native = "hf:any-owner/a-new-model";
  assert.deepEqual(aiRequest("run", { model: native, backend: "mlx", input: "hello" }).request,
    { op: "run", model: native, backend: "mlx", task: "generate", input: "hello", maxTokens: 512 });
  assert.equal("backend" in aiRequest("info", { model: native }).request, false);
  assert.equal(aiInputs.info.safeParse({ model: native, backend: "coreml" }).success, true);
  assert.equal(aiInputs.info.safeParse({ model: native, backend: "onnx" }).success, false, "unimplemented backends are not advertised");
  for (const file of ["../model.safetensors", "a//model.safetensors", "code.py", "/model.safetensors"]) {
    assert.equal(aiInputs.info.safeParse({ model: native, file }).success, false);
  }
  assert.equal(aiInputs.info.safeParse({ model: native, file: "bundle/model.safetensors" }).success, true);
  assert.equal(aiInputs.info.safeParse({ model: native, projector: "model.safetensors" }).success, false);
});

test("native source resources distinguish Git integrity from a known SHA-256", () => {
  const sha256 = "a".repeat(64);
  const source = { backend: "mlx", repo: "any-owner/a-new-model", revision: "b".repeat(40), file: "model.safetensors", sha256,
    files: [{ path: "model.safetensors", bytes: 1024, sha256, role: "model" },
      { path: "config.json", bytes: 100, sha256: null, gitBlob: "c".repeat(40), role: "resource" }] };
  const result = { model: "hf:any-owner/a-new-model", task: "generate", text: "hello", finishReason: "stop", source };
  assert.equal(aiResults.run.safeParse(result).success, true);
  delete (source.files[1] as { gitBlob?: string }).gitBlob;
  assert.equal(aiResults.run.safeParse(result).success, false, "unknown SHA-256 without Git integrity is not provenance");
});
