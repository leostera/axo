import assert from "node:assert/strict";
import test from "node:test";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { ControlFailure } from "../control-protocol.ts";
import { encodeHistoryReply } from "../history-reply.ts";

const entry: SessionEntry = { type: "model_change", id: "owned", parentId: null, timestamp: "now", provider: "fixture", modelId: "fixture" };
const capacity = (error: unknown) => error instanceof ControlFailure && error.code === "capacity";
test("history encoding preserves public documents and permits shared branch references", () => {
  const history = { leafId: "owned", entries: [entry], branch: [entry] };
  assert.deepEqual(JSON.parse(encodeHistoryReply("request", history)), { reply: { id: "request", response: { history } } });
});
test("oversized strings and UTF-8/escaping expansion are capacity, not recovery", () => {
  for (const modelId of ["x".repeat(3 * 1024 * 1024 + 1), "\u0001".repeat(700_000), "🦊".repeat(900_000)]) {
    const document: SessionEntry = { ...entry, modelId };
    assert.throws(() => encodeHistoryReply("request", { leafId: "owned", entries: [document], branch: [] }), capacity);
  }
});
test("node and depth budgets bound encoding before transport", () => {
  assert.throws(() => encodeHistoryReply("request", { leafId: "owned", entries: Array.from({ length: 10_000 }, () => entry), branch: [] }), capacity);
  let nested: unknown = null;
  for (let depth = 0; depth < 70; depth++) nested = { next: nested };
  const document: SessionEntry = { type: "custom", id: "deep", parentId: null, timestamp: "now", customType: "fixture", data: nested };
  assert.throws(() => encodeHistoryReply("request", { leafId: "deep", entries: [document], branch: [] }), capacity);
});
