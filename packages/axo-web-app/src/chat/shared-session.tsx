import { useEffect, useState } from "react";
import { parseMarkdown } from "./markdown.ts";
import { MessageView } from "./message-views.tsx";
import type { ChatMessage, ToolActivity, ToolKind, ToolStatus } from "./transcript.ts";

/**
 * A published conversation, as `/axo-share` writes it (packages/pi-axo/src/share.ts): already
 * redacted on the Mac. Markdown is parsed here, so the stored JSON stays plain text.
 */
interface SharedSessionSnapshot {
  readonly title: string;
  readonly publishedAt: string;
  readonly messages: readonly ChatMessage[];
}

const toolKinds = new Set<ToolKind>(["shell", "edit", "file", "search", "generic"]);
const toolStatuses = new Set<ToolStatus>(["running", "completed", "failed"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const optionalString = (value: unknown): value is string | null => value === null || typeof value === "string";

function parseTool(value: unknown): ToolActivity | null | undefined {
  if (value === null) return null;
  if (!isRecord(value) || typeof value.name !== "string" || !toolKinds.has(value.kind as ToolKind) ||
      !toolStatuses.has(value.status as ToolStatus) || typeof value.output !== "string" ||
      typeof value.outputTruncated !== "boolean" || !optionalString(value.callId) ||
      !optionalString(value.subtitle) || !optionalString(value.command)) return undefined;
  return {
    callId: value.callId, name: value.name, kind: value.kind as ToolKind, subtitle: value.subtitle,
    command: value.command, status: value.status as ToolStatus, output: value.output, outputTruncated: value.outputTruncated,
  };
}

function parseMessage(value: unknown): ChatMessage | null {
  if (!isRecord(value) || typeof value.id !== "string" || typeof value.text !== "string" ||
      !(value.timestamp === null || typeof value.timestamp === "number")) return null;
  // Shared snapshots carry no images; anything else is not a snapshot this viewer wrote.
  if (!Array.isArray(value.images) || value.images.length > 0) return null;
  const tool = parseTool(value.tool);
  if (tool === undefined) return null;
  switch (value.role) {
    case "user":
      return { id: value.id, role: "user", text: value.text, blocks: [], timestamp: value.timestamp, tool: null, images: [] };
    case "assistant":
      return { id: value.id, role: "assistant", text: value.text, blocks: parseMarkdown(value.text), timestamp: value.timestamp, tool: null, images: [] };
    case "tool":
      return tool ? { id: value.id, role: "tool", text: "", blocks: [], timestamp: value.timestamp, tool, images: [] } : null;
    default:
      return null;
  }
}

function parseSnapshot(value: unknown): SharedSessionSnapshot | null {
  if (!isRecord(value) || value.version !== 1 || typeof value.title !== "string" ||
      typeof value.publishedAt !== "string" || !Array.isArray(value.messages)) return null;
  const messages = value.messages.map(parseMessage);
  if (messages.some(message => message === null)) return null;
  return { title: value.title, publishedAt: value.publishedAt, messages: messages as ChatMessage[] };
}

/** Read-only renderer for a published snapshot. It never connects to the account or host APIs. */
export function SharedSession({ shareId }: { shareId: string }) {
  const [snapshot, setSnapshot] = useState<SharedSessionSnapshot | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let active = true;
    void fetch(`/api/public-sessions/${encodeURIComponent(shareId)}`, { headers: { Accept: "application/json" } })
      .then(async response => {
        if (!response.ok) throw new Error("Shared session not found");
        const parsed = parseSnapshot(await response.json());
        if (!parsed) throw new Error("Invalid shared session snapshot");
        if (active) setSnapshot(parsed);
      })
      .catch(() => { if (active) setFailed(true); });
    return () => { active = false; };
  }, [shareId]);

  useEffect(() => {
    if (snapshot) document.title = `${snapshot.title} · Axo`;
  }, [snapshot]);

  if (failed) return <main className="shared-session-state"><h1>This shared session isn’t available</h1><p>It may have been removed, or the link may be incorrect.</p></main>;
  if (!snapshot) return <main className="shared-session-state" aria-live="polite">Loading shared session…</main>;

  return (
    <main className="shared-session">
      <header className="shared-session-header">
        <a className="shared-session-brand" href="/">Axo</a>
        <h1>{snapshot.title}</h1>
        <p>Shared conversation · {new Date(snapshot.publishedAt).toLocaleDateString()} · sensitive details were redacted before publishing</p>
      </header>
      <section className="shared-session-transcript" aria-label="Shared conversation">
        {snapshot.messages.map(message => <MessageView key={message.id} message={message} working={false} />)}
      </section>
      <footer className="shared-session-footer">Published with Axo</footer>
    </main>
  );
}
