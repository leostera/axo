import {
  HOST_SYNC_METHODS,
  LIMITS,
  SYNC,
  JSONRPCErrorException,
  appendParamsSchema,
  chainAtParamsSchema,
  hostSyncParamsSchema,
  metaParamsSchema,
  progressParamsSchema,
  sessionMetadataSchema,
  statusParamsSchema,
  truncateParamsSchema,
  uuid,
  type AppendResult,
  type Call,
  type ClientSession,
  type CloudSessionState,
  type HostSyncResult,
  type JSONRPCServer,
  type Reply,
  type SessionMetadata,
  type SessionStatus,
} from "@axo/protocol";
import { hostV1Results, type HostSnapshot, type HostMethod } from "@axo/protocol/v1";
import { AxoHostRelay, hostRemoteMethods, type HostRemoteMethod } from "./axo-host-relay";
import type { CallerContext, Peer } from "./relay/peer";
import { sessionDOName, type SessionBinding } from "./session-store";
import { recordApiEvent } from "./observability";

/**
 * One paired host (RFD0018, HostDO): owns the host's socket and presence, runs the sync
 * handshake, keeps the host's index of Sessions, routes appends to SessionDOs, forwards commands
 * from ClientDOs, and sends change notices to the ClientDOs that hold a lease on it.
 *
 * The socket transport (negotiation, registration, heartbeats, fragments, shares) is the daemon
 * side of AxoHostRelay. Account state lives in AxoAccountManager, reached by RPC.
 */

export function hostDOName(accountId: string, hostId: string): string {
  return `${uuid.parse(accountId)}:${uuid.parse(hostId)}`;
}

/** What a ClientDO learns from a HostDO, in batches. Only the newest per key is kept. */
export type HostNotice =
  | { kind: "session"; session: ClientSession }
  | { kind: "progress"; sessionId: string; slot: string; snapshot: unknown }
  | { kind: "epoch"; sessionId: string; epoch: number; head: number }
  | { kind: "presence"; online: boolean; hostGeneration: string | null };

export type HostSubscription = {
  online: boolean;
  hostGeneration: string | null;
  sessions: ClientSession[];
  progress: Array<{ sessionId: string; slot: string; snapshot: unknown }>;
};

export type HostCommandOutcome = { result: unknown } | { error: { code: number; message: string } };

type IndexRow = {
  session_id: string;
  metadata_json: string;
  metadata_version: number;
  missing: number;
  epoch: number | null;
  head: number;
  chain: string | null;
};

type ClientStub = { notify(hostId: string, notices: HostNotice[]): Promise<boolean> };
type AccountStub = {
  authorizeHost(hostId: string, credentialId: string, credential: string): Promise<boolean>;
  registerHost(registration: unknown, now: number): Promise<HostSnapshot>;
  touchHost(hostId: string, hostGeneration: string, now: number): Promise<{ acknowledged: true; lastSeenAt: string }>;
};

