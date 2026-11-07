import { memo, useEffect, useMemo, useState } from "react";
import { parseMarkdown, type MarkdownBlock } from "./markdown.ts";
import { Markdown, Redactable } from "./message-views.tsx";
import { Icon, type IconName } from "./icons.tsx";
import type { ToolActivity, ToolKind, ToolStatus } from "./transcript.ts";
import "./shared-session.css";

/**
 * A published conversation, as `/axo-share` writes it (packages/pi-axo/src/share.ts): already
 * redacted on the Mac. Markdown is parsed here, so the stored JSON stays plain text.
 */
interface SharedSessionSnapshot {
  readonly title: string;
  readonly emoji: string | null;
  readonly model: { readonly provider: string; readonly id: string; readonly name: string } | null;
  readonly publishedAt: string;
  readonly messages: readonly SharedMessage[];
}

type SharedMessage =
  | { readonly id: string; readonly role: "user"; readonly text: string; readonly timestamp: number | null }
  | { readonly id: string; readonly role: "assistant"; readonly text: string; readonly blocks: MarkdownBlock[]; readonly timestamp: number | null }
  | { readonly id: string; readonly role: "tool"; readonly tool: ToolActivity; readonly timestamp: number | null };

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

function parseMessage(value: unknown): SharedMessage | null {
  if (!isRecord(value) || typeof value.id !== "string" || typeof value.text !== "string" ||
      !(value.timestamp === null || typeof value.timestamp === "number")) return null;
  // Shared snapshots carry no images; anything else is not a snapshot this viewer wrote.
  if (!Array.isArray(value.images) || value.images.length > 0) return null;
  const tool = parseTool(value.tool);
  if (tool === undefined) return null;
  const { id, text, timestamp } = value;
  switch (value.role) {
    case "user": return { id, role: "user", text, timestamp };
    case "assistant": return { id, role: "assistant", text, blocks: parseMarkdown(text), timestamp };
    case "tool": return tool ? { id, role: "tool", tool, timestamp } : null;
    default: return null;
  }
}

function parseModel(value: unknown): SharedSessionSnapshot["model"] | undefined {
  if (value === undefined) return null;
  if (!isRecord(value) || typeof value.provider !== "string" || typeof value.id !== "string" || typeof value.name !== "string") return undefined;
  return { provider: value.provider, id: value.id, name: value.name };
}

export function parseSnapshot(value: unknown): SharedSessionSnapshot | null {
  if (!isRecord(value) || value.version !== 1 || typeof value.title !== "string" ||
      typeof value.publishedAt !== "string" || !Array.isArray(value.messages) ||
      !(value.emoji === undefined || typeof value.emoji === "string")) return null;
  const model = parseModel(value.model);
  if (model === undefined) return null;
  const messages = value.messages.map(parseMessage);
  if (messages.some(message => message === null)) return null;
  return {
    title: value.title,
    emoji: (value.emoji as string | undefined) ?? emojiFromTitleTool(messages as SharedMessage[]),
    model,
    publishedAt: value.publishedAt,
    messages: messages as SharedMessage[],
  };
}

/** The title tool's own bookkeeping: drawn as the header, not as a step. */
const TITLE_TOOL = "axo_set_title";

/** Shares from before the emoji was published: the title tool said it ("Session named 🐫 …"). */
function emojiFromTitleTool(messages: readonly SharedMessage[]): string | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]!;
    if (message.role !== "tool" || message.tool.name !== TITLE_TOOL) continue;
    const emoji = /^Session (?:named|renamed to) (\S+) /u.exec(message.tool.output)?.[1];
    if (emoji && /\p{Extended_Pictographic}/u.test(emoji)) return emoji;
  }
  return null;
}

/** The snapshot the Worker inlined into the page (sites/axo.leostera.dev/src/share-page.ts). */
function inlinedSnapshot(shareId: string): SharedSessionSnapshot | null {
  const element = typeof document === "undefined" ? null : document.getElementById("axo-share-snapshot");
  if (!element?.textContent) return null;
  try {
    const inlined = JSON.parse(element.textContent) as { shareId?: unknown; snapshot?: unknown };
    return inlined.shareId === shareId ? parseSnapshot(inlined.snapshot) : null;
  } catch {
    return null;
  }
}

// ---- the conversation, as turns ----

type Turn =
  | { kind: "user"; key: string; text: string; timestamp: number | null }
  | { kind: "assistant"; key: string; blocks: MarkdownBlock[]; timestamp: number | null }
  | { kind: "steps"; key: string; tools: { key: string; tool: ToolActivity }[] };

function turnsOf(messages: readonly SharedMessage[]): Turn[] {
  const turns: Turn[] = [];
  for (const message of messages) {
    if (message.role === "tool") {
      if (message.tool.name === TITLE_TOOL) continue;
      const last = turns[turns.length - 1];
      const step = { key: message.id, tool: message.tool };
      if (last?.kind === "steps") last.tools.push(step);
      else turns.push({ kind: "steps", key: message.id, tools: [step] });
    } else if (message.role === "user") {
      turns.push({ kind: "user", key: message.id, text: message.text, timestamp: message.timestamp });
    } else {
      turns.push({ kind: "assistant", key: message.id, blocks: message.blocks, timestamp: message.timestamp });
    }
  }
  return turns;
}

