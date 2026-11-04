import { z } from "zod";

/**
 * Assets (RFD0030): files an account keeps in the cloud, named by the SHA-256 of their bytes.
 * One AxoAssetsDO per account indexes them; the bytes are in R2; reads go through Workers Cache.
 */

export const ASSET_LIMITS = {
  /** Bytes in one asset. */
  assetBytes: 100 * 1024 * 1024,
  /** Bytes an account may hold, counting reservations. */
  accountBytes: 10 * 1024 * 1024 * 1024,
  /** Assets an account may hold, counting reservations. */
  accountAssets: 10_000,
  /** Attachments on one prompt. */
  attachmentsPerPrompt: 8,
  /** Bytes in an asset's display name. */
  nameBytes: 255,
  /** How long a reservation waits for its commit before an alarm releases it. */
  reservationMs: 10 * 60_000,
  /** How long after a delete its tag is purged again: longer than any read takes. */
  latePurgeMs: 15 * 60_000,
  /** Images up to this size reach Pi as images; larger ones as a file path. */
  inlineImageBytes: 5 * 1024 * 1024,
  /** Assets in one page of the list. */
  pageSize: 100,
} as const;

/** The 64 hex digits of an asset's SHA-256, as it appears in URLs. */
export const assetHexSchema = z.string().regex(/^[0-9a-f]{64}$/, "an asset is named by 64 lowercase hex digits");
/** An asset's name where it is referred to: `sha256:<hex>`. */
export const assetRefSchema = z.string().regex(/^sha256:[0-9a-f]{64}$/, "an asset is referred to as sha256:<64 hex digits>");

const encoder = new TextEncoder();
/** A file name to show and save as: no slashes, no control characters, at most 255 bytes. */
export const assetNameSchema = z.string().min(1).refine(
  (name) => encoder.encode(name).byteLength <= ASSET_LIMITS.nameBytes && !/[/\\\u0000-\u001f\u007f]/.test(name) && name !== "." && name !== "..",
  "a file name has no slashes or control characters and is at most 255 bytes",
);

/** Types an asset is stored and served as; anything else is application/octet-stream. */
export const ASSET_TYPES = [
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/heic",
  "application/pdf",
  "text/plain",
  "text/markdown",
  "text/csv",
  "application/json",
  "application/zip",
  "application/octet-stream",
] as const;
export const assetTypeSchema = z.enum(ASSET_TYPES);

/** Images a browser may show inline from Axo's own origin: never SVG or HTML, which can run script. */
export const INLINE_ASSET_TYPES: ReadonlySet<string> = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/** Images Pi may take as image blocks. */
export const MODEL_IMAGE_TYPES: ReadonlySet<string> = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/** The type an upload is stored as: its own if allowed, else application/octet-stream. */
export function assetTypeOf(contentType: string | null): AssetType {
  const base = (contentType ?? "").split(";")[0]!.trim().toLowerCase();
  const parsed = assetTypeSchema.safeParse(base);
  return parsed.success ? parsed.data : "application/octet-stream";
}

export type AssetType = z.infer<typeof assetTypeSchema>;

/** A file attached to a prompt; the Mac fetches it before the prompt reaches Pi. */
export const attachmentSchema = z.object({
  asset: assetRefSchema,
  name: assetNameSchema,
  mimeType: assetTypeSchema,
  size: z.number().int().min(0).max(ASSET_LIMITS.assetBytes),
}).strict();
export type Attachment = z.infer<typeof attachmentSchema>;

export const attachmentsSchema = z.array(attachmentSchema).max(ASSET_LIMITS.attachmentsPerPrompt);

/** One asset, as the list and an upload answer it. */
export const assetSchema = z.object({
  asset: assetRefSchema,
  name: assetNameSchema,
  mimeType: assetTypeSchema,
  size: z.number().int().min(0),
  createdAt: z.string(),
  /** Raised by every upload that succeeds; a delete names the version it saw. */
  version: z.number().int().min(1),
}).strict();
export type Asset = z.infer<typeof assetSchema>;

export const assetListSchema = z.object({
  assets: z.array(assetSchema),
  /** Pass as `before` for the next page; null on the last. */
  next: z.string().nullable(),
  usage: z.object({ bytes: z.number().int().min(0), assets: z.number().int().min(0) }).strict(),
}).strict();
export type AssetList = z.infer<typeof assetListSchema>;

export const assetDeleteSchema = z.object({ version: z.number().int().min(1) }).strict();

/** Why an upload or delete was refused. */
export const ASSET_ERRORS = {
  quota: "quota",
  busy: "busy",
  tooLarge: "tooLarge",
  mismatch: "mismatch",
  invalid: "invalid",
  conflict: "conflict",
  notFound: "notFound",
} as const;
