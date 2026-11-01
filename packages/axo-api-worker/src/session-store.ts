import { DurableObject } from "cloudflare:workers";
import {
  PI3_FORMAT,
  PI3_MAX_LINE_BYTES,
  SYNC,
  pi3Entry,
  pi3FoldChain,
  pi3HeaderHash,
  pi3RecordHash,
  uuid,
  type AppendParams,
  type ClientRecord,
} from "@axo/protocol";

/**
 * One Session's transcript (RFD0018, SessionDO): the lines of its Pi session file as hash-linked
 * records, in the order the host wrote them, with the epoch and the cuts that truncation made.
 * It serves reads and keeps no subscriber state. Named by (account, host, Session) and checks
 * that binding on every call.
 */

export type SessionBinding = { accountId: string; hostId: string; sessionId: string };

export function sessionDOName(accountId: string, hostId: string, sessionId: string): string {
  return `${uuid.parse(accountId)}:${uuid.parse(hostId)}:${uuid.parse(sessionId)}`;
}

export type SessionHead = { epoch: number; count: number; chain: string; heads: string[] };

export type StoreAppendResult =
  | { outcome: "committed"; epoch: number; count: number; chain: string; added: number; cleared: string[] }
  | { outcome: "gap" | "conflict" | "epoch" | "invalid"; epoch: number | null; count: number; chain: string | null };

export type StoreTruncateResult =
  | { outcome: "truncated"; epoch: number; count: number; chain: string }
  | { outcome: "mismatch" };

/** What a reader asks for: records after a cursor, before one, or the last few. */
export type ReadRequest = {
  /** The epoch the reader's cursors belong to; null when it holds nothing. */
  epoch: number | null;
  after?: number;
  before?: number;
  last?: number;
  limit: number;
};

export type ReadResult =
  | { kind: "records"; epoch: number | null; count: number; records: ClientRecord[]; older: number | null; header: string | null }
  /** The reader's epoch is over: drop records past `keep`, the lowest cut since its epoch. */
  | { kind: "reset"; epoch: number; keep: number };

type Transcript = { header: string; header_hash: string; epoch: number };
type RecordRow = { cursor: number; id: string | null; hash: string; chain: string; line: string | null };

/** SQLite holds at most 2 MB in one value; longer lines are kept in parts of this many characters. */
const PART_CHARS = 500_000;
const encoder = new TextEncoder();

