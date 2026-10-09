import { test } from "node:test";
import assert from "node:assert/strict";
import { hostFrameSchema, phoneFrameSchema, parseFrame, MAX_FRAME_BYTES } from "../shared/protocol";
import { projectHistory, projectMessages, submittedCommandIds } from "../bridge/projection";
import { presentTool } from "../bridge/tool-presentation";
import { SessionManager, type SessionEntry } from "@earendil-works/pi-coding-agent";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";

test("cancellation commands target a specific active run", () => {
  const command = { type: "cancel", id: "cancel-1", sessionId: "s1", runId: "run-1" };
  assert.deepEqual(phoneFrameSchema.parse(command), command);
  assert.throws(() => phoneFrameSchema.parse({ ...command, runId: undefined }));
  assert.deepEqual(hostFrameSchema.parse({ type: "ack", id: command.id, disposition: "cancelled" }), {
    type: "ack", id: command.id, disposition: "cancelled",
  });
});

test("phone commands require a destination and reject empty/oversized prompts", () => {
  const command = { type: "prompt", id: "c", sessionId: "s", text: "hello" };
  assert.deepEqual(phoneFrameSchema.parse(command), command);
  for (const change of [{ sessionId: undefined }, { text: " " }, { text: "x".repeat(16_001) }]) {
    assert.throws(() => phoneFrameSchema.parse({ ...command, ...change }));
  }
  assert.throws(() => parseFrame(" ".repeat(MAX_FRAME_BYTES + 1), phoneFrameSchema));
});

test("running snapshots carry bounded tool activity and accept older hosts", () => {
  const snapshot = {
    type: "snapshot", sessionId: "s1", viewId: "v", state: "running", messages: [], hasEarlierMessages: false, question: null,
    activities: [{ id: "tool-1", toolName: "bash", summary: "{ command: ls }", status: "running", output: "README.md" }],
    events: [{ id: "event-1", sequence: 1, timestamp: 1000, category: "tool", name: "tool_execution_start", summary: "bash started", detail: "{ command: ls }" }],
    droppedEvents: 0,
  };
  assert.deepEqual(hostFrameSchema.parse(snapshot), snapshot);
  const oldHost = hostFrameSchema.parse({ ...snapshot, activities: undefined, events: undefined, droppedEvents: undefined });
  assert.equal(oldHost.type, "snapshot");
  if (oldHost.type === "snapshot") {
    assert.equal(oldHost.activities, undefined);
    assert.equal(oldHost.events, undefined);
  }
  assert.throws(() => hostFrameSchema.parse({ ...snapshot, activities: Array(11).fill(snapshot.activities[0]) }));
  assert.throws(() => hostFrameSchema.parse({ ...snapshot, events: Array(51).fill(snapshot.events[0]) }));
  assert.throws(() => hostFrameSchema.parse({ ...snapshot, events: [{ ...snapshot.events[0], detail: "x".repeat(501) }] }));
  assert.throws(() => hostFrameSchema.parse({ ...snapshot, activities: [{ ...snapshot.activities[0], output: "x".repeat(301) }] }));
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
  assert.equal(messages.length, 20);
  assert.equal(messages[0].id, "80");
  assert.ok(!JSON.stringify(messages).includes("never send"));
});

const assistantFixture: AssistantMessage = {
  role: "assistant", api: "openai-completions", provider: "test", model: "test", timestamp: 100,
  stopReason: "toolUse", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  content: [
    { type: "thinking", thinking: "Synthetic provider display text.", thinkingSignature: "OPAQUE SIGNATURE" },
    { type: "thinking", thinking: "A second synthetic block." },
    { type: "text", text: "Checking now." },
    { type: "toolCall", id: "tool-ok", name: "bash", arguments: { command: "ls" } },
    { type: "toolCall", id: "tool-error", name: "read", arguments: { path: "missing" } },
  ],
};
function transcriptFixture(): SessionEntry[] {
  const base = { parentId: null, timestamp: "2026-01-01T00:00:00Z" };
  return [
    { ...base, type: "message", id: "u", message: { role: "user", content: "Check files", timestamp: 1 } },
    { ...base, type: "message", id: "a", message: assistantFixture },
    ...[false, true].map((isError): SessionEntry => ({ ...base, type: "message", id: isError ? "e" : "r",
      message: { role: "toolResult", toolCallId: isError ? "tool-error" : "tool-ok", toolName: isError ? "read" : "bash",
        timestamp: 200, isError, content: [{ type: "text", text: isError ? "File not found" : "README.md" }] } })),
  ];
}

