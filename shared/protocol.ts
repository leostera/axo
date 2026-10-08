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
  role: z.enum(["user", "assistant", "thinking", "tool"]),
  text: z.string().max(24_000),
  toolName: z.string().min(1).max(128).optional(),
  toolCallId: id.optional(),
  status: z.enum(["running", "completed", "failed"]).optional(),
  output: z.string().max(3_000).optional(),
});
export const activitySchema = z.object({
  id,
  toolName: z.string().min(1).max(128),
  summary: z.string().max(250),
  status: z.enum(["running", "completed", "failed"]),
  output: z.string().max(300).optional(),
});
export const agentEventSchema = z.object({
  id,
  sequence: z.number().int().nonnegative(),
  timestamp: z.number().int().nonnegative(),
  category: z.enum(["session", "lifecycle", "turn", "assistant", "tool", "input", "model", "provider"]),
  name: z.string().min(1).max(80),
  anchorMessageId: id.optional(),
  correlationId: id.optional(),
  summary: z.string().max(200),
  detail: z.string().max(500).optional(),
});
export const phoneFrameSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("sync") }),
  z.object({ type: z.literal("prompt"), id, sessionId: id, text: z.string().trim().min(1).max(MAX_PROMPT_LENGTH) }),
  z.object({ type: z.literal("answer"), id, sessionId: id, questionId: id, value: z.string().max(500) }),
  z.object({ type: z.literal("cancel"), id, sessionId: id, runId: id }),
]);
export const hostFrameSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("snapshot"), sessionId: id,
    state: z.enum(["idle", "running", "waiting"]),
    messages: z.array(messageSchema).max(80),
    activities: z.array(activitySchema).max(10).optional(),
    events: z.array(agentEventSchema).max(50).optional(),
    droppedEvents: z.number().int().nonnegative().optional(),
    liveText: z.string().max(4_000).optional(),
    runId: id.nullable().optional(),
    question: questionSchema.nullable(),
  }),
  z.object({ type: z.literal("ack"), id, disposition: z.enum(["submitted", "cancelled"]) }),
  z.object({ type: z.literal("error"), id: id.optional(), message: z.string().max(2_000) }),
]);
export type PhoneFrame = z.infer<typeof phoneFrameSchema>;
export type HostFrame = z.infer<typeof hostFrameSchema>;
export type Question = z.infer<typeof questionSchema>;
export type ConversationMessage = z.infer<typeof messageSchema>;
export type AgentActivity = z.infer<typeof activitySchema>;
export type AgentEvent = z.infer<typeof agentEventSchema>;

export function parseFrame<T>(text: string, schema: z.ZodType<T>): T {
  if (new TextEncoder().encode(text).length > MAX_FRAME_BYTES) throw new Error("Message too large");
  return schema.parse(JSON.parse(text));
}
