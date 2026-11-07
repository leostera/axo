import { parseMarkdown, type MarkdownBlock } from "./markdown.ts";

/**
 * A conversation as the host's records tell it: a port of the phone's `ChatTranscript`. The
 * records are the lines of the agent's transcript (RFD0018), read by `entryOf`, the only part
 * that knows the format. Whole messages make the conversation; progress slots show the reply
 * being written, a running tool's output and a question, until a record says what came of them.
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

/** A file attached to a prompt (RFD0030), kept in the account's assets. */
export interface ChatFile {
  readonly name: string;
  readonly mimeType: string;
  readonly size: string;
  /** The asset's 64 hex digits: `/api/v1/account/assets/<hex>` downloads it. */
  readonly hex: string;
}

export type ChatRole = "user" | "assistant" | "thinking" | "tool";

export interface ChatMessage {
  /** Stable across reloads: the event that made it. */
  readonly id: string;
  /**
   * Stable from the first word of a reply to its record: what the screen keys it by, so a reply
   * written out live carries on as the same message once it is recorded. Pi stamps a reply when it
   * starts, and its progress and its record carry the same stamp.
   */
  readonly key: string;
  readonly role: ChatRole;
  readonly text: string;
  readonly blocks: MarkdownBlock[];
  /** Milliseconds since 1970, as Pi recorded it. */
  readonly timestamp: number | null;
  readonly tool: ToolActivity | null;
  readonly images: ChatImage[];
  /** Files attached to a person's message that the model read as a path, not inline. */
  readonly files?: ChatFile[];
}

export type QuestionKind = "confirm" | "input" | "select" | "editor" | "custom";
export interface ChatQuestion {
  readonly kind: QuestionKind;
  readonly title: string | null;
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

/** One durable record: its place in the Session and its raw line. */
export interface TranscriptRecord {
  readonly cursor: number;
  readonly id: string | null;
  readonly format: string;
  readonly line: string;
}

/**
 * The custom entry the Session's Pi writes just before a client's prompt (RFD0024): its
 * `commandId`, which says which pending message the user message after it is.
 */
export const RECEIPT_ENTRY = "axo.command";

/**
 * The custom entry the Session's Pi writes when it accepts a client's prompt it cannot take at
 * once (RFD0033). Until its receipt follows, the prompt waits: after the reply, or as a steer.
 */
export const QUEUED_ENTRY = "axo.command.queued";

export type Delivery = "followUp" | "steer";

/** A client's prompt the log holds, waiting for Pi. */
export interface QueuedPrompt {
  readonly commandId: string;
  readonly delivery: Delivery;
  readonly text: string;
  /** The names of the files that go with it. */
  readonly files: readonly string[];
}

/** A record as the conversation sees it: a message, a client's receipt or queued prompt, or nothing to show. */
type Entry =
  | { kind: "message"; id: string; message: Record<string, unknown> }
  | { kind: "receipt"; commandId: string }
  | { kind: "queued"; prompt: QueuedPrompt }
  | { kind: "other" };

/** The format adapter for `pi/3`: Pi's session file entries. */
export function entryOf(record: TranscriptRecord): Entry {
  if (record.format !== "pi/3") return { kind: "other" };
  let value: unknown;
  try {
    value = JSON.parse(record.line);
  } catch {
    return { kind: "other" };
  }
  const entry = asObject(value);
  if (entry?.type === "custom" && entry.customType === RECEIPT_ENTRY) {
    const commandId = asObject(entry.data)?.commandId;
    return typeof commandId === "string" ? { kind: "receipt", commandId } : { kind: "other" };
  }
  if (entry?.type === "custom" && entry.customType === QUEUED_ENTRY) {
    const data = asObject(entry.data);
    if (typeof data?.commandId !== "string") return { kind: "other" };
    const files = (Array.isArray(data.attachments) ? data.attachments : [])
      .map(raw => asObject(raw)?.name).filter((name): name is string => typeof name === "string");
    return {
      kind: "queued",
      prompt: {
        commandId: data.commandId,
        delivery: data.delivery === "steer" ? "steer" : "followUp",
        text: typeof data.text === "string" ? data.text : "",
        files,
      },
    };
  }
  const message = asObject(entry?.message);
  if (entry?.type !== "message" || !message) return { kind: "other" };
  return { kind: "message", id: typeof entry.id === "string" ? entry.id : `#${record.cursor}`, message };
}

export class ChatTranscript {
  messages: ChatMessage[] = [];
  /** Pi is working on a reply, as the host last said. */
  working = false;
  /** The reply Pi is writing, as far as it has got; gone once it is whole. */
  live: ChatMessage[] = [];
  question: ChatQuestion | null = null;
  /** The records held, oldest first, without gaps. */
  records: TranscriptRecord[] = [];
  /** The clients' prompts whose user message the log holds, by commandId (RFD0024). */
  delivered = new Set<string>();
  /** The clients' prompts the log holds that Pi has not taken yet, oldest first (RFD0033). */
  queued: QueuedPrompt[] = [];
  /** The entry id of the newest user message: the turn a stop names while Pi works. */
  lastUserEntry: string | null = null;
  /** A receipt whose user message has not been read yet. */
  private receipt: string | null = null;
  private results = new Map<string, ToolResult>();
  /**
   * When each recorded reply was started, as Pi stamps it. A reply's progress carries the same
   * stamp, so a snapshot that arrives after its record (or is replayed on reopening) is known.
   */
  private recordedReplies = new Set<number>();
  /** Running tools' output so far, by call id. */
  private toolOutput = new Map<string, string>();

