import { CONNECTIONS_LIMITS, type CallRecord } from "@axo/protocol";
import { seal, unseal } from "../auth/crypto";

/**
 * The account's call log (RFD0016, Call log): one row per tool call, written before the call is
 * sent so nothing runs unrecorded, and finished with its outcome. Inputs are sealed with a key
 * derived for this account alone; outputs are never kept. Rows older than 30 days are deleted.
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

export class CallLog {
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
    this.sql.exec("DELETE FROM connection_calls WHERE at < ?", now - CONNECTIONS_LIMITS.logDays * DAY_MS);
    this.sql.exec(`INSERT INTO connection_calls (call_id, at, session_id, host_id, service, tool, target_host_id, input_sealed)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, call.callId, now, call.sessionId, call.hostId, call.service, call.tool, call.targetHostId, sealed);
  }

  finish(callId: string, outcome: "ok" | "error" | "unknown", error: string | null, now = Date.now()): void {
    this.sql.exec(`UPDATE connection_calls SET outcome = ?, error = ?, duration_ms = MAX(0, CAST(? - at AS INTEGER))
      WHERE call_id = ? AND outcome IS NULL`, outcome, error?.slice(0, 512) ?? null, now, callId);
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
