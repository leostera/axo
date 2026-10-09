import { z } from "zod";
import { sharedFileSchema } from "./files";

export const MAX_FRAME_BYTES = 256 * 1024;
export const MAX_PROMPT_LENGTH = 16_000;
const id = z.string().min(1).max(128);
const uuid = z.uuid();
const name = z.string().min(1).max(120);

export const questionSchema = z.object({
  id,
  title: z.string().min(1).max(2_000),
  options: z.array(z.string().min(1).max(500)).min(2).max(8),
});
export const toolPresentationSchema = z.object({
  kind: z.enum(["shell", "edit", "file", "search", "generic"]),
  title: z.string().max(128),
  subtitle: z.string().max(500).optional(),
});
export const messageSchema = z.object({
  id,
  role: z.enum(["user", "assistant", "thinking", "tool"]),
  text: z.string().max(24_000),
  toolName: z.string().min(1).max(128).optional(),
  toolCallId: id.optional(),
  status: z.enum(["running", "completed", "failed"]).optional(),
  output: z.string().max(500).optional(),
  toolPresentation: toolPresentationSchema.optional(),
  attachments: z.array(sharedFileSchema).max(8).optional(),
  timestamp: z.number().int().nonnegative().optional(),
  commandId: id.optional(),
  delivery: z.enum(["submitting", "submitted", "steering", "uncertain", "rejected"]).optional(),
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

/** Phone destinations are Axo session IDs. Pi conversation IDs are host-owned binding details. */
export const phoneFrameSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("sync"), id: id.optional() }),
  z.object({ type: z.literal("catalog_page"), id, revision: z.number().int().nonnegative().nullable(), cursor: z.string().max(128).nullable() }),
  z.object({ type: z.literal("subscribe"), id, sessionId: uuid.nullable() }),
  z.object({ type: z.literal("create_workspace"), id, name }),
  z.object({ type: z.literal("create_session"), id, workspaceId: uuid, name }),
  z.object({ type: z.literal("rename_workspace"), id, workspaceId: uuid, name, expectedRevision: z.number().int().nonnegative() }),
  z.object({ type: z.literal("rename_session"), id, sessionId: uuid, name, expectedRevision: z.number().int().nonnegative() }),
  z.object({ type: z.literal("prompt"), id, sessionId: uuid, text: z.string().trim().max(MAX_PROMPT_LENGTH),
    attachmentIds: z.array(z.uuid()).min(1).max(8).optional(),
  }).refine(frame => !!frame.text || !!frame.attachmentIds?.length, "A prompt needs text or attachments"),
  z.object({ type: z.literal("answer"), id, sessionId: uuid, questionId: id, value: z.string().max(500) }),
  z.object({ type: z.literal("cancel"), id, sessionId: uuid, runId: id }),
  z.object({ type: z.literal("history"), id, sessionId: uuid, viewId: id, beforeId: id, direction: z.enum(["before", "after"]).optional() }),
  z.object({ type: z.literal("tool_output"), id, sessionId: uuid, toolCallId: id, offset: z.number().int().nonnegative() }),
]);

export const catalogWorkspaceSchema = z.object({ id: uuid, name, kind: z.enum(["project", "standalone"]) });
export const catalogSessionSchema = z.object({
  id: uuid,
  workspaceId: uuid,
  name,
  conversationId: id.optional(),
  availability: z.enum(["running", "stopped", "failed"]),
});
export const catalogSchema = z.object({
  revision: z.number().int().nonnegative(),
  storeRevision: z.number().int().nonnegative(),
  workspaces: z.array(catalogWorkspaceSchema).max(100),
  sessions: z.array(catalogSessionSchema).max(1_000),
}).superRefine((catalog, ctx) => {
  const workspaceIDs = new Set(catalog.workspaces.map(workspace => workspace.id));
  const sessionIDs = new Set<string>();
  if (workspaceIDs.size !== catalog.workspaces.length) ctx.addIssue({ code: "custom", message: "Duplicate workspace ID" });
  for (const session of catalog.sessions) {
    if (sessionIDs.has(session.id)) ctx.addIssue({ code: "custom", message: "Duplicate session ID" });
    if (!workspaceIDs.has(session.workspaceId)) ctx.addIssue({ code: "custom", message: "Session has no workspace" });
    sessionIDs.add(session.id);
  }
});
export type WorkbenchCatalog = z.infer<typeof catalogSchema>;
export const catalogPageSchema = z.object({
  type: z.literal("catalog_page"),
  requestId: id.optional(),
  revision: z.number().int().nonnegative(),
  items: z.array(z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("workspace"), workspace: catalogWorkspaceSchema }),
    z.object({ kind: z.literal("session"), session: catalogSessionSchema }),
  ])).max(50),
  nextCursor: z.string().max(128).nullable(),
  hostOnline: z.boolean(),
});

/** Host-to-relay frames contain the Axo destination and Pi identity separately. */
export const hostFrameSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("catalog"), catalog: catalogSchema }),
  z.object({ type: z.literal("snapshot"), sessionId: uuid, conversationId: id, viewId: id,
    state: z.enum(["idle", "running", "waiting"]), messages: z.array(messageSchema).max(80),
    hasEarlierMessages: z.boolean(), activities: z.array(activitySchema).max(10).optional(),
    events: z.array(agentEventSchema).max(50).optional(), droppedEvents: z.number().int().nonnegative().optional(),
    liveText: z.string().max(4_000).optional(), runId: id.nullable().optional(), question: questionSchema.nullable() }),
  z.object({ type: z.literal("history"), id, sessionId: uuid, conversationId: id, viewId: id, beforeId: id,
    direction: z.enum(["before", "after"]).optional(), messages: z.array(messageSchema).max(80),
    hasEarlierMessages: z.boolean(), hasLaterMessages: z.boolean() }),
  z.object({ type: z.literal("tool_output"), id, sessionId: uuid, conversationId: id, toolCallId: id,
    offset: z.number().int().nonnegative(), nextOffset: z.number().int().nonnegative().nullable(), text: z.string().max(12_000) }),
  z.object({ type: z.literal("ack"), id, sessionId: uuid.optional(), workspaceId: uuid.optional(), disposition: z.enum(["submitted", "cancelled", "created", "updated"]), delivery: z.enum(["submitted", "steering"]).optional() }),
  z.object({ type: z.literal("error"), id: id.optional(), sessionId: uuid.optional(), message: z.string().max(2_000) }),
]);
export type PhoneFrame = z.infer<typeof phoneFrameSchema>;
export type HostFrame = z.infer<typeof hostFrameSchema>;
export const relayToHostFrameSchema = z.union([
  phoneFrameSchema,
  z.object({ type: z.literal("catalog_request"), revision: z.number().int().nonnegative() }),
  z.object({ type: z.literal("session_sync"), sessionId: uuid.nullable() }),
]);
export type RelayToHostFrame = z.infer<typeof relayToHostFrameSchema>;
export type Question = z.infer<typeof questionSchema>;
export type ConversationMessage = z.infer<typeof messageSchema>;
export type AgentActivity = z.infer<typeof activitySchema>;
export type AgentEvent = z.infer<typeof agentEventSchema>;

export function parseFrame<T>(text: string, schema: z.ZodType<T>): T {
  if (new TextEncoder().encode(text).length > MAX_FRAME_BYTES) throw new Error("Message too large");
  return schema.parse(JSON.parse(text));
}