test("transcript restores provider thinking text and correlated tool blocks from session history", () => {
  const projected = projectMessages(transcriptFixture());
  assert.deepEqual(projected.map(block => block.role), ["user", "thinking", "assistant", "tool", "tool"]);
  assert.equal(projected[3]?.status, "completed");
  assert.equal(projected[3]?.output, "README.md");
  assert.equal(projected[4]?.status, "failed");
  assert.equal(projected[4]?.output, "File not found");
  assert.equal(projected[1]?.text, "Synthetic provider display text.\n\nA second synthetic block.");
  assert.ok(!JSON.stringify(projected).includes("OPAQUE SIGNATURE"));
  assert.deepEqual(projectMessages(transcriptFixture()), projected); // Reconnect uses the same stable row IDs.
  hostFrameSchema.parse({ type: "snapshot", sessionId: "s", viewId: "v", state: "idle", messages: projected, hasEarlierMessages: false, question: null });
});

test("streaming blocks use the same IDs as persisted blocks and are not duplicated", () => {
  const entries = transcriptFixture();
  const partial = { ...assistantFixture, stopReason: "pending" as const };
  const streaming = projectMessages(entries.slice(0, 1), partial);
  assert.deepEqual(streaming.map(block => block.id), projectMessages(entries).map(block => block.id));
  assert.equal(streaming[1]?.text, "Synthetic provider display text.\n\nA second synthetic block.");
  assert.equal(streaming[3]?.status, "running");
  assert.deepEqual(projectMessages(entries, partial), projectMessages(entries));
});

test("empty streaming and redacted thinking blocks do not expose opaque data", () => {
  const empty = { ...assistantFixture, stopReason: "pending" as const, content: [
    { type: "thinking" as const, thinking: "", thinkingSignature: "OPAQUE SIGNATURE" },
  ] };
  assert.equal(projectMessages([], empty)[0]?.text, "Pi is thinking…");
  assert.deepEqual(projectMessages([], { ...empty, stopReason: "stop" }), []);
  const redacted = { ...empty, content: [{ ...empty.content[0]!, thinking: "REDACTED PAYLOAD", redacted: true }] };
  assert.deepEqual(projectMessages([], redacted), []);
  assert.deepEqual(projectMessages([], { ...redacted, stopReason: "stop" }), []);
});

test("public thinking runs stay distinct and empty/signature-only runs do not create blank rows", () => {
  const message: AssistantMessage = { ...assistantFixture, stopReason: "stop", content: [
    { type: "thinking", thinking: "## First public thought\n\n- A point", thinkingSignature: "OPAQUE" },
    { type: "text", text: "A response." },
    { type: "thinking", thinking: "**Second public thought**" },
    { type: "thinking", thinking: "SECRET", redacted: true },
  ] };
  const blocks = projectMessages([], message);
  assert.deepEqual(blocks.map(block => block.text), ["## First public thought\n\n- A point", "A response.", "**Second public thought**"]);
  assert.deepEqual(projectMessages([], { ...message, content: [
    { type: "thinking", thinking: "", thinkingSignature: "OPAQUE" },
    { type: "thinking", thinking: " \n\n " },
  ] }), []);
});

