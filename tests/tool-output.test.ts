import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { readToolOutput } from "../bridge/tool-output";
import { hostFrameSchema, parseFrame } from "../shared/protocol";

function result(text: string, details?: Record<string, string>, toolName = "bash"): SessionEntry[] {
  return [{ type: "message", id: "result", parentId: null, timestamp: "2026-01-01T00:00:00Z",
    message: { role: "toolResult", toolCallId: "call", toolName, timestamp: 1, isError: false,
      content: [{ type: "text", text }], details } }];
}
async function collect(entries: SessionEntry[]): Promise<string> {
  let output = "", offset: number | null = 0;
  while (offset !== null) {
    const page = await readToolOutput(entries, "call", offset);
    parseFrame(JSON.stringify({ type: "tool_output", id: "request", sessionId: "s", toolCallId: "call", offset, ...page }), hostFrameSchema);
    if (page.nextOffset !== null) assert.ok(page.nextOffset > offset);
    output += page.text;
    offset = page.nextOffset;
  }
  return output;
}

test("expanded output restores every character, including UTF-8 across page boundaries", async () => {
  const text = "hello 🚀 日本語\n".repeat(10_000) + "THE END";
  assert.equal(await collect(result(text)), text);
  await assert.rejects(readToolOutput(result(text), "other-call", 0));
  await assert.rejects(readToolOutput(result("short"), "call", 100));
});

test("bash expansion reads Pi's full spool file rather than the truncated result", async () => {
  const path = join(tmpdir(), `pi-bash-${crypto.randomUUID()}.log`);
  const text = "full command output\n".repeat(12_000);
  await writeFile(path, text);
  try {
    const entries = result("Only the final preview", { fullOutputPath: path });
    assert.equal(await collect(entries), text);
    const restored = JSON.parse(JSON.stringify(entries)) as SessionEntry[];
    assert.equal(await collect(restored), text);
  } finally { await rm(path); }
  await assert.rejects(readToolOutput(result("preview", { fullOutputPath: path }), "call", 0), /no longer available/);
});

test("output requests cannot read arbitrary paths or follow symlinks", async () => {
  await assert.rejects(readToolOutput(result("preview", { fullOutputPath: "/etc/passwd" }), "call", 0), /not a Pi bash/);
  const path = join(tmpdir(), `pi-bash-${crypto.randomUUID()}.log`);
  await symlink("/etc/passwd", path);
  try { await assert.rejects(readToolOutput(result("preview", { fullOutputPath: path }), "call", 0), /no longer available/); }
  finally { await rm(path); }
});

test("edit expansion returns the recorded diff without exposing result metadata", async () => {
  assert.equal(await collect(result("Edited file", { diff: "+ new\n- old", secret: "never send" }, "edit")), "+ new\n- old");
});
