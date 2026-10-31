import { z } from "zod";
import { uuid } from "@axo/protocol";
import type { Principal } from "../access";

export interface HostSubscription {
  subscriptionId: string;
  hostGeneration: string;
}
export interface Peer extends Principal {
  connectionId: string;
  machineId: string;
  negotiated: boolean;
  window: number;
  calls: number;
  hostSubscriptions: HostSubscription[];
}
export type CallerContext = { socket: WebSocket; peer: Peer };
export const peerSchema = z
  .object({
    role: z.enum(["client", "daemon"]),
    identity: z.string().min(1).max(256),
    expiresAt: z.number().finite(),
    connectionId: uuid,
    machineId: uuid,
    negotiated: z.boolean(),
    window: z.number(),
    calls: z.number().int().nonnegative(),
    hostSubscriptions: z.array(z.object({
      subscriptionId: z.uuid(),
      hostGeneration: uuid,
    }).strict()).max(64).default([]),
  })
  .strict();