test("public Markdown thinking survives a real Pi JSONL close/reopen and history paging", async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-thinking-history-"));
  try {
    const session = SessionManager.create(directory, directory);
    session.appendMessage({ role: "user", content: "Synthetic question", timestamp: 1 });
    session.appendMessage({ ...assistantFixture, stopReason: "stop", content: [
      { type: "thinking", thinking: "## Public heading\n\nA **formatted** thought.", thinkingSignature: "OPAQUE" },
      { type: "text", text: "## Public response\n\n- Result" },
    ] });
    const before = projectHistory(session.getBranch());
    const reopened = SessionManager.open(session.getSessionFile()!);
    assert.deepEqual(projectHistory(reopened.getBranch()), before);
    assert.equal(before.messages.find(block => block.role === "thinking")?.text, "## Public heading\n\nA **formatted** thought.");
    assert.ok(!JSON.stringify(before).includes("OPAQUE"));
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("projection follows Pi's assistant/tool ordering and shows terminal response errors", () => {
  const content = [...assistantFixture.content, { type: "text" as const, text: "After call arguments." }];
  const blocks = projectMessages([], { ...assistantFixture, content });
  assert.deepEqual(blocks.map(block => block.role), ["thinking", "assistant", "assistant", "tool", "tool"]);
  assert.equal(blocks[3]?.id, "tool-ok");
  const failed = projectMessages([], { ...assistantFixture, content: [], stopReason: "error", errorMessage: "Provider unavailable" });
  assert.equal(failed[0]?.text, "Error: Provider unavailable");
  assert.equal(failed[0]?.status, "failed");
});

test("tool output shares the frame budget and aborted tool calls are failed", () => {
  const entries = transcriptFixture();
  const assistant = { ...assistantFixture, stopReason: "aborted" as const, errorMessage: "Operation aborted" };
  const aborted = projectMessages(entries.slice(0, 1), assistant);
  assert.equal(aborted[3]?.status, "failed");
  assert.equal(aborted[3]?.output, "Operation aborted");
  const manyEntries = Array.from({ length: 100 }, (_, index) => ({
    ...entries[2]!, id: `result-${index}`,
    message: { role: "toolResult" as const, toolCallId: `tool-${index}`, toolName: "bash", isError: false,
      timestamp: index, content: [{ type: "text" as const, text: "\\u0000".repeat(4_000) }] },
  })) as SessionEntry[];
  const bounded = projectMessages(manyEntries);
  assert.ok(bounded.reduce((size, block) => size + block.text.length + (block.output?.length ?? 0), 0) <= 28_000);
  const frame = { type: "snapshot", sessionId: "s", viewId: "v", state: "idle", messages: bounded, hasEarlierMessages: false, question: null };
  parseFrame(JSON.stringify(frame), hostFrameSchema);
});

test("history pages reconstruct the same tools after reconnect, without output consuming the transcript", () => {
  const entries: SessionEntry[] = [];
  const base = { parentId: null, timestamp: "2026-01-01T00:00:00Z" };
  for (let index = 0; index < 180; index++) {
    entries.push({ ...base, type: "message", id: `a-${index}`, message: { ...assistantFixture, timestamp: index,
      content: [{ type: "toolCall", id: `tool-${index}`, name: "bash", arguments: { command: "npm test" } }] } });
    entries.push({ ...base, type: "message", id: `r-${index}`, message: { role: "toolResult", toolName: "bash",
      toolCallId: `tool-${index}`, timestamp: index, isError: false, content: [{ type: "text", text: "x".repeat(20_000) }] } });
  }
  const latest = projectHistory(entries);
  assert.deepEqual(projectHistory(JSON.parse(JSON.stringify(entries))), latest);
  assert.equal(latest.hasEarlierMessages, true);
  let restored = latest.messages;
  let hasEarlier: boolean = latest.hasEarlierMessages;
  while (hasEarlier) {
    const page = projectHistory(entries, undefined, restored[0]!.id);
    assert.ok(page.messages.length > 0);
    restored = [...page.messages, ...restored];
    hasEarlier = page.hasEarlierMessages;
  }
  assert.equal(restored.length, 180);
  assert.equal(new Set(restored.map(message => message.id)).size, 180);
  assert.ok(restored.every(message => message.status === "completed" && message.output?.length === 500));
  assert.throws(() => projectHistory(entries, undefined, "other-branch"));
});

test("tools have shell, edit, file, and search presentations instead of raw JSON", () => {
  assert.deepEqual(presentTool("bash", { command: "npm test", timeout: 10 }), {
    text: "npm test", toolPresentation: { kind: "shell", title: "Bash", subtitle: "Timeout: 10s" },
  });
  const edit = presentTool("edit", { path: "a.swift", edits: [{ oldText: "before", newText: "after" }] });
  assert.equal(edit.toolPresentation?.kind, "edit");
  assert.equal(edit.toolPresentation?.subtitle, "a.swift");
  assert.equal(edit.text, "- before\n+ after");
  assert.equal(presentTool("read", { path: "a.swift", offset: 2, limit: 10 }).text, "From line 2 · 10 lines");
  assert.equal(presentTool("grep", { pattern: "TODO" }).toolPresentation?.kind, "search");
});

test("submitted command IDs are recovered independently of active branch", () => {
  const entries: SessionEntry[] = [{ type: "custom", id: "e", parentId: null, timestamp: "now", customType: "axo.submitted", data: { id: "command" } }];
  assert.deepEqual([...submittedCommandIds(entries)], ["command"]);
});
