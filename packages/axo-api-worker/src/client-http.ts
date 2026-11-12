import { z } from "zod";
import { json } from "./auth/account-access";

/** The same client protocol over HTTPS: delivery is ordered and acknowledged, not a lossy poll. */
export const httpClientRequestSchema = z.object({
  connectionId: z.uuid(),
  action: z.enum(["connect", "send", "poll", "close"]),
  after: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).default(0),
  frame: z.string().max(200_000).optional(),
}).strict().refine(value => value.action === "send" ? value.frame !== undefined : value.frame === undefined);
export type HTTPClientRequest = z.infer<typeof httpClientRequestSchema>;

/** Structural subset used by the existing JSON-RPC router for either wire transport. */
export interface ClientConnection {
  send(frame: string): void;
  close(code?: number, reason?: string): void;
  serializeAttachment(value: unknown): void;
  deserializeAttachment(): unknown;
}

type ConnectionRow = {
  connection_id: string; session_digest: string; attachment: string; lease_until: number; sequence: number; closed: number;
};
export type HTTPPage = { frames: Array<{ sequence: number; frame: string }> };

/**
 * A bounded durable mailbox behind one account/client DO. Polls may be replayed; only an
 * explicit cursor acknowledgment retires data. A new connection fences all old requests.
 */
export class HTTPClientMailbox {
  private wake: (() => void) | undefined;

  constructor(private readonly storage: DurableObjectStorage) {
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS http_connection (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1), connection_id TEXT NOT NULL,
      session_digest TEXT NOT NULL, attachment TEXT NOT NULL, lease_until INTEGER NOT NULL,
      sequence INTEGER NOT NULL, closed INTEGER NOT NULL)`);
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS http_frames (
      sequence INTEGER PRIMARY KEY, frame TEXT NOT NULL, bytes INTEGER NOT NULL)`);
  }

  connect(id: string, digest: string, attachment: unknown, expiresAt: number): ClientConnection {
    this.storage.transactionSync(() => {
      this.storage.sql.exec("DELETE FROM http_frames");
      this.storage.sql.exec(`INSERT OR REPLACE INTO http_connection
        (singleton, connection_id, session_digest, attachment, lease_until, sequence, closed) VALUES (1, ?, ?, ?, ?, 0, 0)`,
        id, digest, JSON.stringify(attachment), Math.min(expiresAt, Date.now() + 45_000));
    });
    this.wake?.();
    return this.connection(id);
  }

  deadline(): number | undefined { return this.row()?.lease_until; }

  active(): ClientConnection | undefined {
    const row = this.row();
    return row && !row.closed && row.lease_until > Date.now() ? this.connection(row.connection_id) : undefined;
  }

  authorize(id: string, digest: string, expiresAt: number): ClientConnection | undefined {
    const row = this.row();
    if (!row || row.connection_id !== id || row.session_digest !== digest || row.closed || row.lease_until <= Date.now()) return undefined;
    this.storage.sql.exec("UPDATE http_connection SET lease_until = ? WHERE singleton = 1", Math.min(expiresAt, Date.now() + 45_000));
    return this.connection(id);
  }

  end(): void {
    this.storage.sql.exec("UPDATE http_connection SET closed = 1 WHERE singleton = 1");
    this.storage.sql.exec("DELETE FROM http_frames");
    this.wake?.();
  }

  page(id: string, after: number): HTTPPage | null {
    const row = this.row();
    if (!row || row.connection_id !== id || row.closed || after > row.sequence) return null;
    this.storage.sql.exec("DELETE FROM http_frames WHERE sequence <= ?", after);
    const frames: HTTPPage["frames"] = [];
    let bytes = 0;
    for (const frame of this.storage.sql.exec<{ sequence: number; frame: string; bytes: number }>(
      "SELECT sequence, frame, bytes FROM http_frames WHERE sequence > ? ORDER BY sequence LIMIT 16", after).toArray()) {
      if (frames.length && bytes + frame.bytes > 256 * 1024) break;
      frames.push({ sequence: frame.sequence, frame: frame.frame });
      bytes += frame.bytes;
    }
    return { frames };
  }

  /** One reader per connection. New polls wake an old one rather than keeping abandoned work. */
  async wait(id: string, after: number): Promise<void> {
    const page = this.page(id, after);
    if (!page || page.frames.length) return;
    this.wake?.();
    await new Promise<void>(resolve => {
      const finish = () => { clearTimeout(timer); if (this.wake === finish) this.wake = undefined; resolve(); };
      const timer = setTimeout(finish, 15_000);
      this.wake = finish;
      // No await between the initial check and publishing the waiter: a notice cannot be lost.
    });
  }

  private connection(id: string): ClientConnection {
    return {
      send: frame => this.enqueue(id, frame),
      close: () => { if (this.row()?.connection_id === id) this.end(); },
      deserializeAttachment: () => {
        const row = this.row();
        return row?.connection_id === id && !row.closed ? JSON.parse(row.attachment) as unknown : null;
      },
      serializeAttachment: value => {
        this.storage.sql.exec("UPDATE http_connection SET attachment = ? WHERE connection_id = ? AND closed = 0", JSON.stringify(value), id);
      },
    };
  }

  private enqueue(id: string, frame: string): void {
    this.storage.transactionSync(() => {
      const row = this.row();
      if (!row || row.connection_id !== id || row.closed || row.lease_until <= Date.now()) throw new Error("HTTP client closed");
      const queued = this.storage.sql.exec<{ n: number; bytes: number }>("SELECT COUNT(*) AS n, COALESCE(SUM(bytes), 0) AS bytes FROM http_frames").one();
      const bytes = new TextEncoder().encode(frame).byteLength;
      if (queued.n >= 512 || queued.bytes + bytes > 32 * 1024 * 1024) {
        this.end();
        return;
      }
      const sequence = row.sequence + 1;
      this.storage.sql.exec("INSERT INTO http_frames (sequence, frame, bytes) VALUES (?, ?, ?)", sequence, frame, bytes);
      this.storage.sql.exec("UPDATE http_connection SET sequence = ? WHERE singleton = 1", sequence);
    });
    this.wake?.();
  }

  private row(): ConnectionRow | undefined {
    return this.storage.sql.exec<ConnectionRow>("SELECT * FROM http_connection WHERE singleton = 1").toArray()[0];
  }
}

export async function readHTTPClientRequest(request: Request): Promise<HTTPClientRequest | null> {
  const reader = request.body?.getReader();
  if (!reader) return null;
  let size = 0;
  const chunks: Uint8Array[] = [];
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 512 * 1024) { await reader.cancel(); return null; }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const parsed = httpClientRequestSchema.safeParse(JSON.parse(new TextDecoder().decode(bytes)));
    return parsed.success ? parsed.data : null;
  } catch { return null; }
}

export function closedHTTPClient(): Response { return json({ error: "Client connection expired or replaced" }, 409); }
