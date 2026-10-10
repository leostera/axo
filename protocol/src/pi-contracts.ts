import { z } from "zod";
import { uuid, destinationSchema } from "./identity.js";
import { runtimeRefSchema } from "./runtime-contracts.js";
const recordedId = z.string().min(1).refine(value => new TextEncoder().encode(value).byteLength <= 128 && !/[\p{Cc}\p{Cs}]/u.test(value));
export const piAdmissionSchema = z.enum(["notAdmitted", "ready", "stopped", "failed", "recoveryRequired"]);
export const piSessionTargetSchema = destinationSchema.extend({ workspaceId: uuid, sessionId: uuid, paneId: uuid }).strict();
export const chatTargetSchema = piSessionTargetSchema.extend({ runtimeHostGeneration: uuid, chatId: uuid, runtimeGeneration: uuid }).strict();
export const piPersistenceSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("fresh") }).strict(),
  z.object({ kind: z.literal("resume"), chatId: uuid, previousRuntime: runtimeRefSchema }).strict(),
]);
const operationSchema = z.enum(["sendMessage", "sendSteeringMessage", "cancelTurn", "answerQuestion", "setViewing"]);
const intentSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("start"), target: piSessionTargetSchema, persistence: piPersistenceSchema }).strict(),
  z.object({ kind: z.literal("chat"), target: chatTargetSchema, operation: operationSchema }).strict(),
]);
export const piDispositionSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("prepared") }).strict(),
  z.object({ kind: z.literal("dispatched") }).strict(),
  z.object({ kind: z.literal("rejected"), code: z.number().int() }).strict(),
]);
export const piReceiptSchema = z.object({ commandId: uuid, intent: intentSchema, disposition: piDispositionSchema, runtime: runtimeRefSchema.nullable() }).strict();
export const questionSchema = z.object({ id: uuid, interactionId: uuid, title: z.string().min(1).max(2000), options: z.array(z.object({ id: uuid, label: z.string().min(1).max(500) }).strict()).min(2).max(8) }).strict();
export const canonicalProjectionSchema = z.object({ entryId: recordedId, parentId: recordedId.nullable(), timestamp: z.string().max(128), kind: z.string().min(1).max(128), role: z.string().max(64).nullable(), text: z.string().refine(value => new TextEncoder().encode(value).byteLength <= 2048), truncated: z.boolean(), toolCallId: recordedId.nullable(), toolName: recordedId.nullable(), toolCalls: z.array(z.object({ id: recordedId, name: recordedId }).strict()).max(32) }).strict();
const messageText = z.string().min(1).refine(value => /[^\p{White_Space}]/u.test(value) && !/^\p{White_Space}*\//u.test(value) && new TextEncoder().encode(value).byteLength <= 48*1024 && !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value));
const chatCommand = { target: chatTargetSchema, commandId: uuid };
const readMode = z.enum(["live", "stopped"]);
const readFields = { target: chatTargetSchema, readMode: readMode.default("live") };
const cursorSchema = z.object({ target: chatTargetSchema, readMode, leafId: recordedId.nullable(), after: recordedId }).strict();
export const piMethods = {
  "axo.session.start": z.object({ target: piSessionTargetSchema, commandId: uuid, persistence: piPersistenceSchema }).strict(),
  "axo.chat.get": z.object(readFields).strict(),
  "axo.chat.history": z.object({ ...readFields, limit: z.number().int().min(1).max(50).default(50), cursor: cursorSchema.optional() }).strict(),
  "axo.chat.getToolOutput": z.object({ ...readFields, entryId: recordedId, toolCallId: recordedId, offset: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER), limit: z.number().int().min(1).max(8192).default(8192) }).strict(),
  "axo.chat.sendMessage": z.object({ ...chatCommand, text: messageText }).strict(),
  "axo.chat.sendSteeringMessage": z.object({ ...chatCommand, text: messageText, interactionId: uuid }).strict(),
  "axo.chat.cancelTurn": z.object({ ...chatCommand, interactionId: uuid }).strict(),
  "axo.chat.answerQuestion": z.object({ ...chatCommand, interactionId: uuid, questionId: uuid, optionId: uuid }).strict(),
  "axo.chat.setViewing": z.object({ ...chatCommand, leaseId: uuid, viewing: z.boolean(), ttlSeconds: z.number().int().min(1).max(120) }).strict(),
} as const;
export const piMutationMethods = ["axo.session.start", "axo.chat.sendMessage", "axo.chat.sendSteeringMessage", "axo.chat.cancelTurn", "axo.chat.answerQuestion", "axo.chat.setViewing"] as const;
const mutationResult = z.object({ hostGeneration: uuid, receipt: piReceiptSchema }).strict();
export const piResults = {
  "axo.session.start": z.object({ hostGeneration: uuid, receipt: piReceiptSchema, chat: chatTargetSchema.nullable(), admission: piAdmissionSchema }).strict(),
  "axo.chat.get": z.object({ hostGeneration: uuid, readMode, target: chatTargetSchema, admission: piAdmissionSchema, busy: z.boolean(), interactionId: uuid.nullable(), uiWaits: z.number().int().min(0).max(65535), question: questionSchema.nullable(), recovery: z.boolean(), leafId: z.string().max(128).nullable(), recentEntries: z.array(canonicalProjectionSchema).max(10), viewingCount: z.number().int().min(0).max(16) }).strict(),
  "axo.chat.history": z.object({ hostGeneration: uuid, readMode, target: chatTargetSchema, leafId: z.string().max(128).nullable(), entries: z.array(canonicalProjectionSchema).max(50), next: cursorSchema.nullable() }).strict(),
  "axo.chat.getToolOutput": z.object({ hostGeneration: uuid, readMode, target: chatTargetSchema, entryId: recordedId, toolCallId: recordedId, offset: z.number().int().min(0), text: z.string().refine(value => new TextEncoder().encode(value).byteLength <= 8192), nextOffset: z.number().int().min(0).nullable(), totalBytes: z.number().int().min(0) }).strict(),
  "axo.chat.sendMessage": mutationResult,
  "axo.chat.sendSteeringMessage": mutationResult,
  "axo.chat.cancelTurn": mutationResult,
  "axo.chat.answerQuestion": mutationResult,
  "axo.chat.setViewing": mutationResult,
} as const;
