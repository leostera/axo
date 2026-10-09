import { test } from "node:test";
import assert from "node:assert/strict";
import { receiveRelayFrame } from "../bridge/connection";

test("relay errors are control frames, never reflected as invalid commands", () => {
  const replies: unknown[] = [], statuses: string[] = [];
  receiveRelayFrame(JSON.stringify({ type: "error", message: "Run /reload in Pi" }), () => assert.fail("Not a command"), frame => replies.push(frame), message => statuses.push(message));
  assert.deepEqual(replies, []);
  assert.deepEqual(statuses, ["Run /reload in Pi"]);
});

test("command handler faults are not mislabeled as command validation failures", () => {
  const replies: { type: string; message?: string }[] = [];
  receiveRelayFrame('{"type":"sync"}', () => { throw new Error("Synthetic projection fault"); }, frame => replies.push(frame), () => {});
  assert.match(replies[0].message ?? "", /could not process/);
  assert.ok(!(replies[0].message ?? "").includes("Synthetic projection fault"));
});
