import { createContext, memo, useContext, useEffect, useMemo, useState } from "react";
import { inlineSpans, parseMarkdown, type InlineSpan, type MarkdownBlock } from "./markdown.ts";
import type { ChatMessage, ChatQuestion, ToolActivity } from "./transcript.ts";
import type { AskedQuestion, PendingPrompt } from "./workbench.ts";
import { Icon, type IconName } from "./icons.tsx";

/** Bold, italics, links and `code` within a line. Remote images are never fetched. */
function Inline({ text }: { text: string }) {
  return <Spans spans={inlineSpans(text)} />;
}

/** Whether words fade in as they arrive: only in a reply still being written. */
const FadeWords = createContext(false);

function Spans({ spans }: { spans: InlineSpan[] }) {
  const fade = useContext(FadeWords);
  return (
    <>
      {spans.map((span, index) => {
        switch (span.kind) {
          case "text": return <span key={index}>{fade ? <Words text={span.text} /> : span.text}</span>;
          case "code": return <code key={index}>{span.text}</code>;
          case "strong": return <strong key={index}><Spans spans={span.children} /></strong>;
          case "emphasis": return <em key={index}><Spans spans={span.children} /></em>;
          case "link": return <a key={index} href={span.href} target="_blank" rel="noreferrer noopener"><Spans spans={span.children} /></a>;
        }
      })}
    </>
  );
}

/**
 * Text as words that each fade in once. Words keep their place as more arrive after them, so only
 * the new ones are mounted, and only they fade.
 */
function Words({ text }: { text: string }) {
  return <>{text.split(/(\s+)/).map((word, index) => word.trim() ? <span key={index} className="word-in">{word}</span> : word)}</>;
}

/** The fewest characters a second the reply comes in at; a backlog is caught up within about this long. */
const REVEAL_CHARS_PER_SECOND = 90;
const REVEAL_CATCH_UP_SECONDS = 0.6;
/** How often the shown text moves on: smooth enough, without parsing a long reply every frame. */
const REVEAL_FRAME_MS = 32;
const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/**
 * The reply being written, let out at an even pace, a word at a time. The Mac sends it in uneven
 * bursts; the pace speeds up with the backlog so the shown text never falls far behind.
 */
