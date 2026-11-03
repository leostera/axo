/**
 * A turn of another Mac's Session, played in this Pi as if its model were answering (RFD0026).
 *
 * pi-axo's remote mode starts a turn here for each user message the other Mac writes. The
 * `axo-remote` provider answers each model call with that Mac's next assistant message: it
 * streams the message's progress as it is written there, then ends with the record itself. Tool
 * calls run proxies that wait for that Mac's tool results. So Pi draws the turn with its own
 * components, and nothing runs on this Mac.
 *
 * `MirrorTurn` walks the copy; `AssistantStream` turns what it finds into Pi's stream events.
 * Neither knows Pi: the copy and the stream come in as interfaces.
 */
import type { AssistantMessage, AssistantMessageEvent } from "@earendil-works/pi-ai";

type Json = Record<string, unknown>;

function asObject(value: unknown): Json | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Json : null;
}

/** The copy as the mirror reads it: it only grows, unless the whole turn is given up. */
export interface MirrorSource {
  readonly length: number;
  entry(index: number): Json | null;
  /** The message being written on the other Mac, as its latest progress shows it. */
  liveMessage(): Json | null;
  /** The latest progress of a tool call running there. */
  toolProgress(toolCallId: string): Json | null;
  /** Resolves on the next change to the copy or its progress, or after `ms`. */
  changed(ms: number, signal?: AbortSignal): Promise<void>;
}

export type MirrorStep =
  | { kind: "assistant"; message: Json }
  /** The other Mac's turn went somewhere this one cannot follow: a steer or another prompt. */
  | { kind: "desync" }
  | { kind: "stopped" };

export interface MirroredToolResult {
  readonly content: unknown[];
  readonly details: unknown;
  readonly isError: boolean;
}

const POLL_MS = 250;

function messageAt(source: MirrorSource, index: number): Json | null {
  const entry = source.entry(index);
  return entry?.type === "message" ? asObject(entry.message) : null;
}

export class MirrorTurn {
  private next: number;
  private given = false;
  /** Timestamps of the messages already answered, so stale progress is not drawn again. */
  private readonly answered = new Set<unknown>();

  constructor(private readonly source: MirrorSource, readonly userIndex: number) {
    this.next = userIndex + 1;
  }

  /** Ends the turn here: every wait returns at once. */
  giveUp(): void {
    this.given = true;
  }

  get givenUp(): boolean {
    return this.given;
  }

  /**
   * The turn's next assistant message, following its progress meanwhile. Tool results, receipts
   * and custom entries are passed over: the proxies show the results, the final redraw the rest.
   */
  async step(signal: AbortSignal | undefined, follow: (live: Json) => void): Promise<MirrorStep> {
    for (;;) {
      if (this.given || signal?.aborted) return { kind: "stopped" };
      while (this.next < this.source.length) {
        const message = messageAt(this.source, this.next);
        this.next += 1;
        if (message?.role === "assistant") {
          this.answered.add(message.timestamp);
          return { kind: "assistant", message };
        }
        if (message?.role === "user") return { kind: "desync" };
      }
      const live = this.source.liveMessage();
      if (live && live.role === "assistant" && !this.answered.has(live.timestamp)) follow(live);
      await this.source.changed(POLL_MS, signal);
    }
  }

  /** The other Mac's result for a tool call of this turn, showing its progress meanwhile. */
  async toolResult(toolCallId: string, signal: AbortSignal | undefined, progress: (partial: unknown) => void): Promise<MirroredToolResult | null> {
    for (;;) {
      if (this.given || signal?.aborted) return null;
      for (let index = this.userIndex + 1; index < this.source.length; index += 1) {
        const message = messageAt(this.source, index);
        if (message?.role === "toolResult" && message.toolCallId === toolCallId) {
          return {
            content: Array.isArray(message.content) ? message.content : [],
            details: message.details ?? {},
            isError: message.isError === true,
          };
        }
      }
      const partial = this.source.toolProgress(toolCallId)?.partialResult;
      if (partial !== undefined) progress(partial);
      await this.source.changed(POLL_MS, signal);
    }
  }
}

