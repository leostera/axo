import { z } from "zod";

export const MAX_FRAME_BYTES = 256 * 1024;
export const MAX_PROMPT_LENGTH = 16_000;
const id = z.string().min(1).max(128);
export const questionSchema = z.object({
  id,
  title: z.string().min(1).max(2_000),
  options: z.array(z.string().min(1).max(500)).min(2).max(8),
});
export const messageSchema = z.object({
  id,
  role: z.enum(["user", "assistant"]),
  text: z.string().max(24_000),
});
export const phoneFrameSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("sync") }),
  z.object({ type: z.literal("prompt"), id, sessionId: id, text: z.string().trim().min(1).max(MAX_PROMPT_LENGTH) }),
  z.object({ type: z.literal("answer"), id, sessionId: id, questionId: id, value: z.string().max(500) }),
]);
export const hostFrameSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("snapshot"), sessionId: id,
    state: z.enum(["idle", "running", "waiting"]),
    messages: z.array(messageSchema).max(80),
    question: questionSchema.nullable(),
  }),
  z.object({ type: z.literal("ack"), id, disposition: z.literal("submitted") }),
  z.object({ type: z.literal("error"), id: id.optional(), message: z.string().max(2_000) }),
]);
export type PhoneFrame = z.infer<typeof phoneFrameSchema>;
export type HostFrame = z.infer<typeof hostFrameSchema>;
export type Question = z.infer<typeof questionSchema>;
export type ConversationMessage = z.infer<typeof messageSchema>;

export function parseFrame<T>(text: string, schema: z.ZodType<T>): T {
  if (new TextEncoder().encode(text).length > MAX_FRAME_BYTES) throw new Error("Message too large");
  return schema.parse(JSON.parse(text));
}
