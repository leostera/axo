import { open, realpath } from "node:fs/promises";
import { constants } from "node:fs";
import { basename, dirname } from "node:path";
import { tmpdir } from "node:os";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { toolResultText } from "./projection";

const CHUNK_BYTES = 12_000;
export interface OutputPage { text: string; nextOffset: number | null }

/** A read-only request names a recorded tool call, never an arbitrary host path. */
export async function readToolOutput(entries: SessionEntry[], toolCallId: string, offset: number): Promise<OutputPage> {
  const entry = entries.find(entry => entry.type === "message" && entry.message.role === "toolResult"
    && entry.message.toolCallId === toolCallId);
  if (!entry || entry.type !== "message" || entry.message.role !== "toolResult") {
    throw new Error("Tool output is not saved yet or is no longer on the active branch.");
  }
  const result = entry.message;
  const details = result.details;
  const fullOutputPath = result.toolName === "bash" && details && typeof details === "object"
    && "fullOutputPath" in details && typeof details.fullOutputPath === "string" ? details.fullOutputPath : undefined;
  if (!fullOutputPath) {
    const bytes = Buffer.from(toolResultText(result));
    if (offset > bytes.length) throw new Error("Output cursor is past the end.");
    return page(bytes.subarray(offset, offset + CHUNK_BYTES + 4), offset, bytes.length);
  }
  // Pi's bash spool files are the only filesystem resources exposed by this endpoint.
  if (!/^pi-bash-[a-zA-Z0-9-]+\.log$/.test(basename(fullOutputPath))
      || await realpath(dirname(fullOutputPath)) !== await realpath(tmpdir())) {
    throw new Error("Full output is not a Pi bash spool file.");
  }
  let file;
  try { file = await open(fullOutputPath, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch { throw new Error("Pi's full-output file is no longer available on the Mac."); }
  try {
    const stat = await file.stat();
    if (!stat.isFile() || offset > stat.size) throw new Error("Invalid output cursor or file.");
    const buffer = Buffer.alloc(CHUNK_BYTES + 4);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, offset);
    return page(buffer.subarray(0, bytesRead), offset, stat.size);
  } finally { await file.close(); }
}

function page(bytes: Buffer, offset: number, total: number): OutputPage {
  let end = Math.min(CHUNK_BYTES, bytes.length);
  // Keep a UTF-8 character intact at each page boundary.
  while (end > 0 && end < bytes.length && (bytes[end]! & 0xc0) === 0x80) end--;
  return { text: bytes.subarray(0, end).toString("utf8"), nextOffset: offset + end < total ? offset + end : null };
}
