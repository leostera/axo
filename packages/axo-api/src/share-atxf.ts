/**
 * A shared conversation as an ATXF v0.1 transcript (https://atxf.leostera.dev), so a share can be
 * downloaded and read by any tool that speaks the format.
 *
 * The snapshot is a redacted, linear view of one Pi branch, and the transcript says no more than
 * that: its fidelity declares a linear topology with no instructions, tool definitions or
 * reasoning, and ids made up from the snapshot's. Nothing the snapshot left out is invented.
 *
 * One Pi assistant entry became several snapshot messages, `<entry>#0`, `<entry>#1`, … (text and
 * tool calls in order; see packages/pi-axo/src/share.ts). They are joined back into one assistant
 * message, and each call's result follows it as a `tool` message, as ATXF requires.
 */
import type { SharedSnapshot } from "./share.ts";

type Message = SharedSnapshot["messages"][number];
type SharedTool = NonNullable<Message["tool"]>;
type Json = Record<string, unknown>;

/** The suggested extension (ATXF §2), and the media type the download is served with. */
export const ATXF_EXTENSION = ".atxf.jsonl";
export const ATXF_MEDIA_TYPE = "application/jsonl; charset=utf-8";

const iso = (milliseconds: number | null, fallback: string) =>
  milliseconds === null ? fallback : new Date(milliseconds).toISOString();

/** The Pi entry a snapshot message came from: everything before `#<piece>`. */
const entryOf = (id: string) => {
  const at = id.lastIndexOf("#");
  return at > 0 ? id.slice(0, at) : id;
};

/** What the call was given, as far as the snapshot kept it. */
function callArguments(tool: SharedTool): Json {
  if (tool.command !== null) return { command: tool.command };
  if (tool.subtitle !== null) return { summary: tool.subtitle };
  return {};
}

/** Returns the transcript's records, the header first. */
export function shareToAtxfRecords(shareId: string, snapshot: SharedSnapshot): Json[] {
  const header: Json = {
    type: "transcript",
    atxf: "0.1",
    id: shareId,
    time: snapshot.publishedAt,
    title: snapshot.title,
    source: { agent: "pi" },
    fidelity: { topology: "linear", instructions: "none", tools: "none", reasoning: "none", usage: "none", native: "none", ids: "synthetic" },
    ext: { axo: { share: shareId, ...(snapshot.emoji ? { emoji: snapshot.emoji } : {}) } },
  };
  const records: Json[] = [header];
  const used = new Set<string>();
  const unique = (wanted: string) => {
    let id = wanted;
    for (let n = 2; used.has(id); n += 1) id = `${wanted}~${n}`;
    used.add(id);
    return id;
  };
  let parentId: string | null = null;
  const append = (record: Json) => {
    records.push({ ...record, parentId });
    parentId = record.id as string;
  };

  if (snapshot.model) {
    append({
      type: "settings",
      id: unique("settings"),
      time: snapshot.publishedAt,
      model: { provider: snapshot.model.provider, id: snapshot.model.id },
    });
  }

  const messages = snapshot.messages;
  for (let index = 0; index < messages.length;) {
    const message = messages[index]!;
    const time = iso(message.timestamp, snapshot.publishedAt);
    if (message.role === "user") {
      append({ type: "message", id: unique(message.id), time, role: "user", content: message.text });
      index += 1;
      continue;
    }

    // One assistant entry: its consecutive text and tool pieces.
    const entry = entryOf(message.id);
    const pieces: Message[] = [];
    while (index < messages.length && messages[index]!.role !== "user" && entryOf(messages[index]!.id) === entry) {
      pieces.push(messages[index]!);
      index += 1;
    }
    const calls: { id: string; tool: SharedTool; time: string }[] = [];
    const content = pieces.map((piece, at) => {
      if (!piece.tool) return { type: "text", text: piece.text };
      const id = unique(piece.tool.callId ?? `${entry}-call-${at}`);
      calls.push({ id, tool: piece.tool, time: iso(piece.timestamp, snapshot.publishedAt) });
      return { type: "tool_call", id, name: piece.tool.name, kind: "function", arguments: callArguments(piece.tool) };
    });
    append({
      type: "message",
      id: unique(entry),
      time,
      role: "assistant",
      content,
      ...(snapshot.model ? { model: { provider: snapshot.model.provider, id: snapshot.model.id } } : {}),
      ...(calls.length ? { stop: "tool_use" } : {}),
    });
    for (const call of calls) {
      // A call still running when the share was made has no result yet.
      if (call.tool.status === "running") continue;
      append({
        type: "message",
        id: unique(`${call.id}:result`),
        time: call.time,
        role: "tool",
        toolCallId: call.id,
        toolName: call.tool.name,
        content: call.tool.output,
        ...(call.tool.status === "failed" ? { isError: true } : {}),
        ...(call.tool.outputTruncated ? { ext: { axo: { outputTruncated: true } } } : {}),
      });
    }
  }
  return records;
}

/** The transcript as ATXF JSON Lines, one record a line. */
export function shareToAtxf(shareId: string, snapshot: SharedSnapshot): string {
  return shareToAtxfRecords(shareId, snapshot).map(record => JSON.stringify(record)).join("\n") + "\n";
}
