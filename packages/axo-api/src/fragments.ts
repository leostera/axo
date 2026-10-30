/**
 * Relay messages larger than one frame (RFD0016, Transport; modelled in specs/relay-fragments.ts).
 *
 * The sender serializes a message as usual. If it does not fit in one frame, its UTF-8 bytes are
 * cut into chunks and each chunk travels, base64-encoded, in an `axo.transport.fragment`
 * notification. The receiver collects every chunk of a message, then parses the whole as if it
 * had arrived in one frame. Fragments of a socket that closed are discarded with it, and a
 * message that breaks these bounds closes the socket.
 *
 * Running out of credit never closes a host socket: everything shares it. Messages have a
 * priority class, and senders interleave fragments by class, so a large reply never waits behind
 * an upload. A message that waits too long for credit is dropped on its own; if some of its
 * fragments went out, an `axo.transport.discard` notice tells the receiver to drop its partial.
 * A receiver also drops a partial that gets no fragment for a minute, and ignores late fragments
 * of a message it dropped.
 */
import { z } from "zod";
import { LIMITS } from "./contracts.js";

export const FRAGMENT_METHOD = "axo.transport.fragment";
export const DISCARD_METHOD = "axo.transport.discard";

/**
 * The order in which a sender spends credit: replies and control first, then durable upload
 * (transcripts), then ephemeral progress. Within a class, messages go in order.
 */
export const PRIORITY = { control: 0, durable: 1, ephemeral: 2 } as const;
export type Priority = (typeof PRIORITY)[keyof typeof PRIORITY];

export const FRAGMENTS = {
  /** Bytes of the message in one fragment: base64 makes it 61,440 characters, under one frame with its envelope. */
  chunkBytes: 46_080,
  /** The largest message that may be reassembled. */
  messageBytes: 2 * 1_048_576,
  /** At most this many fragmented messages may be partly received on one socket. */
  partialPerSocket: 4,
  /** A message that waits this long for credit is dropped, and the socket stays open. */
  creditTimeoutMs: 30_000,
  /** A partial message that gets no fragment for this long is dropped by its receiver. */
  partialTimeoutMs: 60_000,
  /** Dropped messages a receiver remembers per socket, to ignore their late fragments. */
  discardedPerSocket: 64,
} as const;

/** Fragments one message may have: enough for the largest message. */
export const MAX_FRAGMENTS = Math.ceil(FRAGMENTS.messageBytes / FRAGMENTS.chunkBytes);

export const fragmentParamsSchema = z
  .object({
    messageId: z.string().regex(/^[A-Za-z0-9_-]{1,64}$/),
    index: z.number().int().min(0).max(MAX_FRAGMENTS - 1),
    count: z.number().int().min(2).max(MAX_FRAGMENTS),
    data: z.string().max(Math.ceil(FRAGMENTS.chunkBytes / 3) * 4).regex(/^[A-Za-z0-9+/]*={0,2}$/),
  })
  .strict()
  .refine((fragment) => fragment.index < fragment.count, "index must be below count");
export type FragmentParams = z.infer<typeof fragmentParamsSchema>;

export const fragmentSchema = z
  .object({ jsonrpc: z.literal("2.0"), method: z.literal(FRAGMENT_METHOD), params: fragmentParamsSchema })
  .strict();

export const discardParamsSchema = z.object({ messageId: fragmentParamsSchema.shape.messageId }).strict();
export const discardSchema = z
  .object({ jsonrpc: z.literal("2.0"), method: z.literal(DISCARD_METHOD), params: discardParamsSchema })
  .strict();

/** The notice that tells a receiver to drop a message's partial. */
export function discardNotice(messageId: string): string {
  return JSON.stringify({ jsonrpc: "2.0", method: DISCARD_METHOD, params: { messageId } });
}

const encoder = new TextEncoder();

/**
 * The frames that carry `raw`: `[raw]` when it fits in one frame, otherwise its fragments in order.
 * Null when it is larger than any reassembled message may be.
 */
export function splitMessage(raw: string, messageId: string): string[] | null {
  const bytes = encoder.encode(raw);
  if (bytes.byteLength <= LIMITS.frameBytes) return [raw];
  if (bytes.byteLength > FRAGMENTS.messageBytes) return null;
  const count = Math.ceil(bytes.byteLength / FRAGMENTS.chunkBytes);
  const frames: string[] = [];
  for (let index = 0; index < count; index++) {
    const chunk = bytes.subarray(index * FRAGMENTS.chunkBytes, (index + 1) * FRAGMENTS.chunkBytes);
    frames.push(JSON.stringify({ jsonrpc: "2.0", method: FRAGMENT_METHOD, params: { messageId, index, count, data: toBase64(chunk) } }));
  }
  return frames;
}

