import {
  APPS_LIMITS,
  ELICITATION_ERRORS,
  ELICITATION_LIMITS,
  ELICITATION_METHODS,
  elicitationResolveResultSchema,
  elicitationResolvedSchema,
  elicitationSchema,
  hostElicitationResolveParamsSchema,
  HOST_SYNC_METHODS,
  LIMITS,
  isAppsMethod,
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
  type Elicitation,
  type ElicitationResolved,
  type HostSyncResult,
  type JSONRPCServer,
  type Reply,
  type SessionMetadata,
  type SessionStatus,
} from "@axo/protocol";
import { hostV1Results, type HostSnapshot, type HostMethod } from "@axo/protocol/v1";
import { AxoHostRelay, hostRemoteMethods, type HostRemoteMethod } from "./axo-host-relay";
import type { CallerContext, Peer } from "./relay/peer";
import { sessionDOName, type SessionBinding, type SessionHead } from "./session-store";
import { recordApiEvent } from "./observability";
import { addColumns, migrate, type SchemaStep } from "./schema";
import { DIRECT_CLIENT_ROLE, HostClients, isDirectClient } from "./host-clients";
import { PI3_FORMAT, type ClientRecord } from "@axo/protocol";
import { z } from "zod";

/**
 * One paired host (RFD0018, HostDO): owns the host's socket and presence, runs the sync
 * handshake, keeps the host's index of Sessions, routes appends to SessionDOs, forwards commands
 * from ClientDOs, and sends change notices to the ClientDOs following it.
 *
 * Nothing here wakes it on a timer (RFD0031): a ClientDO follows it from hello until its socket
 * closes, progress goes only to the ClientDOs watching that Session, and a failed notice is sent
 * again at once, then as the whole index with the next one. Its only alarm is the base class's:
 * a host route whose heartbeats stopped.
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
  | { kind: "presence"; online: boolean; hostGeneration: string | null }
  /** The Mac was named (RFD0022). */
  | { kind: "label"; label: string }
  /** The Mac asks the person (RFD0029); people's clients show a card. */
  | { kind: "elicitationRequested"; elicitation: Elicitation }
  /** It settled, or the Mac went offline: clients dismiss the card. */
  | { kind: "elicitationResolved"; resolved: ElicitationResolved };

export type HostSubscription = {
  online: boolean;
  hostGeneration: string | null;
  sessions: ClientSession[];
  progress: Array<{ sessionId: string; slot: string; snapshot: unknown }>;
  /** What the Mac is asking now (RFD0029). */
  elicitations: Elicitation[];
};

export type HostCommandOutcome = { result: unknown } | { error: { code: number; message: string } };

/** The longest a `callHost` waits for its reply: the longest a bash may run, and a margin. */
export const CALL_HOST_MAX_MS = APPS_LIMITS.bashMaxTimeoutMs + 30_000;

export type AppsCall = { hostId: string; hostGeneration: string; method: string; params: unknown };
export type CallHostRequest = { method: string; params: unknown; deadlineMs: number };

const outcomeSchema = z.union([
  z.object({ result: z.unknown() }).refine((value) => "result" in value),
  z.object({ error: z.object({ code: z.number().int(), message: z.string() }) }),
]);

type IndexRow = {
  session_id: string;
  metadata_json: string;
  metadata_version: number;
  missing: number;
  epoch: number | null;
  head: number;
  chain: string | null;
  /** The row was last set from an answer that carried the SessionDO's fence, and no write to it is out since. */
  verified: number;
};

type ClientStub = { notify(hostId: string, notices: HostNotice[]): Promise<boolean> };
type AccountStub = {
  authorizeHost(hostId: string, credentialId: string, credential: string): Promise<boolean>;
  registerHost(registration: unknown, now: number): Promise<HostSnapshot>;
  touchHost(hostId: string, hostGeneration: string, now: number): Promise<{ acknowledged: true; lastSeenAt: string }>;
  appsCall(call: AppsCall): Promise<HostCommandOutcome>;
};

