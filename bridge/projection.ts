import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ConversationMessage } from "../shared/protocol";

/** Project durable transcript blocks, not the ephemeral diagnostic event stream. */
export function projectMessages(entries: SessionEntry[], streaming?: AssistantMessage): ConversationMessage[] {
  // Pi persists finalized messages only. Overlay the streaming message until it is saved.
  const hasStreamingMessage = streaming && entries.some(entry => entry.type === "message"
    && entry.message.role === "assistant" && entry.message.timestamp === streaming.timestamp);
  const transcript: SessionEntry[] = streaming && !hasStreamingMessage ? [...entries, {
    type: "message", id: `stream-${streaming.timestamp}`, parentId: null,
    timestamp: new Date(streaming.timestamp).toISOString(), message: streaming,
  }] : entries;
  const blocks: ConversationMessage[] = [];
  const tools = new Map<string, ConversationMessage>();
  for (const entry of transcript) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role === "user") {
      blocks.push({ id: entry.id, role: "user", text: textContent(message.content) });
    } else if (message.role === "assistant") {
      const toolBlocks: ConversationMessage[] = [];
      message.content.forEach((block, index) => {
        const id = `assistant-${message.timestamp}:${index}`;
        switch (block.type) {
          case "text":
            if (block.text) blocks.push({ id, role: "assistant", text: block.text });
            break;
          case "thinking":
            // Like Pi, group adjacent thinking blocks; never serialize reasoning or signatures.
            if (index === 0 || message.content[index - 1]?.type !== "thinking") {
              blocks.push({ id, role: "thinking", text: message.stopReason === "pending"
                ? "Pi is thinking…" : "Thinking block · content not shared" });
            }
            break;
          case "toolCall": {
            const tool: ConversationMessage = {
              id: block.id, role: "tool", toolName: block.name, toolCallId: block.id,
              text: JSON.stringify(block.arguments).slice(0, 1_000),
              status: message.stopReason === "aborted" || message.stopReason === "error" ? "failed" : "running",
              ...(message.stopReason === "aborted" || message.stopReason === "error"
                ? { output: message.errorMessage ?? "Operation aborted" } : {}),
            };
            toolBlocks.push(tool);
            tools.set(block.id, tool);
            break;
          }
        }
      });
      // Pi renders assistant text/thinking first, then creates the tool execution rows.
      blocks.push(...toolBlocks);
      const errorText = message.stopReason === "length" ? "Response was truncated before completion."
        : toolBlocks.length === 0 && message.stopReason === "aborted" ? message.errorMessage ?? "Operation aborted"
        : toolBlocks.length === 0 && message.stopReason === "error" ? `Error: ${message.errorMessage ?? "Unknown error"}`
        : undefined;
      if (errorText) blocks.push({ id: `assistant-${message.timestamp}:error`, role: "assistant", text: errorText, status: "failed" });
    } else if (message.role === "toolResult") {
      const tool = tools.get(message.toolCallId);
      const output = textContent(message.content).slice(0, 3_000);
      const status = message.isError ? "failed" : "completed";
      if (tool) {
        tool.status = status;
        tool.output = output;
      } else {
        blocks.push({ id: message.toolCallId, role: "tool", text: "", toolName: message.toolName,
          toolCallId: message.toolCallId, status, output });
      }
    }
  }
  return boundTranscript(blocks);
}

function textContent(content: string | { type: string; text?: string }[]): string {
  if (typeof content === "string") return content;
  return content.filter(block => block.type === "text").map(block => block.text ?? "").join("\n");
}

function boundTranscript(blocks: ConversationMessage[]): ConversationMessage[] {
  const result: ConversationMessage[] = [];
  // Shared budget includes tool output and leaves room for JSON escaping and event batches.
  let remaining = 28_000;
  for (const block of blocks.reverse()) {
    if (!block.text && block.role !== "tool") continue;
    const text = block.text.slice(0, Math.min(24_000, remaining));
    remaining -= text.length;
    const output = block.output?.slice(0, remaining);
    remaining -= output?.length ?? 0;
    result.unshift({ ...block, text, ...(output !== undefined ? { output } : {}) });
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
