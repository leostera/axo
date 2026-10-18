import type { Session } from "@axo/app";
import { useMemo } from "react";

export type PiConversationMessage = {
  key: string;
  role: "user" | "assistant";
  text: string;
  receivedAt: number;
};

export type PiEventSummary = {
  streamId: string;
  sequence: number;
  name: string;
  data: unknown;
  receivedAt: number;
};

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function visibleText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.flatMap((part: unknown) => {
    const block = record(part);
    if (block?.type === "text" && typeof block.text === "string") return [block.text];
    if (block?.type === "image") return ["[Image attachment]"];
    return [];
  }).join("\n").trim();
}

export function conversationMessageFromPiEvent(event: PiEventSummary): PiConversationMessage | null {
  if (event.name !== "message.end") return null;
  const message = record(record(event.data)?.message);
  if (!message) return null;
  const role = message.role;
  if (role !== "user" && role !== "assistant") return null;

  let text = visibleText(message.content);
  if (!text && role === "assistant" && Array.isArray(message.toolCalls)) {
    const names = message.toolCalls.flatMap((call: unknown) => {
      const toolCall = record(call);
      return typeof toolCall?.name === "string" ? [toolCall.name] : [];
    });
    if (names.length > 0) text = `Using ${names.join(", ")}`;
  }
  if (!text) return null;

  return {
    key: `${event.streamId}:${event.sequence}`,
    role,
    text,
    receivedAt: event.receivedAt,
  };
}

function statusLabel(status: Session["status"]): string {
  switch (status) {
    case "starting": return "Starting";
    case "ready": return "Ready";
    case "working": return "Working";
    case "needsAttention": return "Needs attention";
    case "unavailable": return "Disconnected";
    default: return "Agent";
  }
}

export function PiHistoryPane({
  session,
  messages,
  loading,
  loadingMore,
  hasMore,
  error,
  onLoadMore,
}: {
  session: Session;
  messages: PiConversationMessage[];
  loading: boolean;
  loadingMore: boolean;
  hasMore: boolean;
  error: string | null;
  onLoadMore: () => void;
}) {
  const orderedMessages = useMemo(
    () => [...messages].sort((left, right) => left.receivedAt - right.receivedAt),
    [messages],
  );
  const status = session.status;
  const label = statusLabel(status);

  return (
    <section className="agent-pane" aria-label="Pi conversation history">
      <header className="agent-pane-toolbar">
        <span className="agent-session-emoji" aria-hidden="true">{session.emoji ?? "✦"}</span>
        <span className="agent-session-title">{session.name ?? `Session ${session.sessionId}`}</span>
        <span className={`agent-status agent-status-${status ?? "unknown"}`} title={`Agent ${label.toLowerCase()}`}>
          <span className="agent-status-dot" />{label}
        </span>
        <span className="agent-read-only">Read only</span>
      </header>
      <div className="agent-history" aria-live="polite">
        {hasMore ? (
          <button className="history-load-more" onClick={onLoadMore} disabled={loadingMore}>
            {loadingMore ? "Loading history…" : "Load earlier history"}
          </button>
        ) : null}
        {error ? <p className="history-error" role="alert">{error}</p> : null}
        {loading && orderedMessages.length === 0 ? <p className="history-empty">Loading private Pi history…</p> : null}
        {orderedMessages.map(message => (
          <article className={`conversation-message conversation-message-${message.role}`} key={message.key}>
            <span className="conversation-role">{message.role === "user" ? "You" : "Pi"}</span>
            <p>{message.text}</p>
          </article>
        ))}
        {!loading && orderedMessages.length === 0 && !error ? (
          <p className="history-empty">Structured conversation history will appear here after Pi has a turn.</p>
        ) : null}
      </div>
      {status === "needsAttention" ? (
        <div className="agent-attention-note">Pi is waiting for input. Continue in Axo on the Mac.</div>
      ) : null}
    </section>
  );
}
