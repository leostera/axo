import { z } from "zod";

export const MAX_FILE_BYTES = 25 * 1024 * 1024;
export const MAX_WORKBENCH_BYTES = 1024 * 1024 * 1024;
export const MAX_PROMPT_FILE_BYTES = 50 * 1024 * 1024;
export const MAX_FILE_COUNT = 5_000;
export const FILE_PAGE_SIZE = 20;
export const sessionFileId = z.string().regex(/^[a-zA-Z0-9_.:-]{1,128}$/);
export const sharedFileIdSchema = z.uuid();
export const fileAttributesSchema = z.object({
  filename: z.string().min(1).max(255).refine(name => !/[\x00-\x1f\x7f/\\]/.test(name) && name !== "." && name !== ".."),
  mediaType: z.enum(["image/png", "image/jpeg", "application/pdf", "text/plain", "text/markdown", "application/octet-stream"]),
  byteLength: z.number().int().min(0).max(MAX_FILE_BYTES),
  sha256: z.string().regex(/^[a-f0-9]{64}$/),
});
export const uploadRequestSchema = fileAttributesSchema.extend({ requestId: z.uuid() });
export const sharedFileSchema = fileAttributesSchema.extend({
  id: sharedFileIdSchema, sessionId: sessionFileId, origin: z.enum(["host", "phone"]),
  createdAt: z.number().int().nonnegative(), state: z.enum(["pending", "ready", "deleting", "deleted"]),
});
export const filePageSchema = z.object({ files: z.array(sharedFileSchema).max(FILE_PAGE_SIZE), nextCursor: z.string().nullable(), revision: z.number().int().nonnegative() });
export type SharedFile = z.infer<typeof sharedFileSchema>;
export type UploadRequest = z.infer<typeof uploadRequestSchema>;

/** Messages are safe for clients; do not include paths, credentials, or provider exceptions. */
type FileErrorStatus = 400 | 403 | 404 | 409 | 410 | 413 | 422 | 429 | 503;
export class FileFault extends Error {
  constructor(status: FileErrorStatus, message: string) { super(`${status}:${message}`); }
}
export function fileErrorResponse(error: unknown): Response {
  const match = error instanceof Error ? /^(400|403|404|409|410|413|422|429|503):(.+)$/.exec(error.message) : null;
  return Response.json({ message: match?.[2] ?? "File storage temporarily unavailable." }, {
    status: match ? Number(match[1]) : 503, headers: { "Cache-Control": "private, no-store" },
  });
}