/** How far a partly received message has got. */
export type PartialMessage = { count: number; received: number; bytes: number };

/**
 * Where a receiver keeps partial messages, one fragment at a time. The Durable Object keeps them
 * in SQLite, one row per fragment, so hibernation loses nothing and no row nears its size limit.
 */
export interface PartialStore {
  partial(messageId: string): PartialMessage | undefined;
  has(messageId: string, index: number): boolean;
  add(messageId: string, index: number, count: number, data: string, bytes: number): void;
  /** Every fragment's data in order, removing the message. */
  take(messageId: string): string[];
  /** Messages partly received. */
  count(): number;
  /** Drops a partial and remembers its message, so late fragments of it are ignored. */
  discard(messageId: string): void;
  discarded(messageId: string): boolean;
}

export type FragmentOutcome =
  /** More fragments are needed. */
  | { status: "partial" }
  /** A late fragment of a message the receiver dropped. */
  | { status: "ignored" }
  /** Every fragment is here: `raw` is the whole message, to be parsed as one frame would be. */
  | { status: "complete"; raw: string }
  /** The sender broke the rules; the receiver closes the socket. */
  | { status: "invalid"; reason: string };

/** Takes one fragment notification's params into `store`. */
export function receiveFragment(store: PartialStore, params: unknown): FragmentOutcome {
  const parsed = fragmentParamsSchema.safeParse(params);
  if (!parsed.success) return { status: "invalid", reason: "malformed fragment" };
  const { messageId, index, count, data } = parsed.data;
  if (store.discarded(messageId)) return { status: "ignored" };
  let bytes: number;
  try {
    bytes = fromBase64(data).byteLength;
  } catch {
    return { status: "invalid", reason: "malformed fragment" };
  }
  // Every fragment but the last is exactly one chunk, so a message cannot outgrow its count.
  if (index < count - 1 ? bytes !== FRAGMENTS.chunkBytes : bytes === 0 || bytes > FRAGMENTS.chunkBytes)
    return { status: "invalid", reason: "fragment size" };

  const known = store.partial(messageId);
  if (known && known.count !== count) return { status: "invalid", reason: "fragment count changed" };
  if (!known && store.count() >= FRAGMENTS.partialPerSocket) return { status: "invalid", reason: "too many partial messages" };
  if (store.has(messageId, index)) return { status: "invalid", reason: "fragment repeated" };
  if ((known?.bytes ?? 0) + bytes > FRAGMENTS.messageBytes) return { status: "invalid", reason: "message too large" };
  store.add(messageId, index, count, data, bytes);
  if ((known?.received ?? 0) + 1 < count) return { status: "partial" };

  const chunks = store.take(messageId).map(fromBase64);
  const whole = new Uint8Array(chunks.reduce((n, c) => n + c.byteLength, 0));
  let offset = 0;
  for (const chunk of chunks) {
    whole.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { status: "complete", raw: new TextDecoder("utf-8", { fatal: true }).decode(whole) };
  } catch {
    return { status: "invalid", reason: "message is not UTF-8" };
  }
}

/** A `PartialStore` in memory, for a receiver whose partials need not survive a restart. */
export class MemoryPartialStore implements PartialStore {
  private readonly messages = new Map<string, { count: number; bytes: number; chunks: Map<number, string> }>();
  private readonly dropped: string[] = [];
  discard(messageId: string) {
    this.messages.delete(messageId);
    if (this.dropped.includes(messageId)) return;
    this.dropped.push(messageId);
    if (this.dropped.length > FRAGMENTS.discardedPerSocket) this.dropped.shift();
  }
  discarded(messageId: string) { return this.dropped.includes(messageId); }
  partial(messageId: string): PartialMessage | undefined {
    const m = this.messages.get(messageId);
    return m && { count: m.count, received: m.chunks.size, bytes: m.bytes };
  }
  has(messageId: string, index: number) { return this.messages.get(messageId)?.chunks.has(index) ?? false; }
  add(messageId: string, index: number, count: number, data: string, bytes: number) {
    const m = this.messages.get(messageId) ?? { count, bytes: 0, chunks: new Map() };
    m.chunks.set(index, data);
    m.bytes += bytes;
    this.messages.set(messageId, m);
  }
  take(messageId: string): string[] {
    const m = this.messages.get(messageId);
    this.messages.delete(messageId);
    return m ? [...m.chunks.entries()].sort(([a], [b]) => a - b).map(([, data]) => data) : [];
  }
  count() { return this.messages.size; }
  clear() { this.messages.clear(); this.dropped.length = 0; }
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}
