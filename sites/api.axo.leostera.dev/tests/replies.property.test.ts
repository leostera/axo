import { test } from "node:test";
import assert from "node:assert/strict";
import fc from "fast-check";
import { LIMITS, success, replySchema, type Reply } from "@axo/protocol";
import { boundReplyGroup } from "../src/relay/replies";

const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value)).byteLength;
const id = fc.oneof(
  fc.constant(null),
  fc.double({ min: -Number.MAX_SAFE_INTEGER, max: Number.MAX_SAFE_INTEGER, noNaN: true }),
  fc.string({ maxLength: 128 }),
  fc.integer({ min: 0, max: 64 }).map(length => "🙂".repeat(length)),
);
const reply = fc.tuple(
  id,
  fc.constantFrom("x", "界", "🙂", "\n", '"', "\\", "\u0000"),
  fc.oneof(fc.integer({ min: 0, max: 20000 }), fc.constantFrom(0, 1, 8192, 16384, 20000)),
).map(([id, token, count]) => success(id, token.repeat(count)));
const groups = fc.boolean().chain(batch => fc.record({
  batch: fc.constant(batch),
  replies: fc.array(reply, { minLength: 1, maxLength: batch ? 8 : 1 }),
}));

async function campaign(property: Parameters<typeof fc.check>[0]) {
  const seed = process.env.AXO_PROPERTY_SEED;
  const path = process.env.AXO_PROPERTY_PATH;
  if ((seed !== undefined && (!/^\d{1,10}$/.test(seed) || Number(seed) > 0xffffffff)) ||
      (path !== undefined && (seed === undefined || path.length > 4096 || !/^\d+(?::\d+)*$/.test(path)))) {
    throw new Error("Invalid property replay configuration");
  }
  for (const requested of seed === undefined ? [4282447, 20261011, 12648430] : [Number(seed)]) {
    const result = await fc.check(property, { seed: requested, numRuns: 2000, ...(path === undefined ? {} : { path }) });
    if (result.failed) {
      // Keep shrinking/replay, but never print counterexample bodies or payload exceptions.
      throw new Error(`Relay framing property failed: seed=${result.seed}, path=${result.counterexamplePath}, runs=${result.numRuns}`);
    }
  }
}

test("seeded relay framing campaign preserves IDs, batch shape and encoded byte bounds", { timeout: 60000 }, async () => {
  await campaign(fc.property(groups, ({ batch, replies }) => {
    const bounded = boundReplyGroup(replies, batch);
    assert.equal(bounded.replies.length, replies.length);
    assert.deepEqual(bounded.replies.map(reply => reply.id), replies.map(reply => reply.id));
    assert.equal(bounded.stored, JSON.stringify(bounded.replies));
    const frame = batch ? bounded.replies : bounded.replies[0];
    assert.ok(bytes(frame) <= LIMITS.frameBytes);
    assert.ok(bounded.replies.every(reply => replySchema.safeParse(reply).success));
    if (bytes(batch ? replies : replies[0]) <= LIMITS.frameBytes) {
      assert.deepEqual(bounded.replies, replies);
    } else {
      assert.ok(bounded.replies.every(reply => "error" in reply && reply.error.code === -32004));
    }
  }));
});

test("partial durable groups stay bounded across arbitrary completion order and repeated reductions", { timeout: 60000 }, async () => {
  await campaign(fc.property(fc.array(reply, { minLength: 1, maxLength: 8 }), replies => {
    let accumulated: Reply[] = [];
    for (let index = 0; index < replies.length; index++) {
      const bounded = boundReplyGroup([...accumulated, replies[index]], true);
      // Model SQL serialization between replies (including hibernation), not an in-memory cache.
      accumulated = JSON.parse(bounded.stored) as Reply[];
      assert.ok(bytes(accumulated) <= LIMITS.frameBytes);
      assert.equal(accumulated.length, index + 1);
      assert.deepEqual(accumulated.map(reply => reply.id), JSON.parse(JSON.stringify(replies.slice(0, index + 1).map(reply => reply.id))));
      assert.ok(accumulated.every(reply => replySchema.safeParse(reply).success));
      for (const previous of bounded.replies) {
        if ("error" in previous) assert.equal(previous.error.code, -32004);
      }
    }
  }));
});
