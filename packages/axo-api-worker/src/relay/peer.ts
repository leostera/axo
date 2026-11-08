import { z } from "zod";
import { uuid } from "@axo/protocol";

/**
 * The Mac's socket to its HostDO, as its attachment says. Unknown keys are dropped rather than
 * refused: a socket accepted by an older release keeps fields this one no longer reads.
 */
export const peerSchema = z.object({
  role: z.literal("daemon"),
  /** The account the Mac is paired with. */
  identity: z.string().min(1).max(256),
  expiresAt: z.number().finite(),
  connectionId: uuid,
  machineId: uuid,
  negotiated: z.boolean(),
  /** The start of the current one-second rate window, and the frames received in it. */
  window: z.number(),
  calls: z.number().int().nonnegative(),
});
export type Peer = z.infer<typeof peerSchema>;
export type CallerContext = { socket: WebSocket; peer: Peer };

/** The lease of the Mac's current connection: one row per host, connection state only. */
export type Route = {
  connection_id: string;
  machine_id: string;
  generation: string | null;
  lease_until: number;
  ready: number;
};

/**
 * How a socket this object doesn't serve is closed (RFD0032, Release P). A protocol 3 client that
 * hears it reconnects, and falls back to protocol 2 when the HostDO refuses the new socket.
 */
export const UNOWNED_CLOSE = { code: 4010, reason: "Protocol not served" } as const;
