import { z } from "zod";

const key = z.string().length(88).regex(/^[A-Za-z0-9+/]+={0,2}$/);
const signature = z.string().length(88).regex(/^[A-Za-z0-9+/]+={0,2}$/);
const name = z.string().min(1).max(80).refine(value => value.trim() === value && !/[\u0000-\u001f\u007f-\u009f]/u.test(value));
export const devicePairingClaimSchema = z.strictObject({
  id: z.uuid(), accountId: z.uuid(), hostId: z.uuid(), key, name, signature, proof: signature,
});
export const deviceLinkGrantSchema = z.strictObject({
  accountId: z.uuid(), id: z.uuid(), hostId: z.uuid(), expiresAt: z.number().int().positive(),
  key, name, managerKey: key, signature, deviceSignature: signature,
});
export const deviceUnlinkSchema = z.strictObject({
  accountId: z.uuid(), hostId: z.uuid(), linkId: z.uuid(), expiresAt: z.number().int().positive(),
  key, managerKey: key, signature,
});
export const deviceLinkCommandSchema = z.discriminatedUnion("operation", [
  z.strictObject({ operation: z.literal("redeem"), claim: devicePairingClaimSchema }),
  z.strictObject({ operation: z.literal("link"), grant: deviceLinkGrantSchema }),
  z.strictObject({ operation: z.literal("unlink"), revocation: deviceUnlinkSchema }),
]);
