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
  z.string().max(128).refine(value => value.length <= 128),
  z
    .number()
    .finite()
    .min(-Number.MAX_SAFE_INTEGER)
    .max(Number.MAX_SAFE_INTEGER),
  z.null(),
]);
export type RpcId = z.infer<typeof idSchema>;
// Preserve JSON dictionaries verbatim: Zod's record parser silently drops __proto__ keys.
const paramsSchema = z.custom<Record<string, unknown> | unknown[]>(value =>
  Array.isArray(value) || (value !== null && typeof value === "object" &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)),
).meta({ type: ["object", "array"] });
export const callSchema = z.object({
  jsonrpc: z.literal("2.0"),
  id: idSchema.optional(),
  method: z.string().min(1).max(128).refine(value => value.length <= 128),
  params: paramsSchema.optional(),
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
    if (!interoperableJson(value)) throw new Error("Unsupported JSON value");
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
/** Match serde_json's bounded, finite, Unicode-scalar JSON domain, without recursion. */
function interoperableJson(value: unknown): boolean {
  const pending = [{ value, depth: 0 }];
  while (pending.length) {
    const { value, depth } = pending.pop()!;
    if (typeof value === "number" && !Number.isFinite(value)) return false;
    if (typeof value === "string" && !scalarString(value)) return false;
    if (value !== null && typeof value === "object") {
      if (depth >= 127) return false;
      for (const [key, child] of Object.entries(value)) {
        if (!scalarString(key)) return false;
        pending.push({ value: child, depth: depth + 1 });
      }
    }
  }
  return true;
}
function scalarString(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xdc00 && unit <= 0xdfff) return false;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++index);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
    }
  }
  return true;
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
