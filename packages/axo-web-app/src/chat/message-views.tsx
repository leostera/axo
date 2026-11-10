import { createContext, memo, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { inlineSpans, parseMarkdown, type InlineSpan, type MarkdownBlock } from "./markdown.ts";
import type { ChatMessage, ChatQuestion } from "./transcript.ts";
import type { AskedQuestion, WaitingPrompt } from "./workbench.ts";
import { pendingLabel } from "./pi-controls.ts";
import { Icon } from "./icons.tsx";
import { highlight } from "./highlight.ts";
import { ToolCard } from "./tool-views.tsx";
import type { ToolGroupPlace } from "./tool-groups.ts";
import { noteRender } from "./render-count.ts";
import type { InputFieldKind } from "@axo/protocol";

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
          case "text": return <span key={index}>{fade ? <Words text={span.text} /> : <Redactable text={span.text} />}</span>;
          case "code": return <code key={index}><Redactable text={span.text} /></code>;
          case "strong": return <strong key={index}><Spans spans={span.children} /></strong>;
          case "emphasis": return <em key={index}><Spans spans={span.children} /></em>;
          case "link": return <a key={index} href={span.href} target="_blank" rel="noreferrer noopener"><Spans spans={span.children} /></a>;
        }
      })}
    </>
  );
}

/** What `/axo-share` puts where it removed something: `[redacted:<kind>]` (packages/pi-axo/src/share.ts). */
const REDACTED = /\[redacted:([^\]\s]{1,64})\]/g;

