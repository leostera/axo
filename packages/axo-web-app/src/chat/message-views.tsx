import { memo, useState } from "react";
import { inlineSpans, type InlineSpan, type MarkdownBlock } from "./markdown.ts";
import type { ChatMessage, ChatQuestion, ToolActivity } from "./transcript.ts";
import type { PendingPrompt } from "./workbench.ts";
import { Icon, type IconName } from "./icons.tsx";

/** Bold, italics, links and `code` within a line. Remote images are never fetched. */
function Inline({ text }: { text: string }) {
  return <Spans spans={inlineSpans(text)} />;
}

function Spans({ spans }: { spans: InlineSpan[] }) {
  return (
    <>
      {spans.map((span, index) => {
        switch (span.kind) {
          case "text": return <span key={index}>{span.text}</span>;
          case "code": return <code key={index}>{span.text}</code>;
          case "strong": return <strong key={index}><Spans spans={span.children} /></strong>;
          case "emphasis": return <em key={index}><Spans spans={span.children} /></em>;
          case "link": return <a key={index} href={span.href} target="_blank" rel="noreferrer noopener"><Spans spans={span.children} /></a>;
        }
      })}
    </>
  );
}

/** A reply, drawn where its look changes: prose, headings, lists, quotes, tables, rules and code. */
export const Markdown = memo(function Markdown({ blocks, thinking = false }: { blocks: MarkdownBlock[]; thinking?: boolean }) {
  return (
    <div className={thinking ? "markdown thinking" : "markdown"}>
      {blocks.map((block, index) => {
        switch (block.kind) {
          case "paragraph": return <p key={index}><Inline text={block.text} /></p>;
          case "heading": {
            const Heading = `h${block.level + 1}` as "h2" | "h3" | "h4";
            return <Heading key={index}><Inline text={block.text} /></Heading>;
          }
          case "listItem":
            return (
              <div key={index} className="md-list-item" style={{ paddingLeft: `${block.depth * 1.2}em` }}>
                <span className="md-marker">{block.marker.kind === "bullet" ? (block.depth === 0 ? "•" : "◦") : `${block.marker.value}.`}</span>
                <span><Inline text={block.text} /></span>
              </div>
            );
          case "quote": return <blockquote key={index}><Inline text={block.text} /></blockquote>;
          case "rule": return <hr key={index} />;
          case "code":
            return (
              <div key={index} className="md-code">
                {block.language ? <span className="md-code-language">{block.language}</span> : null}
                <pre><code>{block.text}</code></pre>
              </div>
            );
          case "table":
            return (
              <div key={index} className="md-table">
                <table>
                  <thead><tr>{block.header.map((cell, at) => <th key={at}><Inline text={cell} /></th>)}</tr></thead>
                  <tbody>{block.rows.map((row, at) => <tr key={at}>{row.map((cell, column) => <td key={column}><Inline text={cell} /></td>)}</tr>)}</tbody>
                </table>
              </div>
            );
        }
      })}
    </div>
  );
});

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

/** "3 days ago", "just now": how long since `milliseconds`. */
export function relativeTime(milliseconds: number, now = Date.now()): string {
  const seconds = Math.round((milliseconds - now) / 1000);
  const steps: Array<[Intl.RelativeTimeFormatUnit, number]> = [["year", 31_536_000], ["month", 2_592_000], ["week", 604_800], ["day", 86_400], ["hour", 3_600], ["minute", 60]];
  for (const [unit, size] of steps) if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
  return "just now";
}

function Timestamp({ milliseconds }: { milliseconds: number }) {
  const date = new Date(milliseconds);
  return <time className="message-time" dateTime={date.toISOString()} title={date.toLocaleString()}>{relativeTime(milliseconds)}</time>;
}

function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch {
      setCopied(false);
    }
  };
  return (
    <button className="plain-icon-button" onClick={() => void copy()} aria-label={copied ? "Copied response" : "Copy response"}>
      <Icon name={copied ? "check" : "copy"} size={17} />
    </button>
  );
}

/** Shares a reply where the browser can (the system's share sheet), as the phone does. */
function ShareButton({ text }: { text: string }) {
  if (typeof navigator.share !== "function") return null;
  return (
    <button className="plain-icon-button" onClick={() => void navigator.share({ text }).catch(() => {})} aria-label="Share response">
      <Icon name="share" size={17} />
    </button>
  );
}

export const MessageView = memo(function MessageView({ message, working, live = false }: { message: ChatMessage; working: boolean; live?: boolean }) {
  switch (message.role) {
    case "user":
      return (
        <div className="message user-message">
          {message.images.length ? <div className="message-images">{message.images.map((image, index) => <img key={index} src={image.src} alt="" />)}</div> : null}
          {message.text ? <div className="user-bubble">{message.text}</div> : null}
          {message.timestamp ? <Timestamp milliseconds={message.timestamp} /> : null}
        </div>
      );
    case "assistant":
      return (
        <div className="message assistant-message">
          {message.images.length ? <div className="message-images">{message.images.map((image, index) => <img key={index} src={image.src} alt="" />)}</div> : null}
          <Markdown blocks={message.blocks} />
          {live ? null : (
            <div className="message-actions">
              <CopyButton text={message.text} />
              <ShareButton text={message.text} />
              {message.timestamp ? <Timestamp milliseconds={message.timestamp} /> : null}
            </div>
          )}
        </div>
      );
    case "thinking":
      return <div className="message thinking-message"><Markdown blocks={message.blocks} thinking /></div>;
    case "tool":
      return message.tool ? <ToolCard tool={message.tool} working={working} /> : null;
  }
});

