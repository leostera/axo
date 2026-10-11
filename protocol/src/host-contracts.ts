import { z } from "zod";
import { uuid, destinationSchema } from "./identity.js";
const helperVersion = z.string().min(1).max(128).refine(value => new TextEncoder().encode(value).length <= 128 && !/[\p{Cc}\p{Cs}]/u.test(value));
export const hostUpgradePlanSchema = z.object({
  handoffId: uuid,
  expectedVersion: helperVersion,
  replacementVersion: helperVersion,
  replacementBuildNumber: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
}).strict();
export const hostMethods = {
  "axo.host.get": z.object({ target: destinationSchema }).strict(),
  "axo.host.prepareUpgrade": z.object({ target: destinationSchema, plan: hostUpgradePlanSchema }).strict(),
} as const;
export const hostResults = {
  "axo.host.prepareUpgrade": z.object({
    hostGeneration: uuid,
    machineId: uuid,
    daemonVersion: helperVersion,
    daemonBuildNumber: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
    plan: hostUpgradePlanSchema,
    disposition: z.enum(["quiesced", "deferredActiveWork", "notNewer"]),
  }).strict(),
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
