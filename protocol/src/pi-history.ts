import { z } from "zod";

const recordedId = z.string().min(1).refine(value =>
  new TextEncoder().encode(value).byteLength <= 128 && !/[\p{Cc}\p{Cs}]/u.test(value),
);

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
