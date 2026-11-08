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
import type { EntryRecord, TranscriptHeader } from "@leostera/atxf";
import { addColumns, migrate, type SchemaStep } from "./schema";
import { ATXF_CONVERTER, AtxfTranslator, storedForm, withNative } from "./session-atxf";

/**
 * One Session's transcript (RFD0018, SessionDO): the lines of its Pi session file as hash-linked
 * records, in the order the host wrote them, with the epoch and the cuts that truncation made.
 * It serves reads and keeps no subscriber state. Named by (account, host, Session) and checks
 * that binding on every call.
 *
 * Beside each line it keeps the line's ATXF record (RFD0035), translated in cursor order after the
 * line commits. Translating only adds: it never changes a line, a hash, the chain or a cut.
 */

export type SessionBinding = { accountId: string; hostId: string; sessionId: string };

export function sessionDOName(accountId: string, hostId: string, sessionId: string): string {
  return `${uuid.parse(accountId)}:${uuid.parse(hostId)}:${uuid.parse(sessionId)}`;
}

export type SessionHead = { epoch: number; count: number; chain: string; heads: string[] };

/**
 * Every write's answer says what this object then holds, and its fence (RFD0032, Host sync from
 * the index): a HostDO trusts its index for a Session only after an answer that carries one.
 */
export type StoreAppendResult = (
  | { outcome: "committed"; epoch: number; count: number; chain: string; added: number; cleared: string[] }
  | { outcome: "gap" | "conflict" | "epoch" | "invalid" | "fenced"; epoch: number | null; count: number; chain: string | null }
) & { fence: number };

export type StoreTruncateResult = (
  | { outcome: "truncated"; epoch: number; count: number; chain: string }
  | { outcome: "mismatch" | "fenced"; epoch: number | null; count: number; chain: string | null }
) & { fence: number };

/** What a handshake reads: the head, and the fence it raised. */
export type SyncHead = { head: SessionHead | null; fence: number };

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
type Translation = { atxf_through: number; atxf_error: string | null };

/** A Session's ATXF so far (RFD0035): the header, and records `from` on with `native` restored. */
export type AtxfRead = {
  epoch: number | null;
  count: number;
  through: number;
  converter: string | null;
  error: string | null;
  header: TranscriptHeader | null;
  records: EntryRecord[];
};
type RecordRow = { cursor: number; id: string | null; hash: string; chain: string; format: string; line: string | null };

/** SQLite holds at most 2 MB in one value; longer lines are kept in parts of this many characters. */
const PART_CHARS = 500_000;
const encoder = new TextEncoder();
/** At most this many records, or about this many bytes of lines, are translated in one alarm. */
const TRANSLATE_RECORDS = 2048;
const TRANSLATE_BYTES = 16 * 1_048_576;
/** Lines read back per query when rebuilding the stream. */
const REPLAY_PAGE = 256;

/** The SessionDO's schema, one step per change (RFD0032, Release P). */
const SESSION_SCHEMA: readonly SchemaStep[] = [
  (sql) => {
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
  },
  (sql) => {
    // RFD0035: added columns only, with defaults, so no stored row is rewritten.
    addColumns(sql, "records", { format: "TEXT NOT NULL DEFAULT 'pi/3'", atxf_hash: "TEXT", atxf: "TEXT" });
    addColumns(sql, "transcript", { atxf_header: "TEXT", atxf_through: "INTEGER NOT NULL DEFAULT 0", atxf_converter: "TEXT", atxf_error: "TEXT" });
    sql.exec(`CREATE TABLE IF NOT EXISTS atxf_parts (
      cursor INTEGER NOT NULL, idx INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (cursor, idx))`);
  },
  (sql) => {
    // RFD0032: the highest fence a HostDO's head read carried; older writes are refused.
    sql.exec("CREATE TABLE IF NOT EXISTS write_fence (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), fence INTEGER NOT NULL)");
  },
];

