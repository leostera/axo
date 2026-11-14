import { z } from "zod";
import { attachmentSchema } from "./assets.ts";

const bytes = (value: string) => new TextEncoder().encode(value).length;
export const aiImageSchema = z.union([
  z.string().max(12 * 1024 * 1024).regex(/^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/),
  attachmentSchema.extend({ mimeType: z.enum(["image/png", "image/jpeg", "image/webp"]), size: z.number().int().positive().max(8 * 1024 * 1024) }).strict(),
]).describe("An account image attachment ({asset,name,mimeType,size}), or a base64 PNG/JPEG/WebP data URL. Prefer attachments: inline data must also fit the 64 KiB relay request budget. No local paths or arbitrary URLs.");
const featureName = z.string().min(1).max(128).refine(value => bytes(value) <= 128 && !value.includes("\0"), "feature names require 1..128 UTF-8 bytes without NUL");
const scalarString = z.object({ type: z.literal("string"), value: z.string().max(32768).refine(value => bytes(value) <= 32768, "feature string exceeds 32768 UTF-8 bytes") }).strict();
const scalarInt = z.object({ type: z.literal("int"), value: z.number().int().min(Number.MIN_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER) }).strict();
const scalarFloat = z.object({ type: z.literal("float"), value: z.number().finite() }).strict();
const tensor = z.object({
  type: z.literal("tensor"), dtype: z.enum(["float32", "int32"]),
  shape: z.array(z.number().int().min(1).max(4096)).min(1).max(16),
  data: z.array(z.number().finite()).max(4096),
}).strict().superRefine((value, context) => {
  const count = value.shape.reduce((total, dimension) => total * dimension, 1);
  if (count > 4096 || count !== value.data.length) context.addIssue({ code: "custom", message: "tensor data must match a shape of at most 4096 elements" });
  if (value.data.some(number => value.dtype === "int32" ? !Number.isInteger(number) || number < -2147483648 || number > 2147483647 : !Number.isFinite(Math.fround(number))))
    context.addIssue({ code: "custom", message: "tensor value exceeds its declared dtype" });
});
const inputFeature = z.discriminatedUnion("type", [scalarInt, scalarFloat, scalarString, tensor, z.object({ type: z.literal("image"), image: aiImageSchema }).strict()]);
export const aiPredictionInput = z.object({
  features: z.record(featureName, inputFeature).refine(value => Object.keys(value).length <= 32, "at most 32 named features"),
  outputs: z.array(featureName).min(1).max(32).refine(value => new Set(value).size === value.length, "selected output names must be unique").optional(),
}).strict().superRefine((value, context) => {
  let elements = 0, textBytes = 0, images = 0, imageBytes = 0;
  for (const feature of Object.values(value.features)) {
    elements += feature.type === "tensor" ? feature.data.length : 1;
    if (feature.type === "string") textBytes += bytes(feature.value);
    if (feature.type === "image") {
      images++;
      const image = feature.image;
      imageBytes += typeof image === "string" ? (image.length - image.indexOf(",") - 1) * 3 / 4 - (image.endsWith("==") ? 2 : image.endsWith("=") ? 1 : 0) : image.size;
    }
  }
  if (elements > 4096 || textBytes > 32768) context.addIssue({ code: "custom", message: "prediction exceeds 4096 input elements or 32768 total string bytes" });
  if (images > 4 || imageBytes > 16 * 1024 * 1024) context.addIssue({ code: "custom", message: "prediction images exceed four files or 16 MiB" });
}).describe("Named native features, not chat. Use ai.load with task predict to see names, dtypes and shapes. Select output names with outputs to avoid oversized replies; images are scaled to fill the model's fixed dimensions.");
const outputFeature = z.discriminatedUnion("type", [scalarInt, scalarFloat, scalarString, tensor,
  z.object({ type: z.literal("dictionary"), values: z.record(z.string().max(4096).refine(value => bytes(value) <= 4096), z.number().finite()) }).strict(),
]);
export const aiPredictionOutputs = z.record(featureName, outputFeature).superRefine((value, context) => {
  const values = Object.values(value);
  const count = values.reduce((total, feature) => total + (feature.type === "tensor" ? feature.data.length : feature.type === "dictionary" ? Object.keys(feature.values).length : 1), 0);
  const textBytes = values.reduce((total, feature) => total + (feature.type === "string" ? bytes(feature.value) : 0), 0);
  if (values.length > 32 || count > 4096 || textBytes > 32768) context.addIssue({ code: "custom", message: "prediction outputs exceed their feature/element/string budgets" });
});
const description = z.object({
  optional: z.boolean(), native_type: z.number().int().nonnegative(),
  type: z.enum(["int", "float", "string", "tensor", "dictionary", "image", "unsupported"]),
  dtype: z.string().max(32).optional(), shape: z.array(z.number().int()).max(16).optional(),
  shape_constraint_type: z.number().int().optional(),
  enumerated_shapes: z.array(z.array(z.number().int()).max(16)).max(256).optional(),
  shape_ranges: z.array(z.object({ lower: z.number().nonnegative(), length: z.number().nonnegative().nullable() }).strict()).max(16).optional(),
  key_type: z.enum(["string", "int"]).optional(),
  width: z.number().int().optional(), height: z.number().int().optional(), pixel_format: z.number().int().optional(),
  resize: z.literal("scale-fill").optional(), unsupported: z.string().max(512).optional(),
}).strict();
export const aiModelDescription = z.object({
  inputs: z.record(featureName, description).refine(value => Object.keys(value).length <= 32),
  outputs: z.record(featureName, description).refine(value => Object.keys(value).length <= 32),
}).strict();
