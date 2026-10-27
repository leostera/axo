import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import {
  piEventPageResultSchema,
  storedPiEventSchema,
  type StoredPiEvent,
  uuid,
} from "@axo/protocol";

export { storedPiEventSchema };
export type { StoredPiEvent };
export const sessionEventPageResultSchema = piEventPageResultSchema;

export const SESSION_EVENT_MAX_BYTES = 60_000;

/**
 * Pi events that only show progress: each `message.update` repeats the whole message so far and
 * `tool.update` a tool's output so far, and the finished `message.end` / `tool.end` follows.
 * They go to the clients watching, live, and are never stored: history keeps what was said.
 */
export const TRANSIENT_PI_EVENTS: ReadonlySet<string> = new Set(["message.update", "tool.update"]);

/** Room kept for everything around a trimmed tool result's text. */
const TRIMMED_TEXT_BYTES = 40_000;

/**
 * Makes an event fit history. Only a tool's result is commonly too large (a long command's
 * output): its text is cut to the first 40 kB and the message marked `truncated`, so a client can
 * ask the Mac for the rest. Any other event too large to keep is not kept (`null`).
 */
export function fitForHistory(data: unknown): { data: unknown; trimmedFrom?: number } | null {
  const bytes = byteLength(data);
  if (bytes === null) return null;
  if (bytes <= SESSION_EVENT_MAX_BYTES) return { data };
  const message = (data as { message?: { role?: unknown; content?: unknown } } | null)?.message;
  if (typeof data !== "object" || data === null || message?.role !== "toolResult") return null;
  const text = typeof message.content === "string"
    ? message.content
    : Array.isArray(message.content)
      ? message.content.map(block => (block as { type?: unknown; text?: unknown }).type === "text" ? String((block as { text?: unknown }).text ?? "") : "").join("")
      : "";
  const trimmed = {
    ...data,
    message: { ...message, content: [{ type: "text", text: cutUtf8(text, TRIMMED_TEXT_BYTES) }], truncated: true },
  };
  return byteLength(trimmed)! <= SESSION_EVENT_MAX_BYTES ? { data: trimmed, trimmedFrom: bytes } : null;
}

function byteLength(value: unknown): number | null {
  try {
    const encoded = JSON.stringify(value);
    return encoded === undefined ? null : new TextEncoder().encode(encoded).byteLength;
  } catch {
    return null;
  }
}

/** The longest prefix of `text` within `limit` UTF-8 bytes, never splitting a character. */
function cutUtf8(text: string, limit: number): string {
  const bytes = new TextEncoder().encode(text);
  if (bytes.byteLength <= limit) return text;
  return new TextDecoder().decode(bytes.slice(0, limit)).replace(/\uFFFD$/u, "");
}
const sessionIdSchema = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const piSessionIdSchema = z.string().min(1).max(128).refine(value => !/[\u0000-\u001f\u007f]/u.test(value));
const streamSequenceSchema = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const eventDataSchema = z.unknown().refine(value => {
  try {
    const encoded = JSON.stringify(value);
    return encoded !== undefined && new TextEncoder().encode(encoded).byteLength <= SESSION_EVENT_MAX_BYTES;
  } catch {
    return false;
  }
}, `Pi event data must be JSON and no larger than ${SESSION_EVENT_MAX_BYTES} bytes`);

export const sessionEventBindingSchema = z.object({
  accountId: uuid,
  hostId: uuid,
  hostGeneration: uuid,
  sessionId: sessionIdSchema,
  piSessionId: piSessionIdSchema,
  streamId: uuid,
  sequence: streamSequenceSchema,
  name: z.string().min(1).max(128).refine(value => !/[\u0000-\u001f\u007f]/u.test(value)),
  data: eventDataSchema,
}).strict();
export type SessionEventBinding = z.infer<typeof sessionEventBindingSchema>;

export const sessionEventPageRequestSchema = z.object({
  accountId: uuid,
  hostId: uuid,
  sessionId: sessionIdSchema,
  before: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER).default(0),
  limit: z.number().int().min(1).max(50).default(20),
}).strict();

type SessionIdentity = {
  account_id: string;
  host_id: string;
  session_id: number;
};
type StoredEventRow = {
  id: number;
  host_generation: string;
  pi_session_id: string;
  stream_id: string;
  stream_sequence: number;
  name: string;
  data_json: string;
  received_at: number;
};

