import { z } from "zod";
import { aiImageSchema as image, aiPredictionInput, aiPredictionOutputs, aiModelDescription } from "./ai-features.ts";

export const AI_NAMESPACE = "ai";
export const AI_METHOD = "axo.apps.ai";
export const AI_MAX_TIMEOUT_MS = 240_000;

export const aiModelSchema = z.string().max(259).regex(/^hf:[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9][A-Za-z0-9_.-]*)?(?:@[A-Za-z0-9][A-Za-z0-9_.-]*)?$/)
  .describe("Hugging Face reference: hf:owner/repo[:quant][@revision]. Not a model-name allowlist. Use the HF app to search, ai.capabilities for this host's runtime and ai.info to inspect compatibility before downloading weights.");
const artifact = z.string().max(512).regex(/^(?!\/)(?!.*\/\/)(?!.*(?:^|\/)\.\.?(?:\/|$))[A-Za-z0-9_.\/-]+\.(?:gguf|safetensors|json|model|txt|mlmodel|mlpackage|bin)$/i);
const gguf = artifact.refine(path => path.toLowerCase().endsWith(".gguf"), "projector must be GGUF");
const backend = z.enum(["llama.cpp", "mlx", "coreml"]);
const host = z.string().min(1).max(64).default("self").describe('A paired online Mac from hosts.list(), or "self" (the default).');
const selectionFields = { model: aiModelSchema, backend: backend.optional(), file: artifact.optional(), projector: gguf.optional() };
const selection = z.object(selectionFields).strict();
const task = z.enum(["generate", "classify", "embed", "predict"]);
const images = z.array(image).max(4).optional();
const text = z.string().min(1).max(32_768);
const textInput = z.union([text, z.object({ text, images }).strict()]);
const questionId = z.string().max(64).regex(/^[A-Za-z0-9_-][A-Za-z0-9_.-]*$/);
const instructions = z.string().min(1).max(4096);
const question = z.discriminatedUnion("type", [
  z.object({ type: z.literal("noul"), instructions }).strict(),
  z.object({ type: z.literal("choice"), instructions, criteria: z.record(questionId, z.string().max(4096).nullable()).refine(criteria => Object.keys(criteria).length >= 2 && Object.keys(criteria).length <= 32, "choice needs 2 to 32 criteria") }).strict(),
  z.object({ type: z.literal("score"), instructions, criteria: z.array(instructions).min(2).max(10) }).strict(),
]);
const base = { host, ...selectionFields };
export const aiInputs = {
  capabilities: z.object({ host }).strict(),
  list: z.object({ host }).strict(),
  info: z.object(base).strict(),
  install: z.object(base).strict(),
  load: z.object({ ...base, task: task.default("generate") }).strict(),
  unload: z.object(base).strict(),
  run: z.union([
    z.object({ ...base, task: z.literal("generate").default("generate"), input: textInput, maxTokens: z.number().int().min(1).max(4096).default(512) }).strict(),
    // Preserve 0.54's public prompt spelling at the cloud boundary; the daemon has one input path.
    z.object({ ...base, task: z.literal("generate").default("generate"), prompt: text, maxTokens: z.number().int().min(1).max(4096).default(512) }).strict(),
    z.object({ ...base, task: z.literal("classify"), input: z.object({ state: z.json(), images, questions: z.record(questionId, question).refine(questions => Object.keys(questions).length >= 1 && Object.keys(questions).length <= 16, "supply 1 to 16 questions") }).strict() }).strict(),
    z.object({ ...base, task: z.literal("embed"), input: z.union([text, z.object({ text }).strict()]) }).strict(),
    z.object({ ...base, task: z.literal("predict"), input: aiPredictionInput }).strict(),
  ]),
} as const;
export const aiToolSchema = z.enum(["capabilities", "list", "info", "install", "load", "unload", "run"]);
export type AiTool = z.infer<typeof aiToolSchema>;

