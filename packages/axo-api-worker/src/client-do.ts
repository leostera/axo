import { DurableObject } from "cloudflare:workers";
import {
  CLIENT_METHODS,
  ELICITATION_ERRORS,
  ELICITATION_METHODS,
  clientElicitationResolveParamsSchema,
  DISCARD_METHOD,
  FRAGMENT_METHOD,
  MemoryPartialStore,
  SYNC,
  callSchema,
  clientAckParamsSchema,
  clientCloseParamsSchema,
  clientCommandParamsSchema,
  clientHelloParamsSchema,
  clientHostRenameParamsSchema,
  clientOlderParamsSchema,
  clientOpenParamsSchema,
  decode,
  discardParamsSchema,
  failure,
  receiveFragment,
  splitMessage,
  success,
  uuid,
  type Call,
  type ClientHost,
  type ClientOpenResult,
  type ClientSession,
  type Elicitation,
  type Reply,
} from "@axo/protocol";
import { z } from "zod";
import { hostDOName, type HostCommandOutcome, type HostNotice, type HostSubscription } from "./host-do";
import { sessionDOName, type ReadRequest, type ReadResult, type SessionBinding } from "./session-store";
import { recordApiEvent } from "./observability";

/**
 * One connected client (RFD0018, ClientDO): a browser tab or an app instance, named by
 * (account, clientId). It holds that client's single socket, follows each of the account's hosts
 * on its HostDO for as long as the socket is open, and serves the windows of the Sessions the
 * client has open, one batch at a time: the next batch goes only after the client acknowledges
 * the last.
 *
 * It never wakes itself (RFD0031): it runs when its client sends a frame, or when a HostDO or the
 * account calls it. A call that fails is made again at once, while it is awake.
 */

export function clientDOName(accountId: string, clientId: string): string {
  return `${uuid.parse(accountId)}:${clientId}`;
}

/**
 * The client id of a paired Mac following its account's other Macs (RFD0022). The Mac signs in
 * with its host credential, and its own Sessions are left out: it has them already.
 */
export function peerClientId(hostId: string): string {
  return `host-${uuid.parse(hostId)}`;
}

function peerHostOf(clientId: string): string | null {
  return clientId.startsWith("host-") ? clientId.slice("host-".length) : null;
}

/** Frames a client may send per second; acknowledgements count. */
const FRAMES_PER_SECOND = 60;
/** The largest message a client may send, reassembled. */
const CLIENT_MESSAGE_BYTES = 1_048_576;

const attachmentSchema = z.object({
  accountId: uuid,
  clientId: z.string(),
  expiresAt: z.number(),
  window: z.number(),
  calls: z.number(),
}).strict();
type Attachment = z.infer<typeof attachmentSchema>;

type HostRow = { host_id: string; host_generation: string; label: string; host_kind: string; online: number; last_seen_at: string };
/**
 * A Session the client has open. `acked` is the last cursor the client acknowledged, `sent` the
 * last one sent: a batch is outstanding while they differ. `read_id` is no longer used: read ids
 * live in memory (RFD0031).
 */
type OpenRow = { session_id: string; host_id: string; epoch: number | null; sent: number; acked: number; read_id: number; sent_at: number };

type AccountStub = {
  clientHosts(clientDO?: string): Promise<Array<Omit<ClientHost, "online">>>;
  unfollow(clientDO: string): Promise<void>;
  renameHost(hostId: string, name: string): Promise<string | null>;
};
type HostStub = {
  subscribe(clientDO: string): Promise<HostSubscription>;
  unsubscribe(clientDO: string): Promise<void>;
  watch(clientDO: string, sessionId: string): Promise<Array<{ slot: string; snapshot: unknown }>>;
  unwatch(clientDO: string, sessionId: string): Promise<void>;
  command(method: string, params: unknown): Promise<HostCommandOutcome>;
  resolveElicitation(params: unknown): Promise<HostCommandOutcome>;
};
/** The head a Session's notices or reads last reported, in its epoch. */
type KnownHead = { epoch: number | null; head: number };
type SessionStub = { read(binding: SessionBinding, request: ReadRequest): Promise<ReadResult> };

