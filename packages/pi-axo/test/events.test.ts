import assert from "node:assert/strict";
import test from "node:test";
import { EVENT_DATA_BUDGET_BYTES, fitMessage, messageEvent, ProgressThrottle, toolEvent, turnEndEvent } from "../src/events.js";

const size = (value: unknown) => Buffer.byteLength(JSON.stringify(value), "utf8");

test("a message that fits goes out unchanged, without signatures", () => {
  const message = {
    role: "assistant",
    content: [
      { type: "thinking", thinking: "Plan", thinkingSignature: "x".repeat(10_000) },
      { type: "text", text: "Done." },
    ],
  };
  assert.deepEqual(fitMessage(message), {
    role: "assistant",
    content: [{ type: "thinking", thinking: "Plan" }, { type: "text", text: "Done." }],
  });
});

test("a message too large for the wire is cut to fit and says so", () => {
  const output = "line\n".repeat(40_000);
  const event = messageEvent({
    type: "message_end",
    message: { role: "toolResult", toolCallId: "call-1", content: [{ type: "text", text: output }], isError: false },
  }) as { message: { content: Array<{ text: string }>; truncated?: boolean; toolCallId: string } };
  assert.ok(size(event) <= EVENT_DATA_BUDGET_BYTES, `${size(event)} bytes`);
  assert.equal(event.message.truncated, true);
  assert.equal(event.message.toolCallId, "call-1");
  assert.ok(event.message.content[0]!.text.startsWith("line\nline\n"));
});

test("tool events keep their identity and are cut to fit", () => {
  const event = toolEvent({
    toolCallId: "call-2",
    toolName: "write",
    args: { path: "/tmp/a", content: "y".repeat(200_000) },
  }) as { toolCallId: string; toolName: string; truncated?: boolean; args: { path: string } };
  assert.ok(size(event) <= EVENT_DATA_BUDGET_BYTES);
  assert.equal(event.toolCallId, "call-2");
  assert.equal(event.args.path, "/tmp/a");
  assert.equal(event.truncated, true);
});

test("a turn's end carries its facts, not its messages again", () => {
  assert.deepEqual(
    turnEndEvent({ turnIndex: 3, messageEntryId: "m", toolResultEntryIds: ["t"], outcome: "completed", message: { huge: true } } as never),
    { turnIndex: 3, messageEntryId: "m", toolResultEntryIds: ["t"], outcome: "completed" },
  );
});

test("progress goes out at once, then at most once per interval with the latest, and stops when finished", async () => {
  const sent: Array<[string, unknown]> = [];
  const throttle = new ProgressThrottle((name, data) => sent.push([name, data]), 40);
  throttle.offer("message.update", "message", 1);
  throttle.offer("message.update", "message", 2);
  throttle.offer("message.update", "message", 3);
  assert.deepEqual(sent, [["message.update", 1]]);
  await new Promise(resolve => setTimeout(resolve, 60));
  assert.deepEqual(sent, [["message.update", 1], ["message.update", 3]]);

  throttle.offer("message.update", "message", 4);
  throttle.finish("message.update", "message");
  await new Promise(resolve => setTimeout(resolve, 60));
  assert.deepEqual(sent, [["message.update", 1], ["message.update", 3]], "nothing after the message ended");

  // Each tool has its own pace.
  throttle.offer("tool.update", "a", "a1");
  throttle.offer("tool.update", "b", "b1");
  assert.deepEqual(sent.slice(2), [["tool.update", "a1"], ["tool.update", "b1"]]);
  throttle.finishAll();
});
