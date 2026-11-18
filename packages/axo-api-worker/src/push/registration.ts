import { z } from "zod";
import { apnsDestinationSchema } from "./apns";

const installation = {
  installationId: z.uuid(),
  revision: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
};

/** A durable device-local revision fences late registration, rotation and sign-out requests. */
export const pushRegistrationSchema = z.discriminatedUnion("action", [
  z.strictObject({ ...installation, action: z.literal("enable"), previews: z.enum(["generic", "message"]).default("generic"), destination: apnsDestinationSchema
    .refine(value => value.topic === "dev.leostera.axo" && value.environment === "sandbox") }),
  z.strictObject({ ...installation, action: z.literal("disable") }),
]);
export type PushRegistration = z.infer<typeof pushRegistrationSchema>;
export type PushOwner = { accountId: string; sessionDigest: string; expiresAt: number };
export type PushRegistrationResult = "saved" | "stale" | "conflict" | "limited";

/** No token, session digest or destination is returned to the client. */
export type PushRegistrationReceipt = { revision: number };
