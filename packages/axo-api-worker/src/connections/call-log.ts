import { CONNECTIONS_LIMITS, type CallRecord } from "@axo/protocol";
import { seal, unseal } from "../auth/crypto";

/**
 * The account's call log (RFD0016, Call log): one row per tool call, written before the call is
 * sent so nothing runs unrecorded, and finished with its outcome. Inputs are sealed with a key
 * derived for this account alone; outputs are never kept. Rows older than 30 days are deleted.
 *
 * Every start and finish is also appended to a hash chain (`call_chain`): each event's hash is
 * SHA-256 of the previous event's hash and its own contents, so changing, inserting or removing
 * an event, or a row of the log that disagrees with its events, breaks every hash after it.
 * `verify()` replays the chain and checks the log against it. Deleting events past 30 days keeps
 * the hash of the last one deleted as the chain's anchor. The chain shows tampering with what is
 * stored here; it cannot stop someone who can rewrite the whole Durable Object from rewriting the
 * chain too, unless its head is also kept somewhere else.
 */

const DAY_MS = 24 * 60 * 60 * 1000;

type Row = {
  call_id: string;
  at: number;
  session_id: string | null;
  host_id: string | null;
  service: string;
  tool: string;
  target_host_id: string | null;
  duration_ms: number | null;
  outcome: "ok" | "error" | "unknown" | null;
  error: string | null;
  input_sealed: string;
};

export type CallStart = {
  callId: string;
  sessionId: string | null;
  hostId: string | null;
  service: string;
  tool: string;
  targetHostId: string | null;
  input: unknown;
};

type ChainEvent =
  | { kind: "start"; callId: string; at: number; sessionId: string | null; hostId: string | null; service: string; tool: string; targetHostId: string | null; input: string }
  | { kind: "finish"; callId: string; at: number; outcome: "ok" | "error" | "unknown"; error: string | null };

/** What `verify()` found: the chain's length and head, and the first event that does not hold, if any. */
export type ChainCheck = { verified: boolean; events: number; head: string | null; brokenAt: number | null; reason: string | null };

const GENESIS = "0".repeat(64);

