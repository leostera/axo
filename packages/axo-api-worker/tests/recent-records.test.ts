import assert from "node:assert/strict";
import test from "node:test";
import { SYNC } from "@axo/protocol";
import { RecentRecords } from "../src/host-clients";

/** `count` records of `chars` characters each, from cursor `from`. */
function records(from: number, count: number, chars: number) {
  return Array.from({ length: count }, (_, index) => ({
    cursor: from + index,
    id: `r${from + index}`,
    format: "pi/3" as const,
    hash: `sha256:${from + index}`,
    line: "x".repeat(chars),
  }));
}

test("the records a HostDO keeps for its clients stay inside one budget however many Sessions are busy", () => {
  const recent = new RecentRecords();
  // 64 Sessions each sending full batches: a per-Session cap alone would keep 64 MiB of lines.
  for (let session = 0; session < 64; session++) {
    const sessionId = `00000000-0000-4000-8000-${String(session).padStart(12, "0")}`;
    recent.add(sessionId, 1, records(1, 8, SYNC.clientBytes / 4));
    recent.add(sessionId, 1, records(9, 8, SYNC.clientBytes / 4));
  }
  assert.ok(recent.heldCharacters() <= RecentRecords.characters, `${recent.heldCharacters()} characters held`);
  assert.ok(RecentRecords.characters <= 16 * 1024 * 1024);
});

test("a Session just added is kept before ones written to longer ago", () => {
  const recent = new RecentRecords();
  const old = "00000000-0000-4000-8000-000000000001";
  const busy = "00000000-0000-4000-8000-000000000002";
  recent.add(old, 1, records(1, 2, 16));
  for (let round = 0; round < 40; round++)
    recent.add(`00000000-0000-4000-8000-1${String(round).padStart(11, "0")}`, 1, records(1, 4, SYNC.clientBytes / 4));
  recent.add(busy, 1, records(1, 2, 16));
  assert.equal(recent.after(old, 1, 0), null, "the oldest Session went first");
  assert.deepEqual(recent.after(busy, 1, 0)?.map((record) => record.cursor), [1, 2]);
});

test("records held for a Session are served after a cursor, and missing ones make the caller read", () => {
  const recent = new RecentRecords();
  const session = "00000000-0000-4000-8000-000000000003";
  recent.add(session, 2, records(5, 3, 10));
  assert.deepEqual(recent.after(session, 2, 5)?.map((record) => record.cursor), [6, 7]);
  assert.equal(recent.after(session, 2, 2), null, "records 3 and 4 are not held");
  assert.equal(recent.after(session, 1, 5), null, "another epoch");
  recent.add(session, 2, records(9, 1, 10));
  assert.equal(recent.after(session, 2, 5), null, "a gap started over from cursor 9");
  assert.deepEqual(recent.after(session, 2, 8)?.map((record) => record.cursor), [9]);
});