const toolIcons: Record<ToolActivity["kind"], IconName> = {
  shell: "terminal", edit: "pencil", file: "doc", search: "search", generic: "wrench",
};

/** A tool Pi used: a tinted card with what it ran and a short look at what came back. */
function ToolCard({ tool, working }: { tool: ToolActivity; working: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const running = tool.status === "running" && working;
  const lines = tool.output.split("\n");
  const shown = !expanded && lines.length > 6 ? (running ? lines.slice(-6) : lines.slice(0, 6)) : lines;
  return (
    <div className={`tool-card tool-${tool.status} tool-kind-${tool.kind}`} data-testid="tool-card">
      <div className="tool-heading">
        <Icon name={toolIcons[tool.kind]} size={18} />
        <span className="tool-name">{tool.name}</span>
        <span className="tool-status">
          {tool.status === "completed" ? <span className="tool-badge done" aria-label="Completed"><Icon name="check" size={18} /></span>
            : tool.status === "failed" ? <span className="tool-badge failed" aria-label="Failed"><Icon name="close" size={14} /></span>
              : running ? <span className="spinner" aria-label="Running" /> : null}
        </span>
      </div>
      {tool.subtitle ? <div className="tool-subtitle">{tool.subtitle}</div> : null}
      {tool.command ? <div className={expanded ? "tool-command" : "tool-command clamped"}>$ {tool.command}</div> : null}
      {tool.output ? (
        <pre className="tool-output">
          {tool.kind === "edit" && tool.status !== "failed"
            ? shown.map((line, index) => <span key={index} className={line.startsWith("+") ? "diff-add" : line.startsWith("-") ? "diff-remove" : undefined}>{line}{"\n"}</span>)
            : shown.join("\n")}
        </pre>
      ) : null}
      {tool.output && lines.length > 6 && !running ? (
        <button className="tool-expand" onClick={() => setExpanded(!expanded)}>{expanded ? "Collapse tool output" : "Expand tool output"}</button>
      ) : null}
      {tool.outputTruncated ? <p className="tool-truncated">Output cut short here; the rest is on your Mac.</p> : null}
    </div>
  );
}

const pendingLabels: Record<PendingPrompt["state"], string> = {
  sending: "Sending…",
  sent: "Sent",
  queued: "Queued · answered after the current reply",
  uncertain: "Delivery uncertain · check the chat before sending again",
};

/** A message sent from here that the agent has not recorded yet. */
export function PendingView({ prompt, onEditAgain, onDismiss }: { prompt: PendingPrompt; onEditAgain: () => void; onDismiss: () => void }) {
  return (
    <div className={`message user-message pending pending-${prompt.state}`} data-testid="pending-prompt">
      <div className="user-bubble">{prompt.text}</div>
      <div className="pending-label">
        {prompt.state === "uncertain" ? <Icon name="warning" size={14} /> : null}
        {pendingLabels[prompt.state]}
      </div>
      {prompt.state === "uncertain" ? (
        <div className="pending-actions">
          <button onClick={onEditAgain}>Edit and send again</button>
          <button onClick={onDismiss}>Remove</button>
        </div>
      ) : null}
    </div>
  );
}

/** What the agent is asking, with a way to answer it from here when that can be done. */
export function QuestionCard({ question, canAnswer, onAnswer }: {
  question: ChatQuestion;
  canAnswer: boolean;
  onAnswer: (answer: { kind: "yes" } | { kind: "no" } | { kind: "text"; text: string }) => void;
}) {
  const [text, setText] = useState("");
  const title = question.title ?? "The agent is asking something";
  const skip = <button className="question-skip" disabled={!canAnswer} onClick={() => onAnswer({ kind: "no" })}>Skip</button>;
  return (
    <div className="question-card" role="group" aria-label={title}>
      <p className="question-title"><Icon name="question" size={20} /><span>{title}</span></p>
      {question.kind === "confirm" ? (
        <div className="question-buttons">
          <button className="pill-button primary" disabled={!canAnswer} onClick={() => onAnswer({ kind: "yes" })}>Yes</button>
          <button className="pill-button" disabled={!canAnswer} onClick={() => onAnswer({ kind: "no" })}>No</button>
        </div>
      ) : question.kind === "input" ? (
        <>
          <form className="question-input" onSubmit={event => {
            event.preventDefault();
            if (canAnswer && text.trim()) {
              onAnswer({ kind: "text", text: text.trim() });
              setText("");
            }
          }}>
            <input value={text} onChange={event => setText(event.target.value)} placeholder="Your answer" aria-label="Your answer" />
            <button className="pill-button primary" disabled={!canAnswer || !text.trim()}>Send</button>
          </form>
          {skip}
        </>
      ) : (
        <>
          <p className="question-elsewhere">The choices are on your Mac. Answer there, or skip the question.</p>
          {skip}
        </>
      )}
    </div>
  );
}