  /** The first cursor held, or null when none is. */
  get firstCursor(): number | null {
    return this.records[0]?.cursor ?? null;
  }

  /** The last cursor held: what the next record follows. */
  get lastCursor(): number {
    return this.records.at(-1)?.cursor ?? 0;
  }

  /** Records after the last held; any already held are skipped. */
  append(records: readonly TranscriptRecord[]): void {
    for (const record of records) {
      if (record.cursor <= this.lastCursor) continue;
      this.records.push(record);
      this.applyRecord(record);
    }
  }

  /** Records before the first held, oldest first. */
  prepend(records: readonly TranscriptRecord[]): void {
    const first = this.firstCursor ?? Number.MAX_SAFE_INTEGER;
    const older = records.filter(record => record.cursor < first);
    if (!older.length) return;
    this.records = [...older, ...this.records];
    this.rebuild();
  }

  /** The host's copy was cut back: everything after `keep` goes. */
  cut(keep: number): void {
    if (this.lastCursor <= keep) return;
    this.records = this.records.filter(record => record.cursor <= keep);
    this.rebuild();
  }

  /**
   * A progress slot's newest snapshot, or null to clear it: `"message"` is the reply being
   * written, `"question"` what Pi asks, any other slot a running tool's call id.
   */
  progress(slot: string, snapshot: unknown): void {
    const data = asObject(snapshot);
    if (slot === "message") {
      const message = asObject(data?.message);
      const recorded = typeof message?.timestamp === "number" && this.recordedReplies.has(message.timestamp);
      this.live = message?.role === "assistant" && !recorded
        ? pieces(message, "assistant").map((piece, index) => ({
          id: `live#${index}`, key: replyKey(message.timestamp, index) ?? `live#${index}`,
          role: piece.role, text: piece.text, blocks: blocksFor(piece),
          timestamp: null, tool: piece.tool, images: piece.images,
        }))
        : [];
      return;
    }
    if (slot === "question") {
      if (!data) {
        this.question = null;
        return;
      }
      const kind = typeof data.kind === "string" && questionKinds.has(data.kind as QuestionKind) ? data.kind as QuestionKind : "custom";
      this.question = { kind, title: typeof data.title === "string" ? data.title : null };
      return;
    }
    if (!data) {
      this.toolOutput.delete(slot);
      return;
    }
    const output = visibleText(asObject(data.partialResult)?.content);
    this.toolOutput.set(slot, output);
    const index = this.messages.findIndex(message => message.tool?.callId === slot);
    if (index >= 0 && this.messages[index]!.tool?.status === "running") this.changeTool(index, tool => ({ ...tool, output }));
  }

  /** Whether Pi is working, as the host says; a settled Session has no reply or question showing. */
  settle(working: boolean): void {
    this.working = working;
    if (!working) {
      this.live = [];
      this.question = null;
    }
  }