export class AxoSessionDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    // RFD0018 replaces the extension-event history; each Session is rebuilt by its first sync.
    sql.exec("DROP TABLE IF EXISTS pi_events");
    sql.exec(`CREATE TABLE IF NOT EXISTS session_identity (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      account_id TEXT NOT NULL, host_id TEXT NOT NULL, session_id TEXT NOT NULL)`);
    sql.exec(`CREATE TABLE IF NOT EXISTS transcript (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      header TEXT NOT NULL, header_hash TEXT NOT NULL, epoch INTEGER NOT NULL)`);
    // `refs` lists the ids of earlier records this one references; `referenced` marks records
    // some later record references, so the rest are the heads.
    sql.exec(`CREATE TABLE IF NOT EXISTS records (
      cursor INTEGER PRIMARY KEY, id TEXT, hash TEXT NOT NULL, chain TEXT NOT NULL,
      refs TEXT NOT NULL, referenced INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL, line TEXT)`);
    sql.exec("CREATE INDEX IF NOT EXISTS records_by_id ON records(id, cursor)");
    sql.exec(`CREATE TABLE IF NOT EXISTS record_parts (
      cursor INTEGER NOT NULL, idx INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (cursor, idx))`);
    sql.exec("CREATE TABLE IF NOT EXISTS cuts (epoch INTEGER PRIMARY KEY, keep INTEGER NOT NULL)");
  }

  /** What the cloud holds, or null while it holds nothing. */
  async head(binding: SessionBinding): Promise<SessionHead | null> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    const transcript = this.transcript();
    if (!transcript) return null;
    const sql = this.ctx.storage.sql;
    return {
      epoch: transcript.epoch,
      count: this.count(),
      chain: this.chainAt(this.count(), transcript)!,
      heads: sql.exec<{ hash: string }>("SELECT hash FROM records WHERE referenced = 0 OR id IS NULL ORDER BY hash").toArray().map((row) => row.hash),
    };
  }

  /**
   * Commits a batch in one transaction. A batch that starts at or before the count is a retry:
   * its overlap must match what is stored, and only its new tail is added.
   */
  async append(binding: SessionBinding, params: AppendParams): Promise<StoreAppendResult> {
    if (!this.owns(binding, true)) throw new Error("Session identity conflict");
    let transcript = this.transcript();
    const reject = (outcome: "gap" | "conflict" | "epoch" | "invalid"): StoreAppendResult => ({
      outcome, epoch: transcript?.epoch ?? null, count: this.count(), chain: transcript ? this.chainAt(this.count(), transcript)! : null,
    });
    if (params.records.some((record) => encoder.encode(record.line).byteLength > PI3_MAX_LINE_BYTES)) return reject("invalid");
    if (!transcript || (params.header !== undefined && params.header !== transcript.header && this.count() === 0 && params.from === 1)) {
      if (params.header === undefined || pi3Entry(params.header) === null) return reject(params.header === undefined ? "gap" : "invalid");
      if (params.epoch !== (transcript?.epoch ?? 1)) return reject("epoch");
      transcript = { header: params.header, header_hash: await pi3HeaderHash(params.header), epoch: transcript?.epoch ?? 1 };
    }
    if (params.epoch !== transcript.epoch) return reject("epoch");
    if (params.header !== undefined && params.header !== transcript.header) return reject("conflict");
    const count = this.count();
    if (params.from > count + 1) return reject("gap");

    const overlap = Math.min(params.records.length, count - params.from + 1);
    const sql = this.ctx.storage.sql;
    for (let index = 0; index < overlap; index++) {
      const stored = sql.exec<{ hash: string }>("SELECT hash FROM records WHERE cursor = ?", params.from + index).one();
      if (stored.hash !== params.records[index]!.hash) return reject("conflict");
    }

    // Hash the new tail against what is stored and the batch so far.
    const batchIds = new Map<string, string>();
    const hashOf = (id: string) => batchIds.get(id) ?? sql.exec<{ hash: string }>(
      "SELECT hash FROM records WHERE id = ? ORDER BY cursor DESC LIMIT 1", id).toArray()[0]?.hash;
    let chain = this.chainAt(count, transcript)!;
    const rows: Array<{ id: string | null; hash: string; chain: string; refs: string[]; line: string }> = [];
    const cleared = new Set<string>();
    for (const record of params.records.slice(overlap)) {
      const entry = pi3Entry(record.line);
      if (!entry) return reject("invalid");
      if (entry.id !== record.id) return reject("conflict");
      const hash = await pi3RecordHash(transcript.header_hash, record.line, entry, hashOf);
      if (hash !== record.hash) return reject("conflict");
      chain = await pi3FoldChain(chain, hash);
      rows.push({ id: entry.id, hash, chain, refs: entry.refs.flatMap(([, id]) => (id !== null && hashOf(id) !== undefined ? [id] : [])), line: record.line });
      if (entry.id !== null) batchIds.set(entry.id, hash);
      const slot = clearedSlot(record.line);
      if (slot) cleared.add(slot);
    }

    const committed = transcript;
    const before = !this.transcript();
    return this.ctx.storage.transactionSync(() => {
      // Hashing awaited; anything that changed the transcript since makes this batch a retry.
      const now = this.transcript();
      if (this.count() !== count || (now ? now.epoch !== committed.epoch || (count > 0 && now.header !== committed.header) : !before))
        return reject("gap");
      sql.exec(`INSERT INTO transcript (singleton, header, header_hash, epoch) VALUES (1, ?, ?, ?)
        ON CONFLICT(singleton) DO UPDATE SET header = excluded.header, header_hash = excluded.header_hash`,
        committed.header, committed.header_hash, committed.epoch);
      rows.forEach((row, index) => {
        const cursor = count + index + 1;
        const bytes = encoder.encode(row.line).byteLength;
        const inline = row.line.length <= PART_CHARS;
        sql.exec("INSERT INTO records (cursor, id, hash, chain, refs, bytes, line) VALUES (?, ?, ?, ?, ?, ?, ?)",
          cursor, row.id, row.hash, row.chain, JSON.stringify(row.refs), bytes, inline ? row.line : null);
        if (!inline) splitParts(row.line).forEach((data, idx) =>
          sql.exec("INSERT INTO record_parts (cursor, idx, data) VALUES (?, ?, ?)", cursor, idx, data));
        for (const id of row.refs) sql.exec("UPDATE records SET referenced = 1 WHERE id = ? AND referenced = 0", id);
      });
      return { outcome: "committed", epoch: committed.epoch, count: count + rows.length, chain, added: rows.length, cleared: [...cleared] } as const;
    });
  }

  /** The cloud's chain after each position, or null past its count; position 0 is the header. */
  async chains(binding: SessionBinding, positions: number[]): Promise<{ epoch: number | null; chains: Array<string | null> }> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    const transcript = this.transcript();
    return { epoch: transcript?.epoch ?? null, chains: positions.map((position) => (transcript ? this.chainAt(position, transcript) ?? null : null)) };
  }

  /**
   * Cuts the transcript back to `keep` records if its chain there is `expectedChain`, starts a
   * new epoch, and records the cut so readers of older epochs learn where to drop to.
   */
  async truncate(binding: SessionBinding, keep: number, expectedChain: string): Promise<StoreTruncateResult> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    return this.ctx.storage.transactionSync(() => {
      const transcript = this.transcript();
      if (!transcript || this.chainAt(keep, transcript) !== expectedChain) return { outcome: "mismatch" } as const;
      const sql = this.ctx.storage.sql;
      const epoch = transcript.epoch + 1;
      sql.exec("DELETE FROM records WHERE cursor > ?", keep);
      sql.exec("DELETE FROM record_parts WHERE cursor > ?", keep);
      sql.exec(`UPDATE records SET referenced = (id IS NOT NULL AND id IN (
        SELECT value FROM records AS later, json_each(later.refs)))`);
      sql.exec("UPDATE transcript SET epoch = ?", epoch);
      sql.exec("INSERT INTO cuts (epoch, keep) VALUES (?, ?)", epoch, keep);
      return { outcome: "truncated", epoch, count: keep, chain: expectedChain } as const;
    });
  }

  /**
   * Records in cursor order, at most `limit` and about `SYNC.clientBytes` (a single larger record
   * comes alone). A reader of an older epoch gets `reset` instead, with the lowest cut since.
   */
  async read(binding: SessionBinding, request: ReadRequest): Promise<ReadResult> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    const transcript = this.transcript();
    if (!transcript) return { kind: "records", epoch: null, count: 0, records: [], older: null, header: null };
    const sql = this.ctx.storage.sql;
    if (request.epoch !== null && request.epoch !== transcript.epoch) {
      const keep = sql.exec<{ keep: number | null }>("SELECT MIN(keep) AS keep FROM cuts WHERE epoch > ?", request.epoch).one().keep;
      return { kind: "reset", epoch: transcript.epoch, keep: request.epoch > transcript.epoch ? 0 : keep ?? 0 };
    }
    const count = this.count();
    const limit = Math.min(request.limit, SYNC.clientRecords);
    let range: { from: number; to: number };
    if (request.after !== undefined) range = { from: request.after + 1, to: Math.min(count, request.after + limit) };
    else {
      const end = request.before !== undefined ? Math.min(count, request.before - 1) : count;
      range = { from: Math.max(1, end - (request.last ?? limit) + 1), to: end };
    }
    const sizes = sql.exec<{ cursor: number; bytes: number }>(
      "SELECT cursor, bytes FROM records WHERE cursor BETWEEN ? AND ? ORDER BY cursor", range.from, range.to).toArray();
    // Keep the end nearest the reader's cursor: the start for `after`, the end otherwise.
    const kept = request.after !== undefined ? sizes : sizes.reverse();
    let bytes = 0;
    const chosen: number[] = [];
    for (const row of kept) {
      if (chosen.length > 0 && bytes + row.bytes > SYNC.clientBytes) break;
      bytes += row.bytes;
      chosen.push(row.cursor);
    }
    chosen.sort((a, b) => a - b);
    const records = chosen.length === 0 ? [] : sql.exec<RecordRow>(
      "SELECT cursor, id, hash, chain, line FROM records WHERE cursor BETWEEN ? AND ? ORDER BY cursor", chosen[0]!, chosen.at(-1)!,
    ).toArray().map((row) => ({ cursor: row.cursor, id: row.id, format: PI3_FORMAT, line: row.line ?? this.parts(row.cursor), hash: row.hash }) satisfies ClientRecord);
    const first = records[0]?.cursor ?? (request.after !== undefined ? request.after + 1 : range.from);
    return { kind: "records", epoch: transcript.epoch, count, records, older: first > 1 ? first : null, header: transcript.header };
  }

  private parts(cursor: number): string {
    return this.ctx.storage.sql.exec<{ data: string }>("SELECT data FROM record_parts WHERE cursor = ? ORDER BY idx", cursor)
      .toArray().map((row) => row.data).join("");
  }

  private transcript(): Transcript | undefined {
    return this.ctx.storage.sql.exec<Transcript>("SELECT header, header_hash, epoch FROM transcript WHERE singleton = 1").toArray()[0];
  }

  private count(): number {
    return this.ctx.storage.sql.exec<{ count: number | null }>("SELECT MAX(cursor) AS count FROM records").one().count ?? 0;
  }

  private chainAt(position: number, transcript: Transcript): string | undefined {
    if (position === 0) return transcript.header_hash;
    return this.ctx.storage.sql.exec<{ chain: string }>("SELECT chain FROM records WHERE cursor = ?", position).toArray()[0]?.chain;
  }

  /** Whether this object belongs to `binding`; with `bind`, an unbound object takes it. */
  private owns(binding: SessionBinding, bind = false): boolean {
    const sql = this.ctx.storage.sql;
    const identity = sql.exec<{ account_id: string; host_id: string; session_id: string }>(
      "SELECT account_id, host_id, session_id FROM session_identity WHERE singleton = 1").toArray()[0];
    if (!identity) {
      if (bind) sql.exec("INSERT INTO session_identity (singleton, account_id, host_id, session_id) VALUES (1, ?, ?, ?)",
        binding.accountId, binding.hostId, binding.sessionId);
      return true;
    }
    return identity.account_id === binding.accountId && identity.host_id === binding.hostId && identity.session_id === binding.sessionId;
  }
}

/**
 * The progress slot a durable record completes (RFD0018, Ephemeral progress): an assistant
 * message ends the `"message"` slot, and a tool result ends its tool call's slot.
 */
export function clearedSlot(line: string): string | null {
  try {
    const entry = JSON.parse(line) as { type?: unknown; message?: { role?: unknown; toolCallId?: unknown } };
    if (entry.type !== "message") return null;
    if (entry.message?.role === "assistant") return "message";
    if (entry.message?.role === "toolResult" && typeof entry.message.toolCallId === "string") return entry.message.toolCallId;
  } catch {
    // Not a record a slot waits for.
  }
  return null;
}

/** Cuts a line into parts that each fit a SQLite value, never between a surrogate pair. */
function splitParts(line: string): string[] {
  const parts: string[] = [];
  for (let start = 0; start < line.length;) {
    let end = Math.min(line.length, start + PART_CHARS);
    const last = line.charCodeAt(end - 1);
    if (end < line.length && last >= 0xd800 && last <= 0xdbff) end -= 1;
    parts.push(line.slice(start, end));
    start = end;
  }
  return parts;
}
