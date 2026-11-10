import { useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import { createPortal } from "react-dom";
import type { ToolActivity, ToolInput } from "./transcript.ts";
import type { ToolGroupPlace } from "./tool-groups.ts";
import { toolPreview } from "./tool-groups.ts";
import { highlight } from "./highlight.ts";
import { Icon, type IconName } from "./icons.tsx";

const toolIcons: Record<ToolActivity["kind"], IconName> = {
  shell: "terminal", edit: "pencil", file: "doc", search: "search", generic: "wrench",
};

/** How many lines of a running tool's input show before it is opened. */
const PREVIEW_LINES = 3;
/** About as many lines as the open card's output box shows; more and it offers to show it all. */
const FOLDED_OUTPUT_LINES = 20;

/**
 * A tool the agent used: a row saying what it is and what it works on, in a block with the tools
 * used just before and after it.
 *
 * While it runs, the row shows the start of what it was given and the newest line of what it
 * printed. Tapped (running or not), it opens to all of what it was given and all it printed so
 * far, still coming in; "See full output" shows that output on its own, as big as the window.
 * What came back starts folded once it is done.
 */
export function ToolCard({ tool, working, enter, group }: {
  tool: ToolActivity; working: boolean; enter: boolean; group: ToolGroupPlace | null;
}) {
  const [open, setOpen] = useState(false);
  const [viewing, setViewing] = useState(false);
  const running = tool.status === "running" && working;
  const preview = toolPreview(tool);
  const input = tool.input ?? null;
  const place = !group ? " tool-alone" : `${group.first ? " tool-first" : ""}${group.last ? " tool-last" : ""}`;
  const lastLine = running ? lastNonEmptyLine(tool.output) : "";
  // The start of what it was given, unless the row's line says all of it already.
  const glance = input && input.kind !== "args" && input.text.trim() !== preview ? firstLines(input.text, PREVIEW_LINES) : null;
  const lines = tool.output ? tool.output.split("\n").length : 0;
  return (
    <div className={`tool-card tool-${tool.status} tool-kind-${tool.kind}${place}${open ? " tool-open" : ""}${enter ? " message-enter" : ""}`}
      data-testid="tool-card">
      {group?.title ? <div className="tool-group-title" data-testid="tool-group-title">{group.title}</div> : null}
      <button className="tool-row" aria-expanded={open} onClick={() => setOpen(!open)}
        aria-label={`${tool.name}${preview ? ` ${preview}` : ""}${running ? ", running" : ""}`}>
        <Icon name={toolIcons[tool.kind]} size={16} />
        <span className="tool-name">{tool.name}</span>
        <span className="tool-preview">{preview}</span>
        <span className="tool-status">
          {tool.status === "completed" ? <span className="tool-badge done" aria-label="Completed"><Icon name="check" size={16} /></span>
            : tool.status === "failed" ? <span className="tool-badge failed" aria-label="Failed"><Icon name="close" size={12} /></span>
              : running ? <span className="spinner" aria-label="Running" /> : null}
        </span>
        <Icon name={open ? "chevronDown" : "chevronRight"} size={12} />
      </button>
      {open ? (
        <div className="tool-body">
          {input ? <ToolInputView input={input} subtitle={tool.subtitle} /> : null}
          {tool.output ? <ToolOutput tool={tool} running={running} /> : running ? <p className="tool-note">Nothing printed yet.</p> : null}
          <div className="tool-actions">
            {running || lines > FOLDED_OUTPUT_LINES
              ? <button className="tool-action" onClick={() => setViewing(true)}>See full output ({lines} {lines === 1 ? "line" : "lines"})</button> : null}
            {tool.outputTruncated ? <span className="tool-note">Cut short here; the rest is on your Mac.</span> : null}
          </div>
        </div>
      ) : running ? (
        <div className="tool-glance">
          {glance ? <pre className="tool-input-preview">{glance}</pre> : null}
          {lastLine ? <div className="tool-last-line" data-testid="tool-last-line">{lastLine}</div> : null}
        </div>
      ) : null}
      {viewing ? <OutputViewer tool={tool} running={running} onClose={() => setViewing(false)} /> : null}
    </div>
  );
}

/** What the tool was given, coloured as what it is: a command, a script, a diff, a file, arguments. */
function ToolInputView({ input, subtitle }: { input: ToolInput; subtitle: string | null }) {
  const language = input.kind === "command" ? "sh" : input.kind === "code" ? "js" : input.kind === "diff" ? "diff"
    : input.kind === "args" ? "json" : extension(subtitle);
  const text = input.kind === "command" ? `$ ${input.text}` : input.text;
  return <Highlighted className="tool-input" text={text} language={language} label="Input" />;
}

/** What it printed so far: the end of it stays in view while it runs. */
function ToolOutput({ tool, running }: { tool: ToolActivity; running: boolean }) {
  const box = useRef<HTMLPreElement>(null);
  useFollowEnd(box, tool.output, running);
  return (
    <pre ref={box} className="tool-output" aria-label="Output">
      <OutputText tool={tool} />
    </pre>
  );
}

function OutputText({ tool }: { tool: ToolActivity }) {
  if (tool.kind !== "edit" || tool.status === "failed") return <>{tool.output}</>;
  return <>{tool.output.split("\n").map((line, index) =>
    <span key={index} className={line.startsWith("+") ? "diff-add" : line.startsWith("-") ? "diff-remove" : undefined}>{line}{"\n"}</span>)}</>;
}

/** All of the output, as big as the window, still coming in while the tool runs. */
function OutputViewer({ tool, running, onClose }: { tool: ToolActivity; running: boolean; onClose: () => void }) {
  const box = useRef<HTMLPreElement>(null);
  useFollowEnd(box, tool.output, running);
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);
  const title = `${tool.name} output`;
  const lines = tool.output.split("\n").length;
  return createPortal(
    <div className="sheet-backdrop" onClick={onClose}>
      <section className="sheet output-sheet" role="dialog" aria-modal="true" aria-label={title} onClick={event => event.stopPropagation()}>
        <header className="sheet-header">
          <span className="circle-placeholder" />
          <h2>{title}</h2>
          <button className="circle-button" onClick={onClose} aria-label={`Close ${title}`}><Icon name="close" size={16} /></button>
        </header>
        <p className="output-sheet-note">
          {toolPreview(tool) ? <span className="output-sheet-what">{toolPreview(tool)}</span> : null}
          <span>{lines} {lines === 1 ? "line" : "lines"}{running ? ", still running" : ""}</span>
        </p>
        <pre ref={box} className="tool-output output-sheet-text"><OutputText tool={tool} /></pre>
        {tool.outputTruncated ? <p className="tool-note">Cut short here; the rest is on your Mac.</p> : null}
      </section>
    </div>,
    document.body,
  );
}

