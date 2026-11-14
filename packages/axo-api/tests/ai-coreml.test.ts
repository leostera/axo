import assert from "node:assert/strict";
import { test } from "node:test";
import { z } from "zod";
import { aiInputs, aiRequest, aiResults, aiSourceSchema } from "../src/ai.ts";

const model = "hf:some-owner/a-new-native-model";
const sha256 = "a".repeat(64), revision = "b".repeat(40), gitBlob = "c".repeat(40);
const source = { backend: "coreml", repo: "some-owner/a-new-native-model", revision, file: "model.mlmodel", entrypoint: "model.mlmodel", sha256,
  files: [{ path: "model.mlmodel", bytes: 128, sha256, role: "model" }] };

test("Core ML accepts typed prediction, preserves omitted backend, and exposes feature schemas", () => {
  const input = { features: { x: { type: "tensor", dtype: "float32", shape: [2], data: [4, 5] } }, outputs: ["y"] };
  assert.deepEqual(aiRequest("run", { model, task: "predict", input }).request, { op: "run", model, task: "predict", input });
  assert.equal(aiInputs.info.safeParse({ model, backend: "coreml", file: "models/tiny.mlpackage" }).success, true);
  assert.equal(aiInputs.info.safeParse({ model, file: "tiny.mlmodelc" }).success, false);
  assert.throws(() => aiRequest("run", { model, backend: "mlx", task: "predict", input }), /predict/);
  assert.throws(() => aiRequest("load", { model, backend: "coreml" }), /predict/);
  assert.doesNotThrow(() => z.toJSONSchema(aiInputs.run, { io: "input" }));
  assert.equal(aiResults.load.safeParse({ model, source, status: "loaded", task: "predict", description: { inputs: { x: { type: "tensor", dtype: "float32", shape: [2], native_type: 5, optional: false } }, outputs: { y: { type: "float", native_type: 2, optional: false } } } }).success, true);
  assert.equal(aiResults.load.safeParse({ model, source, status: "loaded", task: "predict" }).success, false);
});
test("prediction boundaries reject impossible shapes, overflow, aliases and arbitrary image paths", () => {
  for (const input of [
    { features: { x: { type: "tensor", dtype: "float32", shape: [2], data: [1] } } },
    { features: { x: { type: "tensor", dtype: "float32", shape: [1], data: [1e100] } } },
    { features: { x: { type: "tensor", dtype: "int32", shape: [1], data: [0.5] } } },
    { features: { x: { type: "int", value: Number.MAX_SAFE_INTEGER + 1 } } },
    { features: { x: { type: "image", image: "file:///private.png" } } },
    { features: { x: { type: "float", value: 1, ignored: true } } },
    { features: {}, outputs: ["y", "y"] }, { features: {}, outputs: [] },
  ]) assert.equal(aiInputs.run.safeParse({ model, task: "predict", input }).success, false, JSON.stringify(input));
  assert.equal(aiInputs.run.safeParse({ model, task: "predict", input: { features: {} }, maxTokens: 1 }).success, false);
  const features = Object.fromEntries(Array.from({ length: 17 }, (_, i) => ["x" + i, { type: "tensor", dtype: "float32", shape: [256], data: Array(256).fill(0) }]));
  assert.equal(aiInputs.run.safeParse({ model, task: "predict", input: { features } }).success, false, "aggregate tensor budget");
});
test("Core ML receipts preserve immutable package identity and reject partial prediction provenance", () => {
  const result = { model, task: "predict", source, outputs: { y: { type: "float", value: 24 } } };
  assert.equal(aiResults.run.safeParse(result).success, true);
  assert.equal(aiResults.run.safeParse({ ...result, source: { ...source, backend: "mlx" } }).success, false);
  const partial = { ...source, sha256: null, gitBlob, files: [{ ...source.files[0], sha256: null, gitBlob }] };
  assert.equal(aiSourceSchema.safeParse(partial).success, true, "an interrupted install may inventory an immutable Git-pinned plan");
  assert.equal(aiResults.run.safeParse({ ...result, source: partial }).success, false, "an executed prediction must have completed SHA-256 receipts");
  assert.equal(aiSourceSchema.safeParse({ ...partial, backend: "llama.cpp" }).success, false);
  const bundle = { ...source, file: "tiny.mlpackage/Data/model.mlmodel", entrypoint: "tiny.mlpackage", files: [
    { ...source.files[0], path: "tiny.mlpackage/Data/model.mlmodel" },
    { path: "tiny.mlpackage/Manifest.json", bytes: 100, sha256, role: "resource" },
  ] };
  assert.equal(aiSourceSchema.safeParse(bundle).success, true);
  assert.equal(aiSourceSchema.safeParse({ ...bundle, entrypoint: "another.mlpackage" }).success, false);
});
