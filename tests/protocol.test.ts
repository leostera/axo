import { test } from "node:test";
import assert from "node:assert/strict";
import { hostFrameSchema, phoneFrameSchema, parseFrame, MAX_FRAME_BYTES } from "../shared/protocol";
import { projectMessages, submittedCommandIds } from "../bridge/projection";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

test("phone commands require a destination and reject empty/oversized prompts", () => {
  const command = { type: "prompt", id: "c", sessionId: "s", text: "hello" };
  assert.deepEqual(phoneFrameSchema.parse(command), command);
  for (const change of [{ sessionId: undefined }, { text: " " }, { text: "x".repeat(16_001) }]) {
    assert.throws(() => phoneFrameSchema.parse({ ...command, ...change }));
  }
  assert.throws(() => parseFrame(" ".repeat(MAX_FRAME_BYTES + 1), phoneFrameSchema));
});

test("roles cannot send each other's messages", () => {
  assert.throws(() => phoneFrameSchema.parse({ type: "snapshot" }));
  assert.throws(() => hostFrameSchema.parse({ type: "prompt", id: "c", sessionId: "s", text: "attack" }));
  assert.throws(() => phoneFrameSchema.parse({ type: "answer", id: "c", sessionId: "s", value: "yes" }));
});

test("projection is bounded and does not expose custom metadata", () => {
  const entries: SessionEntry[] = Array.from({ length: 100 }, (_, n) => ({
    type: "message", id: String(n), parentId: null, timestamp: new Date().toISOString(),
    message: { role: "user", content: "x".repeat(1000), timestamp: Date.now() },
  }));
  entries.push({ type: "custom", id: "secret", parentId: null, timestamp: "now", customType: "credential", data: { secret: "never send" } });
  const messages = projectMessages(entries);
  assert.equal(messages.length, 28);
  assert.equal(messages[0].id, "72");
  assert.ok(!JSON.stringify(messages).includes("never send"));
});

test("submitted command IDs are recovered independently of active branch", () => {
  const entries: SessionEntry[] = [{ type: "custom", id: "e", parentId: null, timestamp: "now", customType: "axo.submitted", data: { id: "command" } }];
  assert.deepEqual([...submittedCommandIds(entries)], ["command"]);
});