export class AxoClientDO extends DurableObject<Env> {
  private readonly partials = new MemoryPartialStore();
  /**
   * The latest read per open Session: a reply to an older one is ignored. In memory, since a read
   * in flight keeps the object in memory, so no row is written before each read.
   */
  private readonly reads = new Map<string, number>();
  /**
   * Each open Session's head as last reported, so a notice that brings nothing new reads nothing.
   * Lost on eviction, which only costs one read.
   */
  private readonly heads = new Map<string, KnownHead>();
  /** What the Macs were asking when last followed, sent once the listing has gone (RFD0029). */
  private asked: Array<{ hostId: string; elicitation: Elicitation }> = [];

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    sql.exec(`CREATE TABLE IF NOT EXISTS client_identity (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), account_id TEXT NOT NULL, client_id TEXT NOT NULL)`);
    sql.exec(`CREATE TABLE IF NOT EXISTS hosts (host_id TEXT PRIMARY KEY, host_generation TEXT NOT NULL, label TEXT NOT NULL,
      host_kind TEXT NOT NULL, online INTEGER NOT NULL, last_seen_at TEXT NOT NULL)`);
    sql.exec(`CREATE TABLE IF NOT EXISTS open_sessions (session_id TEXT PRIMARY KEY, host_id TEXT NOT NULL, epoch INTEGER,
      sent INTEGER NOT NULL, acked INTEGER NOT NULL, read_id INTEGER NOT NULL, sent_at REAL NOT NULL)`);
  }

  // ─── Socket ────────────────────────────────────────────────────────────────

  async fetch(request: Request): Promise<Response> {
    const attachment = attachmentSchema.safeParse({
      accountId: request.headers.get("X-Axo-Account"),
      clientId: request.headers.get("X-Axo-Client"),
      expiresAt: Number(request.headers.get("X-Axo-Expiry")),
      window: Date.now(),
      calls: 0,
    });
    if (!attachment.success || attachment.data.expiresAt <= Date.now() || !this.bind(attachment.data.accountId, attachment.data.clientId))
      return new Response("Invalid internal identity", { status: 403 });
    // One socket per client: a reconnect replaces the old one and starts afresh.
    for (const old of this.ctx.getWebSockets()) old.close(4000, "Replaced");
    await this.forget();
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server!);
    server!.serializeAttachment(attachment.data);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const peer = this.peer(socket);
    if (!peer || peer.expiresAt <= Date.now()) return socket.close(4001, "Sign-in expired");
    if (typeof raw !== "string") return socket.close(1003, "Text required");
    if (Date.now() - peer.window >= 1000) Object.assign(peer, { window: Date.now(), calls: 0 });
    peer.calls += 1;
    socket.serializeAttachment(peer);
    if (peer.calls > FRAMES_PER_SECOND) return socket.close(1008, "Rate limit");

    let decoded = decode(raw);
    if ("error" in decoded) return void this.send(socket, decoded.error);
    const frame = decoded.batch ? undefined : callSchema.safeParse(decoded.entries[0]);
    if (frame?.success && frame.data.method === DISCARD_METHOD) {
      const notice = discardParamsSchema.safeParse(frame.data.params);
      if (notice.success) this.partials.discard(notice.data.messageId);
      return;
    }
    if (frame?.success && frame.data.method === FRAGMENT_METHOD) {
      const outcome = receiveFragment(this.partials, frame.data.params);
      if (outcome.status === "invalid") return socket.close(1008, `Invalid fragment: ${outcome.reason}`);
      if (outcome.status !== "complete") return;
      decoded = decode(outcome.raw, CLIENT_MESSAGE_BYTES);
      if ("error" in decoded) return void this.send(socket, decoded.error);
    }
    if (decoded.batch) return void this.send(socket, failure(null, -32600, "Batches are not supported"));
    const call = callSchema.safeParse(decoded.entries[0]);
    if (!call.success) return void this.send(socket, failure(null, -32600, "Invalid Request"));
    const reply = await this.receive(socket, peer, call.data);
    if (reply && call.data.id !== undefined) this.send(socket, reply);
    // What the Macs are asking now follows the listing, as if just asked (RFD0029).
    if ((call.data.method === CLIENT_METHODS.hello || call.data.method === CLIENT_METHODS.refresh) && reply && "result" in reply)
      this.sendElicitations(socket);
    // What the open did not return follows it, in batches.
    if (call.data.method === CLIENT_METHODS.open && reply && "result" in reply)
      await this.pump(clientOpenParamsSchema.parse(call.data.params).sessionId);
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
    if (!this.ctx.getWebSockets().some((other) => other !== socket)) await this.forget();
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    await this.webSocketClose(socket);
  }

  /**
   * An alarm a ClientDO set before RFD0031 fires once, does nothing, and is not set again. Kept
   * so those alarms end cleanly instead of failing and being retried.
   */
  async alarm(): Promise<void> {}

  /**
   * The account's hosts changed (a Mac paired or revoked): list them again and follow any new
   * one. False tells the account this client is gone.
   */
  async hostsChanged(): Promise<boolean> {
    const socket = this.socket();
    if (!socket || !this.identity()) return false;
    await this.followHosts(socket, false);
    this.sendElicitations(socket);
    return true;
  }

  // ─── Notices from HostDOs ──────────────────────────────────────────────────

  /** Notices from a HostDO; false tells it this client no longer follows it. */
  async notify(hostId: string, notices: HostNotice[]): Promise<boolean> {
    const socket = this.socket();
    const host = this.host(hostId);
    if (!socket || !host) return false;
    const sessions: ClientSession[] = [];
    for (const notice of notices) {
      switch (notice.kind) {
        case "presence":
          this.ctx.storage.sql.exec("UPDATE hosts SET online = ?, host_generation = COALESCE(?, host_generation) WHERE host_id = ?",
            notice.online ? 1 : 0, notice.hostGeneration, hostId);
          this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.hosts, params: { hosts: this.hosts() } });
          break;
        case "session":
          sessions.push(notice.session);
          if (this.open(notice.session.sessionId)?.host_id === hostId)
            this.heads.set(notice.session.sessionId, { epoch: notice.session.epoch, head: notice.session.head });
          break;
        case "progress":
          if (this.open(notice.sessionId)?.host_id === hostId)
            this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.progress, params: { sessionId: notice.sessionId, slot: notice.slot, snapshot: notice.snapshot } });
          break;
        case "epoch":
          if (this.open(notice.sessionId)?.host_id === hostId) this.heads.set(notice.sessionId, { epoch: notice.epoch, head: notice.head });
          break;
        case "label":
          this.ctx.storage.sql.exec("UPDATE hosts SET label = ? WHERE host_id = ?", notice.label, hostId);
          this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.hosts, params: { hosts: this.hosts() } });
          break;
        // Only people see what a Mac asks: a Mac following its peers does not (RFD0029).
        case "elicitationRequested":
          if (this.isPerson()) this.send(socket, { jsonrpc: "2.0", method: ELICITATION_METHODS.requested, params: { hostId, elicitation: notice.elicitation } });
          break;
        case "elicitationResolved":
          if (this.isPerson()) this.send(socket, { jsonrpc: "2.0", method: ELICITATION_METHODS.resolved, params: { hostId, ...notice.resolved } });
          break;
      }
    }
    if (sessions.length) this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.sessions, params: { hostId, sessions } });
    // Anything that moved an open Session's head or epoch may have records for it.
    const touched = new Set(notices.flatMap((notice) =>
      notice.kind === "session" ? [notice.session.sessionId] : notice.kind === "epoch" ? [notice.sessionId] : []));
    for (const sessionId of touched) {
      const open = this.open(sessionId);
      if (!open || open.host_id !== hostId) continue;
      const epochMoved = notices.some((notice) => notice.kind === "epoch" && notice.sessionId === sessionId && notice.epoch !== open.epoch)
        || notices.some((notice) => notice.kind === "session" && notice.session.sessionId === sessionId && notice.session.epoch !== null && open.epoch !== null && notice.session.epoch !== open.epoch);
      await this.pump(sessionId, epochMoved);
    }
    return true;
  }

  // ─── Client requests ───────────────────────────────────────────────────────

  private async receive(socket: WebSocket, peer: Attachment, call: Call): Promise<Reply | null> {
    const id = call.id ?? null;
    try {
      switch (call.method) {
        case CLIENT_METHODS.hello: {
          const params = clientHelloParamsSchema.safeParse(call.params);
          if (!params.success) return failure(id, -32602, "Invalid params");
          if (params.data.clientId !== peer.clientId) return failure(id, -32602, "clientId does not match the socket");
          const sessions = await this.followHosts(socket, true);
          return success(id, { hosts: this.hosts(), sessions });
        }
        case CLIENT_METHODS.refresh: {
          const sessions = await this.followHosts(socket, true);
          return success(id, { hosts: this.hosts(), sessions });
        }
        case CLIENT_METHODS.open: {
          const params = clientOpenParamsSchema.safeParse(call.params);
          // A Mac reads back its own Sessions too: the archived ones it deleted (RFD0027).
          const ownSession = params.success && params.data.hostId === peerHostOf(this.identity()!.clientId);
          if (!params.success || !(ownSession || this.host(params.data.hostId))) return failure(id, -32602, "Invalid params");
          return success(id, await this.openSession(socket, params.data));
        }
        case CLIENT_METHODS.ack: {
          const params = clientAckParamsSchema.safeParse(call.params);
          if (params.success) await this.ack(params.data.sessionId, params.data.cursor);
          return null;
        }
        case CLIENT_METHODS.older: {
          const params = clientOlderParamsSchema.safeParse(call.params);
          const open = params.success ? this.open(params.data.sessionId) : undefined;
          if (!params.success || !open) return failure(id, -32602, "Invalid params");
          const read = await this.read(open, { epoch: open.epoch, before: params.data.before, limit: params.data.limit });
          if (read.kind === "reset") {
            this.reset(socket, open, read);
            return success(id, { epoch: read.epoch, records: [], older: null });
          }
          return success(id, { epoch: read.epoch, records: read.records, older: read.older });
        }
        case CLIENT_METHODS.close: {
          const params = clientCloseParamsSchema.safeParse(call.params);
          const open = params.success ? this.open(params.data.sessionId) : undefined;
          if (!open) return null;
          this.ctx.storage.sql.exec("DELETE FROM open_sessions WHERE session_id = ?", open.session_id);
          this.reads.delete(open.session_id);
          this.heads.delete(open.session_id);
          if (this.host(open.host_id)) await this.hostStub(open.host_id).unwatch(this.name(), open.session_id).catch(() => undefined);
          return null;
        }
        case CLIENT_METHODS.command: {
          const params = clientCommandParamsSchema.safeParse(call.params);
          if (!params.success || !this.host(params.data.hostId)) return failure(id, -32602, "Invalid params");
          // A call that throws may have reached the host: its outcome is unknown, not an
          // invitation to try again with a new commandId (RFD0024).
          const outcome = await this.hostStub(params.data.hostId)
            .command(params.data.method, params.data.params)
            .catch(() => ({ error: { code: -32004, message: "Outcome unknown; reconcile commandId" } }));
          return "error" in outcome ? failure(id, outcome.error.code, outcome.error.message) : success(id, outcome.result);
        }
        case ELICITATION_METHODS.resolve: {
          // Only a person answers: a Mac's own credential cannot, for any Mac (RFD0029).
          if (!this.isPerson()) return failure(id, ELICITATION_ERRORS.notAPerson, "Only a person answers");
          const params = clientElicitationResolveParamsSchema.safeParse(call.params);
          const host = params.success ? this.host(params.data.hostId) : undefined;
          if (!params.success || !host) return failure(id, -32602, "Invalid params");
          const { hostId, elicitationId, action } = params.data;
          const outcome = await this.hostStub(hostId)
            .resolveElicitation({ target: { hostId, hostGeneration: host.host_generation }, elicitationId, action })
            .catch(() => ({ error: { code: -32004, message: "Outcome unknown" } }));
          return "error" in outcome ? failure(id, outcome.error.code, outcome.error.message) : success(id, outcome.result);
        }
        case CLIENT_METHODS.renameHost: {
          const params = clientHostRenameParamsSchema.safeParse(call.params);
          if (!params.success || !this.host(params.data.hostId)) return failure(id, -32602, "Invalid params");
          const label = await this.account().renameHost(params.data.hostId, params.data.name);
          if (label === null) return failure(id, -32602, "Invalid params");
          this.ctx.storage.sql.exec("UPDATE hosts SET label = ? WHERE host_id = ?", label, params.data.hostId);
          return success(id, { label });
        }
        default:
          return failure(id, -32601, "Method not found");
      }
    } catch {
      return failure(id, -32603, "Unavailable; try again");
    }
  }

  /**
   * Opens a Session: the records after `have`, or the last `window` of them. The open counts as
   * acknowledged, and anything past it follows in batches.
   */
  private async openSession(socket: WebSocket, params: z.infer<typeof clientOpenParamsSchema>): Promise<ClientOpenResult> {
    const sql = this.ctx.storage.sql;
    const readId = this.nextRead(params.sessionId);
    sql.exec(`INSERT INTO open_sessions (session_id, host_id, epoch, sent, acked, read_id, sent_at) VALUES (?, ?, NULL, 0, 0, 0, 0)
      ON CONFLICT(session_id) DO UPDATE SET host_id = excluded.host_id`, params.sessionId, params.hostId);
    const open = this.open(params.sessionId)!;
    // Progress goes only to the clients watching a Session (RFD0031). A Mac reading back its own
    // archived Session follows no HostDO for itself, and there is nothing in progress there.
    const progress = this.host(params.hostId) ? this.watch(params.hostId, params.sessionId) : Promise.resolve([]);
    let read = params.have
      ? await this.read(open, { epoch: params.have.epoch, after: params.have.cursor, limit: SYNC.clientRecords })
      : await this.read(open, { epoch: null, last: params.window?.last ?? SYNC.defaultWindow, limit: SYNC.clientRecords });
    if (read.kind === "reset") {
      // The client's copy is from an older epoch: it drops past the cut, then reads on from there.
      this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.reset, params: { sessionId: params.sessionId, epoch: read.epoch, keep: read.keep } });
      read = await this.read(open, { epoch: read.epoch, after: Math.min(params.have!.cursor, read.keep), limit: SYNC.clientRecords });
    }
    if (read.kind === "reset" || this.reads.get(params.sessionId) !== readId) throw new Error("superseded");
    const cursor = read.records.at(-1)?.cursor ?? (params.have ? Math.min(params.have.cursor, read.count) : read.count);
    sql.exec("UPDATE open_sessions SET epoch = ?, sent = ?, acked = ?, sent_at = ? WHERE session_id = ?", read.epoch, cursor, cursor, Date.now(), params.sessionId);
    this.heads.set(params.sessionId, { epoch: read.epoch, head: read.count });
    recordApiEvent({ event: "client_open", records: read.records.length });
    return {
      epoch: read.epoch,
      records: read.records,
      cursor,
      older: params.have ? null : read.older,
      progress: await progress,
      // A copy that starts from nothing needs Pi's header line too (RFD0022).
      ...(params.have?.cursor === 0 && read.header !== null ? { header: read.header } : {}),
    };
  }

  private async ack(sessionId: string, cursor: number): Promise<void> {
    const open = this.open(sessionId);
    if (!open || cursor < open.acked || cursor > open.sent) return;
    this.ctx.storage.sql.exec("UPDATE open_sessions SET acked = ? WHERE session_id = ?", cursor, sessionId);
    if (cursor === open.sent) await this.pump(sessionId);
  }

  /**
   * Sends the next batch of an open Session, reading only when there is something to send
   * (RFD0031): no batch is outstanding and the Session's head is past what was sent, or the head
   * is unknown. With `epochMoved` it reads at once, outstanding batch or not, to learn where the
   * Session was cut. A batch outstanding for `SYNC.stallMs` is sent again.
   */
  private async pump(sessionId: string, epochMoved = false): Promise<void> {
    const socket = this.socket();
    let open = this.open(sessionId);
    if (!socket || !open) return;
    if (!epochMoved && open.sent !== open.acked) {
      if (Date.now() - open.sent_at < SYNC.stallMs) return;
      // The client never acknowledged it; it ignores records it already holds.
      this.ctx.storage.sql.exec("UPDATE open_sessions SET sent = acked WHERE session_id = ?", sessionId);
      recordApiEvent({ event: "client_stalled" });
      open = { ...open, sent: open.acked };
    }
    if (!epochMoved && !hasNews(open, this.heads.get(sessionId))) return;
    const readId = this.nextRead(sessionId);
    const read = await this.read(open, { epoch: open.epoch, after: open.acked, limit: SYNC.clientRecords });
    const current = this.open(sessionId);
    if (!current || this.reads.get(sessionId) !== readId) return;
    if (read.kind === "reset") {
      this.reset(socket, current, read);
      return this.pump(sessionId);
    }
    this.heads.set(sessionId, { epoch: read.epoch, head: read.count });
    if (current.sent !== current.acked || read.records.length === 0) {
      if (current.epoch === null && read.epoch !== null) this.ctx.storage.sql.exec("UPDATE open_sessions SET epoch = ? WHERE session_id = ?", read.epoch, sessionId);
      return;
    }
    const cursor = read.records.at(-1)!.cursor;
    this.ctx.storage.sql.exec("UPDATE open_sessions SET epoch = ?, sent = ?, sent_at = ? WHERE session_id = ?", read.epoch, cursor, Date.now(), sessionId);
    this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.records, params: { sessionId, epoch: read.epoch, records: read.records, cursor } });
  }

  private nextRead(sessionId: string): number {
    const id = (this.reads.get(sessionId) ?? 0) + 1;
    this.reads.set(sessionId, id);
    return id;
  }

  /** Tells the client its copy was cut back, and continues in the new epoch from the cut. */
  private reset(socket: WebSocket, open: OpenRow, read: Extract<ReadResult, { kind: "reset" }>): void {
    const keep = Math.min(open.acked, read.keep);
    this.ctx.storage.sql.exec("UPDATE open_sessions SET epoch = ?, sent = ?, acked = ? WHERE session_id = ?", read.epoch, keep, keep, open.session_id);
    this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.reset, params: { sessionId: open.session_id, epoch: read.epoch, keep: read.keep } });
  }

  private read(open: OpenRow, request: ReadRequest): Promise<ReadResult> {
    const { accountId } = this.identity()!;
    const binding = { accountId, hostId: open.host_id, sessionId: open.session_id };
    const stub = this.ctx.exports.AxoSessionDO.getByName(sessionDOName(accountId, open.host_id, open.session_id)) as unknown as SessionStub;
    return stub.read(binding, request);
  }

  /**
   * Lists the account's hosts and subscribes to each, which also returns each host's index. A
   * host the account no longer lists is let go.
   */
  private async followHosts(socket: WebSocket, hello: boolean): Promise<ClientSession[]> {
    const account = this.account();
    const self = peerHostOf(this.identity()!.clientId);
    const name = this.name();
    // The account remembers this client, and says when its hosts change (RFD0031).
    const listed = (await account.clientHosts(name)).filter((host) => host.hostId !== self);
    const sql = this.ctx.storage.sql;
    const sessions: ClientSession[] = [];
    const followed = new Set<string>();
    this.asked = [];
    await Promise.all(listed.map(async (host) => {
      try {
        // Subscribed until the socket closes; a call that fails is made again at once (RFD0031).
        const subscription = await this.hostStub(host.hostId).subscribe(name)
          .catch(() => this.hostStub(host.hostId).subscribe(name));
        followed.add(host.hostId);
        sql.exec(`INSERT INTO hosts (host_id, host_generation, label, host_kind, online, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(host_id) DO UPDATE SET host_generation = excluded.host_generation, label = excluded.label,
          host_kind = excluded.host_kind, online = excluded.online, last_seen_at = excluded.last_seen_at`,
          host.hostId, subscription.hostGeneration ?? host.hostGeneration, host.label, host.hostKind, subscription.online ? 1 : 0, host.lastSeenAt);
        sessions.push(...subscription.sessions);
        for (const elicitation of subscription.elicitations ?? []) this.asked.push({ hostId: host.hostId, elicitation });
      } catch {
        recordApiEvent({ event: "client_follow_failed" });
      }
    }));
    for (const row of sql.exec<{ host_id: string }>("SELECT host_id FROM hosts").toArray()) {
      if (listed.some((host) => host.hostId === row.host_id)) continue;
      sql.exec("DELETE FROM hosts WHERE host_id = ?", row.host_id);
      await this.hostStub(row.host_id).unsubscribe(name).catch(() => undefined);
    }
    if (!hello) {
      this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.hosts, params: { hosts: this.hosts() } });
      for (const hostId of followed) {
        const hostSessions = sessions.filter((session) => session.hostId === hostId);
        if (hostSessions.length) this.send(socket, { jsonrpc: "2.0", method: CLIENT_METHODS.sessions, params: { hostId, sessions: hostSessions } });
      }
      // The index heals what a lost notice left behind: read whatever an open Session is missing.
      for (const session of sessions) {
        const open = this.open(session.sessionId);
        if (!open || open.host_id !== session.hostId) continue;
        this.heads.set(session.sessionId, { epoch: session.epoch, head: session.head });
        await this.pump(session.sessionId, session.epoch !== null && open.epoch !== null && session.epoch !== open.epoch);
      }
    }
    return sessions;
  }

  /** The socket closed: let go of every host, the account, and every open Session. */
  private async forget(): Promise<void> {
    const identity = this.identity();
    const sql = this.ctx.storage.sql;
    const hosts = sql.exec<{ host_id: string }>("SELECT host_id FROM hosts").toArray();
    sql.exec("DELETE FROM hosts");
    sql.exec("DELETE FROM open_sessions");
    this.partials.clear();
    this.reads.clear();
    this.heads.clear();
    if (!identity) return;
    const name = this.name();
    await Promise.allSettled([
      this.account().unfollow(name),
      ...hosts.map((host) => this.hostStub(host.host_id).unsubscribe(name)),
    ]);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  /** A signed-in person's client, not a Mac following its peers. */
  private isPerson(): boolean {
    const identity = this.identity();
    return Boolean(identity) && peerHostOf(identity!.clientId) === null;
  }

  private sendElicitations(socket: WebSocket): void {
    const asked = this.asked;
    this.asked = [];
    if (!this.isPerson()) return;
    for (const { hostId, elicitation } of asked)
      this.send(socket, { jsonrpc: "2.0", method: ELICITATION_METHODS.requested, params: { hostId, elicitation } });
  }

  private send(socket: WebSocket, value: unknown): boolean {
    const frames = splitMessage(JSON.stringify(value), crypto.randomUUID().replaceAll("-", ""));
    if (!frames) {
      recordApiEvent({ event: "relay_send_failed", reason: "too_large" });
      return false;
    }
    try {
      for (const frame of frames) socket.send(frame);
      return true;
    } catch {
      return false;
    }
  }

  private hosts(): ClientHost[] {
    return this.ctx.storage.sql.exec<HostRow>("SELECT * FROM hosts ORDER BY host_id").toArray().map((row) => ({
      hostId: row.host_id, hostGeneration: row.host_generation, label: row.label, hostKind: row.host_kind,
      online: row.online === 1, lastSeenAt: row.last_seen_at,
    }));
  }

  private host(hostId: string): HostRow | undefined {
    return this.ctx.storage.sql.exec<HostRow>("SELECT * FROM hosts WHERE host_id = ?", hostId).toArray()[0];
  }

  private open(sessionId: string): OpenRow | undefined {
    return this.ctx.storage.sql.exec<OpenRow>("SELECT * FROM open_sessions WHERE session_id = ?", sessionId).toArray()[0];
  }

  private openRows(): OpenRow[] {
    return this.ctx.storage.sql.exec<OpenRow>("SELECT * FROM open_sessions").toArray();
  }

  /** This ClientDO's name, as HostDOs and the account call it back. */
  private name(): string {
    const { accountId, clientId } = this.identity()!;
    return clientDOName(accountId, clientId);
  }

  /** Watches an open Session on its host and returns its progress; a failed call is made again at once. */
  private watch(hostId: string, sessionId: string): Promise<Array<{ slot: string; snapshot: unknown }>> {
    const host = this.hostStub(hostId);
    return host.watch(this.name(), sessionId)
      .catch(() => host.watch(this.name(), sessionId))
      .catch(() => []);
  }

  private account(): AccountStub {
    return this.ctx.exports.AxoAccountDirectory.getByName(this.identity()!.accountId) as unknown as AccountStub;
  }

  private hostStub(hostId: string): HostStub {
    return this.ctx.exports.AxoHostDO.getByName(hostDOName(this.identity()!.accountId, hostId)) as unknown as HostStub;
  }

  private socket(): WebSocket | undefined {
    return this.ctx.getWebSockets().find((socket) =>
      socket.readyState === WebSocket.OPEN && (this.peer(socket)?.expiresAt ?? 0) > Date.now());
  }

  private peer(socket: WebSocket): Attachment | null {
    const parsed = attachmentSchema.safeParse(socket.deserializeAttachment());
    return parsed.success ? parsed.data : null;
  }

  private identity(): { accountId: string; clientId: string } | undefined {
    const row = this.ctx.storage.sql.exec<{ account_id: string; client_id: string }>(
      "SELECT account_id, client_id FROM client_identity WHERE singleton = 1").toArray()[0];
    return row && { accountId: row.account_id, clientId: row.client_id };
  }

  private bind(accountId: string, clientId: string): boolean {
    const identity = this.identity();
    if (!identity) {
      this.ctx.storage.sql.exec("INSERT INTO client_identity (singleton, account_id, client_id) VALUES (1, ?, ?)", accountId, clientId);
      return true;
    }
    return identity.accountId === accountId && identity.clientId === clientId;
  }
}

/** Whether an open Session may have records its client doesn't: its head is past what was sent, or unknown. */
export function hasNews(open: Pick<OpenRow, "epoch" | "sent">, known: KnownHead | undefined): boolean {
  return known === undefined || known.epoch !== open.epoch || known.head > open.sent;
}