export class AxoSessionDO extends DurableObject<Env> {
  /** The stream that translated records 1..`through` of `epoch`, while this object is in memory. */
  private translator: { epoch: number; through: number; read: AtxfTranslator } | undefined;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    migrate(ctx.storage, SESSION_SCHEMA);
  }

  /**
   * The head, for a HostDO's handshake, raising the fence to `fence` first: from now on a write
   * carrying an older fence, or none, is refused. A write a reset HostDO sent before this read can
   * then never land after it, behind an index the new HostDO trusts (RFD0032, fenceOnVerify).
   */
  async syncHead(binding: SessionBinding, fence: number): Promise<SyncHead> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    if (!Number.isSafeInteger(fence) || fence < 1) throw new Error("A fence is a positive integer");
    const sql = this.ctx.storage.sql;
    sql.exec(`INSERT INTO write_fence (singleton, fence) VALUES (1, ?)
      ON CONFLICT(singleton) DO UPDATE SET fence = MAX(fence, excluded.fence)`, fence);
    return { head: await this.head(binding), fence: this.fence() };
  }

  /** What the cloud holds, or null while it holds nothing. */
  async head(binding: SessionBinding): Promise<SessionHead | null> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    const transcript = this.transcript();
    if (!transcript) return null;
    await this.catchUp();
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
  async append(binding: SessionBinding, params: AppendParams, fence?: number): Promise<StoreAppendResult> {
    if (!this.owns(binding, true)) throw new Error("Session identity conflict");
    let transcript = this.transcript();
    const reject = (outcome: "gap" | "conflict" | "epoch" | "invalid" | "fenced"): StoreAppendResult => ({
      outcome, epoch: transcript?.epoch ?? null, count: this.count(), chain: transcript ? this.chainAt(this.count(), transcript)! : null, fence: this.fence(),
    });
    if (this.fenced(fence)) return reject("fenced");
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
    const result: StoreAppendResult = this.ctx.storage.transactionSync((): StoreAppendResult => {
      // Hashing awaited: a head read may have raised the fence since, and anything that changed the
      // transcript makes this batch a retry.
      if (this.fenced(fence)) return reject("fenced");
      const now = this.transcript();
      if (this.count() !== count || (now ? now.epoch !== committed.epoch || (count > 0 && now.header !== committed.header) : !before))
        return reject("gap");
      // A new header (only ever on an empty transcript) starts the translation over.
      sql.exec(`INSERT INTO transcript (singleton, header, header_hash, epoch) VALUES (1, ?, ?, ?)
        ON CONFLICT(singleton) DO UPDATE SET header = excluded.header, header_hash = excluded.header_hash,
          atxf_header = CASE WHEN header = excluded.header THEN atxf_header END,
          atxf_converter = CASE WHEN header = excluded.header THEN atxf_converter END,
          atxf_through = CASE WHEN header = excluded.header THEN atxf_through ELSE 0 END,
          atxf_error = CASE WHEN header = excluded.header THEN atxf_error END`,
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
      return { outcome: "committed", epoch: committed.epoch, count: count + rows.length, chain, added: rows.length, cleared: [...cleared], fence: this.fence() };
    });
    if (result.outcome === "committed") await this.translateAfterAppend(count);
    return result;
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
  async truncate(binding: SessionBinding, keep: number, expectedChain: string, fence?: number): Promise<StoreTruncateResult> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    const result = this.ctx.storage.transactionSync((): StoreTruncateResult => {
      const transcript = this.transcript();
      const refuse = (outcome: "mismatch" | "fenced"): StoreTruncateResult => ({
        outcome, epoch: transcript?.epoch ?? null, count: this.count(), chain: transcript ? this.chainAt(this.count(), transcript)! : null, fence: this.fence(),
      });
      if (this.fenced(fence)) return refuse("fenced");
      if (!transcript || this.chainAt(keep, transcript) !== expectedChain) return refuse("mismatch");
      const sql = this.ctx.storage.sql;
      const epoch = transcript.epoch + 1;
      sql.exec("DELETE FROM records WHERE cursor > ?", keep);
      sql.exec("DELETE FROM record_parts WHERE cursor > ?", keep);
      // The translations of the cut rows went with them; the stream read them, so it starts over.
      sql.exec("DELETE FROM atxf_parts WHERE cursor > ?", keep);
      sql.exec("UPDATE transcript SET atxf_through = MIN(atxf_through, ?), atxf_error = NULL", keep);
      this.translator = undefined;
      sql.exec(`UPDATE records SET referenced = (id IS NOT NULL AND id IN (
        SELECT value FROM records AS later, json_each(later.refs)))`);
      sql.exec("UPDATE transcript SET epoch = ?", epoch);
      sql.exec("INSERT INTO cuts (epoch, keep) VALUES (?, ?)", epoch, keep);
      return { outcome: "truncated", epoch, count: keep, chain: expectedChain, fence: this.fence() };
    });
    // The cut cleared any stop, since the line that caused it may be gone: try again if records wait.
    if (result.outcome === "truncated") await this.catchUp();
    return result;
  }

  /**
   * Records in cursor order, at most `limit` and about `SYNC.clientBytes` (a single larger record
   * comes alone). A reader of an older epoch gets `reset` instead, with the lowest cut since.
   */
  async read(binding: SessionBinding, request: ReadRequest): Promise<ReadResult> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    const transcript = this.transcript();
    if (!transcript) return { kind: "records", epoch: null, count: 0, records: [], older: null, header: null };
    await this.catchUp();
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
      "SELECT cursor, id, hash, chain, format, line FROM records WHERE cursor BETWEEN ? AND ? ORDER BY cursor", chosen[0]!, chosen.at(-1)!,
    ).toArray().map((row) => ({ cursor: row.cursor, id: row.id, format: row.format as typeof PI3_FORMAT, line: row.line ?? this.parts(row.cursor), hash: row.hash }) satisfies ClientRecord);
    const first = records[0]?.cursor ?? (request.after !== undefined ? request.after + 1 : range.from);
    return { kind: "records", epoch: transcript.epoch, count, records, older: first > 1 ? first : null, header: transcript.header };
  }

  /** The ATXF translation so far: the header, and up to `limit` records from cursor `from` (RFD0035). */
  async atxf(binding: SessionBinding, from = 1, limit = SYNC.clientRecords): Promise<AtxfRead> {
    if (!this.owns(binding)) throw new Error("Session identity conflict");
    const sql = this.ctx.storage.sql;
    const row = sql.exec<{ epoch: number; atxf_header: string | null; atxf_through: number; atxf_converter: string | null; atxf_error: string | null }>(
      "SELECT epoch, atxf_header, atxf_through, atxf_converter, atxf_error FROM transcript WHERE singleton = 1").toArray()[0];
    if (!row) return { epoch: null, count: 0, through: 0, converter: null, error: null, header: null, records: [] };
    // About `SYNC.clientBytes` of lines a page, as `read` sends; a larger record comes alone.
    const records: EntryRecord[] = [];
    let bytes = 0;
    for (const record of sql.exec<{ cursor: number; bytes: number }>(
      "SELECT cursor, bytes FROM records WHERE cursor >= ? AND cursor <= ? ORDER BY cursor LIMIT ?", from, row.atxf_through, limit).toArray()) {
      if (records.length > 0 && bytes + record.bytes > SYNC.clientBytes) break;
      bytes += record.bytes;
      const stored = sql.exec<{ line: string | null; atxf: string | null }>("SELECT line, atxf FROM records WHERE cursor = ?", record.cursor).one();
      records.push(withNative(stored.atxf ?? this.parts(record.cursor, "atxf_parts"), stored.line ?? this.parts(record.cursor)));
    }
    return {
      epoch: row.epoch, count: this.count(), through: row.atxf_through, converter: row.atxf_converter, error: row.atxf_error,
      header: row.atxf_header === null ? null : (JSON.parse(row.atxf_header) as TranscriptHeader), records,
    };
  }

  /** Translates what is left, a slice per alarm (RFD0035). */
  async alarm(): Promise<void> {
    if (this.translate(TRANSLATE_RECORDS, TRANSLATE_BYTES)) await this.ctx.storage.setAlarm(Date.now());
  }

  /**
   * Translates a batch just committed after `before` records, in this call when the stream is in
   * memory and caught up; otherwise, or for what remains, an alarm does it.
   */
  private async translateAfterAppend(before: number): Promise<void> {
    const behind = this.translation();
    if (!behind || behind.atxf_error !== null) return;
    const warm = this.translator !== undefined && this.translator.through === before;
    if (behind.atxf_through === before && (warm || before === 0) && !this.translate(SYNC.appendRecords, TRANSLATE_BYTES)) return;
    await this.ctx.storage.setAlarm(Date.now());
  }

  /**
   * Translates records after `atxf_through`, in cursor order, up to `records` records or about
   * `bytes` bytes of lines, rebuilding the stream first if this object lost it. Returns whether
   * more remain. Writes nothing but the ATXF columns, and stops for good, with `atxf_error`, at a
   * line the stream refuses or a stored translation it can't reproduce.
   */
  private translate(records: number, bytes: number): boolean {
    const sql = this.ctx.storage.sql;
    const transcript = this.transcript();
    const state = this.translation();
    if (!transcript || !state || state.atxf_error !== null) return false;
    const count = this.count();
    if (state.atxf_through >= count) return false;
    const stop = (at: number, error: unknown) => {
      this.translator = undefined;
      const message = error instanceof Error ? error.message : String(error);
      sql.exec("UPDATE transcript SET atxf_error = ?", `record ${at}: ${message}`);
      console.error(JSON.stringify({ event: "session.atxf_stopped", cursor: at, error: message }));
      return false;
    };

    let read: AtxfTranslator;
    try {
      read = this.resume(transcript, state.atxf_through);
    } catch (error) {
      return stop(state.atxf_through, error);
    }
    let cursor = state.atxf_through;
    let spent = 0;
    let refused: { at: number; error: unknown } | undefined;
    this.ctx.storage.transactionSync(() => {
      for (const row of sql.exec<{ cursor: number; line: string | null; bytes: number }>(
        "SELECT cursor, line, bytes FROM records WHERE cursor > ? ORDER BY cursor LIMIT ?", cursor, records).toArray()) {
        if (spent > 0 && spent + row.bytes > bytes) break;
        let record: EntryRecord & { hash: string };
        try {
          record = read.next(row.line ?? this.parts(row.cursor));
        } catch (error) {
          refused = { at: row.cursor, error };
          break;
        }
        const stored = storedForm(record);
        const inline = stored.length <= PART_CHARS;
        sql.exec("UPDATE records SET atxf_hash = ?, atxf = ? WHERE cursor = ?", record.hash, inline ? stored : null, row.cursor);
        sql.exec("DELETE FROM atxf_parts WHERE cursor = ?", row.cursor);
        if (!inline) splitParts(stored).forEach((data, idx) =>
          sql.exec("INSERT INTO atxf_parts (cursor, idx, data) VALUES (?, ?, ?)", row.cursor, idx, data));
        cursor = row.cursor;
        spent += row.bytes;
      }
      sql.exec("UPDATE transcript SET atxf_through = ?", cursor);
    });
    if (refused) return stop(refused.at, refused.error);
    this.translator = { epoch: transcript.epoch, through: cursor, read };
    return cursor < count;
  }

  /** Sets an alarm to translate, if records wait for it (RFD0035): a Session stored before, or one that fell behind. */
  private async catchUp(): Promise<void> {
    const state = this.translation();
    if (state && state.atxf_error === null && state.atxf_through < this.count()) await this.ctx.storage.setAlarm(Date.now());
  }

  /**
   * The stream that has read records 1..`through`: the one in memory, or a new one that reads them
   * back and must give the hashes stored for them. Starts the ATXF header on a fresh translation.
   */
  private resume(transcript: Transcript, through: number): AtxfTranslator {
    const held = this.translator;
    if (held && held.epoch === transcript.epoch && held.through === through) return held.read;
    this.translator = undefined;
    const sql = this.ctx.storage.sql;
    const read = new AtxfTranslator();
    const header = read.start(transcript.header);
    if (through === 0) {
      sql.exec("UPDATE transcript SET atxf_header = ?, atxf_converter = ?", JSON.stringify(header), ATXF_CONVERTER);
      return read;
    }
    const stored = sql.exec<{ atxf_header: string | null; atxf_converter: string | null }>("SELECT atxf_header, atxf_converter FROM transcript").one();
    if (stored.atxf_converter !== ATXF_CONVERTER) throw new Error(`translated with ${stored.atxf_converter}, not ${ATXF_CONVERTER}`);
    if (stored.atxf_header !== JSON.stringify(header)) throw new Error("the ATXF header no longer matches its line");
    for (let after = 0; after < through; after += REPLAY_PAGE) {
      for (const row of sql.exec<{ cursor: number; line: string | null; atxf_hash: string | null }>(
        "SELECT cursor, line, atxf_hash FROM records WHERE cursor > ? AND cursor <= ? ORDER BY cursor",
        after, Math.min(through, after + REPLAY_PAGE)).toArray()) {
        if (read.next(row.line ?? this.parts(row.cursor)).hash !== row.atxf_hash) throw new Error(`record ${row.cursor} no longer translates to its stored ATXF record`);
      }
    }
    return read;
  }

  /** The highest fence a head read carried; 0 before any. */
  private fence(): number {
    return this.ctx.storage.sql.exec<{ fence: number }>("SELECT fence FROM write_fence WHERE singleton = 1").toArray()[0]?.fence ?? 0;
  }

  /**
   * Whether a write with `fence` comes from before the last head read. A write with none comes
   * from a HostDO that doesn't fence (older code), and is refused once any head read fenced.
   */
  private fenced(fence: number | undefined): boolean {
    const current = this.fence();
    return fence === undefined ? current > 0 : fence < current;
  }

  private translation(): Translation | undefined {
    return this.ctx.storage.sql.exec<Translation>("SELECT atxf_through, atxf_error FROM transcript WHERE singleton = 1").toArray()[0];
  }

  private parts(cursor: number, table: "record_parts" | "atxf_parts" = "record_parts"): string {
    return this.ctx.storage.sql.exec<{ data: string }>(`SELECT data FROM ${table} WHERE cursor = ? ORDER BY idx`, cursor)
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

/** Adds the columns `table` does not have yet. */
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
