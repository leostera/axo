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
  /**
   * Bytes one `assets.read` returns: base64 of it fits a script's 1 MiB result. A script reads a
   * larger asset in ranges.
   */
  readBytes: 512 * 1024,
  /** Bytes one `assets.save` takes from a script, as text or base64. */
  scriptSaveBytes: 512 * 1024,
  /**
   * Bytes an app tool stores as an asset in one call (a Gmail attachment, a Drive file). They are
   * held in the account's Durable Object while hashed, so this stays well under its memory.
   */
  toolSaveBytes: 32 * 1024 * 1024,
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

/**
 * A file a script's tool stored in the account's assets (RFD0030, Assets from scripts): what
 * `assets.save`, Gmail's `save_attachment` and Drive's `save_file` answer. A script returns it as
 * it is; the Mac's `apps_run` fetches it to `~/.axo/assets/<hash>/<name>` and names the path, and
 * `url` opens it in a browser signed in to the account.
 */
export const savedFileSchema = z.object({
  type: z.literal("file"),
  attachment: attachmentSchema,
  url: z.string().url(),
}).strict();
export type SavedFile = z.infer<typeof savedFileSchema>;

/** `codemode.assets.list({ before?, limit? })`: the account's assets, newest first. */
export const assetsListInputSchema = z.object({
  before: z.string().regex(/^\d{1,16}$/).optional().describe("the `next` of the page before"),
  limit: z.number().int().min(1).max(ASSET_LIMITS.pageSize).optional(),
}).strict();
/** `codemode.assets.get({ asset })`: one asset, as a file a script can return. */
export const assetsGetInputSchema = z.object({ asset: assetRefSchema }).strict();
/** `codemode.assets.read({ asset, offset?, length?, as? })`: a range of an asset's bytes. */
export const assetsReadInputSchema = z.object({
  asset: assetRefSchema,
  offset: z.number().int().min(0).optional().describe("the first byte, 0 when left out"),
  length: z.number().int().min(1).max(ASSET_LIMITS.readBytes).optional().describe(`bytes to read, at most ${ASSET_LIMITS.readBytes} (the default)`),
  as: z.enum(["text", "base64"]).optional().describe("text (UTF-8) for text files, base64 (the default) for anything else"),
}).strict();
/** What `assets.read` answers: the bytes from `offset`, and whether they end the asset. */
export const assetsReadResultSchema = z.object({
  asset: assetRefSchema,
  offset: z.number().int().min(0),
  length: z.number().int().min(0),
  size: z.number().int().min(0),
  /** Whether this range reaches the asset's end. */
  eof: z.boolean(),
  as: z.enum(["text", "base64"]),
  data: z.string(),
}).strict();
export type AssetsReadResult = z.infer<typeof assetsReadResultSchema>;
/** `codemode.assets.save({ name, mimeType?, text | base64 })`: stores what a script made. */
export const assetsSaveInputSchema = z.object({
  name: assetNameSchema,
  mimeType: z.string().max(128).optional().describe("stored as is if it is one of the asset types, else as application/octet-stream"),
  text: z.string().optional(),
  base64: z.string().optional(),
}).strict().refine((input) => (input.text === undefined) !== (input.base64 === undefined), "give text or base64, not both");