/** Parse once, normalize the public API to a single daemon request and enforce relay byte limits. */
export function aiRequest(tool: AiTool, input: unknown): { host: string; request: Record<string, unknown> } {
  let host: string;
  let request: Record<string, unknown>;
  if (tool === "run") {
    const parsed = aiInputs.run.parse(input);
    if ("prompt" in parsed) {
      const { host: target, prompt, ...args } = parsed;
      host = target; request = { op: tool, ...args, input: prompt };
    } else {
      const { host: target, ...args } = parsed;
      host = target; request = { op: tool, ...args };
    }
    const value = request.input;
    const content = typeof value === "string" ? value : value && typeof value === "object" && "text" in value ? value.text : undefined;
    if (typeof content === "string" && new TextEncoder().encode(content).length > 32_768) throw new Error("ai.run: text exceeds 32768 UTF-8 bytes");
  } else {
    const { host: target, ...args } = aiInputs[tool].parse(input);
    host = target; request = { op: tool, ...args };
  }
  if ((tool === "run" || tool === "load") && ((request.backend === "coreml" && request.task !== "predict") || (request.task === "predict" && request.backend !== undefined && request.backend !== "coreml")))
    throw new Error("Core ML uses task: predict; other backends do not expose named-feature prediction");
  if (new TextEncoder().encode(JSON.stringify(request)).length > 65_536)
    throw new Error("AI request exceeds the 64 KiB relay budget; pass image attachments instead of inline bytes");
  return { host, request };
}

const hash = z.string().regex(/^[a-f0-9]{64}$/);
const gitBlob = z.string().regex(/^[a-f0-9]{40}$/);
const file = z.object({ path: artifact, bytes: z.number().int().positive(), sha256: hash.nullable(), gitBlob: gitBlob.optional(), role: z.enum(["model", "projector", "resource"]) }).strict()
  .refine(file => file.sha256 !== null || file.gitBlob !== undefined, "artifact needs SHA-256 or immutable Git-object integrity");
export const aiSourceSchema = z.object({
  backend: backend.optional(), gitBlob: gitBlob.optional(), entrypoint: artifact.optional(),
  repo: z.string().max(256), revision: z.string().regex(/^[a-f0-9]{40}$/),
  file: artifact, sha256: hash.nullable(), files: z.array(file).min(1).max(128),
}).strict().refine(source => source.files[0]?.role === "model" && source.files[0].path === source.file && source.files[0].sha256 === source.sha256,
  "source must identify the first model artifact consistently")
  .refine(source => {
    if (source.backend === "coreml") {
      const entry = source.entrypoint;
      if (!entry || !source.file.endsWith(".mlmodel") || source.files.filter(file => file.role === "model").length !== 1
        || source.files.filter(file => file.path.endsWith(".mlmodel")).length !== 1
        || source.files.some(file => file.role === "projector")
        || (source.sha256 === null && (!source.gitBlob || source.gitBlob !== source.files[0].gitBlob))) return false;
      if (entry.endsWith(".mlpackage")) return source.files.every(file => file.path.startsWith(entry + "/") && (file.role === "model" || /\.(?:json|bin)$/.test(file.path)))
        && source.files.some(file => file.path === entry + "/Manifest.json");
      return entry === source.file && source.files.length === 1;
    }
    if (source.entrypoint !== undefined || source.sha256 === null) return false;
    return source.backend === "mlx"
      ? source.files.every(file => file.role === "resource" ? file.path.endsWith(".json") : file.role === "model" && file.path.endsWith(".safetensors"))
      : source.files.every(file => file.role !== "resource" && file.path.toLowerCase().endsWith(".gguf"));
  }, "source artifacts must match the selected backend");
