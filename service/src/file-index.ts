import { FILE_PAGE_SIZE, FileFault, MAX_FILE_COUNT, MAX_WORKBENCH_BYTES, sharedFileSchema, uploadRequestSchema, sessionFileId, type SharedFile, type UploadRequest } from "../../shared/files";
import type { Principal } from "./access";

type Row = { seq: number; id: string; session_id: string; request_id: string; metadata: string; state: SharedFile["state"]; object_key: string | null; lease_until: number; expires_at: number; writer_finished: 0 | 1; signed_upload: 0 | 1 };
export type UploadLease = { file: SharedFile; key: string; expiresAt: number };
const DAY = 24 * 60 * 60 * 1000;
const LEASE = 5 * 60 * 1000;

/** Durable metadata only. Network I/O never holds a SQLite transaction. */
export class FileIndex {
  private readonly registeredSessions = new Set<string>();

  constructor(private readonly storage: DurableObjectStorage, private readonly bucket: R2Bucket,
              private readonly changed: (sessionId: string, revision: number) => void) {
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS file_sessions (id TEXT PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS shared_files (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, session_id TEXT NOT NULL,
        request_id TEXT NOT NULL, metadata TEXT NOT NULL, state TEXT NOT NULL,
        object_key TEXT, lease_until INTEGER NOT NULL DEFAULT 0, expires_at INTEGER NOT NULL,
        writer_finished INTEGER NOT NULL DEFAULT 0, last_maintenance INTEGER NOT NULL DEFAULT 0,
        signed_upload INTEGER NOT NULL DEFAULT 0,
        UNIQUE(session_id, request_id));
      CREATE INDEX IF NOT EXISTS shared_files_session ON shared_files(session_id, seq);
      CREATE TABLE IF NOT EXISTS file_revision (singleton INTEGER PRIMARY KEY, revision INTEGER NOT NULL);
      INSERT OR IGNORE INTO file_revision VALUES (1, 0);
      CREATE TABLE IF NOT EXISTS file_rate (singleton INTEGER PRIMARY KEY, started INTEGER NOT NULL, count INTEGER NOT NULL);`);
    const columns = storage.sql.exec<{ name: string }>("PRAGMA table_info(shared_files)").toArray();
    if (!columns.some(column => column.name === "writer_finished")) {
      storage.sql.exec("ALTER TABLE shared_files ADD COLUMN writer_finished INTEGER NOT NULL DEFAULT 0");
      storage.sql.exec("UPDATE shared_files SET writer_finished=1 WHERE state='ready'");
    }
    if (!columns.some(column => column.name === "signed_upload")) storage.sql.exec("ALTER TABLE shared_files ADD COLUMN signed_upload INTEGER NOT NULL DEFAULT 0");
    if (!columns.some(column => column.name === "last_maintenance")) storage.sql.exec("ALTER TABLE shared_files ADD COLUMN last_maintenance INTEGER NOT NULL DEFAULT 0");
  }

  registerSession(id: string): void {
    sessionFileId.parse(id);
    if (this.registeredSessions.has(id)) return;
    const exists = this.storage.sql.exec("SELECT id FROM file_sessions WHERE id=?", id).toArray().length > 0;
    if (!exists) {
      const count = this.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM file_sessions").one().count;
      if (count >= 1000) throw new FileFault(413, "Registered session limit reached.");
      this.storage.sql.exec("INSERT INTO file_sessions VALUES (?)", id);
    }
    this.registeredSessions.add(id);
  }

  admitRequest(): void {
    const now = Date.now();
    const current = this.storage.sql.exec<{ started: number; count: number }>("SELECT started, count FROM file_rate WHERE singleton=1").toArray()[0];
    if (current && now - current.started < 60_000 && current.count >= 120) throw new FileFault(429, "File request limit reached. Try again later.");
    if (!current || now - current.started >= 60_000) this.storage.sql.exec("INSERT OR REPLACE INTO file_rate VALUES (1, ?, 1)", now);
    else this.storage.sql.exec("UPDATE file_rate SET count=count+1 WHERE singleton=1");
  }

  reserve(sessionId: string, input: UploadRequest, origin: Principal["role"]): SharedFile {
    this.requireSession(sessionId);
    const attributes = uploadRequestSchema.parse(input);
    const existing = this.storage.sql.exec<Row>("SELECT * FROM shared_files WHERE session_id=? AND request_id=?", sessionId, attributes.requestId).toArray()[0];
    if (existing) {
      const file = this.present(existing);
      const matches = file.filename === attributes.filename && file.mediaType === attributes.mediaType
        && file.byteLength === attributes.byteLength && file.sha256 === attributes.sha256 && file.origin === origin;
      if (!matches) throw new FileFault(409, "Upload request ID already names a different file.");
      return file;
    }
    const all = this.storage.sql.exec<{ count: number; bytes: number }>(
      "SELECT COUNT(*) AS count, COALESCE(SUM(CASE WHEN state!='deleted' THEN json_extract(metadata, '$.byteLength') ELSE 0 END),0) AS bytes FROM shared_files").one();
    if (all.count >= MAX_FILE_COUNT || all.bytes + attributes.byteLength > MAX_WORKBENCH_BYTES) throw new FileFault(413, "Session file capacity reached. Delete files before uploading more.");
    const file: SharedFile = { id: crypto.randomUUID(), sessionId, origin, createdAt: Date.now(), state: "pending",
      filename: attributes.filename, mediaType: attributes.mediaType, byteLength: attributes.byteLength, sha256: attributes.sha256 };
    this.storage.sql.exec("INSERT INTO shared_files (id,session_id,request_id,metadata,state,expires_at) VALUES (?,?,?,?,?,?)",
      file.id, sessionId, attributes.requestId, JSON.stringify(file), "pending", Date.now() + DAY);
    this.invalidate(sessionId);
    return file;
  }

  get(sessionId: string, id: string): SharedFile { return this.present(this.row(sessionId, id)); }

  list(sessionId: string, cursor?: string) {
    this.requireSession(sessionId);
    if (cursor !== undefined && !/^[1-9][0-9]{0,15}$/.test(cursor)) throw new FileFault(400, "Invalid file cursor.");
    const before = cursor === undefined ? Number.MAX_SAFE_INTEGER : Number(cursor);
    if (!Number.isSafeInteger(before)) throw new FileFault(400, "Invalid file cursor.");
    const rows = this.storage.sql.exec<Row>("SELECT * FROM shared_files WHERE session_id=? AND seq<? ORDER BY seq DESC LIMIT ?", sessionId, before, FILE_PAGE_SIZE + 1).toArray();
    const page = rows.slice(0, FILE_PAGE_SIZE);
    return { files: page.map(row => this.present(row)), nextCursor: rows.length > FILE_PAGE_SIZE ? String(page.at(-1)!.seq) : null, revision: this.revision() };
  }

  beginUpload(sessionId: string, id: string, signed = false): UploadLease | { file: SharedFile } {
    const row = this.row(sessionId, id);
    if (row.state === "ready") return { file: this.present(row) };
    if (row.state !== "pending" || row.expires_at <= Date.now()) throw new FileFault(410, "Upload is cancelled or expired.");
    if (signed && row.signed_upload === 1 && row.object_key && row.lease_until > Date.now()) {
      return { file: this.present(row), key: row.object_key, expiresAt: row.lease_until };
    }
    // A previous attempt is reconciled before allowing another key to consume capacity.
    if (row.object_key) throw new FileFault(409, "Upload is in progress or awaiting recovery. Check its status shortly.");
    const active = this.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM shared_files WHERE state='pending' AND object_key IS NOT NULL").one().count;
    if (active >= 3) throw new FileFault(429, "Too many concurrent uploads.");
    const key = `files/${id}/${crypto.randomUUID()}`;
    const expiresAt = Date.now() + LEASE;
    this.storage.sql.exec("UPDATE shared_files SET object_key=?, lease_until=?, writer_finished=0, signed_upload=? WHERE id=?", key, expiresAt, signed ? 1 : 0, id);
    return { file: this.present(row), key, expiresAt };
  }

  commit(sessionId: string, id: string, key: string): SharedFile {
    const row = this.row(sessionId, id);
    if (row.state === "ready" && row.object_key === key) return this.present(row);
    if (row.state !== "pending" || row.object_key !== key || row.expires_at <= Date.now() || (row.signed_upload === 0 && row.lease_until <= Date.now())) {
      throw new FileFault(409, "Upload completion is stale. Check the file status.");
    }
    this.storage.sql.exec("UPDATE shared_files SET state='ready', lease_until=CASE WHEN signed_upload=0 THEN 0 ELSE lease_until END, writer_finished=CASE WHEN signed_upload=0 THEN 1 ELSE 0 END WHERE id=?", id);
    this.invalidate(sessionId);
    return this.get(sessionId, id);
  }

  async completeSignedUpload(sessionId: string, id: string): Promise<SharedFile> {
    const row = this.row(sessionId, id);
    if (row.state === "ready") return this.present(row);
    if (row.signed_upload !== 1 || !row.object_key || row.state !== "pending") throw new FileFault(409, "No active signed upload.");
    const object = await this.bucket.head(row.object_key);
    if (!matchesSnapshot(object, this.present(row))) throw new FileFault(422, "Uploaded file length or checksum did not match. Check status before retrying.");
    return this.commit(sessionId, id, row.object_key);
  }

  finishAttempt(sessionId: string, id: string, key: string): void {
    // Only the upload handler, after BOTH pipe and R2 promises settle, can prove quiescence.
    this.row(sessionId, id);
    this.storage.sql.exec("UPDATE shared_files SET writer_finished=1 WHERE id=? AND object_key=? AND signed_upload=0", id, key);
  }

  contentKey(sessionId: string, id: string): string {
    const row = this.row(sessionId, id);
    if (row.state !== "ready" || !row.object_key) throw new FileFault(row.state === "pending" ? 409 : 410, "File is not available.");
    return row.object_key;
  }

  async remove(sessionId: string, id: string): Promise<SharedFile> {
    const row = this.row(sessionId, id);
    if (row.state === "deleted") return this.present(row);
    this.storage.sql.exec("UPDATE shared_files SET state='deleting' WHERE id=?", id);
    this.invalidate(sessionId);
    if (row.signed_upload === 1) {
      await this.finishSignedDelete(row);
      return this.get(sessionId, id);
    }
    // An upload can still be draining until its lease ends. Keep its key/capacity tracked.
    if (row.writer_finished === 0 && row.lease_until > Date.now()) return this.get(sessionId, id);
    await this.finishDelete(row);
    return this.get(sessionId, id);
  }

  async maintain(): Promise<void> {
    const now = Date.now();
    const rows = this.storage.sql.exec<Row>("SELECT * FROM shared_files WHERE (state='deleting' AND (signed_upload=1 OR writer_finished=1 OR lease_until+60000<=?)) OR (state='pending' AND (expires_at<=? OR (object_key IS NOT NULL AND (writer_finished=1 OR lease_until+60000<=?)))) ORDER BY last_maintenance,expires_at LIMIT 80", now, now, now).toArray();
    for (const row of rows) {
      this.storage.sql.exec("UPDATE shared_files SET last_maintenance=? WHERE id=?", Date.now(), row.id);
      try { await this.reconcile(row, now); }
      catch { /* Keep durable state/capacity and retry at the next alarm. */ }
    }
  }

  private async reconcile(row: Row, now: number): Promise<void> {
    if (row.state === "deleting" || row.expires_at <= now) {
      if (row.state !== "deleting") {
        this.storage.sql.exec("UPDATE shared_files SET state='deleting' WHERE id=?", row.id);
        this.invalidate(row.session_id);
      }
      if (row.signed_upload === 1) await this.finishSignedDelete(row);
      else if (row.writer_finished === 1 || row.lease_until + 60_000 <= now) await this.finishDelete(row);
      return;
    }
    if (row.object_key && (row.writer_finished === 1 || row.lease_until + 60_000 <= now)) await this.recoverAttempt(row, row.object_key);
  }

  private async recoverAttempt(row: Row, key: string): Promise<void> {
    const object = await this.bucket.head(key);
    const current = this.row(row.session_id, row.id);
    if (current.state !== "pending" || current.object_key !== key || current.expires_at <= Date.now()) return;
    if (matchesSnapshot(object, this.present(current))) {
      this.storage.sql.exec("UPDATE shared_files SET state='ready', lease_until=CASE WHEN signed_upload=0 THEN 0 ELSE lease_until END, writer_finished=CASE WHEN signed_upload=0 THEN 1 ELSE 0 END WHERE id=?", row.id);
      this.invalidate(row.session_id);
      return;
    }
    // Missing HEAD + elapsed lease does NOT prove an outstanding R2 put cannot finish.
    if (current.signed_upload === 0 && current.writer_finished === 0 && !object) return;
    await this.releaseFailedAttempt(current, key);
  }

  private async releaseFailedAttempt(row: Row, key: string): Promise<void> {
    if (row.signed_upload === 1) await this.fenceSignedAttempt(key);
    else await this.bucket.delete(key);
    const latest = this.row(row.session_id, row.id);
    if (latest.state === "pending" && latest.object_key === key) this.storage.sql.exec("UPDATE shared_files SET object_key=NULL, lease_until=0 WHERE id=?", row.id);
  }

  nextMaintenance(): number | undefined {
    const row = this.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM shared_files WHERE state IN ('pending','deleting')").one();
    return row.count ? Date.now() + 60_000 : undefined;
  }

  private async fenceSignedAttempt(key: string): Promise<void> {
    // Never make a signed key absent again. A zero-byte sentinel atomically removes
    // content AND keeps every signed If-None-Match:* PUT permanently fenced.
    await this.bucket.put(key, new Uint8Array(), { customMetadata: { axo: "deleted-upload" } });
  }

  private async finishSignedDelete(row: Row): Promise<void> {
    if (row.object_key) await this.fenceSignedAttempt(row.object_key);
    const current = this.row(row.session_id, row.id);
    if (current.state !== "deleting" || current.object_key !== row.object_key) return;
    this.storage.sql.exec("UPDATE shared_files SET state='deleted', lease_until=0, writer_finished=1 WHERE id=?", row.id);
    this.invalidate(row.session_id);
  }

  private async finishDelete(row: Row): Promise<void> {
    if (row.object_key && row.writer_finished === 0) {
      // A visible immutable object proves the single conditional writer committed.
      if (!await this.bucket.head(row.object_key)) return;
      this.storage.sql.exec("UPDATE shared_files SET writer_finished=1 WHERE id=? AND object_key=?", row.id, row.object_key);
    }
    if (row.object_key) await this.bucket.delete(row.object_key);
    const current = this.row(row.session_id, row.id);
    if (current.state !== "deleting" || current.object_key !== row.object_key) return;
    this.storage.sql.exec("UPDATE shared_files SET state='deleted', object_key=NULL, lease_until=0 WHERE id=?", row.id);
    this.invalidate(row.session_id);
  }

  private row(sessionId: string, id: string): Row {
    this.requireSession(sessionId);
    const row = this.storage.sql.exec<Row>("SELECT * FROM shared_files WHERE session_id=? AND id=?", sessionId, id).toArray()[0];
    if (!row) throw new FileFault(404, "File not found in this session.");
    return row;
  }
  private requireSession(id: string): void {
    if (!sessionFileId.safeParse(id).success || !this.storage.sql.exec("SELECT id FROM file_sessions WHERE id=?", id).toArray().length) throw new FileFault(404, "Unknown session. Connect the Mac first.");
  }
  private present(row: Row): SharedFile { return sharedFileSchema.parse({ ...JSON.parse(row.metadata), state: row.state }); }
  private revision(): number { return this.storage.sql.exec<{ revision: number }>("SELECT revision FROM file_revision WHERE singleton=1").one().revision; }
  private invalidate(sessionId: string): void {
    this.storage.sql.exec("UPDATE file_revision SET revision=revision+1 WHERE singleton=1");
    this.changed(sessionId, this.revision());
  }
}

function matchesSnapshot(object: R2Object | null, file: SharedFile): boolean {
  const digest = object?.checksums.sha256;
  if (!digest || object?.size !== file.byteLength) return false;
  const checksum = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  return checksum === file.sha256;
}
