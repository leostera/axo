import { LIMITS, failure, type Reply } from "@axo/protocol";

/**
 * The replies to one message, sent as one frame: a batch's array, or a single reply. When that
 * frame would exceed `limit`, every reply becomes "outcome unknown", keeping each correlation ID
 * and the batch shape, so the caller reconciles instead of guessing.
 */
export function boundReplies(replies: Reply[], batch: boolean, limit: number = LIMITS.frameBytes): Reply[] {
  const frame = batch ? replies : replies[0];
  const bytes = new TextEncoder().encode(JSON.stringify(frame)).byteLength;
  return bytes <= limit ? replies : replies.map((reply) => failure(reply.id, -32004, "Outcome unknown; reconcile commandId"));
}