/** Text with each redaction drawn as a short marker; its kind is in the tooltip. */
export function Redactable({ text }: { text: string }) {
  if (!text.includes("[redacted:")) return <>{text}</>;
  const parts: ReactNode[] = [];
  let last = 0;
  for (const match of text.matchAll(REDACTED)) {
    if (match.index > last) parts.push(text.slice(last, match.index));
    const kind = match[1]!.replace(/-/g, " ");
    parts.push(<span key={match.index} className="redacted" title={`Redacted before sharing: ${kind}`}>redacted</span>);
    last = match.index + match[0].length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return <>{parts}</>;
}

/**
 * Text as words that each fade in once. Words keep their place as more arrive after them, so only
 * the new ones are mounted, and only they fade.
 */
function Words({ text }: { text: string }) {
  return <>{text.split(/(\s+)/).map((word, index) => word.trim() ? <span key={index} className="word-in">{word}</span> : word)}</>;
}

/**
 * A reply or its thinking as far as its words are out (the feed lets them out, RFD0040), its new
 * words fading in.
 */
function RevealedMarkdown({ text, thinking = false }: { text: string; thinking?: boolean }) {
  const blocks = useMemo(() => parseMarkdown(text), [text]);
  return <FadeWords.Provider value={true}><Markdown blocks={blocks} thinking={thinking} /></FadeWords.Provider>;
}

/** A reply, drawn where its look changes: prose, headings, lists, quotes, tables, rules and code. */
export const Markdown = memo(function Markdown({ blocks, thinking = false }: { blocks: MarkdownBlock[]; thinking?: boolean }) {
  noteRender("Markdown");
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
          case "code": return <CodeBlock key={index} language={block.language} text={block.text} />;
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

/** A fenced block: coloured by its language, with its own copy button. */
const CodeBlock = memo(function CodeBlock({ language, text }: { language: string | null; text: string }) {
  const tokens = useMemo(() => highlight(text, language), [text, language]);
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  return (
    <div className="md-code">
      <div className="md-code-header">
        <span className="md-code-language">{language ?? ""}</span>
        <button className="md-code-copy" onClick={() => void navigator.clipboard?.writeText(text).then(() => setCopied(true), () => {})}
          aria-label={copied ? "Copied code" : "Copy code"}>
          <Icon name={copied ? "check" : "copy"} size={14} /><span>{copied ? "Copied" : "Copy"}</span>
        </button>
      </div>
      <pre><code>{tokens.map((token, at) => token.kind === "plain" ? token.text : <span key={at} className={`tok-${token.kind}`}>{token.text}</span>)}</code></pre>
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
/**
 * One message. `live` is the reply still being written; `enter` is a message that arrived while the
 * chat was on screen, which comes in with a short rise; `reveal` lets a reply's words out evenly.
 */
export const MessageView = memo(function MessageView({ message, working, live = false, enter = false, revealed = null, group = null }: {
  message: ChatMessage; working: boolean; live?: boolean; enter?: boolean;
  /** A tool's place among the tools used one after another. */
  group?: ToolGroupPlace | null;
  /** How many characters of its words are out, while they are let out; null when it shows whole. */
  revealed?: number | null;
}) {
  // The one growing (being written, or its words let out) apart from the rest, which should not
  // render at all as it grows.
  noteRender(live || revealed !== null ? "Growing" : "Message");
  const entering = enter ? " message-enter" : "";
  const text = (thinking: boolean) => revealed !== null
    ? <RevealedMarkdown text={message.text.slice(0, revealed)} thinking={thinking} />
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
      return message.tool ? <ToolCard tool={message.tool} working={working} enter={enter} group={group} /> : null;
  }
});

/** A message the agent has not recorded yet: sent from here, or queued in the log. */
export function PendingView({ prompt, onDismiss }: { prompt: WaitingPrompt; onDismiss: () => void }) {
  return (
    <div className={`message user-message pending pending-${prompt.state}`} data-testid="pending-prompt">
      {prompt.files.length ? (
        <div className="pending-files">
          {prompt.files.map((name, index) => <span key={`${index}:${name}`} className="pending-file"><Icon name="paperclip" size={13} />{name}</span>)}
        </div>
      ) : null}
      {prompt.text ? <div className="user-bubble">{prompt.text}</div> : null}
      <div className="pending-label">
        {prompt.state === "uncertain" ? <Icon name="warning" size={14} /> : null}
        {pendingLabel(prompt)}
      </div>
      {prompt.state === "uncertain" && prompt.mine ? (
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
  onAnswer: (action: "accept" | "decline", values?: Record<string, string>) => void;
}) {
  const { elicitation, answering } = question;
  if (elicitation.kind === "input" && elicitation.input) return <InputCard question={question} canAnswer={canAnswer} onAnswer={onAnswer} />;
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

const AUTOCOMPLETE: Record<InputFieldKind, { type: string; autoComplete: string; inputMode?: "numeric" }> = {
  username: { type: "text", autoComplete: "username" },
  email: { type: "email", autoComplete: "username" },
  password: { type: "password", autoComplete: "current-password" },
  code: { type: "text", autoComplete: "one-time-code", inputMode: "numeric" },
  text: { type: "text", autoComplete: "off" },
};

/**
 * Values the agent must not see, for a form on the person's Mac (RFD0029). What it shows is the
 * Mac's own reading of the window; what the person types is sealed to that Mac before it leaves
 * this tab, and the agent only learns that the fields were filled.
 */
function InputCard({ question, canAnswer, onAnswer }: {
  question: AskedQuestion;
  canAnswer: boolean;
  onAnswer: (action: "accept" | "decline", values?: Record<string, string>) => void;
}) {
  const { elicitation, answering } = question;
  const input = elicitation.input!;
  const [values, setValues] = useState<Record<string, string>>({});
  const disabled = !canAnswer || answering !== null;
  const complete = input.fields.every(field => (values[field.id] ?? "") !== "");
  const title = "Axo asks you to sign in on your Mac";
  return (
    <form
      className="tool-card elicitation-card"
      aria-label={title}
      autoComplete="on"
      onSubmit={event => {
        event.preventDefault();
        if (disabled || !complete) return;
        onAnswer("accept", values);
        setValues({});
      }}
    >
      <div className="tool-heading">
        <Icon name="laptop" size={18} />
        <span className="tool-name">{title}</span>
        {answering ? <span className="spinner" aria-hidden="true" /> : null}
      </div>
      <p className="elicitation-place">
        <strong>{input.origin ?? input.window}</strong>
        <span>in {input.app}{input.submit ? `, then “${input.submit}”` : ""}</span>
      </p>
      {input.fields.map(field => {
        const hint = AUTOCOMPLETE[field.kind];
        return (
          <label key={field.id} className="elicitation-field">
            <span>{field.label || field.kind}</span>
            <input
              name={field.id}
              type={hint.type}
              autoComplete={hint.autoComplete}
              inputMode={hint.inputMode}
              maxLength={1000}
              disabled={disabled}
              value={values[field.id] ?? ""}
              onChange={event => setValues(current => ({ ...current, [field.id]: event.target.value }))}
            />
          </label>
        );
      })}
      <p className="elicitation-note">Goes straight to your Mac, encrypted for it. The agent never sees it.</p>
      <div className="elicitation-actions">
        <button type="submit" className="elicitation-button primary" disabled={disabled || !complete}>Fill in</button>
        <button type="button" className="elicitation-button" disabled={disabled} onClick={() => onAnswer("decline")}>Cancel</button>
      </div>
    </form>
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