/** Pages are newest first; `before` is the id of the oldest event already seen (0 starts at the newest). */
/** Durable, account-private Pi event history for exactly one host-owned Axo Session. */
export class AxoSessionDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS session_identity (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        account_id TEXT NOT NULL,
        host_id TEXT NOT NULL,
        session_id INTEGER NOT NULL
      )
    `);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS pi_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        host_generation TEXT NOT NULL,
        pi_session_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        stream_sequence INTEGER NOT NULL,
        name TEXT NOT NULL,
        data_json TEXT NOT NULL CHECK (json_valid(data_json)),
        received_at INTEGER NOT NULL,
        UNIQUE (host_generation, pi_session_id, stream_id, stream_sequence)
      )
    `);
  }

  async append(binding: unknown): Promise<
    | { ok: true; eventId: number; inserted: boolean }
    | { ok: false; reason: "invalid" | "identityConflict" | "eventConflict" }
  > {
    const parsed = sessionEventBindingSchema.safeParse(binding);
    if (!parsed.success) return { ok: false, reason: "invalid" };
    const input = parsed.data;
    const dataJson = JSON.stringify(input.data);
    if (dataJson === undefined) return { ok: false, reason: "invalid" };
    return this.ctx.storage.transactionSync(() => {
      const identity = this.identity();
      if (identity && (
        identity.account_id !== input.accountId ||
        identity.host_id !== input.hostId ||
        identity.session_id !== input.sessionId
      )) return { ok: false, reason: "identityConflict" };
      if (!identity) {
        this.ctx.storage.sql.exec(
          "INSERT INTO session_identity (singleton, account_id, host_id, session_id) VALUES (1, ?, ?, ?)",
          input.accountId,
          input.hostId,
          input.sessionId,
        );
      }
      const sql = this.ctx.storage.sql;
      const existing = sql.exec<{ id: number; name: string; data_json: string }>(
        `SELECT id, name, data_json FROM pi_events
         WHERE host_generation = ? AND pi_session_id = ? AND stream_id = ? AND stream_sequence = ?`,
        input.hostGeneration,
        input.piSessionId,
        input.streamId,
        input.sequence,
      ).toArray()[0];
      if (existing) {
        if (existing.name !== input.name || existing.data_json !== dataJson)
          return { ok: false, reason: "eventConflict" };
        return { ok: true, eventId: existing.id, inserted: false };
      }
      sql.exec(`INSERT INTO pi_events (
        host_generation, pi_session_id, stream_id, stream_sequence, name, data_json, received_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
        input.hostGeneration,
        input.piSessionId,
        input.streamId,
        input.sequence,
        input.name,
        dataJson,
        Date.now(),
      );
      return { ok: true, eventId: sql.exec<{ id: number }>("SELECT last_insert_rowid() AS id").one().id, inserted: true };
    });
  }

  async list(request: unknown): Promise<
    | { ok: true; events: StoredPiEvent[]; next: number | null }
    | { ok: false; reason: "invalid" | "identityConflict" }
  > {
    const parsed = sessionEventPageRequestSchema.safeParse(request);
    if (!parsed.success) return { ok: false, reason: "invalid" };
    const input = parsed.data;
    const identity = this.identity();
    if (!identity) return { ok: true, events: [], next: null };
    if (identity.account_id !== input.accountId || identity.host_id !== input.hostId || identity.session_id !== input.sessionId)
      return { ok: false, reason: "identityConflict" };
    const rows = this.ctx.storage.sql.exec<StoredEventRow>(
      `SELECT * FROM pi_events WHERE (? = 0 OR id < ?) ORDER BY id DESC LIMIT ?`,
      input.before,
      input.before,
      input.limit + 1,
    ).toArray();
    const hasMore = rows.length > input.limit;
    const page = rows.slice(0, input.limit).map(row => ({
      id: row.id,
      hostGeneration: row.host_generation,
      piSessionId: row.pi_session_id,
      streamId: row.stream_id,
      sequence: row.stream_sequence,
      name: row.name,
      data: JSON.parse(row.data_json) as unknown,
      receivedAt: row.received_at,
    }));
    return {
      ok: true,
      events: page,
      next: hasMore ? page.at(-1)!.id : null,
    };
  }

  private identity(): SessionIdentity | undefined {
    return this.ctx.storage.sql.exec<SessionIdentity>(
      "SELECT account_id, host_id, session_id FROM session_identity WHERE singleton = 1",
    ).toArray()[0];
  }
}

export function sessionDOName(accountId: string, hostId: string, sessionId: number): string {
  const parsedAccount = uuid.parse(accountId);
  const parsedHost = uuid.parse(hostId);
  const parsedSession = sessionIdSchema.parse(sessionId);
  return `${parsedAccount}:${parsedHost}:${parsedSession}`;
}
