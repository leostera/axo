import { z } from "zod";
import { uuid, destinationSchema } from "./identity.js";
import { runtimeRefSchema, terminalSchema } from "./runtime-contracts.js";
import { piAdmissionSchema, piReceiptSchema } from "./pi-contracts.js";
import { shellPaneSchema, paneReceiptSchema } from "./pane-contracts.js";

export const workNameSchema = z.string().min(1).max(80).refine(
  name => name.trim() === name && !/[\p{Cc}\p{Cs}]/u.test(name),
);
export const workRevisionSchema = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
export const workspaceTargetSchema = destinationSchema.extend({ workspaceId: uuid }).strict();
export const sessionDestinationSchema = destinationSchema.extend({ workspaceId: uuid.nullable().default(null) }).strict();
export const sessionTargetSchema = sessionDestinationSchema.extend({ sessionId: uuid }).strict();
export const workspaceRecordSchema = z.object({
  workspaceId: uuid,
  name: workNameSchema,
  directoryId: z.string().regex(/^[a-zA-Z0-9_-]{1,64}$/),
}).strict();
export const sessionRecordSchema = z.object({
  sessionId: uuid,
  workspaceId: uuid.nullable(),
  name: workNameSchema,
  piPaneId: uuid,
}).strict();
// A runtime is a process observation, not evidence of Pi admission.
export const workSessionSchema = z.object({
  sessionId: uuid,
  workspaceId: uuid.nullable(),
  name: workNameSchema,
  nameSource: z.literal("manual"),
  pi: z.object({
    paneId: uuid,
    chatId: uuid.nullable(),
    admission: piAdmissionSchema,
    title: workNameSchema.nullable().optional(),
  }).strict(),
  runtime: terminalSchema.nullable(),
  shellPanes: z.array(shellPaneSchema).max(32).default([]),
}).strict();
const cursorFields = {
  target: destinationSchema,
  revision: workRevisionSchema,
  after: uuid,
};
export const workspaceCursorSchema = z.object({
  ...cursorFields,
  scope: z.object({ kind: z.literal("workspaces") }).strict(),
}).strict();
export const sessionCursorSchema = z.object({
  ...cursorFields,
  scope: z.object({
    kind: z.literal("sessions"),
    workspaceId: uuid.nullable().default(null),
  }).strict(),
}).strict();
const pageLimit = z.number().int().min(1).max(50).default(50);
const mutationFields = {
  commandId: uuid,
  expectedRevision: workRevisionSchema,
  name: workNameSchema,
};
export const workMethods = {
  "axo.workspace.directories": z.object({ target: destinationSchema }).strict(),
  "axo.workspace.list": z.object({
    target: destinationSchema,
    cursor: workspaceCursorSchema.optional(),
    limit: pageLimit,
  }).strict(),
  "axo.workspace.create": z.object({
    target: destinationSchema,
    ...mutationFields,
    directoryId: workspaceRecordSchema.shape.directoryId,
  }).strict(),
  "axo.workspace.rename": z.object({
    target: workspaceTargetSchema,
    ...mutationFields,
  }).strict(),
  "axo.session.list": z.object({
    target: destinationSchema,
    workspaceId: uuid.optional(),
    cursor: sessionCursorSchema.optional(),
    limit: pageLimit,
  }).strict(),
  "axo.session.get": z.object({ target: sessionTargetSchema }).strict(),
  "axo.session.create": z.object({
    target: sessionDestinationSchema,
    ...mutationFields,
  }).strict(),
  "axo.session.rename": z.object({
    target: sessionTargetSchema,
    ...mutationFields,
  }).strict(),
  "axo.command.get": z.object({
    target: destinationSchema,
    commandId: uuid,
  }).strict(),
} as const;
// Selecting a local folder is approval on that host; never expose paths to cloud callers.
export const localDirectoryPathSchema = z.string().min(1).max(16384)
  .regex(/^\/[^\0]*$/u)
  .refine(path => new TextEncoder().encode(path).length <= 16384)
  .brand<"LocalDirectoryPath">();
export const localWorkMethods = {
  "axo.session.createIfEmpty": z.object({ target: destinationSchema, ...mutationFields }).strict(),
  "axo.workspace.createLocal": z.object({
    target: destinationSchema,
    ...mutationFields,
    directoryPath: localDirectoryPathSchema,
    initialSessionName: workNameSchema.optional(),
  }).strict(),
} as const;
export const workMutationMethods = [
  "axo.workspace.create",
  "axo.workspace.rename",
  "axo.session.create",
  "axo.session.rename",
] as const;
const workspaceResult = z.object({
  hostGeneration: uuid,
  revision: workRevisionSchema,
  workspace: workspaceRecordSchema,
}).strict();
const sessionResult = z.object({
  hostGeneration: uuid,
  revision: workRevisionSchema,
  session: workSessionSchema,
}).strict();
const committedSchema = z.object({
  revision: workRevisionSchema,
  record: z.discriminatedUnion("kind", [
    z.object({ kind: z.literal("workspace"), record: workspaceRecordSchema }).strict(),
    z.object({ kind: z.literal("session"), record: sessionRecordSchema }).strict(),
    z.object({ kind: z.literal("workspaceSession"), record: z.object({
      workspace: workspaceRecordSchema, session: sessionRecordSchema,
    }).strict().refine(record => record.session.workspaceId === record.workspace.workspaceId) }).strict(),
  ]),
}).strict();
export const commandReceiptSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("pane"), receipt: paneReceiptSchema }).strict(),
  z.object({ kind: z.literal("pi"), receipt: piReceiptSchema }).strict(),
  z.object({ kind: z.literal("work"), committed: committedSchema }).strict(),
  z.object({
    kind: z.literal("runtime"),
    runtime: runtimeRefSchema,
    terminal: terminalSchema.nullable(),
  }).strict(),
]);
export const localWorkResults = {
  "axo.workspace.createLocal": workspaceResult.extend({ session: workSessionSchema.optional() }).strict(),
  "axo.session.createIfEmpty": sessionResult,
} as const;
export const workResults = {
  "axo.workspace.directories": z.object({
    hostGeneration: uuid,
    directories: z.array(z.object({
      directoryId: workspaceRecordSchema.shape.directoryId,
      name: workNameSchema,
    }).strict()).max(16),
  }).strict(),
  "axo.workspace.list": z.object({
    hostGeneration: uuid,
    revision: workRevisionSchema,
    workspaces: z.array(workspaceRecordSchema).max(50),
    next: workspaceCursorSchema.nullable(),
  }).strict(),
  "axo.workspace.create": workspaceResult,
  "axo.workspace.rename": workspaceResult,
  "axo.session.list": z.object({
    hostGeneration: uuid,
    revision: workRevisionSchema,
    sessions: z.array(workSessionSchema).max(50),
    next: sessionCursorSchema.nullable(),
  }).strict(),
  "axo.session.get": sessionResult,
  "axo.session.create": sessionResult,
  "axo.session.rename": sessionResult,
  "axo.command.get": z.object({
    hostGeneration: uuid,
    receipt: commandReceiptSchema.nullable(),
  }).strict(),
} as const;