/** The HostDO's schema, one step per change (RFD0032, Release P). */
const HOST_SCHEMA: readonly SchemaStep[] = [
  (sql) => {
    sql.exec(`CREATE TABLE IF NOT EXISTS host_identity (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), account_id TEXT NOT NULL, host_id TEXT NOT NULL)`);
    // `missing` marks a Session the last manifest did not list: archived, never deleted.
    sql.exec(`CREATE TABLE IF NOT EXISTS session_index (
      session_id TEXT PRIMARY KEY, metadata_json TEXT NOT NULL, metadata_version INTEGER NOT NULL,
      missing INTEGER NOT NULL DEFAULT 0, epoch INTEGER, head INTEGER NOT NULL DEFAULT 0, chain TEXT)`);
    sql.exec("CREATE TABLE IF NOT EXISTS sync_round (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), round INTEGER NOT NULL)");
    // RFD0031: followers stay until their socket closes; `behind` marks one a notice failed to reach.
    sql.exec("DROP TABLE IF EXISTS subscribers");
    sql.exec("CREATE TABLE IF NOT EXISTS followers (client_do TEXT PRIMARY KEY, behind INTEGER NOT NULL DEFAULT 0)");
    sql.exec(`CREATE TABLE IF NOT EXISTS watchers (
      client_do TEXT NOT NULL, session_id TEXT NOT NULL, PRIMARY KEY (client_do, session_id))`);
  },
  (sql) => {
    // RFD0032, Host sync from the index: rows start distrusted; the fence only grows.
    addColumns(sql, "session_index", { verified: "INTEGER NOT NULL DEFAULT 0" });
    sql.exec("CREATE TABLE IF NOT EXISTS sync_fence (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), fence INTEGER NOT NULL)");
  },
  (sql) => {
    // RFD0032, release P: created so a rollback from protocol 3 finds the table; never read.
    sql.exec(`CREATE TABLE IF NOT EXISTS client_opens (
      socket_id TEXT NOT NULL, session_id TEXT NOT NULL, epoch INTEGER NOT NULL,
      sent INTEGER NOT NULL, acked INTEGER NOT NULL, PRIMARY KEY (socket_id, session_id))`);
  },
  (sql) => {
    // RFD0032, protocol 3: what each client socket has of each Session it opened (HostClients).
    // Release P's table was never written, and allowed no Session without records yet.
    sql.exec("DROP TABLE IF EXISTS client_opens");
    sql.exec(`CREATE TABLE client_opens (
      socket_id TEXT NOT NULL, session_id TEXT NOT NULL, epoch INTEGER, sent INTEGER NOT NULL,
      acked INTEGER NOT NULL, sent_at REAL NOT NULL, PRIMARY KEY (socket_id, session_id))`);
    sql.exec("CREATE INDEX IF NOT EXISTS client_opens_by_session ON client_opens(session_id)");
  },
  (sql) => {
    // When the account last recorded this host as seen, so an eviction doesn't lose the throttle.
    sql.exec(`CREATE TABLE IF NOT EXISTS account_touch (singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      host_generation TEXT NOT NULL, at REAL NOT NULL, last_seen_at TEXT NOT NULL)`);
  },
];

/**
 * Presence a HostDO reported while its base class was still being constructed, by generation.
 * The base constructor fences the routes of sockets that did not survive a restart (a deploy, an
 * eviction), which reports the host offline before this class's fields exist. The report waits
 * here, outside the object, and is sent once construction is done.
 */
const offlineDuringConstruction = new WeakMap<AxoHostDO, string>();