  private rebuild(): void {
    this.messages = [];
    this.results = new Map();
    this.recordedReplies = new Set();
    this.delivered = new Set();
    this.queued = [];
    this.lastUserEntry = null;
    this.receipt = null;
    for (const record of this.records) this.applyRecord(record);
  }

  private applyRecord(record: TranscriptRecord): void {
    const entry = entryOf(record);
    if (entry.kind === "receipt") {
      this.receipt = entry.commandId;
      if (this.queued.some(prompt => prompt.commandId === entry.commandId)) {
        this.queued = this.queued.filter(prompt => prompt.commandId !== entry.commandId);
      }
      return;
    }
    if (entry.kind === "queued") {
      if (!this.queued.some(prompt => prompt.commandId === entry.prompt.commandId)) this.queued = [...this.queued, entry.prompt];
      return;
    }
    if (entry.kind !== "message") return;
    const { id, message } = entry;
    const role = message.role;
    if (typeof role !== "string") return;
    if (role === "user") {
      this.lastUserEntry = id;
      if (this.receipt !== null) this.delivered.add(this.receipt);
      this.receipt = null;
    }
    if (role === "toolResult") {
      this.recordResult(message);
      return;
    }
    const timestamp = typeof message.timestamp === "number" ? message.timestamp : null;
    if (role === "assistant") {
      this.live = [];
      if (timestamp !== null) this.recordedReplies.add(timestamp);
    }
    pieces(message, role).forEach((piece, index) => {
      const callId = piece.tool?.callId;
      const result = callId ? this.results.get(callId) : undefined;
      const output = callId ? this.toolOutput.get(callId) : undefined;
      const tool = piece.tool && result ? filled(piece.tool, result) : piece.tool && output ? { ...piece.tool, output } : piece.tool;
      const pieceId = index === 0 ? id : `${id}#${index}`;
      this.messages.push({
        id: pieceId, key: (role === "assistant" ? replyKey(timestamp, index) : null) ?? pieceId,
        role: piece.role, text: piece.text,
        blocks: blocksFor(piece), timestamp, tool, images: piece.images,
        ...(piece.files?.length ? { files: piece.files } : {}),
      });
    });
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
    this.toolOutput.delete(callId);
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

interface Piece {
  role: ChatRole;
  text: string;
  tool: ToolActivity | null;
  images: ChatImage[];
  files?: ChatFile[];
}

/** A reply's piece, by the stamp Pi gave the reply and the piece's place in it. */
function replyKey(timestamp: unknown, index: number): string | null {
  return typeof timestamp === "number" ? `reply:${timestamp}#${index}` : null;
}

function blocksFor(piece: Piece): MarkdownBlock[] {
  return piece.role === "assistant" || piece.role === "thinking" ? parseMarkdown(piece.text) : [];
}

function pieces(message: Record<string, unknown>, role: string): Piece[] {
  const content = message.content;
  if (role === "user") {
    const { text, files } = attachmentsIn(visibleText(content));
    const images = imagesIn(content);
    return text || images.length || files.length ? [{ role: "user", text, tool: null, images, ...(files.length ? { files } : {}) }] : [];
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

const ATTACHED_IMAGE = /^\[Attached image: .+ at .+ axo-asset:sha256:[0-9a-f]{64}\]$/u;
const ATTACHED_FILE = /^\[Attached file: (.+) \(([^,()]+), ([^()]+)\) at .+ axo-asset:sha256:([0-9a-f]{64})\]$/u;

/**
 * The lines pi-axo adds for a prompt's attachments, taken out of what the person said: an image's
 * line goes (the image shows itself), a file's becomes a download.
 */
export function attachmentsIn(text: string): { text: string; files: ChatFile[] } {
  const files: ChatFile[] = [];
  const kept = text.split("\n").filter(line => {
    if (ATTACHED_IMAGE.test(line)) return false;
    const file = ATTACHED_FILE.exec(line);
    if (!file) return true;
    files.push({ name: file[1]!, mimeType: file[2]!, size: file[3]!, hex: file[4]! });
    return false;
  });
  return { text: kept.join("\n").trim(), files };
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
