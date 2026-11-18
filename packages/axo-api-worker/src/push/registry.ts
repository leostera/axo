import { DurableObject } from "cloudflare:workers";
import { InformationNotifications, type NoticeOwner } from "./notices";
import { recordApiEvent } from "../observability";
import { z } from "zod";
import { ApnsProvider, ApnsRequestNotice, ApnsRequestResolution, apnsDestinationSchema, type ApnsResult } from "./apns";
import { pushRegistrationSchema, type PushOwner, type PushRegistrationResult } from "./registration";
import { hostDOName } from "../host-do";

const routeSchema = z.strictObject({ accountId: z.uuid(), hostId: z.uuid(), sessionId: z.uuid(), requestId: z.uuid(), expiresAt: z.number().int().positive() });
export type PushRoute = z.infer<typeof routeSchema>;
export type PushRegistrationRow = {
  installation_id: string; revision: number; account_id: string; session_digest: string;
  expires_at: number; registered_at: number; previews: number; token: string | null;
};

/**
 * Pilot registry: one private coordinator enforces token uniqueness across account switches.
 * It has no public listing or dispatch endpoint. Raw tokens never enter notices or logs.
 */
export class AxoPushRegistry extends DurableObject<Env> {
  private provider: Promise<ApnsProvider> | undefined;
  private readonly notices: InformationNotifications;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS push_registrations (
      installation_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, account_id TEXT NOT NULL,
      session_digest TEXT NOT NULL, expires_at INTEGER NOT NULL, registered_at INTEGER NOT NULL, token TEXT UNIQUE)`);
    if (!ctx.storage.sql.exec<{ name: string }>("PRAGMA table_info(push_registrations)").toArray().some(row => row.name === "previews"))
      ctx.storage.sql.exec("ALTER TABLE push_registrations ADD COLUMN previews INTEGER NOT NULL DEFAULT 0");
    ctx.storage.sql.exec("CREATE INDEX IF NOT EXISTS push_by_account ON push_registrations(account_id)");
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS push_attempts (
      account_id TEXT NOT NULL, host_id TEXT NOT NULL, request_id TEXT NOT NULL,
      installation_id TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL,
      next_at INTEGER, expires_at INTEGER NOT NULL,
      PRIMARY KEY(account_id, host_id, request_id, installation_id))`);
    this.notices = new InformationNotifications(ctx.storage, {
      activeHost: (accountId, hostId) => this.ctx.exports.AxoAccountDirectory.getByName(accountId).isPushHostActive(hostId),
      liveSession: (accountId, digest) => this.ctx.exports.AxoAccountDirectory.getByName(accountId).verifyPushSession(digest, Date.now()),
      provider: () => this.getProvider(), current: row => this.current(row),
    });
    ctx.blockConcurrencyWhile(() => this.notices.schedule());
  }

  async notify(owner: NoticeOwner, input: unknown): Promise<{ id: string; queued: true }> {
    return this.notices.enqueue(owner, input);
  }

  notifications(accountId: string) { return this.notices.list(accountId); }
  async alarm(): Promise<void> { await this.notices.alarm(); }

  async register(owner: PushOwner, input: unknown): Promise<PushRegistrationResult> {
    const parsed = pushRegistrationSchema.safeParse(input);
    if (!parsed.success || !z.uuid().safeParse(owner.accountId).success) return "conflict";
    // Recheck the native session in the owning actor, not merely the earlier HTTP admission.
    const account = this.ctx.exports.AxoAccountDirectory.getByName(owner.accountId);
    if (!await account.verifyPushSession(owner.sessionDigest, Date.now())) return "conflict";
    const command = parsed.data;
    return this.ctx.storage.transactionSync(() => {
      const sql = this.ctx.storage.sql;
      const previous = sql.exec<PushRegistrationRow>("SELECT * FROM push_registrations WHERE installation_id = ?", command.installationId).toArray()[0];
      if (previous && command.revision <= previous.revision) return "stale";
      // Tombstones retain their revision: delayed enable requests cannot undo disable.
      const total = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM push_registrations WHERE account_id = ?", owner.accountId).one().count;
      if (total >= 1024 && previous?.account_id !== owner.accountId) return "limited";
      const count = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM push_registrations WHERE account_id = ? AND token IS NOT NULL AND expires_at > ?", owner.accountId, Date.now()).one().count;
      if (command.action === "enable" && count >= 20 && (!previous?.token || previous.account_id !== owner.accountId)) return "limited";
      const token = command.action === "enable" ? command.destination.token : null;
      // A different installation cannot steal a known destination. Same-install account switches
      // use the same monotonic revision; an old request can never reclaim it afterward.
      if (token && sql.exec("SELECT 1 FROM push_registrations WHERE token=? AND installation_id!=?", token, command.installationId).toArray().length) return "conflict";
      sql.exec(`INSERT INTO push_registrations (installation_id, revision, account_id, session_digest, expires_at, registered_at, token)
        VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(installation_id) DO UPDATE SET
        revision=excluded.revision, account_id=excluded.account_id, session_digest=excluded.session_digest,
        expires_at=excluded.expires_at, registered_at=excluded.registered_at, token=excluded.token`, command.installationId, command.revision,
        owner.accountId, owner.sessionDigest, owner.expiresAt, Date.now(), token);
      sql.exec("UPDATE push_registrations SET previews=? WHERE installation_id=?", command.action === "enable" && command.previews === "message" ? 1 : 0, command.installationId);
      return "saved";
    });
  }

  /** Called only from the authoritative HostDO's durable outbox. */
  async dispatch(input: unknown): Promise<number | null> {
    const parsed = routeSchema.safeParse(input);
    if (!parsed.success) return null;
    if (!this.env.APNS_PRIVATE_KEY || !this.env.APNS_KEY_ID || !this.env.APNS_TEAM_ID) {
      recordApiEvent({ event: "request_push", outcome: "unconfigured" });
      return null;
    }
    const route = parsed.data;
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM push_attempts WHERE expires_at <= ?", Date.now());
    const rows = sql.exec<PushRegistrationRow>("SELECT * FROM push_registrations WHERE account_id = ? AND token IS NOT NULL AND expires_at > ? LIMIT 20", route.accountId, Date.now()).toArray();
    recordApiEvent({ event: "request_push", outcome: "attempting", destinations: rows.length });
    let nextAt: number | null = null;
    for (const row of rows) {
      const retry = await this.deliver(route, row);
      if (retry !== null) nextAt = Math.min(nextAt ?? retry, retry);
    }
    return nextAt;
  }

  /** Authoritative terminal outbox only. Cleanup is idempotent; it cannot answer a request. */
  async resolve(input: unknown): Promise<number | null> {
    const parsed = routeSchema.safeParse(input);
    if (!parsed.success || !this.env.APNS_PRIVATE_KEY || !this.env.APNS_KEY_ID || !this.env.APNS_TEAM_ID) return null;
    const route = parsed.data;
    const account = this.ctx.exports.AxoAccountDirectory.getByName(route.accountId);
    if (!await account.isPushHostActive(route.hostId)) return null;
    const host = this.ctx.exports.AxoHostDO.getByName(hostDOName(route.accountId, route.hostId));
    if (await host.pendingPush(route.requestId)) return null;
    const rows = this.ctx.storage.sql.exec<PushRegistrationRow>(
      "SELECT * FROM push_registrations WHERE account_id=? AND token IS NOT NULL AND expires_at>? LIMIT 20",
      route.accountId, Date.now()).toArray();
    const provider = await this.getProvider();
    let next: number | null = null;
    for (const row of rows) {
      if (!await account.verifyPushSession(row.session_digest, Date.now()) || !this.current(row)) continue;
      if (!await account.isPushHostActive(route.hostId) || !this.current(row)) continue;
      const { expiresAt, ...routing } = route;
      const notice = new ApnsRequestResolution(routing, expiresAt);
      const result = await provider.send(apnsDestinationSchema.parse({
        topic: "dev.leostera.axo", environment: "sandbox", token: row.token,
      }), notice);
      this.invalidate(row, result);
      // Unlike answers/alerts, repeating a retraction is safe after transport uncertainty.
      const retry = result.kind === "deferred" ? result.notBefore
        : result.kind === "uncertain" ? Date.now() + 30_000 : null;
      if (retry !== null && retry < route.expiresAt) next = Math.min(next ?? retry, retry);
    }
    return next;
  }

  private async deliver(route: PushRoute, row: PushRegistrationRow): Promise<number | null> {
    const sql = this.ctx.storage.sql;
    const key = [route.accountId, route.hostId, route.requestId, row.installation_id];
    const prior = sql.exec<{ state: string; next_at: number | null }>(`SELECT state, next_at FROM push_attempts
      WHERE account_id=? AND host_id=? AND request_id=? AND installation_id=?`, ...key).toArray()[0];
    if (prior && prior.state !== "deferred") return null;
    if (prior?.next_at && prior.next_at > Date.now()) return prior.next_at;
    const account = this.ctx.exports.AxoAccountDirectory.getByName(route.accountId);
    if (!await account.verifyPushSession(row.session_digest, Date.now())) return null;
    const host = this.ctx.exports.AxoHostDO.getByName(hostDOName(route.accountId, route.hostId));
    // Reads current pending state and current host ownership, never trusts an agent's alert text.
    const current = await host.pendingPush(route.requestId);
    if (!current || current.accountId !== route.accountId || current.hostId !== route.hostId
      || current.sessionId !== route.sessionId || current.expiresAt !== route.expiresAt) return null;
    if (!this.current(row)) return null;
    const question = row.previews === 1 ? await host.notificationQuestion(route.requestId) : null;
    const notice = question ? await ApnsRequestNotice.withQuestion({
      accountId: route.accountId, hostId: route.hostId, sessionId: route.sessionId, requestId: route.requestId,
    }, route.expiresAt, question.elicitation.message,
      question.elicitation.title ?? (question.elicitation.askedBy === "computerUse" ? "Mac action" : "Agent question")) : new ApnsRequestNotice({
      accountId: route.accountId, hostId: route.hostId, sessionId: route.sessionId, requestId: route.requestId,
    }, route.expiresAt);
    const provider = await this.getProvider();
    if (!this.current(row) || !await host.pendingPush(route.requestId)) return null;
    if (!await account.verifyPushSession(row.session_digest, Date.now()) || !this.current(row)) return null;
    // Claim before network I/O. An eviction/crash leaves an uncertain attempt, not a replay.
    const claimed = this.ctx.storage.transactionSync(() => {
      // Recheck after every authority/provider await: another dispatch may have claimed meanwhile.
      const latest = sql.exec<{ state: string; next_at: number | null }>(`SELECT state, next_at FROM push_attempts
        WHERE account_id=? AND host_id=? AND request_id=? AND installation_id=?`, ...key).toArray()[0];
      if (latest && (latest.state !== "deferred" || (latest.next_at ?? 0) > Date.now())) return false;
      sql.exec(`INSERT INTO push_attempts (account_id, host_id, request_id, installation_id, revision, state, next_at, expires_at)
        VALUES (?, ?, ?, ?, ?, 'attempting', NULL, ?) ON CONFLICT(account_id, host_id, request_id, installation_id)
        DO UPDATE SET state='attempting', revision=excluded.revision, next_at=NULL`, ...key, row.revision, route.expiresAt);
      return true;
    });
    if (!claimed) return null;
    const destination = apnsDestinationSchema.parse({ topic: "dev.leostera.axo", environment: "sandbox", token: row.token });
    const result = await provider.send(destination, notice);
    recordApiEvent({ event: "request_push", outcome: result.kind });
    const retry = result.kind === "deferred" && result.notBefore < route.expiresAt ? result.notBefore : null;
    sql.exec(`UPDATE push_attempts SET state=?, next_at=? WHERE account_id=? AND host_id=? AND request_id=? AND installation_id=?`, retry === null ? result.kind : "deferred", retry, ...key);
    this.invalidate(row, result);
    // A terminal event may race this in-flight alert. Retract again after its admission.
    if (!await host.pendingPush(route.requestId)) {
      await this.resolve({ ...route, expiresAt: Date.now() + 24 * 60 * 60_000 });
    }
    return retry;
  }

  private current(row: PushRegistrationRow): boolean {
    return this.ctx.storage.sql.exec(`SELECT 1 FROM push_registrations
      WHERE installation_id=? AND revision=? AND account_id=? AND session_digest=? AND token=? AND expires_at>?`,
      row.installation_id, row.revision, row.account_id, row.session_digest, row.token, Date.now()).toArray().length === 1;
  }

  private invalidate(row: PushRegistrationRow, result: ApnsResult): void {
    if (result.kind !== "invalid-token") return;
    if (result.invalidatedAt !== null && result.invalidatedAt < row.registered_at) return;
    // Compare the exact generation and token: feedback cannot erase a newer registration.
    // Apple's timestamp can only refer to this same generation, never justify deleting another.
    this.ctx.storage.sql.exec("UPDATE push_registrations SET token=NULL WHERE installation_id=? AND revision=? AND token=?",
      row.installation_id, row.revision, row.token);
  }

  private getProvider(): Promise<ApnsProvider> {
    this.provider ??= ApnsProvider.create({ teamId: this.env.APNS_TEAM_ID!, keyId: this.env.APNS_KEY_ID!,
      privateKey: this.env.APNS_PRIVATE_KEY!, environment: "sandbox", topics: ["dev.leostera.axo"] })
      .catch(() => { this.provider = undefined; throw new Error("Push provider unavailable"); });
    return this.provider;
  }
}