const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });
const timeFormat = new Intl.DateTimeFormat(undefined, { timeStyle: "short" });
const fullFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "short" });

function duration(milliseconds: number): string | null {
  const minutes = Math.round(milliseconds / 60_000);
  if (minutes < 1) return null;
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return minutes % 60 ? `${hours} h ${minutes % 60} min` : `${hours} h`;
}

const plural = (count: number, one: string, many = `${one}s`) => `${count.toLocaleString()} ${count === 1 ? one : many}`;

function Time({ at }: { at: number | null }) {
  if (at === null) return null;
  const date = new Date(at);
  return <time dateTime={date.toISOString()} title={fullFormat.format(date)}>{timeFormat.format(date)}</time>;
}

// ---- tool calls ----

const toolIcons: Record<ToolKind, IconName> = { shell: "terminal", edit: "pencil", file: "doc", search: "search", generic: "wrench" };
/** Output lines shown before "Show all": enough to judge it, short enough to scroll past. */
const OUTPUT_PREVIEW_LINES = 20;

const lines = (text: string) => text ? text.replace(/\n$/, "").split("\n").length : 0;

/** What a call did, in one line: the command, or what it was pointed at. */
function toolSummary(tool: ToolActivity): string {
  const input = tool.command ?? tool.subtitle ?? "";
  return input.split("\n").find(line => line.trim())?.trim() ?? "";
}

const ToolStep = memo(function ToolStep({ tool }: { tool: ToolActivity }) {
  const [full, setFull] = useState(false);
  const outputLines = lines(tool.output);
  const shown = full || outputLines <= OUTPUT_PREVIEW_LINES + 4
    ? tool.output
    : tool.output.split("\n").slice(0, OUTPUT_PREVIEW_LINES).join("\n");
  const summary = toolSummary(tool);
  const input = tool.command ?? tool.subtitle;
  return (
    <details className={`share-tool share-tool-${tool.status} share-tool-kind-${tool.kind}`}>
      <summary>
        <Icon name="chevronRight" size={14} />
        <span className="share-tool-icon"><Icon name={toolIcons[tool.kind]} size={15} /></span>
        <span className="share-tool-name">{tool.name}</span>
        <span className="share-tool-summary">{summary ? <Redactable text={tool.kind === "shell" ? `$ ${summary}` : summary} /> : null}</span>
        <span className="share-tool-meta">
          {tool.status === "failed" ? <span className="share-tool-failed">Failed</span>
            : tool.status === "running" ? <span>Running</span>
              : outputLines ? plural(outputLines, "line") : "No output"}
        </span>
      </summary>
      <div className="share-tool-body">
        {input ? (
          <section>
            <h4>Input</h4>
            <pre className="share-pre"><Redactable text={tool.kind === "shell" ? `$ ${input}` : input} /></pre>
          </section>
        ) : null}
        <section>
          <h4>Output</h4>
          {tool.output ? <pre className="share-pre share-output"><Redactable text={shown} /></pre> : <p className="share-tool-empty">No output.</p>}
          {shown !== tool.output ? (
            <button className="share-show-more" onClick={() => setFull(true)}>Show all {plural(outputLines, "line")}</button>
          ) : null}
          {tool.outputTruncated ? <p className="share-tool-empty">The output was cut short when it was shared.</p> : null}
        </section>
      </div>
    </details>
  );
});

/** Runs of this many steps or more start folded into one line, so the replies stay close together. */
const FOLD_STEPS_FROM = 4;

function Steps({ tools }: { tools: { key: string; tool: ToolActivity }[] }) {
  const rows = <div className="share-steps-list">{tools.map(({ key, tool }) => <ToolStep key={key} tool={tool} />)}</div>;
  if (tools.length < FOLD_STEPS_FROM) return rows;
  const counts = new Map<string, number>();
  for (const { tool } of tools) counts.set(tool.name, (counts.get(tool.name) ?? 0) + 1);
  const failed = tools.filter(({ tool }) => tool.status === "failed").length;
  return (
    <details className="share-steps">
      <summary>
        <Icon name="chevronRight" size={14} />
        <span className="share-steps-title">{plural(tools.length, "tool call")}</span>
        <span className="share-steps-breakdown">
          {[...counts].sort((a, b) => b[1] - a[1]).map(([name, count]) => count > 1 ? `${name} ×${count}` : name).join(" · ")}
        </span>
        {failed ? <span className="share-tool-failed">{failed} failed</span> : null}
      </summary>
      {rows}
    </details>
  );
}

// ---- the page ----

