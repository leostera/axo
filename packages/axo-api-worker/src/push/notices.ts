import { z } from "zod";
import { ApnsInformationNotice, apnsDestinationSchema, type ApnsProvider } from "./apns";
import { notifyInputSchema } from "./content";
import type { PushRegistrationRow } from "./registry";
import { recordApiEvent } from "../observability";

const ownerSchema = z.strictObject({ accountId: z.uuid(), hostId: z.uuid(), sessionId: z.uuid() });
export type NoticeOwner = z.infer<typeof ownerSchema>;
type NoticeRow = { account_id: string; id: string; host_id: string; session_id: string; title: string;
  message: string; created_at: number; expires_at: number; next_at: number | null; passes: number };
type Dependencies = {
  activeHost(accountId: string, hostId: string): Promise<boolean>;
  liveSession(accountId: string, digest: string): Promise<boolean>;
  provider(): Promise<ApnsProvider>;
  current(row: PushRegistrationRow): boolean;
};
const RETENTION_MS = 7 * 24 * 60 * 60_000;

/** Informational messages have their own durable ledger, never an approval or command queue. */
export class InformationNotifications {
  constructor(private readonly storage: DurableObjectStorage, private readonly deps: Dependencies) {
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS agent_notifications (
      account_id TEXT NOT NULL, id TEXT NOT NULL, host_id TEXT NOT NULL, session_id TEXT NOT NULL,
      title TEXT NOT NULL, message TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
      next_at INTEGER, passes INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(account_id,id))`);
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS notice_attempts (
      account_id TEXT NOT NULL, id TEXT NOT NULL, installation_id TEXT NOT NULL, state TEXT NOT NULL,
      next_at INTEGER, PRIMARY KEY(account_id,id,installation_id))`);
  }

  async enqueue(rawOwner: unknown, input: unknown): Promise<{ id: string; queued: true }> {
    const owner = ownerSchema.parse(rawOwner), command = notifyInputSchema.parse(input);
    if (!await this.deps.activeHost(owner.accountId, owner.hostId)) throw new Error("Notification source is no longer paired");
    const id = command.idempotencyKey ?? crypto.randomUUID();
    this.storage.transactionSync(() => {
      const sql = this.storage.sql;
      this.prune();
      const previous = sql.exec<NoticeRow>("SELECT * FROM agent_notifications WHERE account_id=? AND id=?", owner.accountId, id).toArray()[0];
      if (previous) {
        if (previous.host_id !== owner.hostId || previous.session_id !== owner.sessionId
          || previous.title !== command.title || previous.message !== command.message)
          throw new Error("Notification idempotency key already used for different content");
        return;
      }
      const recent = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM agent_notifications WHERE account_id=? AND created_at>?", owner.accountId, Date.now() - 60_000).one().count;
      const total = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM agent_notifications WHERE account_id=?", owner.accountId).one().count;
      if (recent >= 6 || total >= 1000) throw new Error("Notification limit reached; do not retry automatically");
      const now = Date.now();
      sql.exec(`INSERT INTO agent_notifications (account_id,id,host_id,session_id,title,message,created_at,expires_at,next_at)
        VALUES (?,?,?,?,?,?,?,?,?)`, owner.accountId, id, owner.hostId, owner.sessionId, command.title, command.message,
        now, now + 15 * 60_000, now + 1);
    });
    await this.schedule();
    return { id, queued: true };
  }

  list(accountId: string) {
    z.uuid().parse(accountId);
    this.prune();
    return this.storage.sql.exec<NoticeRow>("SELECT * FROM agent_notifications WHERE account_id=? ORDER BY created_at DESC,id LIMIT 50", accountId).toArray()
      .map(row => ({ id: row.id, hostId: row.host_id, sessionId: row.session_id, title: row.title, message: row.message, createdAt: row.created_at }));
  }

  async schedule(): Promise<void> {
    const next = this.storage.sql.exec<{ at: number | null }>("SELECT MIN(next_at) AS at FROM agent_notifications").one().at;
    if (next === null) await this.storage.deleteAlarm();
    else await this.storage.setAlarm(Math.max(Date.now() + 1, next));
  }

  async alarm(): Promise<void> {
    this.prune();
    const due = this.storage.sql.exec<NoticeRow>("SELECT * FROM agent_notifications WHERE next_at<=? ORDER BY next_at LIMIT 1", Date.now()).toArray();
    for (const notice of due) {
      let next: number | null = null;
      if (notice.expires_at > Date.now() && notice.passes < 8) {
        try { next = await this.dispatch(notice); }
        catch { next = Date.now() + 30_000; }
      }
      if (next !== null && next >= notice.expires_at) next = null;
      this.storage.sql.exec("UPDATE agent_notifications SET next_at=?,passes=passes+1 WHERE account_id=? AND id=?", next, notice.account_id, notice.id);
    }
    await this.schedule();
  }

  private async dispatch(notice: NoticeRow): Promise<number | null> {
    if (!await this.deps.activeHost(notice.account_id, notice.host_id)) return null;
    const rows = this.storage.sql.exec<PushRegistrationRow>("SELECT * FROM push_registrations WHERE account_id=? AND token IS NOT NULL AND expires_at>? LIMIT 20", notice.account_id, Date.now()).toArray();
    let next: number | null = null;
    for (const row of rows) {
      const retry = await this.deliver(notice, row);
      if (retry !== null) next = Math.min(next ?? retry, retry);
    }
    return next;
  }

  private async deliver(notice: NoticeRow, row: PushRegistrationRow): Promise<number | null> {
    const sql = this.storage.sql, key = [notice.account_id, notice.id, row.installation_id];
    const prior = sql.exec<{ state: string; next_at: number | null }>("SELECT state,next_at FROM notice_attempts WHERE account_id=? AND id=? AND installation_id=?", ...key).toArray()[0];
    if (prior && prior.state !== "deferred") return null;
    if (prior?.next_at && prior.next_at > Date.now()) return prior.next_at;
    if (!await this.deps.liveSession(notice.account_id, row.session_digest)) return null;
    const provider = await this.deps.provider();
    if (!await this.deps.activeHost(notice.account_id, notice.host_id) || !this.deps.current(row) || notice.expires_at <= Date.now()) return null;
    const claimed = this.storage.transactionSync(() => {
      const latest = sql.exec<{ state: string; next_at: number | null }>("SELECT state,next_at FROM notice_attempts WHERE account_id=? AND id=? AND installation_id=?", ...key).toArray()[0];
      if (latest && (latest.state !== "deferred" || (latest.next_at ?? 0) > Date.now())) return false;
      sql.exec(`INSERT INTO notice_attempts (account_id,id,installation_id,state) VALUES (?,?,?,'attempting')
        ON CONFLICT(account_id,id,installation_id) DO UPDATE SET state='attempting',next_at=NULL`, ...key);
      return true;
    });
    if (!claimed) return null;
    const result = await provider.send(apnsDestinationSchema.parse({ topic: "dev.leostera.axo", environment: "sandbox", token: row.token }),
      new ApnsInformationNotice({ accountId: notice.account_id, hostId: notice.host_id, sessionId: notice.session_id, requestId: notice.id },
        notice.expires_at, { title: notice.title, message: notice.message }, row.previews === 1));
    recordApiEvent({ event: "request_push", outcome: result.kind });
    const next = result.kind === "deferred" && result.notBefore < notice.expires_at ? result.notBefore : null;
    sql.exec("UPDATE notice_attempts SET state=?,next_at=? WHERE account_id=? AND id=? AND installation_id=?", next === null ? result.kind : "deferred", next, ...key);
    if (result.kind === "invalid-token" && (result.invalidatedAt === null || result.invalidatedAt >= row.registered_at))
      sql.exec("UPDATE push_registrations SET token=NULL WHERE installation_id=? AND revision=? AND token=?", row.installation_id, row.revision, row.token);
    return next;
  }

  private prune(): void {
    this.storage.sql.exec("DELETE FROM agent_notifications WHERE created_at<?", Date.now() - RETENTION_MS);
    this.storage.sql.exec("DELETE FROM notice_attempts WHERE NOT EXISTS (SELECT 1 FROM agent_notifications n WHERE n.account_id=notice_attempts.account_id AND n.id=notice_attempts.id)");
  }
}
