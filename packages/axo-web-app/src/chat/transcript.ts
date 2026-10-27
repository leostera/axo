import { parseMarkdown, type MarkdownBlock } from "./markdown.ts";

/**
 * A conversation as Pi's events tell it: a port of the phone's `ChatTranscript`. Whole messages
 * (`message.end`) make the conversation; the reply being written (`message.update`) and a running
 * tool's output (`tool.update`) show as they grow; the rest says whether Pi is working or asking.
 * Replaying an event, or reading history that overlaps what arrived live, never repeats a message.
 * A tool's result is not a message of its own: it fills in the tool that asked.
 */
export type ToolKind = "shell" | "edit" | "file" | "search" | "generic";
export type ToolStatus = "running" | "completed" | "failed";

export interface ToolActivity {
  readonly callId: string | null;
  readonly name: string;
  readonly kind: ToolKind;
  /** The file or pattern the tool works on. */
  readonly subtitle: string | null;
  /** The shell command, for shell tools. */
  readonly command: string | null;
  readonly status: ToolStatus;
  readonly output: string;
  /** Cut short to cross the wire; the Mac has all of it. */
  readonly outputTruncated: boolean;
}

export interface ChatImage {
  readonly src: string;
}

export type ChatRole = "user" | "assistant" | "thinking" | "tool";

export interface ChatMessage {
  /** Stable across reloads: the event that made it. */
  readonly id: string;
  readonly role: ChatRole;
  readonly text: string;
  readonly blocks: MarkdownBlock[];
  /** Milliseconds since 1970, as Pi recorded it. */
  readonly timestamp: number | null;
  readonly tool: ToolActivity | null;
  readonly images: ChatImage[];
}

export type QuestionKind = "confirm" | "input" | "select" | "editor" | "custom";
export interface ChatQuestion {
  readonly kind: QuestionKind;
  readonly title: string | null;
}

/** One of Pi's events, from the live stream or stored history. */
export interface PiEventRecord {
  readonly streamId: string;
  readonly sequence: number;
  readonly name: string;
  readonly data: unknown;
}

interface ToolResult {
  status: ToolStatus;
  output: string;
  truncated: boolean;
}

export function toolKind(name: string): ToolKind {
  switch (name) {
    case "bash": return "shell";
    case "edit": case "write": return "edit";
    case "read": return "file";
    case "grep": case "find": case "ls": case "search": return "search";
    default: return "generic";
  }
}

const questionKinds = new Set<QuestionKind>(["confirm", "input", "select", "editor", "custom"]);

export class ChatTranscript {
  messages: ChatMessage[] = [];
  working = false;
  /** The reply Pi is writing, as far as it has got; gone once it is whole. */
  live: ChatMessage[] = [];
  question: ChatQuestion | null = null;
  private known = new Set<string>();
  private results = new Map<string, ToolResult>();
  /** The first this many messages came from stored history; the rest arrived live. */
  private historical = 0;

  /** A conversation read from stored events, oldest first. */
  static fromHistory(records: readonly PiEventRecord[]): ChatTranscript {
    const transcript = new ChatTranscript();
    for (const record of records) transcript.apply(record);
    transcript.historical = transcript.messages.length;
    return transcript;
  }