export class AxoHostDO extends AxoHostRelay {
  /** The newest progress snapshot per Session and slot; never stored (RFD0018, Ephemeral progress). */
  private readonly progress = new Map<string, Map<string, unknown>>();
  private readonly statuses = new Map<string, SessionStatus>();
  private readonly notices = new Map<string, HostNotice>();
  private noticeTimer: ReturnType<typeof setTimeout> | null = null;
  /** Commands from ClientDOs waiting for the host's reply, by the id they were sent with. */
  private readonly commands = new Map<string, { method: HostRemoteMethod; generation: string; resolve: (outcome: HostCommandOutcome) => void }>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    sql.exec(`CREATE TABLE IF NOT EXISTS host_identity (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), account_id TEXT NOT NULL, host_id TEXT NOT NULL)`);
    // `missing` marks a Session the last manifest did not list: archived, never deleted.
    sql.exec(`CREATE TABLE IF NOT EXISTS session_index (
      session_id TEXT PRIMARY KEY, metadata_json TEXT NOT NULL, metadata_version INTEGER NOT NULL,
      missing INTEGER NOT NULL DEFAULT 0, epoch INTEGER, head INTEGER NOT NULL DEFAULT 0, chain TEXT)`);
    sql.exec("CREATE TABLE IF NOT EXISTS sync_round (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), round INTEGER NOT NULL)");
    sql.exec("CREATE TABLE IF NOT EXISTS subscribers (client_do TEXT PRIMARY KEY, lease_until REAL NOT NULL)");
  }

  // ─── Socket admission and registration ─────────────────────────────────────

  protected override supportsLegacyMachineMethods(): boolean { return false; }

  protected override async authorizeRelayPeer(request: Request, peer: Peer): Promise<boolean> {
    if (peer.role !== "daemon" || !this.bind(peer.identity, peer.machineId)) return false;
    return this.account().authorizeHost(
      peer.machineId,
      request.headers.get("X-Axo-Credential-Id") ?? "",
      request.headers.get("X-Axo-Credential") ?? "",
    );
  }

  protected override async storeHostRegistration(registration: unknown): Promise<HostSnapshot> {
    return this.account().registerHost(registration, Date.now());
  }

  protected override async storeHostHeartbeat(reference: unknown): Promise<{ acknowledged: true; lastSeenAt: string }> {
    const { hostId, hostGeneration } = reference as { hostId: string; hostGeneration: string };
    return this.account().touchHost(hostId, hostGeneration, Date.now());
  }

  protected override async storeHostSessions(): Promise<{ storedAt: string }> {
    throw new Error("Sessions are synced with axo.host.sync");
  }

  /** The firehose is gone (RFD0018): a host that still sends it is out of date. */
  protected override async storeHostEvent(): Promise<void> {
    throw new Error("Host events are replaced by axo.host.sync");
  }

  protected override presenceChanged(_hostId: string, hostGeneration: string, status: "online" | "offline"): void {
    if (status === "offline") {
      this.progress.clear();
      this.statuses.clear();
    }
    this.queue({ kind: "presence", online: status === "online", hostGeneration }, true);
  }

  protected override fence(connectionId: string): void {
    super.fence(connectionId);
    for (const [id, command] of this.commands) {
      this.commands.delete(id);
      command.resolve({ error: { code: -32004, message: "Outcome unknown; reconcile commandId" } });
    }
  }

  // ─── Upload: Axod → HostDO ─────────────────────────────────────────────────

  protected override hostMethodNames(): string[] {
    return Object.values(HOST_SYNC_METHODS);
  }

  protected override addHostMethods(server: JSONRPCServer<CallerContext>): void {
    server.addMethod(HOST_SYNC_METHODS.sync, (params, caller) => this.sync(params, caller));
    server.addMethod(HOST_SYNC_METHODS.append, (params, caller) => this.append(params, caller));
    server.addMethod(HOST_SYNC_METHODS.chainAt, (params, caller) => this.chainAt(params, caller));
    server.addMethod(HOST_SYNC_METHODS.truncate, (params, caller) => this.truncate(params, caller));
    server.addMethod(HOST_SYNC_METHODS.meta, (params, caller) => this.meta(params, caller));
  }

  protected override async receiveHostNotification(_socket: WebSocket, peer: Peer, call: Call): Promise<boolean> {
    if (call.method === HOST_SYNC_METHODS.progress) {
      const parsed = progressParamsSchema.safeParse(call.params);
      if (!parsed.success || !this.ready(peer)) return true;
      const { sessionId, slot, snapshot } = parsed.data;
      const slots = this.progress.get(sessionId) ?? new Map<string, unknown>();
      if (snapshot === null || snapshot === undefined) slots.delete(slot);
      else slots.set(slot, snapshot);
      this.progress.set(sessionId, slots);
      this.queue({ kind: "progress", sessionId, slot, snapshot: snapshot ?? null });
      return true;
    }
    if (call.method === HOST_SYNC_METHODS.status) {
      const parsed = statusParamsSchema.safeParse(call.params);
      if (!parsed.success || !this.ready(peer)) return true;
      this.statuses.set(parsed.data.sessionId, parsed.data.status);
      const row = this.indexRow(parsed.data.sessionId);
      if (row) this.queue({ kind: "session", session: this.clientSession(row) });
      return true;
    }
    return false;
  }

  /**
   * The handshake: upserts every manifest row into the index, marks rows the manifest left out
   * as missing (never deleted), and answers with what each SessionDO holds. A manifest from an
   * older round than the last one applied changes nothing.
   */
  private async sync(params: unknown, { peer }: CallerContext): Promise<HostSyncResult> {
    const input = hostSyncParamsSchema.safeParse(params);
    if (!input.success || !this.ready(peer) || input.data.hostId !== peer.machineId)
      throw new JSONRPCErrorException("Invalid sync manifest", -32602);
    const { round, sessions } = input.data;
    const sql = this.ctx.storage.sql;
    const last = sql.exec<{ round: number }>("SELECT round FROM sync_round WHERE singleton = 1").toArray()[0]?.round ?? 0;
    if (round < last) return { round, applied: false, sessions: [], serverOnly: [] };
    const listed = new Set(sessions.map((session) => session.sessionId));
    this.ctx.storage.transactionSync(() => {
      sql.exec("INSERT INTO sync_round (singleton, round) VALUES (1, ?) ON CONFLICT(singleton) DO UPDATE SET round = excluded.round", round);
      for (const session of sessions) this.upsertMetadata(session.sessionId, session.metadataVersion, session.metadata, false);
    });
    const serverOnly: string[] = [];
    for (const row of sql.exec<IndexRow>("SELECT * FROM session_index").toArray()) {
      if (listed.has(row.session_id)) continue;
      serverOnly.push(row.session_id);
      if (!row.missing) {
        sql.exec("UPDATE session_index SET missing = 1 WHERE session_id = ?", row.session_id);
        this.queueSession(row.session_id);
      }
    }
    const states: CloudSessionState[] = [];
    for (let start = 0; start < sessions.length; start += 16) {
      const batch = sessions.slice(start, start + 16);
      states.push(...await Promise.all(batch.map(async ({ sessionId }): Promise<CloudSessionState> => {
        const head = await this.session(sessionId).head(this.binding(sessionId));
        this.refreshHead(sessionId, head ? head.epoch : null, head?.count ?? 0, head?.chain ?? null);
        return head ? { sessionId, state: "known", ...head } : { sessionId, state: "unknown" };
      })));
    }
    this.renewRoute(peer);
    recordApiEvent({ event: "host_sync", sessions: sessions.length, unknown: states.filter((state) => state.state === "unknown").length });
    return { round, applied: true, sessions: states, serverOnly: serverOnly.slice(0, SYNC.manifestSessions) };
  }

  private async append(params: unknown, { peer }: CallerContext): Promise<AppendResult> {
    const input = appendParamsSchema.safeParse(params);
    if (!input.success || !this.ready(peer)) throw new JSONRPCErrorException("Invalid append", -32602);
    const { sessionId } = input.data;
    if (!this.indexRow(sessionId)) throw new JSONRPCErrorException("Unknown Session; sync first", -32602);
    const result = await this.session(sessionId).append(this.binding(sessionId), input.data);
    recordApiEvent({ event: "session_append", outcome: result.outcome, records: input.data.records.length });
    this.renewRoute(peer);
    if (result.outcome !== "committed") return result;
    this.refreshHead(sessionId, result.epoch, result.count, result.chain);
    for (const slot of result.cleared) {
      if (!this.progress.get(sessionId)?.delete(slot)) continue;
      this.queue({ kind: "progress", sessionId, slot, snapshot: null });
    }
    return { outcome: "committed", epoch: result.epoch, count: result.count, chain: result.chain };
  }

  private async chainAt(params: unknown, { peer }: CallerContext) {
    const input = chainAtParamsSchema.safeParse(params);
    if (!input.success || !this.ready(peer)) throw new JSONRPCErrorException("Invalid chainAt", -32602);
    const { sessionId, round, positions } = input.data;
    const result = await this.session(sessionId).chains(this.binding(sessionId), positions);
    return { round, ...result };
  }

  private async truncate(params: unknown, { peer }: CallerContext) {
    const input = truncateParamsSchema.safeParse(params);
    if (!input.success || !this.ready(peer)) throw new JSONRPCErrorException("Invalid truncate", -32602);
    const { sessionId, round, keep, expectedChain } = input.data;
    const result = await this.session(sessionId).truncate(this.binding(sessionId), keep, expectedChain);
    recordApiEvent({ event: "session_truncate", outcome: result.outcome });
    if (result.outcome === "mismatch") return { round, outcome: "mismatch" as const };
    this.refreshHead(sessionId, result.epoch, result.count, result.chain);
    this.queue({ kind: "epoch", sessionId, epoch: result.epoch, head: result.count }, true);
    return { round, ...result };
  }

  private meta(params: unknown, { peer }: CallerContext) {
    const input = metaParamsSchema.safeParse(params);
    if (!input.success || !this.ready(peer)) throw new JSONRPCErrorException("Invalid metadata", -32602);
    const applied = this.upsertMetadata(input.data.sessionId, input.data.metadataVersion, input.data.metadata, true);
    return { applied };
  }

  /** Applies metadata newer than what the index holds; returns whether it did. */
  private upsertMetadata(sessionId: string, version: number, metadata: SessionMetadata, alone: boolean): boolean {
    const sql = this.ctx.storage.sql;
    const row = this.indexRow(sessionId);
    if (row && row.metadata_version >= version) {
      if (row.missing && !alone) {
        sql.exec("UPDATE session_index SET missing = 0 WHERE session_id = ?", sessionId);
        this.queueSession(sessionId);
      }
      return false;
    }
    sql.exec(`INSERT INTO session_index (session_id, metadata_json, metadata_version, missing) VALUES (?, ?, ?, 0)
      ON CONFLICT(session_id) DO UPDATE SET metadata_json = excluded.metadata_json,
      metadata_version = excluded.metadata_version, missing = CASE WHEN ? THEN missing ELSE 0 END`,
      sessionId, JSON.stringify(metadata), version, alone ? 1 : 0);
    this.queueSession(sessionId);
    return true;
  }

  /** The index caches each Session's head; subscribers hear when it changes. */
  private refreshHead(sessionId: string, epoch: number | null, head: number, chain: string | null): void {
    const row = this.indexRow(sessionId);
    if (!row || (row.epoch === epoch && row.head === head && row.chain === chain)) return;
    this.ctx.storage.sql.exec("UPDATE session_index SET epoch = ?, head = ?, chain = ? WHERE session_id = ?", epoch, head, chain, sessionId);
    if (row.epoch !== null && epoch !== null && epoch > row.epoch) this.queue({ kind: "epoch", sessionId, epoch, head }, true);
    this.queueSession(sessionId);
  }

  // ─── Delivery: ClientDO ↔ HostDO ───────────────────────────────────────────

  /** Takes or renews a ClientDO's lease, and returns the host's index and progress. */
  async subscribe(clientDO: string, leaseMs: number = SYNC.leaseMs): Promise<HostSubscription> {
    const until = Date.now() + Math.min(Math.max(leaseMs, 1_000), SYNC.leaseMs);
    this.ctx.storage.sql.exec(`INSERT INTO subscribers (client_do, lease_until) VALUES (?, ?)
      ON CONFLICT(client_do) DO UPDATE SET lease_until = excluded.lease_until`, clientDO, until);
    await this.schedule();
    const presence = this.presence();
    return {
      online: presence.online,
      hostGeneration: presence.hostGeneration,
      sessions: this.ctx.storage.sql.exec<IndexRow>("SELECT * FROM session_index").toArray().map((row) => this.clientSession(row)),
      progress: [...this.progress].flatMap(([sessionId, slots]) => [...slots].map(([slot, snapshot]) => ({ sessionId, slot, snapshot }))),
    };
  }

  async unsubscribe(clientDO: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM subscribers WHERE client_do = ?", clientDO);
  }

  /** The current progress snapshots of one Session, for a client opening it. */
  async sessionProgress(sessionId: string): Promise<Array<{ slot: string; snapshot: unknown }>> {
    return [...(this.progress.get(sessionId) ?? [])].map(([slot, snapshot]) => ({ slot, snapshot }));
  }

  /**
   * Forwards a command to the host and returns its reply. An offline host fails at once and
   * nothing is queued; a socket that drops first leaves the outcome unknown.
   */
  async command(method: string, params: unknown): Promise<HostCommandOutcome> {
    if (!Object.hasOwn(hostRemoteMethods, method)) return { error: { code: -32601, message: "Method not found" } };
    const remote = method as HostRemoteMethod;
    const parsed = hostRemoteMethods[remote].safeParse(params);
    if (!parsed.success) return { error: { code: -32602, message: "Invalid params" } };
    const identity = this.identity();
    const active = identity ? this.active(identity.host_id) : undefined;
    if (!identity || !active) return { error: { code: -32005, message: "Host offline; nothing queued" } };
    if (parsed.data.target.hostId !== identity.host_id || parsed.data.target.hostGeneration !== active.route.generation)
      return { error: { code: -32002, message: "Stale host" } };
    if (this.commands.size >= LIMITS.pendingPerMachine) return { error: { code: -32006, message: "Pending capacity" } };
    const id = crypto.randomUUID();
    return new Promise<HostCommandOutcome>((resolve) => {
      const timer = setTimeout(() => {
        if (this.commands.delete(id)) resolve({ error: { code: -32004, message: "Outcome unknown; reconcile commandId" } });
      }, LIMITS.deadlineMs);
      this.commands.set(id, {
        method: remote,
        generation: active.route.generation!,
        resolve: (outcome) => {
          clearTimeout(timer);
          resolve(outcome);
        },
      });
      if (!this.send(active.socket, { jsonrpc: "2.0", id, method, params: parsed.data })) {
        this.commands.delete(id);
        clearTimeout(timer);
        resolve({ error: { code: -32004, message: "Outcome unknown; reconcile commandId" } });
      }
    });
  }

  protected override receiveReply(socket: WebSocket, reply: Reply): void {
    const command = typeof reply.id === "string" ? this.commands.get(reply.id) : undefined;
    if (!command) return super.receiveReply(socket, reply);
    this.commands.delete(reply.id as string);
    // The host is the account's own Mac: its reason reaches the client, bounded.
    if ("error" in reply) return command.resolve({ error: { code: reply.error.code, message: reply.error.message.slice(0, 256) || "Host rejected operation" } });
    const result = hostV1Results[command.method as HostMethod].safeParse(reply.result);
    const generation = (result.data as { hostGeneration?: unknown } | undefined)?.hostGeneration;
    if (!result.success || (generation !== undefined && generation !== command.generation))
      return command.resolve({ error: { code: -32004, message: "Invalid host outcome; reconcile commandId" } });
    command.resolve({ result: reply.result });
  }

  /** Ends the host's connection: it was revoked, or its credential changed. */
  async disconnect(): Promise<void> {
    const identity = this.identity();
    if (identity) this.closeHostRelay(identity.host_id);
  }

  async presenceOf(): Promise<{ online: boolean; hostGeneration: string | null }> {
    return this.presence();
  }

  override presence() {
    const identity = this.identity();
    return identity ? super.presence(identity.host_id) : { online: false, hostGeneration: null };
  }

  override async alarm(): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM subscribers WHERE lease_until <= ?", Date.now());
    await super.alarm();
  }

  // ─── Notices ───────────────────────────────────────────────────────────────

  private queueSession(sessionId: string): void {
    const row = this.indexRow(sessionId);
    if (row) this.queue({ kind: "session", session: this.clientSession(row) });
  }

  /** Gathers notices for `SYNC.noticeMs`, keeping the newest per key; `now` sends at once. */
  private queue(notice: HostNotice, now = false): void {
    const key = notice.kind === "presence" ? "presence"
      : notice.kind === "session" ? `session:${notice.session.sessionId}`
      : notice.kind === "epoch" ? `epoch:${notice.sessionId}`
      : `progress:${notice.sessionId}:${notice.slot}`;
    this.notices.delete(key);
    this.notices.set(key, notice);
    if (now) {
      if (this.noticeTimer) clearTimeout(this.noticeTimer);
      this.noticeTimer = null;
      void this.flushNotices();
    } else if (!this.noticeTimer) {
      this.noticeTimer = setTimeout(() => {
        this.noticeTimer = null;
        void this.flushNotices();
      }, SYNC.noticeMs);
    }
  }

  private async flushNotices(): Promise<void> {
    const identity = this.identity();
    if (!identity || this.notices.size === 0) return;
    const notices = [...this.notices.values()];
    this.notices.clear();
    const sql = this.ctx.storage.sql;
    const subscribers = sql.exec<{ client_do: string }>("SELECT client_do FROM subscribers WHERE lease_until > ?", Date.now()).toArray();
    await Promise.all(subscribers.map(async ({ client_do }) => {
      try {
        if (!(await this.client(client_do).notify(identity.host_id, notices))) throw new Error("not following");
      } catch {
        sql.exec("DELETE FROM subscribers WHERE client_do = ?", client_do);
      }
    }));
    if (subscribers.length) recordApiEvent({ event: "notice_batch", subscribers: subscribers.length, notices: notices.length });
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  private clientSession(row: IndexRow): ClientSession {
    const metadata = sessionMetadataSchema.parse(JSON.parse(row.metadata_json));
    return {
      hostId: this.identity()!.host_id,
      sessionId: row.session_id,
      metadata: row.missing ? { ...metadata, archived: true } : metadata,
      epoch: row.epoch,
      head: row.head,
      status: this.statuses.get(row.session_id) ?? null,
    };
  }

  private indexRow(sessionId: string): IndexRow | undefined {
    return this.ctx.storage.sql.exec<IndexRow>("SELECT * FROM session_index WHERE session_id = ?", sessionId).toArray()[0];
  }

  private ready(peer: Peer): boolean {
    try {
      return Boolean(this.admittedDaemon(peer).ready);
    } catch {
      return false;
    }
  }

  private identity(): { account_id: string; host_id: string } | undefined {
    return this.ctx.storage.sql.exec<{ account_id: string; host_id: string }>(
      "SELECT account_id, host_id FROM host_identity WHERE singleton = 1").toArray()[0];
  }

  /** Binds this object to (account, host) on first use; false if it belongs to another. */
  private bind(accountId: string, hostId: string): boolean {
    const identity = this.identity();
    if (!identity) {
      this.ctx.storage.sql.exec("INSERT INTO host_identity (singleton, account_id, host_id) VALUES (1, ?, ?)", accountId, hostId);
      return true;
    }
    return identity.account_id === accountId && identity.host_id === hostId;
  }

  private binding(sessionId: string): SessionBinding {
    const identity = this.identity()!;
    return { accountId: identity.account_id, hostId: identity.host_id, sessionId };
  }

  private session(sessionId: string) {
    const { accountId, hostId } = this.binding(sessionId);
    return this.ctx.exports.AxoSessionDO.getByName(sessionDOName(accountId, hostId, sessionId));
  }

  private account(): AccountStub {
    return this.ctx.exports.AxoAccountDirectory.getByName(this.identity()!.account_id) as unknown as AccountStub;
  }

  private client(name: string): ClientStub {
    return this.ctx.exports.AxoClientDO.getByName(name) as unknown as ClientStub;
  }
}

