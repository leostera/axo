import { z } from "zod";
import { uuid, destinationSchema } from "./identity.js";
import { terminalSchema, runtimeRefSchema } from "./runtime-contracts.js";
import { canonicalProjectionSchema } from "./pi-contracts.js";
const revision = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const name = z.string().min(1).max(80).refine(value => value.trim() === value && !/[\u0000-\u001f\u007f]/u.test(value));
export const stateTargetSchema = destinationSchema.extend({ storeGeneration: uuid }).strict();
export const stateSessionTargetSchema = stateTargetSchema.extend({ workspaceId: uuid.nullable(), sessionId: uuid }).strict();
const lifecycle = z.enum(["open", "archived"]);
export const statePiBindingTargetSchema = stateSessionTargetSchema.extend({ paneId: uuid, runtime: runtimeRefSchema, chatId: uuid }).strict().refine(value => value.runtime.target.session_id === value.sessionId && value.runtime.target.pane_id === value.paneId);
const questionText = (maximum: number) => z.string().min(1).max(maximum).refine(value => value.length <= maximum && !value.includes("\0"));
const piQuestion = z.object({ id: uuid, interactionId: uuid, title: questionText(2000), options: z.array(z.object({ id: uuid, label: questionText(500) }).strict()).min(2).max(8) }).strict().refine(value => new Set(value.options.map(option => option.id)).size === value.options.length);
const piTitle = z.string().min(1).max(80).refine(value => value.length <= 80 && value.trim() === value && !/\p{Cc}/u.test(value));
const piLiveState = z.object({ title: piTitle.nullable(), leafId: z.string().min(1).refine(value => new TextEncoder().encode(value).length <= 128 && !/\p{Cc}/u.test(value)).nullable(), busy: z.boolean(), interactionId: uuid.nullable(), uiWaits: z.number().int().min(0).max(65535), question: piQuestion.nullable(), pending: z.boolean(), recovery: z.boolean() }).strict().refine(value => value.question === null || (value.uiWaits > 0 && value.question.interactionId === value.interactionId));
const piLiveObservation = z.object({ kind: z.literal("live"), target: statePiBindingTargetSchema, state: piLiveState }).strict();
export const statePiObservationSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("notAdmitted") }).strict(),
  piLiveObservation,
  z.object({ kind: z.literal("stopped"), target: statePiBindingTargetSchema }).strict(),
]).refine(value => value.kind !== "live" || value.target.runtime.host_generation === value.target.hostGeneration);
export const desiredWorkspaceSchema = z.object({ workspaceId: uuid, name, directory: z.string().min(1).max(4096), lifecycle, configRevision: revision }).strict();
export const desiredSessionSchema = z.object({ sessionId: uuid, workspaceId: uuid.nullable(), name, manualName: z.boolean(), lifecycle, configRevision: revision }).strict();
const role = z.discriminatedUnion("kind", [z.object({ kind: z.literal("pi") }).strict(), z.object({ kind: z.literal("accountShell") }).strict(), z.object({ kind: z.literal("profileShell"), profileId: z.string().min(1).max(80) }).strict()]);
export const desiredPaneSchema = z.object({ paneId: uuid, sessionId: uuid, role, present: z.boolean(), ordinal: z.number().int().min(0).max(31), configRevision: revision }).strict();
const panes = z.array(desiredPaneSchema).min(2).max(32);
const graph = z.object({ session: desiredSessionSchema, panes }).strict().refine(value => new Set(value.panes.map(pane => pane.paneId)).size === value.panes.length && value.panes.every(pane => pane.sessionId === value.session.sessionId));
const workspaceGraph = z.object({ workspace: desiredWorkspaceSchema, initialSession: graph }).strict().refine(value => value.initialSession.session.workspaceId === value.workspace.workspaceId);
const subject = z.discriminatedUnion("kind", [z.object({ kind: z.literal("workspace"), workspaceId: uuid }).strict(), z.object({ kind: z.literal("session"), workspaceId: uuid.nullable(), sessionId: uuid }).strict()]);
const accepted = <T extends z.ZodType>(graph: T) => z.object({ commandId: uuid, revision: revision.min(1), graph }).strict();
export const stateOperationSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("createWorkspace"), accepted: accepted(workspaceGraph) }).strict(),
  z.object({ kind: z.literal("createSession"), accepted: accepted(graph) }).strict(),
  z.object({ kind: z.literal("createStandalone"), accepted: accepted(graph) }).strict(),
  z.object({ kind: z.literal("addShell"), accepted: accepted(desiredPaneSchema) }).strict(),
  z.object({ kind: z.literal("removeShell"), accepted: accepted(uuid) }).strict(),
  z.object({ kind: z.literal("setLifecycle"), accepted: accepted(subject) }).strict(),
]);
const availability = z.enum(["live", "materializing", "restarting", "stopping", "stopped", "blocked"]);
const observedPane = z.object({ desired: desiredPaneSchema, availability, lastRuntime: runtimeRefSchema.nullable(), terminal: terminalSchema.nullable() }).strict().refine(value => {
  if (value.terminal === null) return true;
  return value.availability === "live" && value.lastRuntime !== null && JSON.stringify(value.terminal.runtime) === JSON.stringify(value.lastRuntime) && value.terminal.runtime.target.pane_id === value.desired.paneId && value.terminal.runtime.target.session_id === value.desired.sessionId;
});
export const stateSessionViewSchema = z.object({ session: desiredSessionSchema, panes: z.array(observedPane).min(2).max(32), readiness: z.enum(["ready", "materializing", "blocked", "stopped"]) }).strict().refine(value => {
  if (new Set(value.panes.map(pane => pane.desired.paneId)).size !== value.panes.length || !value.panes.every(pane => pane.desired.sessionId === value.session.sessionId && pane.desired.present)) return false;
  return value.readiness !== "ready" || value.panes.every(pane => pane.availability === "live" && pane.terminal !== null);
});
const historyCollection = z.enum(["branch", "entries"]);
const historyDigest = z.string().regex(/^[0-9a-f]{64}$/u);
const historyEntryId = z.string().min(1).refine(value => new TextEncoder().encode(value).length <= 128 && !/\p{Cc}/u.test(value));
const historyCursor = z.object({ target: statePiBindingTargetSchema, readMode: z.literal("stopped"), collection: historyCollection, headDigest: historyDigest, after: historyEntryId }).strict();
const historyProjection = canonicalProjectionSchema.refine(value => new TextEncoder().encode(value.timestamp).length <= 128 && historyEntryId.safeParse(value.kind).success && (value.role === null || (new TextEncoder().encode(value.role).length <= 64 && value.role.length > 0 && !/\p{Cc}/u.test(value.role))));
const stoppedHistoryPage = z.object({ target: statePiBindingTargetSchema, readMode: z.literal("stopped"), collection: historyCollection, headDigest: historyDigest, leafId: historyEntryId.nullable(), entries: z.array(historyProjection).max(50), cursor: historyCursor.nullable() }).strict().refine(value => {
  if (new Set(value.entries.map(entry => entry.entryId)).size !== value.entries.length) return false;
  const cursor = value.cursor;
  return cursor === null || (JSON.stringify(cursor.target) === JSON.stringify(value.target) && cursor.collection === value.collection && cursor.headDigest === value.headDigest && cursor.after === value.entries.at(-1)?.entryId);
});
const domain = z.discriminatedUnion("kind", [z.object({ kind: z.literal("workspaces") }).strict(), z.object({ kind: z.literal("sessions"), workspaceId: uuid.nullable() }).strict()]);
const cursor = z.object({ target: stateTargetSchema, revision, domain, after: uuid }).strict();
const page = { target: stateTargetSchema, cursor: cursor.optional(), limit: z.number().int().min(1).max(50).default(8) };
const mutation = { target: stateTargetSchema, commandId: uuid, expectedRevision: revision };
export const stateRemoteMethods = {
  "axo.state.get": z.object({ target: destinationSchema }).strict(),
  "axo.state.workspace.list": z.object(page).strict(),
  "axo.state.session.list": z.object({ ...page, workspaceId: uuid.nullable() }).strict(),
  "axo.state.session.get": z.object({ target: stateSessionTargetSchema }).strict(),
  "axo.state.chat.observe": z.object({ target: stateSessionTargetSchema }).strict(),
  "axo.state.chat.get": z.object({ target: statePiBindingTargetSchema.refine(value => value.runtime.host_generation === value.hostGeneration) }).strict(),
  "axo.state.chat.history": z.object({ target: statePiBindingTargetSchema, readMode: z.literal("stopped"), collection: historyCollection.default("branch"), cursor: historyCursor.optional(), limit: z.number().int().min(1).max(50).default(8) }).strict().refine(value => value.cursor === undefined || (JSON.stringify(value.cursor.target) === JSON.stringify(value.target) && value.cursor.collection === value.collection)),
  "axo.state.session.create": z.object({ ...mutation, workspaceId: uuid.nullable(), name }).strict(),
  "axo.state.operation.get": z.object({ target: stateTargetSchema, commandId: uuid }).strict(),
} as const;
export const stateLocalMethods = {
  "axo.state.workspace.create": z.object({ ...mutation, name, directoryPath: z.string().min(1).max(4096).refine(value => value.startsWith("/") && !value.includes("\0")) }).strict(),
  "axo.state.lifecycle.set": z.object({ ...mutation, subject, lifecycle }).strict(),
  "axo.state.pane.add": z.object({ ...mutation, target: stateSessionTargetSchema }).strict(),
  "axo.state.pane.remove": z.object({ ...mutation, target: stateSessionTargetSchema, paneId: uuid }).strict(),
  "axo.state.session.completion": z.object({ target: stateSessionTargetSchema, runtimes: z.array(runtimeRefSchema).min(1).max(32).refine(value => new Set(value.map(runtime => JSON.stringify(runtime))).size === value.length) }).strict(),
} as const;
export const stateMutationMethods = ["axo.state.workspace.create", "axo.state.session.create", "axo.state.lifecycle.set", "axo.state.pane.add", "axo.state.pane.remove"] as const;
const envelope = <T extends z.ZodType>(value: T) => z.object({ hostGeneration: uuid, storeGeneration: uuid, revision, value }).strict();
const operation = envelope(z.object({ operation: stateOperationSchema.nullable(), session: stateSessionViewSchema.nullable() }).strict());
export const stateResults = {
  "axo.state.get": envelope(z.object({ backendCompleteCreation: z.literal(true), schemaVersion: z.literal(3) }).strict()),
  "axo.state.workspace.list": envelope(z.object({ records: z.array(desiredWorkspaceSchema).max(50), cursor: cursor.nullable() }).strict()),
  "axo.state.session.list": envelope(z.object({ records: z.array(stateSessionViewSchema).max(50), cursor: cursor.nullable() }).strict()),
  "axo.state.session.get": envelope(stateSessionViewSchema),
  "axo.state.chat.observe": envelope(statePiObservationSchema).refine(value => value.value.kind === "notAdmitted" || (value.value.target.hostGeneration === value.hostGeneration && value.value.target.storeGeneration === value.storeGeneration)),
  "axo.state.chat.get": envelope(piLiveObservation).refine(value => value.value.target.runtime.host_generation === value.hostGeneration && value.value.target.hostGeneration === value.hostGeneration && value.value.target.storeGeneration === value.storeGeneration),
  "axo.state.chat.history": envelope(stoppedHistoryPage).refine(value => value.value.target.hostGeneration === value.hostGeneration && value.value.target.storeGeneration === value.storeGeneration),
  "axo.state.workspace.create": operation, "axo.state.session.create": operation, "axo.state.lifecycle.set": operation,
  "axo.state.pane.add": operation, "axo.state.pane.remove": operation, "axo.state.operation.get": operation,
  "axo.state.session.completion": envelope(z.object({ completed: z.array(runtimeRefSchema).max(32) }).strict()),
} as const;