function Header({ snapshot, turns }: { snapshot: SharedSessionSnapshot; turns: Turn[] }) {
  const times = snapshot.messages.map(message => message.timestamp).filter((at): at is number => at !== null);
  const took = times.length > 1 ? duration(Math.max(...times) - Math.min(...times)) : null;
  const toolCalls = turns.reduce((count, turn) => count + (turn.kind === "steps" ? turn.tools.length : 0), 0);
  const published = new Date(snapshot.publishedAt);
  const facts = [
    <time key="date" dateTime={published.toISOString()} title={fullFormat.format(published)}>{dateFormat.format(published)}</time>,
    snapshot.model ? <span key="model" title={`${snapshot.model.provider}/${snapshot.model.id}`}>{snapshot.model.name}</span> : null,
    toolCalls ? <span key="tools">{plural(toolCalls, "tool call")}</span> : null,
    took ? <span key="took">{took}</span> : null,
  ].filter(Boolean);
  return (
    <header className="share-header">
      <h1>
        {snapshot.emoji ? <span className="share-emoji" aria-hidden="true">{snapshot.emoji}</span> : null}
        <span>{snapshot.title}</span>
      </h1>
      <p className="share-facts">{facts.flatMap((fact, at) => at ? [<span key={`dot${at}`} aria-hidden="true"> · </span>, fact] : [fact])}</p>
      <p className="share-note">
        <Icon name="info" size={14} />
        A Pi session from Axo. Secrets and private paths were redacted on the Mac before it was published.
      </p>
    </header>
  );
}

function TurnView({ turn, assistantName }: { turn: Turn; assistantName: string }) {
  switch (turn.kind) {
    case "user":
      return (
        <article className="share-turn share-user">
          <div className="share-role"><span className="share-role-dot" />User <Time at={turn.timestamp} /></div>
          <div className="share-user-text"><Redactable text={turn.text} /></div>
        </article>
      );
    case "assistant":
      return (
        <article className="share-turn share-assistant">
          <div className="share-role"><span className="share-role-dot" />{assistantName} <Time at={turn.timestamp} /></div>
          <Markdown blocks={turn.blocks} />
        </article>
      );
    case "steps":
      return <div className="share-turn share-steps-turn"><Steps tools={turn.tools} /></div>;
  }
}

/** Opens every folded step, or closes them all: the button, and `e` on the keyboard. */
function toggleAllSteps(): boolean {
  const all = [...document.querySelectorAll<HTMLDetailsElement>("details.share-steps, details.share-tool")];
  const open = all.some(details => !details.open);
  for (const details of all) details.open = open;
  return open;
}

function TopBar({ transcriptHref }: { transcriptHref: string }) {
  const [expanded, setExpanded] = useState(false);
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "e" || event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.target instanceof HTMLElement && event.target.closest("input, textarea, [contenteditable]")) return;
      setExpanded(toggleAllSteps());
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  return (
    <nav className="share-bar" aria-label="Shared session">
      <a className="share-brand" href="/">axo</a>
      <span className="share-bar-label">Shared session</span>
      <span className="spacer" />
      <button className="share-bar-button share-bar-wide" onClick={() => setExpanded(toggleAllSteps())} title="Expand or collapse every tool call (E)">
        {expanded ? "Collapse all" : "Expand all"}
      </button>
      <button className="share-bar-button" onClick={() => void navigator.clipboard?.writeText(location.href).then(() => setCopied(true), () => {})}>
        <Icon name={copied ? "check" : "copy"} size={15} /><span className="share-bar-wide">{copied ? "Copied" : "Copy link"}</span>
      </button>
      <a className="share-bar-button" href={transcriptHref} download title="Download as an ATXF transcript (JSON Lines)">
        <Icon name="arrowDown" size={15} /><span>.jsonl</span>
      </a>
    </nav>
  );
}

/** Read-only renderer for a published snapshot. It never connects to the account or host APIs. */
export function SharedSession({ shareId }: { shareId: string }) {
  const [snapshot, setSnapshot] = useState<SharedSessionSnapshot | null>(() => inlinedSnapshot(shareId));
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (snapshot) return;
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
    if (snapshot) document.title = `${snapshot.emoji ? `${snapshot.emoji} ` : ""}${snapshot.title} · Axo`;
  }, [snapshot]);

  const turns = useMemo(() => snapshot ? turnsOf(snapshot.messages) : [], [snapshot]);
  const transcriptHref = `${location.pathname.replace(/\/$/, "")}.jsonl`;

  if (failed) return <main className="share-state"><h1>This shared session isn’t available</h1><p>It may have been removed, or the link may be incorrect.</p></main>;
  if (!snapshot) return <main className="share-state" aria-live="polite">Loading shared session…</main>;

  const assistantName = snapshot.model?.name ?? "Assistant";
  return (
    <div className="share-page">
      <TopBar transcriptHref={transcriptHref} />
      <main className="share-column">
        <Header snapshot={snapshot} turns={turns} />
        <section className="share-transcript" aria-label="Conversation">
          {turns.map(turn => <TurnView key={turn.key} turn={turn} assistantName={assistantName} />)}
        </section>
        <footer className="share-footer">
          <span>Shared from <a href="/">Axo</a>, your agents on your Macs, from anywhere.</span>
          <a href={transcriptHref} download>Download the transcript (ATXF)</a>
        </footer>
      </main>
    </div>
  );
}