function useRevealedText(text: string): string {
  const [shown, setShown] = useState(0);
  useEffect(() => {
    if (reducedMotion()) {
      setShown(text.length);
      return;
    }
    let frame = 0;
    let last = performance.now();
    let at = Math.min(shown, text.length);
    const step = (now: number) => {
      const elapsed = now - last;
      if (elapsed >= REVEAL_FRAME_MS) {
        last = now;
        const backlog = text.length - at;
        const rate = Math.max(REVEAL_CHARS_PER_SECOND, backlog / REVEAL_CATCH_UP_SECONDS);
        at = wordEnd(text, Math.min(text.length, at + Math.max(1, Math.round(rate * elapsed / 1000))));
        setShown(at);
      }
      if (at < text.length) frame = requestAnimationFrame(step);
    };
    if (at < text.length) frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [text]);
  return text.slice(0, shown);
}

/** The end of the word `at` falls in, so a word never shows half written. */
function wordEnd(text: string, at: number): number {
  const space = text.slice(at).search(/\s/);
  return space < 0 ? text.length : at + space;
}

/**
 * A reply or its thinking let out evenly, its new words fading in: while it is written, and on
 * after it is recorded until all of it is out. `final` says no more is coming; once all of a final
 * text is out, `onDone` says so, and what comes after it may show.
 */
function RevealMarkdown({ text, thinking = false, final, onDone }: { text: string; thinking?: boolean; final: boolean; onDone: () => void }) {
  const shown = useRevealedText(text);
  const blocks = useMemo(() => parseMarkdown(shown), [shown]);
  const done = final && shown.length >= text.length;
  useEffect(() => { if (done) onDone(); }, [done]);
  return <FadeWords.Provider value={true}><Markdown blocks={blocks} thinking={thinking} /></FadeWords.Provider>;
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

/** How a message written while the chat is on screen is let out (see `RevealMarkdown`). */
export interface Reveal {
  /** Nothing more is coming: it is recorded, or more of the reply comes after it. */
  final: boolean;
  /** Called with the message's key once all of it is out; stable, so the view stays memoized. */
  onDone: (key: string) => void;
}

/**
 * One message. `live` is the reply still being written; `enter` is a message that arrived while the
 * chat was on screen, which comes in with a short rise; `reveal` lets a reply's words out evenly.
 */
export const MessageView = memo(function MessageView({ message, working, live = false, enter = false, reveal = null }: {
  message: ChatMessage; working: boolean; live?: boolean; enter?: boolean; reveal?: Reveal | null;
}) {
  const entering = enter ? " message-enter" : "";
  const onDone = () => reveal?.onDone(message.key);
  const text = (thinking: boolean) => reveal
    ? <RevealMarkdown text={message.text} thinking={thinking} final={reveal.final} onDone={onDone} />
    : <Markdown blocks={message.blocks} thinking={thinking} />;
  switch (message.role) {
    case "user":
      return (
        <div className={`message user-message${entering}`}>
          {message.images.length ? <div className="message-images">{message.images.map((image, index) => <img key={index} src={image.src} alt="" />)}</div> : null}
          {message.files?.length ? (
            <div className="pending-files">
              {message.files.map(file => (
                <a key={file.hex} className="pending-file" href={`/api/v1/account/assets/${file.hex}`} download={file.name} title={`${file.mimeType} · ${file.size}`}>
                  <Icon name="paperclip" size={13} />{file.name}
                </a>
              ))}
            </div>
          ) : null}
          {message.text ? <div className="user-bubble">{message.text}</div> : null}
          {message.timestamp ? <Timestamp milliseconds={message.timestamp} /> : null}
        </div>
      );
    case "assistant":
      return (
        <div className={`message assistant-message${entering}`}>
          {message.images.length ? <div className="message-images">{message.images.map((image, index) => <img key={index} src={image.src} alt="" />)}</div> : null}
          {text(false)}
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
      return (
        <div className={`message thinking-message${entering}`}>
          {text(true)}
        </div>
      );
    case "tool":
      return message.tool ? <ToolCard tool={message.tool} working={working} enter={enter} /> : null;
  }
});

const toolIcons: Record<ToolActivity["kind"], IconName> = {
  shell: "terminal", edit: "pencil", file: "doc", search: "search", generic: "wrench",
};

/** A tool Pi used: a tinted card with what it ran; what came back stays folded until asked for. */
function ToolCard({ tool, working, enter }: { tool: ToolActivity; working: boolean; enter: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const running = tool.status === "running" && working;
  const lines = tool.output.split("\n");
  const lineCount = `${lines.length} ${lines.length === 1 ? "line" : "lines"}`;
  return (
    <div className={`tool-card tool-${tool.status} tool-kind-${tool.kind}${enter ? " message-enter" : ""}`} data-testid="tool-card">
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
      {tool.output && expanded ? (
        <pre className="tool-output">
          {tool.kind === "edit" && tool.status !== "failed"
            ? lines.map((line, index) => <span key={index} className={line.startsWith("+") ? "diff-add" : line.startsWith("-") ? "diff-remove" : undefined}>{line}{"\n"}</span>)
            : tool.output}
        </pre>
      ) : null}
      {tool.output ? (
        <button className="tool-expand" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>
          {expanded ? "Hide output" : `Show output (${lineCount}${running ? ", still running" : ""})`}
        </button>
      ) : null}
      {tool.outputTruncated && expanded ? <p className="tool-truncated">Output cut short here; the rest is on your Mac.</p> : null}
    </div>
  );
}

const pendingLabels: Record<PendingPrompt["state"], string> = {
  sending: "Sending…",
  sent: "Sent",
  queued: "Queued · answered after the current reply",
  uncertain: "Not confirmed yet · trying again",
};

/** A message sent from here that the agent has not recorded yet. */
export function PendingView({ prompt, onDismiss }: { prompt: PendingPrompt; onDismiss: () => void }) {
  return (
    <div className={`message user-message pending pending-${prompt.state}`} data-testid="pending-prompt">
      {prompt.attachments.length ? (
        <div className="pending-files">
          {prompt.attachments.map(file => <span key={file.asset} className="pending-file"><Icon name="paperclip" size={13} />{file.name}</span>)}
        </div>
      ) : null}
      {prompt.text ? <div className="user-bubble">{prompt.text}</div> : null}
      <div className="pending-label">
        {prompt.state === "uncertain" ? <Icon name="warning" size={14} /> : null}
        {pendingLabels[prompt.state]}
      </div>
      {prompt.state === "uncertain" ? (
        <div className="pending-actions">
          <button onClick={onDismiss}>Remove</button>
        </div>
      ) : null}
    </div>
  );
}

/**
 * What a Mac's agent asks the person (RFD0029). Only the person can answer: the agent waits for
 * Yes or No, and an answer from any of their devices settles it everywhere.
 */
export function ElicitationCard({ question, canAnswer, onAnswer }: {
  question: AskedQuestion;
  canAnswer: boolean;
  onAnswer: (action: "accept" | "decline") => void;
}) {
  const { elicitation, answering } = question;
  const disabled = !canAnswer || answering !== null;
  // Axo's computer-use gate asks before an action it stopped; only axod's own tools can say so.
  const title = elicitation.askedBy === "computerUse" ? "Axo asks before acting on your Mac" : "The agent asks you";
  return (
    <div className="tool-card elicitation-card" role="group" aria-label={title}>
      <div className="tool-heading">
        <Icon name={elicitation.askedBy === "computerUse" ? "laptop" : "question"} size={18} />
        <span className="tool-name">{title}</span>
        {answering ? <span className="spinner" aria-hidden="true" /> : null}
      </div>
      <p className="elicitation-message">{elicitation.message}</p>
      <div className="elicitation-actions">
        <button className="elicitation-button primary" disabled={disabled} onClick={() => onAnswer("accept")}>Yes</button>
        <button className="elicitation-button" disabled={disabled} onClick={() => onAnswer("decline")}>No</button>
      </div>
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