function Highlighted({ className, text, language, label }: { className: string; text: string; language: string | null; label: string }) {
  const tokens = useMemo(() => highlight(text, language), [text, language]);
  return (
    <pre className={className} aria-label={label}>
      <code>{tokens.map((token, at) => token.kind === "plain" ? token.text : <span key={at} className={`tok-${token.kind}`}>{token.text}</span>)}</code>
    </pre>
  );
}

/**
 * Keeps the end of a box in view as text comes in while `running`, unless the reader scrolled up
 * in it to read.
 */
function useFollowEnd(box: RefObject<HTMLElement | null>, text: string, running: boolean): void {
  const following = useRef(true);
  useEffect(() => {
    const element = box.current;
    if (!element) return;
    const onScroll = () => { following.current = element.scrollHeight - element.scrollTop - element.clientHeight < 8; };
    element.addEventListener("scroll", onScroll, { passive: true });
    return () => element.removeEventListener("scroll", onScroll);
  }, [box]);
  useLayoutEffect(() => {
    const element = box.current;
    if (element && running && following.current) element.scrollTop = element.scrollHeight;
  }, [box, text, running]);
}

function firstLines(text: string, count: number): string {
  const lines = text.split("\n");
  return lines.length > count ? `${lines.slice(0, count).join("\n")}\n…` : text;
}

function lastNonEmptyLine(text: string): string {
  const lines = text.split("\n");
  for (let index = lines.length - 1; index >= 0; index--) if (lines[index]!.trim()) return lines[index]!;
  return "";
}

/** A file's language, by its extension: the subtitle is its path, maybe with a range after it. */
function extension(subtitle: string | null): string | null {
  const path = subtitle?.split(" · ")[0] ?? "";
  const dot = path.lastIndexOf(".");
  return dot > 0 ? path.slice(dot + 1) : null;
}