  apply(record: PiEventRecord): void {
    const data = asObject(record.data);
    switch (record.name) {
      case "agent.start":
        this.working = true;
        return;
      case "agent.end":
      case "agent.settled":
        this.working = false;
        this.live = [];
        return;
      case "activity.snapshot":
        if (typeof data?.working === "boolean") this.working = data.working;
        return;
      case "ui.prompt.start": {
        const kind = typeof data?.kind === "string" && questionKinds.has(data.kind as QuestionKind)
          ? data.kind as QuestionKind : "custom";
        this.question = { kind, title: typeof data?.title === "string" ? data.title : null };
        return;
      }
      case "ui.prompt.end":
        this.question = null;
        return;
      case "message.update": {
        const message = asObject(data?.message);
        if (message?.role !== "assistant") return;
        this.live = pieces(message, "assistant").map((piece, index) => ({
          id: `live#${index}`, role: piece.role, text: piece.text, blocks: blocksFor(piece),
          timestamp: null, tool: piece.tool, images: piece.images,
        }));
        return;
      }
      case "tool.update": {
        const callId = data?.toolCallId;
        if (typeof callId !== "string") return;
        const index = this.messages.findIndex(message => message.tool?.callId === callId);
        if (index < 0 || this.messages[index]!.tool?.status !== "running") return;
        const output = visibleText(asObject(data?.partialResult)?.content);
        this.changeTool(index, tool => ({ ...tool, output }));
        return;
      }
      case "message.end": {
        const id = `${record.streamId.toLowerCase()}:${record.sequence}`;
        if (this.known.has(id)) return;
        const message = asObject(data?.message);
        const role = message?.role;
        if (!message || typeof role !== "string") return;
        if (role === "toolResult") {
          this.recordResult(message);
          return;
        }
        if (role === "assistant") this.live = [];
        const timestamp = typeof message.timestamp === "number" ? message.timestamp : null;
        pieces(message, role).forEach((piece, index) => {
          this.known.add(id);
          const result = piece.tool?.callId ? this.results.get(piece.tool.callId) : undefined;
          const tool = piece.tool && result ? filled(piece.tool, result) : piece.tool;
          this.messages.push({
            id: index === 0 ? id : `${id}#${index}`, role: piece.role, text: piece.text,
            blocks: blocksFor(piece), timestamp, tool, images: piece.images,
          });
        });
        return;
      }
    }
  }

  /**
   * Joins the newest page of stored history: after the older history already shown (when
   * `keepingOlder`: the page reaches back into it) and before what arrived live and is not in it.
   * History says nothing about whether Pi is working now.
   */
  mergeNewest(page: ChatTranscript, keepingOlder: boolean): void {
    const inPage = new Set(page.messages.map(message => message.id));
    const older = keepingOlder ? this.messages.slice(0, this.historical).filter(message => !inPage.has(message.id)) : [];
    const live = this.messages.slice(this.historical).filter(message => !inPage.has(message.id));
    this.messages = [...older, ...page.messages, ...live];
    this.historical = older.length + page.messages.length;
    if (!keepingOlder) this.known = new Set(this.messages.map(message => baseId(message.id)));
    this.join(page);
  }

  /** Puts an older page of stored history before everything shown. */
  prependOlder(page: ChatTranscript): void {
    const fresh = page.messages.filter(message => !this.known.has(baseId(message.id)));
    this.messages = [...fresh, ...this.messages];
    this.historical += fresh.length;
    this.join(page, fresh.length);
  }

  /** What the Mac last said about whether Pi is working, for when live events were missed. */
  settle(working: boolean): void {
    this.working = working;
    if (!working) {
      this.live = [];
      this.question = null;
    }
  }

  private join(page: ChatTranscript, filling = this.messages.length): void {
    // A result that arrived live wins over the history's.
    for (const [callId, result] of page.results) if (!this.results.has(callId)) this.results.set(callId, result);
    for (let index = 0; index < Math.min(filling, this.messages.length); index += 1) {
      const callId = this.messages[index]!.tool?.callId;
      const result = callId ? this.results.get(callId) : undefined;
      if (result) this.changeTool(index, tool => filled(tool, result));
    }
    for (const id of page.known) this.known.add(id);
  }

  private recordResult(message: Record<string, unknown>): void {
    const callId = message.toolCallId;
    if (typeof callId !== "string") return;
    const result: ToolResult = {
      status: message.isError === true ? "failed" : "completed",
      output: visibleText(message.content),
      truncated: message.truncated === true,
    };
    this.results.set(callId, result);
    const index = this.messages.findIndex(candidate => candidate.tool?.callId === callId);
    if (index >= 0) this.changeTool(index, tool => filled(tool, result));
  }

  /** Messages are replaced, never changed in place, so a view can tell which ones changed. */
  private changeTool(index: number, change: (tool: ToolActivity) => ToolActivity): void {
    const message = this.messages[index]!;
    if (!message.tool) return;
    this.messages[index] = { ...message, tool: change(message.tool) };
  }
}

function filled(tool: ToolActivity, result: ToolResult): ToolActivity {
  return { ...tool, status: result.status, output: result.output, outputTruncated: result.truncated };
}

