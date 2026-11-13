import { z } from "zod";

/** Host-targeted local inference. This first release deliberately supports one reviewed model. */
export const AI_NAMESPACE = "ai";
export const AI_METHOD = "axo.apps.ai";
export const AI_MODEL = "hf:ggml-org/gemma-3-270m-it-GGUF";
export const AI_MAX_TIMEOUT_MS = 240_000;

const host = z.string().min(1).max(64).default("self").describe('A Mac from hosts.list(), or "self" (the default).');
const model = z.literal(AI_MODEL).describe("Gemma 3 270M instruction-tuned, Q8_0. First use downloads the pinned 292 MB artifact onto this Mac.");
const modelInput = z.object({ host, model }).strict();
export const aiInputs = {
  list: z.object({ host }).strict(),
  install: modelInput,
  load: modelInput,
  unload: modelInput,
  run: z.object({ host, model, prompt: z.string().min(1).max(32_768), maxTokens: z.number().int().min(1).max(4096).default(512) }).strict(),
} as const;
export const aiToolSchema = z.enum(["list", "install", "load", "unload", "run"]);
export type AiTool = z.infer<typeof aiToolSchema>;

export const aiSourceSchema = z.object({
  repo: z.literal("ggml-org/gemma-3-270m-it-GGUF"),
  revision: z.literal("e7647be17ae1108f2f605ed061ca0608b171afff"),
  file: z.literal("gemma-3-270m-it-Q8_0.gguf"),
  sha256: z.literal("0ef57d2c838458a1952664260dcba38e5bdda37494f3af732f06e4add24068e3"),
}).strict();
const receipt = { model, source: aiSourceSchema };
export const aiResults = {
  list: z.object({ models: z.array(z.object({
    id: model,
    task: z.literal("generate"),
    available: z.boolean(),
    installed: z.boolean(),
    status: z.enum(["stopped", "sleeping", "loaded"]),
    downloadBytes: z.literal(291_545_600),
    source: aiSourceSchema,
  }).strict()).max(1) }).strict(),
  install: z.object({ ...receipt, installed: z.literal(true) }).strict(),
  load: z.object({ ...receipt, status: z.literal("loaded") }).strict(),
  unload: z.object({ ...receipt, status: z.literal("stopped") }).strict(),
  run: z.object({ ...receipt, text: z.string().max(1_048_576), finishReason: z.enum(["stop", "length"]) }).strict(),
} as const;
