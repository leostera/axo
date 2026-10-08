import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ConversationMessage } from "../shared/protocol";
import { presentTool } from "./tool-presentation";

/** Project durable transcript blocks, not the ephemeral diagnostic event stream. */
export function projectMessages(entries: SessionEntry[], streaming?: AssistantMessage): ConversationMessage[] {
  return projectHistory(entries, streaming).messages;
}

export function projectHistory(entries: SessionEntry[], streaming?: AssistantMessage, beforeId?: string): {
  messages: ConversationMessage[]; hasEarlierMessages: boolean;
} {
  const blocks = projectTranscript(entries, streaming);
  const end = beforeId === undefined ? blocks.length : blocks.findIndex(block => block.id === beforeId);
  if (end < 0) throw new Error("That history cursor is no longer on the active branch. Reconnect to refresh.");
  const messages = boundTranscript(blocks.slice(0, end));
  return { messages, hasEarlierMessages: messages.length < end };
}

function projectTranscript(entries: SessionEntry[], streaming?: AssistantMessage): ConversationMessage[] {
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
      const text = textContent(message.content);
      if (text) blocks.push({ id: entry.id, role: "user", text });
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
              ...presentTool(block.name, block.arguments),
              status: message.stopReason === "aborted" || message.stopReason === "error" ? "failed" : "running",
              ...(message.stopReason === "aborted" || message.stopReason === "error"
                ? { output: (message.errorMessage ?? "Operation aborted").slice(0, 500) } : {}),
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
      const fullOutput = toolResultText(message);
      const output = message.toolName === "bash" || message.toolName === "powershell"
        ? fullOutput.slice(-500) : fullOutput.slice(0, 500);
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
  return blocks;
}

export function toolResultText(message: { toolName: string; content: { type: string; text?: string }[]; details?: unknown; isError: boolean }): string {
  const details = message.details;
  if (message.toolName === "edit" && !message.isError && details && typeof details === "object"
      && "diff" in details && typeof details.diff === "string") return details.diff;
  return textContent(message.content);
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
    if (result.length > 0 && block.text.length + (block.output?.length ?? 0) > remaining) break;
    const text = block.text.slice(0, Math.min(24_000, remaining));
    remaining -= text.length;
    const output = block.output?.slice(0, remaining);
    remaining -= output?.length ?? 0;
    let bounded = { ...block, text, ...(output !== undefined ? { output } : {}) };
    // Count encoded bytes too: escapes and tool presentation metadata consume real frame space.
    if (result.length > 0 && Buffer.byteLength(JSON.stringify([bounded, ...result])) > 72_000) break;
    while (Buffer.byteLength(JSON.stringify(bounded)) > 72_000) {
      bounded = { ...bounded, text: bounded.text.slice(0, Math.floor(bounded.text.length / 2)) };
    }
    result.unshift(bounded);
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