/** Where `AssistantStream` puts its events: Pi's `AssistantMessageEventStream`. */
export interface EventSink {
  push(event: AssistantMessageEvent): void;
}

export interface MirrorModel {
  readonly api: string;
  readonly provider: string;
  readonly id: string;
}

type Block = AssistantMessage["content"][number];
type TextKey = "text" | "thinking";

function textKey(type: unknown): TextKey | null {
  return type === "text" ? "text" : type === "thinking" ? "thinking" : null;
}

/**
 * One assistant message, streamed as the other Mac writes it. Events stay balanced: each block
 * starts once, in order, and ends once, and the stream ends with exactly one `done` or `error`.
 */
export class AssistantStream {
  readonly out: AssistantMessage;
  private readonly started: boolean[] = [];
  private closed = false;

  constructor(private readonly sink: EventSink, private readonly model: MirrorModel) {
    this.out = {
      role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "stop", timestamp: Date.now(),
    } as AssistantMessage;
    this.sink.push({ type: "start", partial: this.out });
  }

  private push(event: Record<string, unknown>): void {
    this.sink.push({ ...event, partial: this.out } as AssistantMessageEvent);
  }

  /** Draws the message so far. Blocks that do not extend what is drawn wait for the record. */
  follow(live: Json): void {
    if (this.closed) return;
    const blocks = Array.isArray(live.content) ? live.content : [];
    blocks.forEach((value, index) => this.extend(index, asObject(value), false));
  }

  private extend(index: number, block: Json | null, final: boolean): boolean {
    if (!block) return false;
    const content = this.out.content as Block[];
    const existing = content[index] as unknown as Json | undefined;
    if (existing && existing.type !== block.type) return false;
    if (!existing && index !== content.length) return false;
    const key = textKey(block.type);
    if (block.type === "toolCall") {
      if (!existing) {
        content.push({ ...block, arguments: asObject(block.arguments) ?? {} } as unknown as Block);
        this.started[index] = true;
        this.push({ type: "toolcall_start", contentIndex: index });
      }
      if (final) {
        content[index] = block as unknown as Block;
        this.push({ type: "toolcall_end", contentIndex: index, toolCall: block });
      }
      return true;
    }
    if (!key) {
      // A block Pi streams no events for (an image, say): it only arrives with the record.
      if (final && !existing) content.push(block as unknown as Block);
      return final;
    }
    if (!existing) {
      content.push({ type: block.type, [key]: "" } as unknown as Block);
      this.started[index] = true;
      this.push({ type: `${key}_start`, contentIndex: index });
    }
    const drawn = content[index] as unknown as Json;
    const have = String(drawn[key] ?? "");
    const want = String(block[key] ?? "");
    if (want.length > have.length && want.startsWith(have)) {
      drawn[key] = want;
      this.push({ type: `${key}_delta`, contentIndex: index, delta: want.slice(have.length) });
    }
    if (final) {
      content[index] = block as unknown as Block;
      this.push({ type: `${key}_end`, contentIndex: index, content: want });
    }
    return true;
  }

  /** Ends with the other Mac's record: the message Pi keeps is exactly what was written there. */
  finish(record: Json): void {
    if (this.closed) return;
    this.closed = true;
    const blocks = Array.isArray(record.content) ? record.content : [];
    const followed = blocks.every((value, index) => this.extend(index, asObject(value), true));
    const message = { ...record, api: this.model.api, provider: this.model.provider, model: this.model.id } as unknown as AssistantMessage;
    // Should the record not extend what was drawn, the message still ends as written there.
    if (!followed) (this.out as { content: unknown }).content = message.content;
    const reason = message.stopReason;
    if (reason === "error" || reason === "aborted") this.sink.push({ type: "error", reason, error: message });
    // A record is finished; a "pending" one (never written as such) ends as a plain stop.
    else this.sink.push({ type: "done", reason: reason === "pending" ? "stop" : reason, message });
  }

  /** Ends without a record: the turn here stops, and the redraw that follows shows what was. */
  stop(why: string): void {
    if (this.closed) return;
    this.closed = true;
    const message = { ...this.out, stopReason: "aborted", errorMessage: why } as AssistantMessage;
    this.sink.push({ type: "error", reason: "aborted", error: message });
  }
}
