import test from "node:test";
import assert from "node:assert/strict";
import fc from "fast-check";
import {
  FRAGMENTS,
  LIMITS,
  MAX_FRAGMENTS,
  MemoryPartialStore,
  receiveFragment,
  splitMessage,
  type FragmentOutcome,
} from "@axo/protocol";

const paramsOf = (frame: string) => (JSON.parse(frame) as { params: Record<string, unknown> }).params;

function deliver(frames: string[], store = new MemoryPartialStore()): FragmentOutcome[] {
  return frames.map((frame) => receiveFragment(store, paramsOf(frame)));
}

function message(bytes: number, fill = "a"): string {
  const envelope = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { text: "" } });
  return JSON.stringify({ jsonrpc: "2.0", id: 1, result: { text: fill.repeat(Math.max(0, bytes - envelope.length)) } });
}

test("a message that fits in one frame is sent as it is", () => {
  const raw = message(LIMITS.frameBytes);
  assert.deepEqual(splitMessage(raw, "m1"), [raw]);
});

test("a larger message crosses in fragments that each fit a frame, and comes back whole", () => {
  const raw = message(LIMITS.frameBytes * 5 + 17);
  const frames = splitMessage(raw, "m1")!;
  assert.equal(frames.length, Math.ceil(new TextEncoder().encode(raw).byteLength / FRAGMENTS.chunkBytes));
  for (const frame of frames) assert.ok(new TextEncoder().encode(frame).byteLength <= LIMITS.frameBytes);
  const outcomes = deliver(frames);
  assert.deepEqual(outcomes.slice(0, -1).map((o) => o.status), frames.slice(0, -1).map(() => "partial"));
  assert.deepEqual(outcomes.at(-1), { status: "complete", raw });
});

test("characters cut across fragments are rejoined", () => {
  const raw = message(LIMITS.frameBytes * 2, "🦎");
  const outcomes = deliver([...splitMessage(raw, "m1")!].reverse());
  assert.deepEqual(outcomes.at(-1), { status: "complete", raw });
});

test("the largest message fits, and anything larger is refused before sending", () => {
  const largest = message(FRAGMENTS.messageBytes);
  const frames = splitMessage(largest, "m1")!;
  assert.ok(frames.length <= MAX_FRAGMENTS);
  assert.deepEqual(deliver(frames).at(-1), { status: "complete", raw: largest });
  assert.equal(splitMessage(message(FRAGMENTS.messageBytes + 1), "m2"), null);
});

test("two messages interleave on one socket", () => {
  const a = message(LIMITS.frameBytes * 2, "a");
  const b = message(LIMITS.frameBytes * 2, "b");
  const fa = splitMessage(a, "a")!;
  const fb = splitMessage(b, "b")!;
  const store = new MemoryPartialStore();
  const interleaved = fa.flatMap((frame, i) => [frame, fb[i]!]);
  const done = deliver(interleaved, store).filter((o) => o.status === "complete");
  assert.deepEqual(done.map((o) => (o as { raw: string }).raw).sort(), [a, b].sort());
  assert.equal(store.count(), 0);
});

test("a peer that breaks the rules is refused", () => {
  const frames = splitMessage(message(LIMITS.frameBytes * 2), "m1")!;
  const first = paramsOf(frames[0]!);
  const refuse = (params: unknown, store = new MemoryPartialStore()) => receiveFragment(store, params).status;

  assert.equal(refuse({ ...first, count: MAX_FRAGMENTS + 1 }), "invalid", "too many fragments");
  assert.equal(refuse({ ...first, index: frames.length, count: frames.length }), "invalid", "index past count");
  assert.equal(refuse({ ...first, data: "not base64!" }), "invalid", "bad data");
  assert.equal(refuse({ ...first, data: btoa("short") }), "invalid", "a middle fragment that is not a full chunk");

  const store = new MemoryPartialStore();
  assert.equal(refuse(first, store), "partial");
  assert.equal(refuse(first, store), "invalid", "a repeated fragment");

  const changed = new MemoryPartialStore();
  receiveFragment(changed, first);
  assert.equal(refuse({ ...paramsOf(frames[1]!), count: frames.length + 1 }, changed), "invalid", "a count that changes");

  const full = new MemoryPartialStore();
  for (let i = 0; i < FRAGMENTS.partialPerSocket; i++) receiveFragment(full, { ...first, messageId: `m${i}` });
  assert.equal(refuse({ ...first, messageId: "one-more" }, full), "invalid", "too many partial messages");
});

test("any message survives splitting, in any order of its fragments", () => {
  fc.assert(
    fc.property(
      fc.string({ unit: "grapheme", minLength: 200, maxLength: 3000 }),
      fc.integer({ min: 1, max: 40 }),
      fc.integer(),
      (text, repeat, seed) => {
        const raw = JSON.stringify({ jsonrpc: "2.0", id: "x", result: { text: text.repeat(repeat * 40) } });
        const frames = splitMessage(raw, "m");
        if (!frames) return new TextEncoder().encode(raw).byteLength > FRAGMENTS.messageBytes;
        if (frames.length === 1) return frames[0] === raw;
        const shuffled = [...frames].sort((x, y) => ((x.length * 31 + seed) % 7) - ((y.length * 17 + seed) % 7));
        const done = deliver(shuffled).filter((o) => o.status === "complete");
        return done.length === 1 && (done[0] as { raw: string }).raw === raw;
      },
    ),
    { numRuns: 60 },
  );
});

test("a dropped message's late fragments are ignored", () => {
  const frames = splitMessage(message(LIMITS.frameBytes * 2), "m1")!;
  const store = new MemoryPartialStore();
  assert.equal(receiveFragment(store, paramsOf(frames[0]!)).status, "partial");
  store.discard("m1");
  assert.equal(store.count(), 0);
  assert.deepEqual(frames.slice(1).map((frame) => receiveFragment(store, paramsOf(frame)).status), frames.slice(1).map(() => "ignored"));
});
