import { LIMITS, failure, type Reply } from "@axo/protocol";

export interface BoundedReplyGroup {
  replies: Reply[];
  stored: string;
}

/** Bound the actual delivery shape, not the SQL array used to store a single reply. */
export function boundReplyGroup(replies: Reply[], batch: boolean): BoundedReplyGroup {
  const frame = batch ? replies : replies[0];
  const bytes = new TextEncoder().encode(JSON.stringify(frame)).byteLength;
  // Replies already have validated IDs, and there are at most eight per group.
  // Reducing payloads must preserve every correlation ID and the caller's batch shape.
  const bounded = bytes <= LIMITS.frameBytes
    ? replies
    : replies.map(reply => failure(reply.id, -32004, "Outcome unknown; reconcile commandId"));
  return { replies: bounded, stored: JSON.stringify(bounded) };
}
