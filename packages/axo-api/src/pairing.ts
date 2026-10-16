import { z } from "zod";
import { uuid } from "./identity.js";

export const hostPairingCodeSchema = z.string()
  .transform(value => value.toUpperCase())
  .pipe(z.string().regex(/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/));

const hostCredentialSchema = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const hostKindSchema = z.string().regex(/^[a-z][a-z0-9-]{0,63}$/);

export const hostPairingCreateResultSchema = z.object({
  code: hostPairingCodeSchema,
  expiresAt: z.string().datetime({ offset: true }),
}).strict();

export const hostPairingRedeemRequestSchema = z.object({
  code: hostPairingCodeSchema,
  hostId: uuid,
  hostGeneration: uuid,
  credentialId: uuid,
  credential: hostCredentialSchema,
  label: z.string().min(1).max(128),
  hostKind: hostKindSchema,
}).strict();

export const hostPairingRedeemResultSchema = z.object({
  linked: z.literal(true),
  accountId: uuid,
  hostId: uuid,
  hostGeneration: uuid,
  credentialId: uuid,
  linkedAt: z.string().datetime({ offset: true }),
}).strict();

export type HostPairingCreateResult = z.infer<typeof hostPairingCreateResultSchema>;
export type HostPairingRedeemRequest = z.infer<typeof hostPairingRedeemRequestSchema>;
export type HostPairingRedeemResult = z.infer<typeof hostPairingRedeemResultSchema>;
