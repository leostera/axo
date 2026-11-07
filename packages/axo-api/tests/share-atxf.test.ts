import assert from "node:assert/strict";
import { test } from "node:test";
import { parseTranscript, validateTranscript } from "@leostera/atxf";
import { sharedSnapshotSchema, type SharedSnapshot } from "../src/share.ts";
import { shareToAtxf } from "../src/share-atxf.ts";

const shareId = "fuVgs7XzUJNX7wpVhCTqWg";

const tool = (callId: string | null, command: string, output: string, status: "completed" | "failed" | "running" = "completed") => ({
  callId, name: "bash", kind: "shell" as const, subtitle: null, command, status, output, outputTruncated: false,
});

// As packages/pi-axo/src/share.ts builds it: one assistant entry split into `#<piece>` messages.
const snapshot: SharedSnapshot = sharedSnapshotSchema.parse({
  version: 1,
  title: "riot: zcaml toolchain",
  emoji: "🐫",
  model: { provider: "anthropic", id: "claude-opus-4-5", name: "Claude Opus 4.5" },
  publishedAt: "2026-11-06T23:14:19.610Z",
  messages: [
    { id: "u1", role: "user", text: "could you explore [redacted:internal-resource-identifier]?", timestamp: 1_793_968_478_817, tool: null, images: [] },
    { id: "a1#0", role: "assistant", text: "Looking.", timestamp: 1_793_968_478_848, tool: null, images: [] },
    { id: "a1#1", role: "tool", text: "", timestamp: 1_793_968_478_848, tool: tool("toolu_1", "ls", "README.md"), images: [] },
    { id: "a1#2", role: "tool", text: "", timestamp: 1_793_968_478_848, tool: tool("toolu_2", "false", "", "failed"), images: [] },
    { id: "a2#0", role: "tool", text: "", timestamp: 1_793_968_479_000, tool: { ...tool(null, "cat big", "…"), outputTruncated: true }, images: [] },
    { id: "a2#1", role: "tool", text: "", timestamp: 1_793_968_479_000, tool: tool("toolu_4", "sleep 9", "", "running"), images: [] },
    { id: "a3#0", role: "assistant", text: "## Done\nIt **works**.", timestamp: 1_793_968_480_000, tool: null, images: [] },
  ],
});

test("a share downloads as a valid ATXF transcript", () => {
  const text = shareToAtxf(shareId, snapshot);
  const result = validateTranscript(text);
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.ok, true);
});

test("the transcript keeps the conversation's order, calls and results", () => {
  const { header, records } = parseTranscript(shareToAtxf(shareId, snapshot));
  assert.equal(header.id, shareId);
  assert.equal((header as { title?: string }).title, "riot: zcaml toolchain");
  assert.deepEqual(records.map(record => record.type === "message" ? `${record.role}:${record.id}` : record.type), [
    "settings", "user:u1", "assistant:a1", "tool:toolu_1:result", "tool:toolu_2:result",
    "assistant:a2", "tool:a2-call-0:result", "assistant:a3",
  ]);
  // Each record hangs off the one before it: the snapshot is one linear branch.
  records.forEach((record, index) => {
    if ("parentId" in record) assert.equal(record.parentId, index === 0 ? null : records[index - 1]!.id);
  });
  const first = records[2]!;
  assert.ok(first.type === "message" && first.role === "assistant");
  assert.deepEqual(first.content, [
    { type: "text", text: "Looking." },
    { type: "tool_call", id: "toolu_1", name: "bash", kind: "function", arguments: { command: "ls" } },
    { type: "tool_call", id: "toolu_2", name: "bash", kind: "function", arguments: { command: "false" } },
  ]);
  const failed = records[4]!;
  assert.ok(failed.type === "message" && failed.role === "tool");
  assert.equal(failed.isError, true);
  const truncated = records[6]!;
  assert.deepEqual(truncated.ext, { axo: { outputTruncated: true } });
});

test("a share published before emoji and model existed still converts", () => {
  const { emoji: _emoji, model: _model, ...old } = snapshot;
  const result = validateTranscript(shareToAtxf(shareId, old));
  assert.equal(result.ok, true);
  assert.equal(parseTranscript(shareToAtxf(shareId, old)).records[0]!.type, "message");
});
