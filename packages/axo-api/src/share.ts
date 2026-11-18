/**
 * Shared conversations: a redacted, read-only snapshot of one conversation, published by a host.
 *
 * pi-axo builds and redacts the snapshot on the Mac, axod forwards it over its relay link, and
 * the cloud stores it in the public-sessions bucket under an ID it picks. The viewer at
 * `/s/<shareId>/<slug>` reads it back through `/api/public-sessions/<shareId>`.
 */
import { z } from "zod";
import { hostGenerationSchema, hostIdSchema } from "./v1.ts";

export const SHARE_PUBLISH_METHOD = "axo.host.share.publish";
export const SHARED_SNAPSHOT_VERSION = 1;
export const MAX_SHARED_MESSAGES = 5_000;

/**
 * How much an account may publish. Shares are public on Axo's own origin and anyone can sign up,
 * so each one is bounded, and so is what one account keeps and how fast it adds to it. Pi's
 * `/axo-share` keeps a snapshot under 1.9 MB (packages/pi-axo/src/share-command.ts).
 */
export const SHARE_LIMITS = {
  /** One snapshot, as stored: UTF-8 JSON. */
  snapshotBytes: 2 * 1_048_576,
  /** Shares one account keeps at once. */
  perAccount: 1_000,
  /** Bytes of shares one account keeps at once. */
  accountBytes: 256 * 1_048_576,
  /** Shares one account publishes in an hour. */
  perHour: 30,
} as const;
export const shareIdSchema = z.string().regex(/^[A-Za-z0-9_-]{22}$/);

const text = (max: number) => z.string().max(max);

export const sharedToolSchema = z.object({
  callId: text(256).nullable(),
  name: text(128).min(1),
  kind: z.enum(["shell", "edit", "file", "search", "generic"]),
  subtitle: text(4_096).nullable(),
  command: text(20_000).nullable(),
  status: z.enum(["completed", "failed", "running"]),
  output: text(8_000),
  outputTruncated: z.boolean(),
}).strict();

export const sharedMessageSchema = z.object({
  id: text(128).min(1),
  role: z.enum(["user", "assistant", "tool"]),
  text: text(40_000),
  timestamp: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).nullable(),
  tool: sharedToolSchema.nullable(),
  images: z.array(z.never()).max(0),
}).strict();

/** The model that wrote the replies, as Pi names it. */
export const sharedModelSchema = z.object({
  provider: text(64).min(1),
  id: text(128).min(1),
  name: text(128).min(1),
}).strict();

export const sharedSnapshotSchema = z.object({
  version: z.literal(SHARED_SNAPSHOT_VERSION),
  title: text(200).min(1),
  // Optional: shares published before they were added have neither.
  emoji: text(16).min(1).optional(),
  model: sharedModelSchema.optional(),
  publishedAt: z.string().datetime({ offset: true }),
  messages: z.array(sharedMessageSchema).min(1).max(MAX_SHARED_MESSAGES),
}).strict();
export type SharedSnapshot = z.infer<typeof sharedSnapshotSchema>;

export const sharePublishParamsSchema = z.object({
  hostId: hostIdSchema,
  hostGeneration: hostGenerationSchema,
  snapshot: sharedSnapshotSchema,
}).strict();
export type SharePublishParams = z.infer<typeof sharePublishParamsSchema>;

export const sharePublishResultSchema = z.object({
  shareId: shareIdSchema,
  url: z.url(),
}).strict();
export type SharePublishResult = z.infer<typeof sharePublishResultSchema>;

/** One of the account's shares, as the account lists them. */
export const accountShareSchema = z.object({
  shareId: shareIdSchema,
  hostId: hostIdSchema,
  bytes: z.number().int().nonnegative(),
  publishedAt: z.string().datetime({ offset: true }),
}).strict();
export type AccountShare = z.infer<typeof accountShareSchema>;
export const accountShareListSchema = z.object({ shares: z.array(accountShareSchema) }).strict();

/** The readable tail of a share URL; placeholders left by redaction are dropped. */
export function shareSlug(title: string): string {
  const slug = title.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
    .replace(/\[redacted:[^\]]*\]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60).replace(/-+$/, "");
  return slug || "session";
}
