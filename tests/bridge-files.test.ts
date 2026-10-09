import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, readFile, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { stageFile, validateImage, shareCommandPath } from "../bridge/files";
import { attachmentFiles, projectMessages, projectHistory } from "../bridge/projection";
import { phoneFrameSchema } from "../shared/protocol";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";

const axoSessionId = "00000000-0000-4000-8000-000000000101";
const file = { id: "00000000-0000-4000-8000-000000000001", sessionId: "session", filename: "report.md", mediaType: "text/markdown" as const,
  byteLength: 12, sha256: "a".repeat(64), origin: "host" as const, createdAt: 0, state: "ready" as const };

test("explicit share commands decode Ghostty-style paths without running a shell", () => {
  assert.equal(shareCommandPath(String.raw`/tmp/Report\ with\ \$cash\ \(draft\).md`), "/tmp/Report with $cash (draft).md");
  assert.equal(shareCommandPath(`'/tmp/Bob'\\''s report.md'`), "/tmp/Bob's report.md");
  assert.equal(shareCommandPath('"/tmp/$(touch forbidden).md"'), "/tmp/$(touch forbidden).md");
  assert.throws(() => shareCommandPath("'unfinished"));
});

test("Mac publication stages an immutable private snapshot, not a path alias", async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-stage-test-"));
  try {
    const source = join(directory, "report.md");
    await writeFile(source, "original snapshot");
    const staged = await stageFile(source);
    try {
      await writeFile(source, "later edit");
      assert.equal(await readFile(staged.path, "utf8"), "original snapshot");
      assert.equal(staged.sha256, createHash("sha256").update("original snapshot").digest("hex"));
      assert.equal(staged.mediaType, "text/markdown");
      assert.equal(staged.byteLength, 17);
    } finally { await staged.dispose(); }
    await mkdir(join(directory, "folder"));
    await assert.rejects(stageFile(join(directory, "folder")), /regular files/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test("attachment metadata follows durable Pi custom messages and branch projection", () => {
  const base = { parentId: null, timestamp: "2026-01-01T00:00:00Z" };
  const entry: SessionEntry = { ...base, type: "custom_message", id: "attachment-row", customType: "axo.attachments",
    content: [{ type: "text", text: "Model-facing input" }, { type: "image", mimeType: "image/png", data: "OPAQUE_BASE64" }],
    display: true, details: { commandId: "command", text: "Discuss the report", files: [file] } };
  const rows = projectMessages([entry]);
  assert.equal(rows[0].role, "user");
  assert.equal(rows[0].text, "Discuss the report");
  assert.equal(rows[0].attachments?.[0].id, file.id);
  assert.equal(rows[0].id, "attachment-row");
  assert.ok(!JSON.stringify(rows).includes("OPAQUE_BASE64"));
  assert.deepEqual(projectMessages(JSON.parse(JSON.stringify([entry]))), rows);
  assert.deepEqual(projectMessages([]), []);
  assert.deepEqual(attachmentFiles({ files: [{ ...file, filename: "../bad" }] }), []);
  assert.equal(projectMessages([{ ...entry, details: { text: "", files: [file] } }])[0].text, "");
});

test("attachment-only prompts are bounded and full history is only read through cursors", () => {
  assert.ok(phoneFrameSchema.safeParse({ type: "prompt", id: "c", sessionId: axoSessionId, text: "", attachmentIds: [file.id] }).success);
  assert.equal(phoneFrameSchema.safeParse({ type: "prompt", id: "c", sessionId: axoSessionId, text: "" }).success, false);
  assert.equal(phoneFrameSchema.safeParse({ type: "prompt", id: "c", sessionId: axoSessionId, text: "", attachmentIds: Array(9).fill(file.id) }).success, false);
  const entries: SessionEntry[] = Array.from({ length: 2000 }, (_, n) => ({ type: "message", id: `m-${n}`, parentId: null, timestamp: "now",
    message: { role: "user", content: `Message ${n}`, timestamp: n } }));
  const tail = projectHistory(entries);
  assert.equal(tail.messages.length, 20);
  assert.equal(tail.messages[0].id, "m-1980");
  const earlier = projectHistory(entries, undefined, "m-1980");
  assert.equal(earlier.messages[0].id, "m-1960");
  assert.equal(earlier.hasLaterMessages, true);
  const newer = projectHistory(entries, undefined, "m-1979", "after");
  assert.deepEqual(newer.messages, tail.messages);
  assert.equal(newer.hasLaterMessages, false);
});

test("attachment cards consume the recent rendered-block budget without downloading their bytes", () => {
  const files = Array.from({ length: 8 }, () => ({ ...file, id: crypto.randomUUID() }));
  const entries: SessionEntry[] = Array.from({ length: 10 }, (_, index) => ({ type: "custom_message", id: `attachment-${index}`, parentId: null,
    timestamp: "now", customType: "axo.attachments", content: "Discuss files", display: true, details: { text: "Discuss files", files } }));
  const page = projectHistory(entries);
  assert.equal(page.messages.length, 2);
  assert.equal(page.messages[0].id, "attachment-8");
  assert.equal(page.hasEarlierMessages, true);
});

test("model image input rejects mismatched types and decompression-sized dimensions", () => {
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGQsAAAAASUVORK5CYII=", "base64");
  validateImage(png, "image/png");
  assert.throws(() => validateImage(png, "image/jpeg"));
  const oversized = Buffer.from(png);
  oversized.writeUInt32BE(100_000, 16);
  oversized.writeUInt32BE(100_000, 20);
  assert.throws(() => validateImage(oversized, "image/png"), /megapixels/);
});