const resolved = z.object({ selection, backend: backend.optional(), revision: z.string().regex(/^[a-f0-9]{40}$/), architecture: z.string().max(128).nullable(), taskHints: z.array(task), files: z.array(file).min(1).max(128) }).strict();
const compatibility = z.object({ status: z.enum(["candidate", "unsupported", "ambiguous"]), reasons: z.array(z.string().max(4096)).max(32) }).strict();
const receipt = { model: aiModelSchema, source: aiSourceSchema };
const probability = z.number().min(0).max(1);
const answer = z.union([
  z.object({ type: z.literal("noul"), noul: probability }).passthrough(),
  z.object({ type: z.literal("choice"), choice: z.string(), probabilities: z.record(z.string(), probability) }).passthrough(),
  z.object({ type: z.literal("score"), score: z.number().min(0) }).passthrough(),
]);
export const aiResults = {
  capabilities: z.object({
    apiVersion: z.union([z.literal(2), z.literal(3), z.literal(4)]), available: z.boolean(),
    runtime: z.object({ name: z.literal("llama.cpp"), commit: z.string().regex(/^[a-f0-9]{40}$/), build: z.number().int(), recognizedArchitectures: z.array(z.string()).min(1) }).strict(),
    runtimes: z.array(z.object({
      name: backend, available: z.boolean(), version: z.string().optional(), commit: gitBlob.optional(), build: z.number().int().optional(),
      formats: z.array(z.enum(["gguf", "safetensors", "mlmodel", "mlpackage"])),  tasks: z.array(task),
      recognizedArchitectures: z.array(z.string().max(128)).max(512), inputs: z.array(z.enum(["text", "image", "json", "features"])).optional(),
      devices: z.array(z.object({kind: z.enum(["cpu", "gpu", "neural-engine", "unknown"]), nativeClass: z.string().max(128)}).strict()).max(16).optional(),
      computePolicy: z.literal("all").optional(), osVersion: z.string().max(256).optional(),
      tensorDtypes: z.array(z.enum(["float32", "int32"])).optional(), maxTensorElements: z.number().int().positive().optional(), maxFeatures: z.number().int().positive().optional(),
      contextTokens: z.number().int().positive().optional(), kvCache: z.boolean().optional(), reason: z.string().max(4096).optional(),
    }).strict()).max(8).optional(),
    formats: z.array(z.enum(["gguf", "mlx", "safetensors", "coreml", "mlmodel", "mlpackage"])), tasks: z.array(task), inputs: z.object({ generate: z.array(z.string()), classify: z.array(z.string()), embed: z.array(z.string()), predict: z.array(z.string()).optional() }).strict(),
    architectureCheck: z.string(), modelSource: z.string(), selection: z.string(), customCode: z.literal(false), privateRepositories: z.literal(false), backends: z.array(backend),
    limits: z.object({ physicalMemoryBytes: z.number(), maxModelBytes: z.number(), freeDiskBytes: z.number(), maxDownloadBytes: z.number(), maxArtifacts: z.number(), maxImages: z.number(), maxImageBytes: z.number(), maxTotalImageBytes: z.number(), maxTextBytes: z.number(), contextTokens: z.number(), maxOutputTokens: z.number(), maxOperationMs: z.number(), concurrentOperations: z.number() }).strict(),
    unsupported: z.array(z.string()),
  }).strict(),
  info: z.object({ info: z.object({ model: aiModelSchema, compatibility, formats: z.array(z.string()), architecture: z.string().nullable(), taskHints: z.array(task), candidates: z.array(artifact), resolved: resolved.nullable() }).strict(), installed: z.boolean() }).strict(),
  list: z.object({ models: z.array(z.object({ model: aiModelSchema, selection, installed: z.boolean(), status: z.enum(["stopped", "sleeping", "loaded"]), source: aiSourceSchema, downloadBytes: z.number().int().positive() }).strict()).max(256) }).strict(),
  install: z.object({ ...receipt, installed: z.literal(true) }).strict(),
  load: z.object({ ...receipt, status: z.literal("loaded"), task, description: aiModelDescription.optional() }).strict().refine(result => result.task !== "predict" || (result.source.backend === "coreml" && result.description !== undefined), "predict loads require a Core ML feature description"),
  unload: z.object({ model: aiModelSchema, status: z.literal("stopped") }).strict(),
  run: z.discriminatedUnion("task", [
    z.object({ ...receipt, task: z.literal("generate"), text: z.string().max(1_048_576), finishReason: z.enum(["stop", "length"]) }).strict(),
    z.object({ ...receipt, task: z.literal("classify"), answers: z.record(z.string(), answer) }).strict(),
    z.object({ ...receipt, task: z.literal("embed"), embedding: z.array(z.number().finite()).min(1).max(65_536) }).strict(),
    z.object({ ...receipt, task: z.literal("predict"), outputs: aiPredictionOutputs }).strict().refine(result => result.source.backend === "coreml" && result.source.files.every(file => file.sha256 !== null), "predictions require verified Core ML artifact receipts"),
  ]),
} as const;
