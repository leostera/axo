import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { ConversationMessage } from "../shared/protocol";

/** A bounded phone projection; Pi remains authoritative for the full history. */
export function projectMessages(entries: SessionEntry[]): ConversationMessage[] {
  const result: ConversationMessage[] = [];
  // Leave room for worst-case JSON escaping, envelope fields, and a question.
  let remaining = 28_000;
  for (const entry of [...entries].reverse()) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = typeof message.content === "string" ? message.content : message.content
      .filter(block => block.type === "text").map(block => block.text).join("\n");
    if (!text) continue;
    const visible = text.slice(0, Math.min(24_000, remaining));
    result.unshift({ id: entry.id, role: message.role, text: visible === text ? text : `${visible.slice(0, -20)}\n[truncated on phone]` });
    remaining -= visible.length;
    if (result.length >= 80 || remaining <= 0) break;
  }
  return result;
}

export function submittedCommandIds(entries: SessionEntry[]): Set<string> {
  const ids = new Set<string>();
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== "axo.submitted") continue;
    const data = entry.data;
    if (data && typeof data === "object" && "id" in data && typeof data.id === "string") ids.add(data.id);
  }
  return ids;
}