export class AxoHostDO extends AxoHostRelay {
  /** The newest progress snapshot per Session and slot; never stored (RFD0018, Ephemeral progress). */
  private readonly progress = new Map<string, Map<string, unknown>>();
  private readonly statuses = new Map<string, SessionStatus>();
  /**
   * What the Mac is asking the person now, by id (RFD0029); never stored. The Mac owns them and
   * sends them again when it reconnects, so they are dropped with its socket.
   */
  private readonly elicitations = new Map<string, Elicitation>();
  private readonly notices = new Map<string, HostNotice>();
  private noticeTimer: ReturnType<typeof setTimeout> | null = null;
  /**
   * Commands waiting for the host's reply, by the id they were sent with, and the connection they
   * went out on: only that connection's end leaves their outcome unknown.
   */
  private readonly commands = new Map<string, { method: HostRemoteMethod; generation: string; connectionId: string; resolve: (outcome: HostCommandOutcome) => void }>();
  /** `callHost` hops waiting for the daemon's reply, with the socket they were sent on. */
  private readonly hops = new Map<string, { connectionId: string; resolve: (outcome: HostCommandOutcome) => void }>();
  /** `axo.apps.*` calls from the daemon waiting for the account. */
  private appsCalls = 0;
  /** Protocol 3's client sockets (RFD0032). */
  private readonly clients: HostClients;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    migrate(ctx.storage, HOST_SCHEMA);
    this.clients = new HostClients(ctx, {
      hostId: () => this.identity()?.host_id,
      presence: () => this.presence(),
      sessions: () => this.ctx.storage.sql.exec<IndexRow>("SELECT * FROM session_index").toArray().map((row) => this.clientSession(row)),
      head: (sessionId) => {
        const row = this.indexRow(sessionId);
        return row && { epoch: row.epoch, head: row.head };
      },
      read: (sessionId, request) => this.session(sessionId).read(this.binding(sessionId), request),
      progress: (sessionId) => [...(this.progress.get(sessionId) ?? [])].map(([slot, snapshot]) => ({ slot, snapshot })),
      elicitations: () => [...this.elicitations.values()],
      command: (method, params) => this.command(method, params),
      resolveElicitation: (params) => this.resolveElicitation(params),
    });
    const offline = offlineDuringConstruction.get(this);
    if (offline !== undefined) {
      offlineDuringConstruction.delete(this);
      this.presenceChanged("", offline, "offline");
    }
  }

  // ─── Socket admission and registration ─────────────────────────────────────

  protected override supportsLegacyMachineMethods(): boolean { return false; }

  /**
   * The relay serves the Mac's daemon socket; a client socket of another shape, left by a newer
   * release, is closed when the object wakes (RFD0032, Release P).
   */
  protected override owns(attachment: unknown): boolean {
    return super.owns(attachment) && (attachment as Peer).role === "daemon";
  }

  /** Protocol 3's client sockets are this class's own (RFD0032). */
  protected override keeps(attachment: unknown): boolean {
    return isDirectClient(attachment);
  }

  /**
   * A protocol 3 client socket, which the Worker forwards once it has checked that the signed-in
   * account owns this host; anything else is the daemon's, through the relay.
   */
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("X-Axo-Role") !== DIRECT_CLIENT_ROLE) return super.fetch(request);
    const account = uuid.safeParse(request.headers.get("X-Axo-Account"));
    const host = uuid.safeParse(request.headers.get("X-Axo-Machine"));
    if (!account.success || !host.success || !this.bind(account.data, host.data)) return new Response("Invalid internal identity", { status: 403 });
    return this.clients.accept(request);
  }

  override async webSocketMessage(socket: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (this.clients.serves(socket)) return this.clients.receive(socket, raw);
    return super.webSocketMessage(socket, raw);
  }

  override webSocketClose(socket: WebSocket): void {
    if (this.clients.serves(socket)) return this.clients.closed(socket);
    super.webSocketClose(socket);
  }

  override webSocketError(socket: WebSocket): void {
    if (this.clients.serves(socket)) return this.clients.closed(socket);
    super.webSocketError(socket);
  }

  protected override async authorizeRelayPeer(request: Request, peer: Peer): Promise<boolean> {
    if (peer.role !== "daemon" || !this.bind(peer.identity, peer.machineId)) return false;
    return this.account().authorizeHost(
      peer.machineId,
      request.headers.get("X-Axo-Credential-Id") ?? "",
      request.headers.get("X-Axo-Credential") ?? "",
    );
  }

  protected override async storeHostRegistration(registration: unknown): Promise<HostSnapshot> {
    const now = Date.now();
    const snapshot = await this.account().registerHost(registration, now);
    // Registering records the host as seen, as a heartbeat's touch does.
    this.touched(snapshot.hostGeneration, now, snapshot.lastSeenAt);
    return snapshot;
  }

  protected override async storeHostHeartbeat(reference: unknown): Promise<{ acknowledged: true; lastSeenAt: string }> {
    // The account's last-seen time only needs SYNC.lastSeenMs resolution; presence is here (RFD0031).
    // It is kept in SQLite: kept in memory, every eviction between heartbeats cost a touch.
    const { hostId, hostGeneration } = reference as { hostId: string; hostGeneration: string };
    const last = this.ctx.storage.sql.exec<{ host_generation: string; at: number; last_seen_at: string }>(
      "SELECT host_generation, at, last_seen_at FROM account_touch WHERE singleton = 1").toArray()[0];
    if (last && last.host_generation === hostGeneration && Date.now() - last.at < SYNC.lastSeenMs)
      return { acknowledged: true, lastSeenAt: last.last_seen_at };
    const now = Date.now();
    const reply = await this.account().touchHost(hostId, hostGeneration, now);
    this.touched(hostGeneration, now, reply.lastSeenAt);
    return reply;
  }

  private touched(hostGeneration: string, at: number, lastSeenAt: string): void {
    this.ctx.storage.sql.exec(`INSERT INTO account_touch (singleton, host_generation, at, last_seen_at) VALUES (1, ?, ?, ?)
      ON CONFLICT(singleton) DO UPDATE SET host_generation = excluded.host_generation, at = excluded.at, last_seen_at = excluded.last_seen_at`,
      hostGeneration, at, lastSeenAt);
  }

  protected override async storeHostSessions(): Promise<{ storedAt: string }> {
    throw new Error("Sessions are synced with axo.host.sync");
  }

  /** The firehose is gone (RFD0018): a host that still sends it is out of date. */
  protected override async storeHostEvent(): Promise<void> {
    throw new Error("Host events are replaced by axo.host.sync");
  }

  protected override presenceChanged(_hostId: string, hostGeneration: string, status: "online" | "offline"): void {
    if (this.constructing()) {
      if (status === "offline") offlineDuringConstruction.set(this, hostGeneration);
      return;
    }
    if (status === "offline") {
      this.progress.clear();
      this.statuses.clear();
      for (const elicitation of this.elicitations.values())
        this.queue({ kind: "elicitationResolved", resolved: { id: elicitation.id, sessionId: elicitation.sessionId, action: "cancel" } });
      this.elicitations.clear();
    }
    this.queue({ kind: "presence", online: status === "online", hostGeneration }, true);
  }

  protected override fence(connectionId: string): void {
    super.fence(connectionId);
    // Nothing waits on a connection while the object is still being built: the maps start empty.
    if (this.constructing()) return;
    for (const [id, hop] of this.hops) {
      if (hop.connectionId !== connectionId) continue;
      this.hops.delete(id);
      hop.resolve({ error: { code: -32004, message: "Host disconnected; the call may have run" } });
    }
    for (const [id, command] of this.commands) {
      if (command.connectionId !== connectionId) continue;
      this.commands.delete(id);
      command.resolve({ error: { code: -32004, message: "Outcome unknown; reconcile commandId" } });
    }
  }

  /**
   * Whether the base class constructor is still running, so this class's fields do not exist
   * yet. The base constructor calls `fence` and, through it, `presenceChanged`.
   */
  private constructing(): boolean {
    return this.progress === undefined;
  }

  // ─── Upload: Axod → HostDO ─────────────────────────────────────────────────

  protected override hostMethodNames(): string[] {
    return [...Object.values(HOST_SYNC_METHODS), ELICITATION_METHODS.requested, ELICITATION_METHODS.resolved];
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
    if (call.method === ELICITATION_METHODS.requested) {
      const parsed = elicitationSchema.safeParse(call.params);
      if (!parsed.success || !this.ready(peer)) return true;
      if (!this.elicitations.has(parsed.data.id) && this.elicitations.size >= ELICITATION_LIMITS.pendingPerHost) return true;
      this.elicitations.set(parsed.data.id, parsed.data);
      recordApiEvent({ event: "elicitation_requested", kind: parsed.data.kind });
      this.queue({ kind: "elicitationRequested", elicitation: parsed.data }, true);
      return true;
    }
    if (call.method === ELICITATION_METHODS.resolved) {
      const parsed = elicitationResolvedSchema.safeParse(call.params);
      if (!parsed.success || !this.ready(peer)) return true;
      this.elicitations.delete(parsed.data.id);
      recordApiEvent({ event: "elicitation_resolved", outcome: parsed.data.action });
      this.queue({ kind: "elicitationResolved", resolved: parsed.data }, true);
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
    // A verified row that agrees with the manifest is the answer (RFD0032, answerFromIndex); the
    // rest are read from their SessionDO, with a fence raised once for this handshake.
    const states = new Map<string, CloudSessionState>();
    const toRead: string[] = [];
    for (const { sessionId, upload } of sessions) {
      const row = this.indexRow(sessionId);
      const agrees = row !== undefined && row.verified === 1 &&
        (upload === null || (row.epoch !== null && row.head === upload.count && row.chain === upload.chain));
      if (agrees) states.set(sessionId, indexState(row));
      else toRead.push(sessionId);
    }
    const fence = toRead.length > 0 ? this.raiseFence() : this.currentFence();
    for (let start = 0; start < toRead.length; start += 16) {
      await Promise.all(toRead.slice(start, start + 16).map(async (sessionId) => {
        const read = await this.syncHead(sessionId, fence);
        this.refreshHead(sessionId, read.head ? read.head.epoch : null, read.head?.count ?? 0, read.head?.chain ?? null, read.fenced);
        states.set(sessionId, read.head ? { sessionId, state: "known", ...read.head } : { sessionId, state: "unknown" });
      }));
    }
    this.renewRoute(peer);
    const answered = sessions.map(({ sessionId }) => states.get(sessionId)!);
    recordApiEvent({ event: "host_sync", sessions: sessions.length, read: toRead.length, unknown: answered.filter((state) => state.state === "unknown").length });
    return { round, applied: true, sessions: answered, serverOnly: serverOnly.slice(0, SYNC.manifestSessions) };
  }

  /** A SessionDO's head for the handshake, raising its fence. */
  private async syncHead(sessionId: string, fence: number): Promise<{ head: SessionHead | null; fenced: boolean }> {
    const read = await this.session(sessionId).syncHead(this.binding(sessionId), fence);
    this.adoptFence(read.fence);
    return { head: read.head && { epoch: read.head.epoch, count: read.head.count, chain: read.head.chain, heads: [...read.head.heads] }, fenced: read.fence >= fence };
  }

  private currentFence(): number {
    return this.ctx.storage.sql.exec<{ fence: number }>("SELECT fence FROM sync_fence WHERE singleton = 1").toArray()[0]?.fence ?? 0;
  }

  /** Raises the fence in SQLite, so it outlives a reset, and returns it. */
  private raiseFence(): number {
    const fence = this.currentFence() + 1;
    this.ctx.storage.sql.exec("INSERT INTO sync_fence (singleton, fence) VALUES (1, ?) ON CONFLICT(singleton) DO UPDATE SET fence = excluded.fence", fence);
    return fence;
  }

  /**
   * A SessionDO holds at most the fence this object gave it, so this changes nothing unless that
   * was lost. If it was, writes would be refused for good while the index went on answering; so
   * the HostDO takes up any higher fence an answer carries.
   */
  private adoptFence(fence: number | undefined): void {
    if (fence === undefined || fence <= this.currentFence()) return;
    this.ctx.storage.sql.exec("INSERT INTO sync_fence (singleton, fence) VALUES (1, ?) ON CONFLICT(singleton) DO UPDATE SET fence = excluded.fence", fence);
  }

  /** Marks a row distrusted before a write goes out: only the SessionDO's answer verifies it again (distrustWhileWriting). */
  private distrust(sessionId: string): void {
    this.ctx.storage.sql.exec("UPDATE session_index SET verified = 0 WHERE session_id = ?", sessionId);
  }

  private async append(params: unknown, { peer }: CallerContext): Promise<AppendResult> {
    const input = appendParamsSchema.safeParse(params);
    if (!input.success || !this.ready(peer)) throw new JSONRPCErrorException("Invalid append", -32602);
    const { sessionId } = input.data;
    if (!this.indexRow(sessionId)) throw new JSONRPCErrorException("Unknown Session; sync first", -32602);
    this.distrust(sessionId);
    const result = await this.session(sessionId).append(this.binding(sessionId), input.data, this.currentFence());
    recordApiEvent({ event: "session_append", outcome: result.outcome, records: input.data.records.length });
    this.renewRoute(peer);
    // Whatever the outcome, the answer says what the SessionDO holds, fenced: it verifies the row.
    this.adoptFence(result.fence);
    this.refreshHead(sessionId, result.epoch, result.count, result.chain, true);
    // A fenced write reaches axod as the conflict it already handles by handshaking again.
    if (result.outcome === "fenced") return { outcome: "conflict", epoch: result.epoch, count: result.count, chain: result.chain };
    if (result.outcome !== "committed") return { outcome: result.outcome, epoch: result.epoch, count: result.count, chain: result.chain };
    for (const slot of result.cleared) {
      if (!this.progress.get(sessionId)?.delete(slot)) continue;
      this.queue({ kind: "progress", sessionId, slot, snapshot: null });
    }
    // The records it just committed go to protocol 3's sockets from here, with no read
    // (pushFromAppend). Those sends happen before the first await; axod's answer waits for no read.
    void this.clients.committed(sessionId, result.epoch, committedRecords(input.data, result.count, result.added)).catch(() => undefined);
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
    this.distrust(sessionId);
    const result = await this.session(sessionId).truncate(this.binding(sessionId), keep, expectedChain, this.currentFence());
    recordApiEvent({ event: "session_truncate", outcome: result.outcome });
    this.adoptFence(result.fence);
    this.refreshHead(sessionId, result.epoch, result.count, result.chain, true);
    if (result.outcome !== "truncated") return { round, outcome: "mismatch" as const };
    // This HostDO made the cut, so protocol 3's sockets learn where with no read.
    this.clients.cut(sessionId, result.epoch, keep);
    this.queue({ kind: "epoch", sessionId, epoch: result.epoch, head: result.count }, true);
    // axod's schema is strict: only what it reads, never the fence.
    return { round, outcome: "truncated" as const, epoch: result.epoch, count: result.count, chain: result.chain };
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

  /**
   * The index caches each Session's head; subscribers hear when it changes. `verified` when the
   * head came in an answer carrying the SessionDO's fence.
   */
  private refreshHead(sessionId: string, epoch: number | null, head: number, chain: string | null, verified = false): void {
    const row = this.indexRow(sessionId);
    if (!row) return;
    if (verified !== (row.verified === 1)) this.ctx.storage.sql.exec("UPDATE session_index SET verified = ? WHERE session_id = ?", verified ? 1 : 0, sessionId);
    if (row.epoch === epoch && row.head === head && row.chain === chain) return;
    this.ctx.storage.sql.exec("UPDATE session_index SET epoch = ?, head = ?, chain = ? WHERE session_id = ?", epoch, head, chain, sessionId);
    if (row.epoch !== null && epoch !== null && epoch > row.epoch) {
      // Memory is per epoch: what was held may be past the cut.
      this.clients.epochMoved(sessionId);
      this.queue({ kind: "epoch", sessionId, epoch, head }, true);
    }
    this.queueSession(sessionId);
  }

  // ─── Delivery: ClientDO ↔ HostDO ───────────────────────────────────────────

  /** Adds a ClientDO as a follower until its socket closes, and returns the host's index. */
  async subscribe(clientDO: string): Promise<HostSubscription> {
    this.ctx.storage.sql.exec(`INSERT INTO followers (client_do, behind) VALUES (?, 0)
      ON CONFLICT(client_do) DO UPDATE SET behind = 0`, clientDO);
    const presence = this.presence();
    return {
      online: presence.online,
      hostGeneration: presence.hostGeneration,
      sessions: this.ctx.storage.sql.exec<IndexRow>("SELECT * FROM session_index").toArray().map((row) => this.clientSession(row)),
      progress: [...this.progress].flatMap(([sessionId, slots]) => [...slots].map(([slot, snapshot]) => ({ sessionId, slot, snapshot }))),
      elicitations: [...this.elicitations.values()],
    };
  }

  /**
   * A person's answer to what the Mac asked (RFD0029), from a ClientDO, which takes it only from
   * a signed-in person's client. The Mac decides: the first answer it takes wins.
   */
  async resolveElicitation(params: unknown): Promise<HostCommandOutcome> {
    const parsed = hostElicitationResolveParamsSchema.safeParse(params);
    if (!parsed.success) return { error: { code: -32602, message: "Invalid params" } };
    const presence = this.presence();
    if (!presence.online) return { error: { code: -32005, message: "Host offline; nothing sent" } };
    if (parsed.data.target.hostGeneration !== presence.hostGeneration) return { error: { code: -32002, message: "Stale host" } };
    if (!this.elicitations.has(parsed.data.elicitationId))
      return { error: { code: ELICITATION_ERRORS.notPending, message: "Already answered, or no longer asked" } };
    const outcome = await this.callHost({ method: ELICITATION_METHODS.resolve, params: parsed.data, deadlineMs: 15_000 });
    if ("error" in outcome) return outcome;
    return elicitationResolveResultSchema.safeParse(outcome.result).success
      ? outcome
      : { error: { code: -32004, message: "Invalid host outcome" } };
  }

  async unsubscribe(clientDO: string): Promise<void> {
    this.forgetFollower(clientDO);
  }

  /**
   * A follower opened a Session: its progress goes to that ClientDO from now on. Returns the
   * current snapshots.
   */
  async watch(clientDO: string, sessionId: string): Promise<Array<{ slot: string; snapshot: unknown }>> {
    const sql = this.ctx.storage.sql;
    if (sql.exec("SELECT 1 FROM followers WHERE client_do = ?", clientDO).toArray().length)
      sql.exec("INSERT OR IGNORE INTO watchers (client_do, session_id) VALUES (?, ?)", clientDO, sessionId);
    return [...(this.progress.get(sessionId) ?? [])].map(([slot, snapshot]) => ({ slot, snapshot }));
  }

  async unwatch(clientDO: string, sessionId: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM watchers WHERE client_do = ? AND session_id = ?", clientDO, sessionId);
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
        connectionId: active.route.connection_id,
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
    const hop = typeof reply.id === "string" ? this.hops.get(reply.id) : undefined;
    if (hop) {
      // A reply on a later socket answers nothing: that hop already failed as disconnected.
      if (this.peer(socket).connectionId !== hop.connectionId) return;
      this.hops.delete(reply.id as string);
      return hop.resolve("error" in reply ? { error: { code: reply.error.code, message: reply.error.message } } : { result: reply.result });
    }
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

  /**
   * Calls `method` on the host and waits for its reply, for the account (RFD0016, Apps).
   * It is sent once, never retried: a socket that ends or a deadline that passes first leaves the
   * outcome unknown, and a reply that comes later, on another socket, is ignored.
   */
  async callHost({ method, params, deadlineMs }: CallHostRequest): Promise<HostCommandOutcome> {
    const identity = this.identity();
    const active = identity ? this.active(identity.host_id) : undefined;
    if (!active || !active.route.ready || !active.route.generation) {
      recordApiEvent({ event: "host_call", outcome: "offline" });
      return { error: { code: -32005, message: "Host offline; nothing sent" } };
    }
    const id = crypto.randomUUID();
    const outcome = await new Promise<HostCommandOutcome>((resolve) => {
      const timer = setTimeout(() => {
        if (this.hops.delete(id)) resolve({ error: { code: -32004, message: "No answer in time; the call may have run" } });
      }, Math.min(Math.max(Math.floor(deadlineMs), 1), CALL_HOST_MAX_MS));
      this.hops.set(id, {
        connectionId: active.route.connection_id,
        resolve: (outcome) => {
          clearTimeout(timer);
          resolve(outcome);
        },
      });
      if (!this.send(active.socket, { jsonrpc: "2.0", id, method, params }) && this.hops.delete(id)) {
        clearTimeout(timer);
        resolve({ error: { code: -32004, message: "Host disconnected; the call may have run" } });
      }
    });
    recordApiEvent({ event: "host_call", outcome: "result" in outcome ? "result" : outcomeKind(outcome.error) });
    return outcome;
  }

  /**
   * An `axo.apps.*` call from the daemon goes to the account unchanged, and its outcome
   * back to the daemon. It is awaited without holding the socket: other messages keep flowing
   * while a slow one (an execute) runs.
   */
  protected override async receiveHostCall(socket: WebSocket, peer: Peer, call: Call): Promise<boolean> {
    if (!isAppsMethod(call.method)) return false;
    const answer = (outcome: HostCommandOutcome) => {
      if (socket.readyState !== WebSocket.OPEN) return;
      this.send(socket, "result" in outcome
        ? { jsonrpc: "2.0", id: call.id, result: outcome.result }
        // A reply's error message is at most 256 characters on the wire; a longer one would be refused by the Mac.
        : { jsonrpc: "2.0", id: call.id, error: { code: outcome.error.code, message: outcome.error.message.slice(0, 256) } });
    };
    const route = this.ready(peer) ? this.admittedDaemon(peer) : undefined;
    if (!route?.generation) {
      recordApiEvent({ event: "host_apps_call", outcome: "refused" });
      answer({ error: { code: -32002, message: "Stale lease" } });
      return true;
    }
    if (this.appsCalls >= LIMITS.pendingPerMachine) {
      recordApiEvent({ event: "host_apps_call", outcome: "refused" });
      answer({ error: { code: -32006, message: "Pending capacity" } });
      return true;
    }
    this.appsCalls += 1;
    let outcome: HostCommandOutcome;
    try {
      const reply = outcomeSchema.safeParse(await this.account().appsCall({
        hostId: peer.machineId, hostGeneration: route.generation, method: call.method, params: call.params,
      }));
      outcome = reply.success ? reply.data as HostCommandOutcome : { error: { code: -32004, message: "Outcome unknown; the call may have run" } };
    } catch {
      outcome = { error: { code: -32004, message: "Outcome unknown; the call may have run" } };
    } finally {
      this.appsCalls -= 1;
    }
    recordApiEvent({ event: "host_apps_call", outcome: "result" in outcome ? "result" : outcome.error.code === -32004 ? "unknown" : "error" });
    answer(outcome);
    return true;
  }

  /** Ends the host's connection (4003) because it was revoked; its credential no longer admits it. */
  async disconnect(): Promise<void> {
    const identity = this.identity();
    if (!identity) return;
    const active = this.active(identity.host_id);
    // Protocol 3's clients keep their sockets: they see the Mac go offline, its Sessions still
    // listed, until their next hello, which no longer lists it (as in protocol 2).
    if (active) this.drop(active.socket, 4003, "Host revoked");
    this.closeHostRelay(identity.host_id);
  }

  /** Tells the clients following this Mac its new name at once. */
  async renamed(label: string): Promise<void> {
    this.queue({ kind: "label", label }, true);
  }

  async presenceOf(): Promise<{ online: boolean; hostGeneration: string | null }> {
    return this.presence();
  }

  override presence() {
    const identity = this.identity();
    return identity ? super.presence(identity.host_id) : { online: false, hostGeneration: null };
  }

  // ─── Notices ───────────────────────────────────────────────────────────────

  private queueSession(sessionId: string): void {
    const row = this.indexRow(sessionId);
    if (row) this.queue({ kind: "session", session: this.clientSession(row) });
  }

  /** Gathers notices for `SYNC.noticeMs`, keeping the newest per key; `now` sends at once. */
  private queue(notice: HostNotice, now = false): void {
    const key = notice.kind === "presence" ? "presence"
      : notice.kind === "label" ? "label"
      : notice.kind === "elicitationRequested" ? `elicitation:${notice.elicitation.id}`
      : notice.kind === "elicitationResolved" ? `elicitation:${notice.resolved.id}`
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
    const followers = sql.exec<{ client_do: string; behind: number }>("SELECT client_do, behind FROM followers").toArray();
    const watching = new Map<string, Set<string>>();
    for (const row of sql.exec<{ client_do: string; session_id: string }>("SELECT client_do, session_id FROM watchers"))
      watching.set(row.client_do, (watching.get(row.client_do) ?? new Set()).add(row.session_id));
    let sent = 0;
    await Promise.all(followers.map(async ({ client_do, behind }) => {
      const watches = watching.get(client_do) ?? new Set<string>();
      // Progress and epochs are for the ClientDOs with that Session open (RFD0031).
      const batch = behind ? this.everything(watches) : notices.filter((notice) =>
        notice.kind !== "progress" && notice.kind !== "epoch" ? true : watches.has(notice.sessionId));
      if (behind) batch.push(...notices.filter((notice) => notice.kind === "epoch" && watches.has(notice.sessionId)));
      if (batch.length === 0) return;
      sent += 1;
      const client = this.client(client_do);
      // A notice that fails is sent again at once; if that fails too, the next one carries everything.
      const following = await client.notify(identity.host_id, batch)
        .catch(() => client.notify(identity.host_id, batch))
        .catch(() => null);
      if (following === false) this.forgetFollower(client_do);
      else if (following === null) sql.exec("UPDATE followers SET behind = 1 WHERE client_do = ?", client_do);
      else if (behind) sql.exec("UPDATE followers SET behind = 0 WHERE client_do = ?", client_do);
    }));
    if (sent) recordApiEvent({ event: "notice_batch", subscribers: sent, notices: notices.length });
    await this.clients.deliver(notices);
  }

  /** What a follower a notice failed to reach needs: the index, presence, and its Sessions' progress. */
  private everything(watches: Set<string>): HostNotice[] {
    const presence = this.presence();
    return [
      { kind: "presence", online: presence.online, hostGeneration: presence.hostGeneration },
      ...this.ctx.storage.sql.exec<IndexRow>("SELECT * FROM session_index").toArray()
        .map((row): HostNotice => ({ kind: "session", session: this.clientSession(row) })),
      ...[...watches].flatMap((sessionId) => [...(this.progress.get(sessionId) ?? [])]
        .map(([slot, snapshot]): HostNotice => ({ kind: "progress", sessionId, slot, snapshot }))),
      ...[...this.elicitations.values()].map((elicitation): HostNotice => ({ kind: "elicitationRequested", elicitation })),
    ];
  }

  private forgetFollower(clientDO: string): void {
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM followers WHERE client_do = ?", clientDO);
    sql.exec("DELETE FROM watchers WHERE client_do = ?", clientDO);
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

/**
 * The records an append committed, as clients see them: the last `added` of the batch, which end
 * at `count`. The SessionDO checked each one's line, id and hash before it committed them.
 */
export function committedRecords(params: { records: Array<{ id: string | null; line: string; hash: string }> }, count: number, added: number): ClientRecord[] {
  return params.records.slice(params.records.length - added).map((record, index) => ({
    cursor: count - added + index + 1, id: record.id, format: PI3_FORMAT, line: record.line, hash: record.hash,
  }));
}

/** A verified index row as the handshake's answer; axod ignores `heads`, which the index doesn't keep. */
function indexState(row: IndexRow): CloudSessionState {
  if (row.epoch === null || row.chain === null) return { sessionId: row.session_id, state: "unknown" };
  return { sessionId: row.session_id, state: "known", epoch: row.epoch, count: row.head, chain: row.chain, heads: [] };
}

function outcomeKind(error: { code: number; message: string }): "error" | "disconnected" | "timeout" {
  if (error.code !== -32004) return "error";
  return error.message.startsWith("No answer") ? "timeout" : "disconnected";
}
