import assert from "node:assert/strict";
import test from "node:test";
import type { AssistantMessageEvent } from "@earendil-works/pi-ai";
import { AssistantStream, MirrorTurn, type MirrorSource } from "../src/remote-mirror.js";

type Json = Record<string, unknown>;

/** A copy that grows as the test says, with the progress of the message being written. */
class Copy implements MirrorSource {
  entries: Json[] = [];
  live: Json | null = null;
  tools = new Map<string, Json>();
  private waiters: Array<() => void> = [];
  get length() { return this.entries.length; }
  entry(index: number) { return this.entries[index] ?? null; }
  liveMessage() { return this.live; }
  toolProgress(id: string) { return this.tools.get(id) ?? null; }
  changed(ms: number, signal?: AbortSignal) {
    return new Promise<void>(resolve => {
      const timer = setTimeout(resolve, ms);
      signal?.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
      this.waiters.push(() => { clearTimeout(timer); resolve(); });
    });
  }
  add(message: Json) {
    this.entries.push({ type: "message", id: `e${this.entries.length}`, message });
    this.wake();
  }
  wake() {
    const waiters = this.waiters;
    this.waiters = [];
    for (const wake of waiters) wake();
  }
}

const usage = { input: 1, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 3, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.5 } };
const reply = (content: Json[], stopReason: string, timestamp = 1) => ({ role: "assistant", content, stopReason, usage, api: "x", provider: "y", model: "z", timestamp });
const model = { api: "axo-remote-mirror", provider: "axo-remote", id: "Mac Studio" };

function sink() {
  const events: AssistantMessageEvent[] = [];
  return { events, push: (event: AssistantMessageEvent) => events.push(event) };
}

test("a turn's assistant messages come in order, past its tool results and receipts", async () => {
  const copy = new Copy();
  copy.add({ role: "user", content: [{ type: "text", text: "go" }] });
  const turn = new MirrorTurn(copy, 0);
  copy.add(reply([{ type: "toolCall", id: "c1", name: "bash", arguments: { command: "ls" } }], "toolUse"));
  copy.add({ role: "toolResult", toolCallId: "c1", toolName: "bash", content: [{ type: "text", text: "a b" }], isError: false });
  copy.entries.push({ type: "custom", customType: "axo.command", data: { commandId: "x" } });
  copy.add(reply([{ type: "text", text: "done" }], "stop", 2));
  const first = await turn.step(undefined, () => {});
  const second = await turn.step(undefined, () => {});
  assert.equal(first.kind === "assistant" && first.message.stopReason, "toolUse");
  assert.equal(second.kind === "assistant" && second.message.stopReason, "stop");
  assert.deepEqual(await turn.toolResult("c1", undefined, () => {}), { content: [{ type: "text", text: "a b" }], details: {}, isError: false });
});

test("a turn follows the message being written, then ends with the record", async () => {
  const copy = new Copy();
  copy.add({ role: "user", content: "go" });
  const turn = new MirrorTurn(copy, 0);
  const seen: string[] = [];
  const step = turn.step(undefined, live => seen.push(((live.content as Json[])[0]!.text as string)));
  copy.live = reply([{ type: "text", text: "Wor" }], "stop");
  copy.wake();
  await new Promise(resolve => setTimeout(resolve, 5));
  copy.live = reply([{ type: "text", text: "Working" }], "stop");
  copy.wake();
  await new Promise(resolve => setTimeout(resolve, 5));
  copy.add(reply([{ type: "text", text: "Working on it" }], "stop"));
  const result = await step;
  assert.deepEqual(seen, ["Wor", "Working"]);
  assert.equal(result.kind, "assistant");
});

test("another user message mid-turn, a stop here, or giving up ends the wait", async () => {
  const copy = new Copy();
  copy.add({ role: "user", content: "go" });
  copy.add({ role: "user", content: "actually, wait" });
  assert.deepEqual(await new MirrorTurn(copy, 0).step(undefined, () => {}), { kind: "desync" });

  const quiet = new Copy();
  quiet.add({ role: "user", content: "go" });
  const stop = new AbortController();
  const waiting = new MirrorTurn(quiet, 0).step(stop.signal, () => {});
  stop.abort();
  assert.deepEqual(await waiting, { kind: "stopped" });

  const turn = new MirrorTurn(quiet, 0);
  const tool = turn.toolResult("c1", undefined, () => {});
  turn.giveUp();
  quiet.wake();
  assert.equal(await tool, null);
});

test("a tool's progress there shows here until its result lands", async () => {
  const copy = new Copy();
  copy.add({ role: "user", content: "go" });
  const turn = new MirrorTurn(copy, 0);
  const partials: unknown[] = [];
  const result = turn.toolResult("c1", undefined, partial => partials.push(partial));
  copy.tools.set("c1", { toolCallId: "c1", partialResult: { content: [{ type: "text", text: "building…" }] } });
  copy.wake();
  await new Promise(resolve => setTimeout(resolve, 5));
  copy.add({ role: "toolResult", toolCallId: "c1", content: [{ type: "text", text: "built" }], isError: true });
  assert.equal((await result)?.isError, true);
  assert.deepEqual(partials[0], { content: [{ type: "text", text: "building…" }] });
});

test("a streamed message has balanced events and ends as the other Mac wrote it", () => {
  const { events, push } = sink();
  const stream = new AssistantStream({ push }, model);
  stream.follow(reply([{ type: "thinking", thinking: "Hmm" }], "stop"));
  stream.follow(reply([{ type: "thinking", thinking: "Hmm, ok" }, { type: "text", text: "Let" }], "stop"));
  stream.follow(reply([{ type: "text", text: "unrelated" }], "stop"));
  const record = reply([
    { type: "thinking", thinking: "Hmm, ok." },
    { type: "text", text: "Let me look." },
    { type: "toolCall", id: "c1", name: "bash", arguments: { command: "ls" } },
  ], "toolUse");
  stream.finish(record);
  assert.deepEqual(events.map(event => event.type), [
    "start",
    "thinking_start", "thinking_delta", "thinking_delta", "text_start", "text_delta",
    "thinking_delta", "thinking_end", "text_delta", "text_end", "toolcall_start", "toolcall_end",
    "done",
  ]);
  const done = events.at(-1)!;
  assert.equal(done.type === "done" && done.reason, "toolUse");
  assert.deepEqual(done.type === "done" && done.message.content, record.content);
  assert.deepEqual(done.type === "done" && [done.message.usage, done.message.provider, done.message.model], [usage, "axo-remote", "Mac Studio"]);
});

test("a stopped or failed message ends in error, once", () => {
  const { events, push } = sink();
  const stream = new AssistantStream({ push }, model);
  stream.finish(reply([{ type: "text", text: "partial" }], "aborted"));
  stream.stop("too late");
  assert.deepEqual(events.map(event => event.type), ["start", "text_start", "text_delta", "text_end", "error"]);

  const stopped = sink();
  new AssistantStream({ push: stopped.push }, model).stop("Stopped on Mac Studio");
  const last = stopped.events.at(-1)!;
  assert.equal(last.type === "error" && last.error.errorMessage, "Stopped on Mac Studio");
});