export class CallLog {
  /** Appends run one at a time, so each one chains onto the one before it. */
  private tail: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly sql: SqlStorage,
    private readonly secret: string,
    private readonly accountId: string,
  ) {
    sql.exec(`CREATE TABLE IF NOT EXISTS connection_calls (
      call_id TEXT PRIMARY KEY, at REAL NOT NULL, session_id TEXT, host_id TEXT, service TEXT NOT NULL,
      tool TEXT NOT NULL, target_host_id TEXT, duration_ms INTEGER, outcome TEXT, error TEXT,
      input_sealed TEXT NOT NULL)`);
    sql.exec("CREATE INDEX IF NOT EXISTS connection_calls_at ON connection_calls (at)");
    sql.exec("CREATE INDEX IF NOT EXISTS connection_calls_service_at ON connection_calls (service, at)");
    sql.exec(`CREATE TABLE IF NOT EXISTS call_chain (
      seq INTEGER PRIMARY KEY, call_id TEXT NOT NULL, at REAL NOT NULL, body TEXT NOT NULL, prev TEXT NOT NULL, hash TEXT NOT NULL)`);
    sql.exec("CREATE TABLE IF NOT EXISTS call_chain_anchor (id INTEGER PRIMARY KEY CHECK (id = 1), seq INTEGER NOT NULL, hash TEXT NOT NULL)");
    // Calls logged before there was a chain join it first, in the order they were made.
    this.tail = this.serial(() => this.seed());
  }

  private get purpose(): string {
    return `connections-call-input\0${this.accountId}`;
  }

  async start(call: CallStart, now = Date.now()): Promise<void> {
    const text = JSON.stringify(call.input ?? null);
    // A third-party input may be large; the log keeps its first 64 KiB, marked as cut.
    const kept = text.length <= CONNECTIONS_LIMITS.scriptBytes
      ? call.input ?? null
      : { truncated: true, length: text.length, head: text.slice(0, CONNECTIONS_LIMITS.scriptBytes) };
    const sealed = await seal(this.secret, this.purpose, kept);
    await this.serial(async () => {
      this.forget(now - CONNECTIONS_LIMITS.logDays * DAY_MS);
      this.sql.exec(`INSERT INTO connection_calls (call_id, at, session_id, host_id, service, tool, target_host_id, input_sealed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, call.callId, now, call.sessionId, call.hostId, call.service, call.tool, call.targetHostId, sealed);
      await this.append({ kind: "start", callId: call.callId, at: now, sessionId: call.sessionId, hostId: call.hostId, service: call.service, tool: call.tool, targetHostId: call.targetHostId, input: sealed });
    });
  }

  async finish(callId: string, outcome: "ok" | "error" | "unknown", error: string | null, now = Date.now()): Promise<void> {
    await this.serial(async () => {
      const kept = error?.slice(0, 512) ?? null;
      const changed = this.sql.exec(`UPDATE connection_calls SET outcome = ?, error = ?, duration_ms = MAX(0, CAST(? - at AS INTEGER))
        WHERE call_id = ? AND outcome IS NULL`, outcome, kept, now, callId).rowsWritten;
      if (changed) await this.append({ kind: "finish", callId, at: now, outcome, error: kept });
    });
  }

  /** The chain's head: its length and last hash, cheap to read. */
  head(): { events: number; head: string | null } {
    const last = this.sql.exec<{ seq: number; hash: string }>("SELECT seq, hash FROM call_chain ORDER BY seq DESC LIMIT 1").toArray()[0];
    const count = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM call_chain").one().n;
    return { events: count, head: last?.hash ?? null };
  }

  /**
   * Replays the chain from its anchor, checking every hash, then checks that every row of the
   * log is what its events say: no row without a start, and each finished row as its finish.
   */
  async verify(): Promise<ChainCheck> {
    return this.serial(async () => {
      const anchor = this.sql.exec<{ seq: number; hash: string }>("SELECT seq, hash FROM call_chain_anchor WHERE id = 1").toArray()[0];
      let prev = anchor?.hash ?? GENESIS;
      let expectedSeq = (anchor?.seq ?? 0) + 1;
      let events = 0;
      const calls = new Map<string, { start?: Extract<ChainEvent, { kind: "start" }>; finish?: Extract<ChainEvent, { kind: "finish" }> }>();
      const broken = (seq: number | null, reason: string): ChainCheck => ({ verified: false, events, head: prev, brokenAt: seq, reason });
      for (const row of this.sql.exec<{ seq: number; call_id: string; body: string; prev: string; hash: string }>("SELECT * FROM call_chain ORDER BY seq")) {
        if (row.seq !== expectedSeq) return broken(row.seq, `event ${expectedSeq} is missing`);
        if (row.prev !== prev) return broken(row.seq, "does not follow the event before it");
        if (row.hash !== (await chainHash(prev, row.body))) return broken(row.seq, "its contents were changed");
        const event = JSON.parse(row.body) as ChainEvent;
        if (event.callId !== row.call_id) return broken(row.seq, "names another call");
        const entry = calls.get(event.callId) ?? {};
        if (event.kind === "start") entry.start = event;
        else entry.finish = event;
        calls.set(event.callId, entry);
        prev = row.hash;
        expectedSeq++;
        events++;
      }
      for (const row of this.sql.exec<Row>("SELECT * FROM connection_calls")) {
        const entry = calls.get(row.call_id);
        if (!entry?.start) return broken(null, `call ${row.call_id} is not in the chain`);
        const s = entry.start;
        if (s.at !== row.at || s.sessionId !== row.session_id || s.hostId !== row.host_id || s.service !== row.service || s.tool !== row.tool
          || s.targetHostId !== row.target_host_id || s.input !== row.input_sealed) return broken(null, `call ${row.call_id} was changed`);
        const f = entry.finish;
        if ((row.outcome ?? null) !== (f?.outcome ?? null) || (row.error ?? null) !== (f?.error ?? null)) return broken(null, `call ${row.call_id}'s outcome was changed`);
      }
      return { verified: true, events, head: events ? prev : anchor?.hash ?? null, brokenAt: null, reason: null };
    });
  }

  private serial<T>(work: () => Promise<T>): Promise<T> {
    const run = this.tail.then(work, work);
    this.tail = run.catch(() => undefined);
    return run;
  }

  private async append(event: ChainEvent): Promise<void> {
    const last = this.sql.exec<{ seq: number; hash: string }>("SELECT seq, hash FROM call_chain ORDER BY seq DESC LIMIT 1").toArray()[0]
      ?? this.sql.exec<{ seq: number; hash: string }>("SELECT seq, hash FROM call_chain_anchor WHERE id = 1").toArray()[0];
    const prev = last?.hash ?? GENESIS;
    const body = JSON.stringify(event);
    this.sql.exec("INSERT INTO call_chain (seq, call_id, at, body, prev, hash) VALUES (?, ?, ?, ?, ?, ?)",
      (last?.seq ?? 0) + 1, event.callId, event.at, body, prev, await chainHash(prev, body));
  }

  /**
   * Past 30 days, calls and their events go; the chain keeps the hash of the last event it lets
   * go, so what is left still verifies. Only whole calls go, so no call loses its start.
   */
  private forget(before: number): void {
    const old = this.sql.exec<{ call_id: string }>("SELECT call_id FROM connection_calls WHERE at < ?", before).toArray().map((r) => r.call_id);
    if (!old.length) return;
    this.sql.exec("DELETE FROM connection_calls WHERE at < ?", before);
    // The chain is cut at the newest event older than the cutoff, so it stays one unbroken run.
    const cut = this.sql.exec<{ seq: number; hash: string }>("SELECT seq, hash FROM call_chain WHERE at < ? ORDER BY seq DESC LIMIT 1", before).toArray()[0];
    if (!cut) return;
    const keep = this.sql.exec<{ n: number }>(
      "SELECT COUNT(*) AS n FROM call_chain c JOIN connection_calls l ON l.call_id = c.call_id WHERE c.seq <= ?", cut.seq).one().n;
    // A call still kept that started before the cut keeps the chain from being cut there.
    if (keep) return;
    this.sql.exec("DELETE FROM call_chain WHERE seq <= ?", cut.seq);
    this.sql.exec("INSERT INTO call_chain_anchor (id, seq, hash) VALUES (1, ?, ?) ON CONFLICT (id) DO UPDATE SET seq = excluded.seq, hash = excluded.hash", cut.seq, cut.hash);
  }

  /** Calls logged before the chain existed join it, start and finish, oldest first. */
  private async seed(): Promise<void> {
    const chained = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM call_chain").one().n;
    const anchored = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM call_chain_anchor").one().n;
    if (chained || anchored) return;
    for (const row of this.sql.exec<Row>("SELECT * FROM connection_calls ORDER BY at, call_id").toArray()) {
      await this.append({ kind: "start", callId: row.call_id, at: row.at, sessionId: row.session_id, hostId: row.host_id, service: row.service, tool: row.tool, targetHostId: row.target_host_id, input: row.input_sealed });
      if (row.outcome) await this.append({ kind: "finish", callId: row.call_id, at: row.at + (row.duration_ms ?? 0), outcome: row.outcome, error: row.error });
    }
  }

  /** Newest first, of every service or only `service`. A call still running reads as `unknown`. */
  async read(limit: number = CONNECTIONS_LIMITS.logPage, before?: string, service?: string, now = Date.now()): Promise<CallRecord[]> {
    const until = before ? Date.parse(before) : Number.MAX_SAFE_INTEGER;
    const page = Math.min(Math.max(limit, 1), CONNECTIONS_LIMITS.logPage);
    const since = now - CONNECTIONS_LIMITS.logDays * DAY_MS;
    const rows = (service
      ? this.sql.exec<Row>("SELECT * FROM connection_calls WHERE service = ? AND at < ? AND at >= ? ORDER BY at DESC, call_id LIMIT ?", service, until, since, page)
      : this.sql.exec<Row>("SELECT * FROM connection_calls WHERE at < ? AND at >= ? ORDER BY at DESC, call_id LIMIT ?", until, since, page)
    ).toArray();
    return Promise.all(rows.map(async (row) => ({
      callId: row.call_id,
      at: new Date(row.at).toISOString(),
      sessionId: row.session_id,
      hostId: row.host_id,
      service: row.service,
      tool: row.tool,
      targetHostId: row.target_host_id,
      durationMs: row.duration_ms ?? Math.max(0, Math.floor(now - row.at)),
      outcome: row.outcome ?? "unknown",
      error: row.error,
      input: (await unseal(this.secret, this.purpose, row.input_sealed, 4 * CONNECTIONS_LIMITS.scriptBytes + 1024)) ?? null,
    })));
  }
}

async function chainHash(prev: string, body: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${prev}\n${body}`)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}