function baseId(id: string): string {
  return id.split("#")[0]!;
}

interface Piece {
  role: ChatRole;
  text: string;
  tool: ToolActivity | null;
  images: ChatImage[];
}

function blocksFor(piece: Piece): MarkdownBlock[] {
  return piece.role === "assistant" || piece.role === "thinking" ? parseMarkdown(piece.text) : [];
}

function pieces(message: Record<string, unknown>, role: string): Piece[] {
  const content = message.content;
  if (role === "user") {
    const text = visibleText(content);
    const images = imagesIn(content);
    return text || images.length ? [{ role: "user", text, tool: null, images }] : [];
  }
  if (role !== "assistant") return [];
  const found = assistantBlocks(content);
  // Some events list the calls apart from the content.
  for (const call of Array.isArray(message.toolCalls) ? message.toolCalls : []) {
    const tool = toolActivity(call);
    if (tool) found.push({ role: "tool", text: "", tool, images: [] });
  }
  return found;
}

/** The reply in the order Pi wrote it: reasoning, words, then the tools it reached for. */
function assistantBlocks(content: unknown): Piece[] {
  if (typeof content === "string") {
    const text = content.trim();
    return text ? [{ role: "assistant", text, tool: null, images: [] }] : [];
  }
  const found: Piece[] = [];
  let words: string[] = [];
  let images: ChatImage[] = [];
  const flushWords = () => {
    const text = words.join("\n").trim();
    if (text || images.length) found.push({ role: "assistant", text, tool: null, images });
    words = [];
    images = [];
  };
  for (const raw of Array.isArray(content) ? content : []) {
    const block = asObject(raw);
    switch (block?.type) {
      case "text":
        if (typeof block.text === "string") words.push(block.text);
        break;
      case "image": {
        const image = imageFrom(block);
        if (image) images.push(image);
        else words.push("[Image attachment]");
        break;
      }
      case "thinking": {
        flushWords();
        const text = typeof block.thinking === "string" ? block.thinking.trim() : "";
        if (text) found.push({ role: "thinking", text, tool: null, images: [] });
        break;
      }
      case "toolCall": {
        flushWords();
        const tool = toolActivity(block);
        if (tool) found.push({ role: "tool", text: "", tool, images: [] });
        break;
      }
    }
  }
  flushWords();
  return found;
}

function toolActivity(raw: unknown): ToolActivity | null {
  const call = asObject(raw);
  if (typeof call?.name !== "string") return null;
  const args = asObject(call.arguments);
  const kind = toolKind(call.name);
  const subtitle = ["path", "file_path", "pattern", "query"]
    .map(key => args?.[key]).find((value): value is string => typeof value === "string") ?? null;
  const command = typeof args?.command === "string" ? args.command : null;
  return {
    callId: typeof call.id === "string" ? call.id : null,
    name: call.name,
    kind,
    subtitle: kind === "shell" ? null : subtitle,
    command: kind === "shell" ? command : null,
    status: "running",
    output: "",
    outputTruncated: false,
  };
}

/** The words of a message; a picture without its data (cut to cross the wire) is named. */
function visibleText(content: unknown): string {
  if (typeof content === "string") return content.trim();
  return (Array.isArray(content) ? content : []).flatMap(raw => {
    const block = asObject(raw);
    if (block?.type === "text" && typeof block.text === "string") return [block.text];
    if (block?.type === "image" && !imageFrom(block)) return ["[Image attachment]"];
    return [];
  }).join("\n").trim();
}

function imagesIn(content: unknown): ChatImage[] {
  return (Array.isArray(content) ? content : []).flatMap(raw => {
    const block = asObject(raw);
    const image = block?.type === "image" ? imageFrom(block) : null;
    return image ? [image] : [];
  });
}

const imageTypes = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

function imageFrom(block: Record<string, unknown>): ChatImage | null {
  const data = block.data;
  if (typeof data !== "string" || !data || !/^[A-Za-z0-9+/=\s]+$/.test(data)) return null;
  const mimeType = typeof block.mimeType === "string" && imageTypes.has(block.mimeType) ? block.mimeType : "image/png";
  return { src: `data:${mimeType};base64,${data.replace(/\s/g, "")}` };
}

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
