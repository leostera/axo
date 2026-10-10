import { z } from "zod";
import { uuid, destinationSchema } from "./identity.js";
export const hostMethods = { "axo.host.get": z.object({ target: destinationSchema }).strict() } as const;
export const hostResults = {
  "axo.host.get": z.object({
    hostGeneration: uuid,
    machineId: uuid,
    hostname: z.string().min(1).max(80),
    machineType: z.string().min(1).max(80),
    daemonVersion: z.string().min(1).max(128),
    cloud: z.discriminatedUnion("kind", [
      z.object({ kind: z.literal("notConfigured") }).strict(),
      z.object({ kind: z.literal("connecting") }).strict(),
      z.object({ kind: z.literal("offline") }).strict(),
      z.object({ kind: z.literal("online"), leaseId: uuid, expiresAt: z.number().int().positive().max(Number.MAX_SAFE_INTEGER) }).strict(),
    ]),
  }).strict(),
} as const;
