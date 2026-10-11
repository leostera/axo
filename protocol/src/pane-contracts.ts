import { z } from "zod";
import { destinationSchema, uuid } from "./identity.js";
import { runtimeRefSchema, terminalSchema } from "./runtime-contracts.js";

export const paneSessionTargetSchema = destinationSchema.extend({ workspaceId: uuid.nullable().default(null), sessionId: uuid }).strict();
const profileId = z.string().regex(/^[a-zA-Z0-9_-]{1,64}$/);
export const paneIntentSchema = z.discriminatedUnion("operation", [
  z.object({ operation: z.literal("addPane"), target: paneSessionTargetSchema, profileId }).strict(),
  z.object({ operation: z.literal("removePane"), target: paneSessionTargetSchema, paneId: uuid, runtime: runtimeRefSchema.nullable() }).strict(),
]);
const rejection = z.enum(["invalid_request", "stale_host", "stale_runtime", "stale_attachment", "not_found", "conflict", "capacity", "already_attached", "not_running", "recovery_required", "launch_failed", "storage_failed", "input_blocked", "invalid_size", "invalid_transition"]);
export const paneReceiptSchema = z.object({
  commandId: uuid,
  intent: paneIntentSchema,
  paneId: uuid,
  runtime: runtimeRefSchema.nullable(),
  disposition: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("prepared") }).strict(),
    z.object({ kind: z.literal("added") }).strict(),
    z.object({ kind: z.literal("removed") }).strict(),
    z.object({ kind: z.literal("rejected"), reason: rejection }).strict(),
  ]),
}).strict();
export const shellPaneSchema = z.object({
  paneId: uuid,
  kind: z.literal("shell"),
  profileId,
  state: z.enum(["adding", "open", "failed", "closing", "removed"]),
  runtime: runtimeRefSchema.nullable(),
  terminal: terminalSchema.nullable(),
}).strict();
export const paneMethods = {
  "axo.session.pane.add": z.object({ target: paneSessionTargetSchema, commandId: uuid, profileId }).strict(),
  "axo.session.pane.remove": z.object({ target: paneSessionTargetSchema, commandId: uuid, paneId: uuid, runtime: runtimeRefSchema.nullable() }).strict(),
} as const;
export const paneMutationMethods = ["axo.session.pane.add", "axo.session.pane.remove"] as const;
const paneResult = z.object({ hostGeneration: uuid, receipt: paneReceiptSchema, pane: shellPaneSchema }).strict();
export const paneResults = { "axo.session.pane.add": paneResult, "axo.session.pane.remove": paneResult } as const;
