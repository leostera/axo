import { test } from "node:test";
import assert from "node:assert/strict";
import { LIMITS, success, type RpcId } from "@axo/protocol";
import { boundReplies } from "../src/relay/replies";

const size = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).byteLength;

test("a single reply is measured as it goes on the wire, not as the array a batch would be", () => {
  // Framing fixtures only, not method-specific metadata or execution evidence.
  const base = success(1, "");
  const reply = success(1, "x".repeat(LIMITS.frameBytes - size(base)));
  assert.equal(size(reply), LIMITS.frameBytes);
  assert.deepEqual(boundReplies([reply], false), [reply]);
  const batch = boundReplies([reply], true);
  assert.equal(batch[0].id, 1);
  assert.ok("error" in batch[0]);
  assert.ok(size(batch) <= LIMITS.frameBytes);
});

test("single oversized reply preserves its original ID and requires reconciliation", () => {
  const originalId = "🙂".repeat(64);
  const reply = success(originalId, "x".repeat(LIMITS.frameBytes));
  const bounded = boundReplies([reply], false);
  assert.deepEqual(bounded, [{ jsonrpc: "2.0", id: originalId, error: { code: -32004, message: "Outcome unknown; reconcile commandId" } }]);
  assert.ok(size(bounded[0]) <= LIMITS.frameBytes);
});

test("batch reduction retains all null, numeric and Unicode correlation IDs", () => {
  const ids: RpcId[] = [null, 0, -1, 1.5, 9007199254740991, "", "🙂".repeat(64), "id"];
  const replies = ids.map(id => success(id, "界".repeat(3000)));
  // Unicode strings fit by character count but exceed the encoded-byte budget together.
  assert.ok(JSON.stringify(replies).length < LIMITS.frameBytes);
  assert.ok(size(replies) > LIMITS.frameBytes);
  const bounded = boundReplies(replies, true);
  assert.deepEqual(bounded.map(reply => reply.id), ids);
  assert.ok(bounded.every(reply => "error" in reply && reply.error.code === -32004));
  assert.ok(size(bounded) <= LIMITS.frameBytes);
});
