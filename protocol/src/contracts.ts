import { z } from "zod";
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
// UUID case cannot create two directory entries/relay objects for one identity.
export const uuid = z
  .string()
  .uuid()
  .transform((value) => value.toLowerCase());
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
export const destinationSchema = z
  .object({ machineId: uuid, hostGeneration: uuid })
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
  "axo.runtime.list": listSchema,
  "axo.runtime.startApproved": startSchema,
} as const;
export type RemoteMethod = keyof typeof remoteMethods;
export const METHODS = Object.keys(remoteMethods) as RemoteMethod[];
const processSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("starting") }).strict(),
  z
    .object({ kind: z.literal("running"), pid: z.number().int().positive() })
    .strict(),
  z
    .object({ kind: z.literal("stopping"), pid: z.number().int().positive() })
    .strict(),
  z
    .object({ kind: z.literal("exited"), wait_status: z.number().int() })
    .strict(),
  z.object({ kind: z.literal("failed") }).strict(),
  z.object({ kind: z.literal("recovery_required") }).strict(),
]);
export const terminalSchema = z
  .object({
    runtime: z
      .object({
        host_generation: uuid,
        target: z.object({ session_id: uuid, pane_id: uuid }).strict(),
        runtime_generation: uuid,
      })
      .strict(),
    process: processSchema,
    attached: z.boolean(),
    backlog_bytes: z.number().int().min(0).max(8192),
  })
  .strict();
export const results = {
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
