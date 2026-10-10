import { test } from "node:test";
import assert from "node:assert/strict";
import { LIMITS, success, type RpcId } from "@axo/protocol";
import { boundReplyGroup } from "../src/relay/replies";

const size = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).byteLength;

test("single reply uses wire bytes, not its two-byte SQL array wrapper", () => {
  // Framing fixtures only, not method-specific metadata or execution evidence.
  const base = success(1, "");
  const reply = success(1, "x".repeat(LIMITS.frameBytes - size(base)));
  assert.equal(size(reply), LIMITS.frameBytes);
  const bounded = boundReplyGroup([reply], false);
  assert.deepEqual(bounded.replies, [reply]);
  assert.equal(size(JSON.parse(bounded.stored)), LIMITS.frameBytes + 2);
  const batch = boundReplyGroup([reply], true);
  assert.equal(batch.replies[0].id, 1);
  assert.ok("error" in batch.replies[0]);
  assert.ok(size(batch.replies) <= LIMITS.frameBytes);
});

test("single oversized reply preserves its original ID and requires reconciliation", () => {
  const originalId = "🙂".repeat(64);
  const reply = success(originalId, "x".repeat(LIMITS.frameBytes));
  const bounded = boundReplyGroup([reply], false);
  assert.deepEqual(bounded.replies, [{ jsonrpc: "2.0", id: originalId, error: { code: -32004, message: "Outcome unknown; reconcile commandId" } }]);
  assert.ok(size(bounded.replies[0]) <= LIMITS.frameBytes);
});

test("batch reduction retains all null, numeric and Unicode correlation IDs", () => {
  const ids: RpcId[] = [null, 0, -1, 1.5, 9007199254740991, "", "🙂".repeat(64), "id"];
  const replies = ids.map(id => success(id, "界".repeat(3000)));
  // Unicode strings fit by character count but exceed the encoded-byte budget together.
  assert.ok(JSON.stringify(replies).length < LIMITS.frameBytes);
  assert.ok(size(replies) > LIMITS.frameBytes);
  const bounded = boundReplyGroup(replies, true);
  assert.deepEqual(bounded.replies.map(reply => reply.id), ids);
  assert.ok(bounded.replies.every(reply => "error" in reply && reply.error.code === -32004));
  assert.deepEqual(JSON.parse(bounded.stored), bounded.replies);
  assert.ok(size(bounded.replies) <= LIMITS.frameBytes);
});
