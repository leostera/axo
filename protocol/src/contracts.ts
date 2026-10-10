import { z } from "zod";
import { uuid, destinationSchema } from "./identity.js";
import { terminalSchema } from "./runtime-contracts.js";
import { workMethods, workResults } from "./work-contracts.js";
export { uuid, destinationSchema } from "./identity.js";
export * from "./runtime-contracts.js";
export * from "./work-contracts.js";
import {
  createJSONRPCErrorResponse,
  createJSONRPCSuccessResponse,
} from "json-rpc-2.0";

export const LIMITS = {
  frameBytes: 65_536,
  batchCalls: 8,
  machines: 16,
  pendingPerClient: 32,
  pendingPerMachine: 128,
  clientsPerMachine: 8,
  leaseMs: 30_000,
  deadlineMs: 10_000,
} as const;
export const idSchema = z.union([
  z.string().max(128),
  z
    .number()
    .finite()
    .min(-Number.MAX_SAFE_INTEGER)
    .max(Number.MAX_SAFE_INTEGER),
  z.null(),
]);
export type RpcId = z.infer<typeof idSchema>;
export const callSchema = z.object({
  jsonrpc: z.literal("2.0"),
  id: idSchema.optional(),
  method: z.string().min(1).max(128),
  params: z
    .union([z.record(z.string(), z.unknown()), z.array(z.unknown())])
    .optional(),
});
export type Call = z.infer<typeof callSchema>;
export const replySchema = z.union([
  z
    .object({ jsonrpc: z.literal("2.0"), id: idSchema, result: z.unknown() })
    .strict()
    .refine((value) => Object.hasOwn(value, "result")),
  z
    .object({
      jsonrpc: z.literal("2.0"),
      id: idSchema,
      error: z
        .object({
          code: z.number().int(),
          message: z.string().max(256),
          data: z.unknown().optional(),
        })
        .strict(),
    })
    .strict(),
]);
export type Reply = z.infer<typeof replySchema>;
export function failure(
  id: RpcId,
  code: number,
  message: string,
): Extract<Reply, { error: unknown }> {
  return createJSONRPCErrorResponse(id, code, message);
}
export function success(
  id: RpcId,
  result: unknown,
): Extract<Reply, { result: unknown }> {
  return createJSONRPCSuccessResponse(id, result);
}
export type Decoded = { batch: boolean; entries: unknown[] } | { error: Reply };
export function decode(raw: string): Decoded {
  if (
    raw.length > LIMITS.frameBytes ||
    new TextEncoder().encode(raw).byteLength > LIMITS.frameBytes
  )
    return { error: failure(null, -32600, "Frame limit") };
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return { error: failure(null, -32700, "Parse error") };
  }
  if (Array.isArray(value)) {
    if (!value.length || value.length > LIMITS.batchCalls)
      return { error: failure(null, -32600, "Batch limit") };
    return { batch: true, entries: value };
  }
  return { batch: false, entries: [value] };
}
export const negotiateSchema = z
  .object({ protocolVersion: z.literal(1) })
  .strict();
// Private, boot-fenced local discovery. Routing metadata, not authentication.
export const localEndpointSchema = z
  .object({
    version: z.literal(1),
    protocolVersion: z.literal(1),
    endpoint: z
      .string()
      .regex(/^ws:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}\/v1\/rpc$/)
      .refine((value) => Number(value.split(":")[2]?.split("/")[0]) <= 65535),
    machineId: uuid,
    hostGeneration: uuid,
  })
  .strict();
export type LocalEndpoint = z.infer<typeof localEndpointSchema>;

export const registrationSchema = z
  .object({
    protocolVersion: z.literal(1),
    machineId: uuid,
    hostGeneration: uuid,
    label: z.string().min(1).max(80),
  })
  .strict();
export type Registration = z.infer<typeof registrationSchema>;
export const machineListResultSchema = z
  .object({
    machines: z
      .array(
        z
          .object({
            machineId: uuid,
            label: z.string().min(1).max(80),
            online: z.boolean(),
            hostGeneration: uuid.nullable(),
          })
          .strict(),
      )
      .max(LIMITS.machines),
  })
  .strict();
export const listSchema = z
  .object({
    target: destinationSchema,
    after: uuid.optional(),
    limit: z.number().int().min(1).max(50).default(50),
  })
  .strict();
export const startSchema = z
  .object({
    target: destinationSchema
      .extend({ sessionId: uuid, paneId: uuid })
      .strict(),
    commandId: uuid,
    profileId: z.string().regex(/^[a-zA-Z0-9_-]{1,64}$/),
  })
  .strict();
export const remoteMethods = {
  ...workMethods,
  "axo.runtime.list": listSchema,
  "axo.runtime.startApproved": startSchema,
} as const;
export type RemoteMethod = keyof typeof remoteMethods;
export const METHODS = Object.keys(remoteMethods) as RemoteMethod[];
export const results = {
  ...workResults,
  "axo.runtime.list": z
    .object({
      hostGeneration: uuid,
      terminals: z.array(terminalSchema).max(50),
      next: uuid.nullable(),
    })
    .strict(),
  "axo.runtime.startApproved": z
    .object({ hostGeneration: uuid, terminal: terminalSchema })
    .strict(),
} as const;
