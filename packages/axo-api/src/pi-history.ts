import { z } from "zod";

const recordedId = z.string().min(1).refine(value =>
  new TextEncoder().encode(value).byteLength <= 128 && !/[\p{Cc}\p{Cs}]/u.test(value),
);

const piSessionId = z.string().min(1).max(128).refine(value => !/[\u0000-\u001f\u007f]/u.test(value));
const piEventData = z.unknown().refine(value => {
  try {
    const encoded = JSON.stringify(value);
    return encoded !== undefined && new TextEncoder().encode(encoded).byteLength <= 60_000;
  } catch {
    return false;
  }
}, "Pi event data must be JSON and no larger than 60000 bytes");

export const storedPiEventSchema = z.object({
  id: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  hostGeneration: z.uuid(),
  piSessionId,
  streamId: z.uuid(),
  sequence: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  name: z.string().min(1).max(128).refine(value => !/[\u0000-\u001f\u007f]/u.test(value)),
  data: piEventData,
  receivedAt: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
}).strict();
export type StoredPiEvent = z.infer<typeof storedPiEventSchema>;

export const piEventPageResultSchema = z.object({
  events: z.array(storedPiEventSchema).max(50),
  next: z.number().int().positive().max(Number.MAX_SAFE_INTEGER).nullable(),
}).strict();
export type PiEventPageResult = z.infer<typeof piEventPageResultSchema>;

export const centralPiProjectionSchema = z.object({
  entryId: recordedId,
  parentId: recordedId.nullable(),
  timestamp: z.string().max(128),
  kind: recordedId,
  role: z.string().max(64).nullable(),
  text: z.string().refine(value => new TextEncoder().encode(value).byteLength <= 2048),
  truncated: z.boolean(),
  toolCallId: recordedId.nullable(),
  toolName: recordedId.nullable(),
  toolCalls: z.array(z.object({ id: recordedId, name: recordedId }).strict()).max(32),
}).strict();
