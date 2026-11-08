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

/**
 * How a socket this object doesn't serve is closed (RFD0032, Release P). A protocol 3 client that
 * hears it reconnects, and falls back to protocol 2 when the HostDO refuses the new socket.
 */
export const UNOWNED_CLOSE = { code: 4010, reason: "Protocol not served" } as const;
