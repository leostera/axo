import { DurableObject } from "cloudflare:workers";
import {
  LIMITS,
  callSchema,
  decode,
  failure,
  negotiateSchema,
  unsupportedProtocolVersionCode,
  replySchema,
  type Call,
  type Reply,
  createProfileServer,
  JSONRPCErrorException,
  type JSONRPCServer,
  type TypedJSONRPCServer,
  type ServiceMethods,
  FRAGMENT_METHOD,
  DISCARD_METHOD,
  FRAGMENTS,
  discardParamsSchema,
  receiveFragment,
  splitMessage,
  type Decoded,
  type PartialStore,
  SHARE_PUBLISH_METHOD,
  sharePublishParamsSchema,
  shareSlug,
  type SharePublishResult,
} from "@axo/protocol";
import { hostV1Methods, hostV1Results, type HostSnapshot } from "@axo/protocol/v1";
import { UNOWNED_CLOSE, peerSchema, type Peer, type CallerContext, type Route } from "./relay/peer";
import { recordApiEvent } from "./observability";
import { boundReplies } from "./relay/replies";
import { APP_ORIGIN } from "./auth/config";
import type { z } from "zod";

type HostRegistrationMethods = {
  "axo.host.register": (
    params: z.input<typeof hostV1Methods["axo.host.register"]>,
  ) => z.output<typeof hostV1Results["axo.host.register"]>;
  "axo.host.heartbeat": (
    params: z.input<typeof hostV1Methods["axo.host.heartbeat"]>,
  ) => z.output<typeof hostV1Results["axo.host.heartbeat"]>;
};

/**
 * Inbound frame budget for the Mac's socket per second. A host streams terminal output as one
 * frame per PTY read; the budget still bounds it to about 38 MiB/s of 64 KiB frames.
 */
export const DAEMON_FRAMES_PER_SECOND = 600;
const byteLength = (raw: string) => new TextEncoder().encode(raw).byteLength;

/**
 * The Mac's socket to its HostDO: admission, negotiation, the lease that registration starts and
 * every frame renews, messages larger than a frame (RFD0016, Transport), and share publishing.
 * Everything else the Mac says is the subclass's, through the hooks below.
 *
 * A route is the lease of the Mac's current connection, one row per host. It is connection
 * state, not data: `reconcile` fences the route of a socket that did not survive a restart.
 */
export abstract class AxoHostRelay extends DurableObject<Env> {
  private readonly rpc: JSONRPCServer<CallerContext>;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    // A route table from before one row per host has no rows worth keeping: they are leases.
    if (sql.exec<{ name: string }>("PRAGMA table_info(route)").toArray().some((column) => column.name === "singleton"))
      sql.exec("DROP TABLE route");
    sql.exec("CREATE TABLE IF NOT EXISTS route (machine_id TEXT PRIMARY KEY, connection_id TEXT NOT NULL UNIQUE, generation TEXT, lease_until REAL NOT NULL, ready INTEGER NOT NULL)");
    // Messages larger than a frame: fragments received so far, one row each. They only ever hold
    // traffic of open sockets.
    sql.exec(
      "CREATE TABLE IF NOT EXISTS fragments_in (connection_id TEXT NOT NULL, message_id TEXT NOT NULL, idx INTEGER NOT NULL, count INTEGER NOT NULL, bytes INTEGER NOT NULL, data TEXT NOT NULL, received_at REAL NOT NULL, PRIMARY KEY (connection_id, message_id, idx))",
    );
    sql.exec(
      "CREATE TABLE IF NOT EXISTS fragments_discarded (connection_id TEXT NOT NULL, message_id TEXT NOT NULL, discarded_at REAL NOT NULL, PRIMARY KEY (connection_id, message_id))",
    );
    this.rpc = this.createRpcServer();
  }

  /**
   * Repairs what a restart (a deploy, an eviction) left: closes sockets this release doesn't serve,
   * fences the route of a Mac whose socket is gone, and drops its partial messages. The subclass
   * calls it once its own fields exist, because fencing reports the host offline to it.
   */
  protected reconcile(): void {
    this.closeUnowned();
    const connected = new Set(this.owned().map((socket) => this.peer(socket).connectionId));
    for (const route of this.routes())
      if (!connected.has(route.connection_id)) this.fence(route.connection_id);
    const sql = this.ctx.storage.sql;
    for (const table of ["fragments_in", "fragments_discarded"])
      for (const row of sql.exec<{ connection_id: string }>(`SELECT DISTINCT connection_id FROM ${table}`).toArray())
        if (!connected.has(row.connection_id)) sql.exec(`DELETE FROM ${table} WHERE connection_id = ?`, row.connection_id);
  }

  private createRpcServer(): JSONRPCServer<CallerContext> {
    const server = createProfileServer<CallerContext>();
    const typed: TypedJSONRPCServer<Pick<ServiceMethods, "axo.protocol.negotiate"> & HostRegistrationMethods, CallerContext> = server;
    typed.addMethod("axo.protocol.negotiate", (params, { socket }) => {
      if (!negotiateSchema.safeParse(params).success)
        throw new JSONRPCErrorException(
          "Unsupported protocol version: this Mac's Axo and the cloud must both speak protocol 2; update Axo",
          unsupportedProtocolVersionCode,
        );
      const current = this.peer(socket);
      current.negotiated = true;
      socket.serializeAttachment(current);
      return {
        protocolVersion: 2,
        methods: ["axo.host.register", "axo.host.heartbeat", SHARE_PUBLISH_METHOD, ...this.hostMethodNames()],
      };
    });
    typed.addMethod("axo.host.register", (params, caller) => this.registerHost(params, caller));
    typed.addMethod("axo.host.heartbeat", (params, caller) => this.heartbeatHost(params, caller));
    server.addMethod(SHARE_PUBLISH_METHOD, (params, caller) => this.publishShare(params, caller));
    this.addHostMethods(server);
    return server;
  }

  protected peer(socket: WebSocket): Peer {
    return peerSchema.parse(socket.deserializeAttachment());
  }

  /**
   * Whether a subclass serves a socket with this attachment itself (protocol 3's client sockets on
   * a HostDO). The relay leaves it alone: it is neither closed nor the Mac's.
   */
  protected abstract keeps(attachment: unknown): boolean;

  /**
   * Whether this is the Mac's socket. Any other socket this object doesn't keep was accepted by
   * another release (RFD0032, Release P): nothing would ever write to it, so it is closed when the
   * object wakes, and ignored until it is gone.
   */
  private isOwned(socket: WebSocket): boolean {
    return peerSchema.safeParse(socket.deserializeAttachment()).success;
  }
  private owned(): WebSocket[] {
    return this.ctx.getWebSockets().filter((socket) => this.isOwned(socket));
  }
  private closeUnowned(): void {
    for (const socket of this.ctx.getWebSockets()) {
      if (this.isOwned(socket) || this.keeps(socket.deserializeAttachment())) continue;
      recordApiEvent({ event: "connection_closed", role: "unowned", code: UNOWNED_CLOSE.code });
      try {
        socket.close(UNOWNED_CLOSE.code, UNOWNED_CLOSE.reason);
      } catch {
        // Already closing.
      }
    }
  }
  private sockets(): WebSocket[] {
    return this.owned().filter((socket) => this.peer(socket).expiresAt > Date.now());
  }
  private socket(id: string): WebSocket | undefined {
    return this.sockets().find((socket) => this.peer(socket).connectionId === id);
  }
  private route(machineId: string): Route | undefined {
    return this.ctx.storage.sql.exec<Route>("SELECT * FROM route WHERE machine_id = ?", machineId).toArray()[0];
  }
  private routeByConnection(connectionId: string): Route | undefined {
    return this.ctx.storage.sql.exec<Route>("SELECT * FROM route WHERE connection_id = ?", connectionId).toArray()[0];
  }
  private routes(): Route[] {
    return this.ctx.storage.sql.exec<Route>("SELECT * FROM route").toArray();
  }
  /** The Mac's registered connection, while its lease holds. */
  protected active(machineId: string): { route: Route; socket: WebSocket } | undefined {
    const route = this.route(machineId);
    if (!route?.ready || route.lease_until <= Date.now()) return;
    const socket = this.socket(route.connection_id);
    if (socket) return { route, socket };
  }
  protected presenceOfMachine(machineId: string): { online: boolean; hostGeneration: string | null } {
    const active = this.active(machineId);
    return { online: !!active, hostGeneration: active?.route.generation ?? null };
  }

  // ─── Hooks ─────────────────────────────────────────────────────────────────

  /** Whether the Mac may connect: its account owns this object and its credential holds. */
  protected abstract authorizeRelayPeer(request: Request, peer: Peer): Promise<boolean>;
  /** Methods a subclass adds for the Mac, and their names for negotiation. */
  protected abstract addHostMethods(server: JSONRPCServer<CallerContext>): void;
  protected abstract hostMethodNames(): string[];
  /** A call from the negotiated Mac that a subclass answers itself; true when it took it. */
  protected abstract receiveHostCall(socket: WebSocket, peer: Peer, call: Call): Promise<boolean>;
  /** A notification from the negotiated Mac; true when the subclass took it. */
  protected abstract receiveHostNotification(socket: WebSocket, peer: Peer, call: Call): Promise<boolean>;
  /** A reply from the Mac to something the subclass sent it. */
  protected abstract receiveReply(socket: WebSocket, reply: Reply): void;
  /** The host's presence changed: it registered, or its route ended. */
  protected abstract presenceChanged(hostGeneration: string, status: "online" | "offline"): void;
  protected abstract storeHostRegistration(registration: unknown): Promise<HostSnapshot>;
  protected abstract storeHostHeartbeat(reference: unknown): Promise<{ acknowledged: true; lastSeenAt: string }>;

  // ─── The socket ────────────────────────────────────────────────────────────

  async fetch(request: Request): Promise<Response> {
    const now = Date.now();
    const parsed = peerSchema.safeParse({
      role: request.headers.get("X-Axo-Role"),
      identity: request.headers.get("X-Axo-Identity"),
      expiresAt: Number(request.headers.get("X-Axo-Expiry")),
      machineId: request.headers.get("X-Axo-Machine"),
      connectionId: crypto.randomUUID(),
      negotiated: false,
      window: now,
      calls: 0,
    });
    if (!parsed.success || parsed.data.expiresAt <= now)
      return new Response("Invalid internal identity", { status: 403 });
    const peer = parsed.data;
    if (!(await this.authorizeRelayPeer(request, peer)))
      return new Response("Host is not authorized", { status: 403 });
    const old = this.route(peer.machineId);
    if (old && old.lease_until > now && this.socket(old.connection_id))
      return new Response("Duplicate machine connection", { status: 409 });
    if (old) this.fence(old.connection_id);
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO route (machine_id, connection_id, generation, lease_until, ready) VALUES (?, ?, NULL, ?, 0)",
      peer.machineId,
      peer.connectionId,
      Math.min(peer.expiresAt, now + LIMITS.deadlineMs),
    );
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(peer);
    await this.schedule();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (!this.isOwned(socket)) return;
    const peer = this.peer(socket);
    if (peer.expiresAt <= Date.now()) {
      this.drop(socket, 4001, "Access expired");
      return;
    }
    if (typeof raw !== "string") {
      this.drop(socket, 1003, "Text required");
      return;
    }
    const decoded = decode(raw);
    if ("error" in decoded) {
      this.send(socket, decoded.error);
      return;
    }
    if (Date.now() - peer.window >= 1000) {
      peer.window = Date.now();
      peer.calls = 0;
    }
    peer.calls += decoded.entries.length;
    socket.serializeAttachment(peer);
    if (peer.calls > DAEMON_FRAMES_PER_SECOND) {
      this.drop(socket, 1008, "Rate limit");
      return;
    }
    const transport = decoded.batch ? undefined : callSchema.safeParse(decoded.entries[0]);
    if (transport?.success && transport.data.method === DISCARD_METHOD) {
      const notice = discardParamsSchema.safeParse(transport.data.params);
      if (transport.data.id !== undefined || !notice.success) {
        this.drop(socket, 1008, "Invalid discard");
        return;
      }
      this.partials(peer.connectionId).discard(notice.data.messageId);
      return;
    }
    if (transport?.success && transport.data.method === FRAGMENT_METHOD) {
      if (transport.data.id !== undefined) {
        this.drop(socket, 1008, "Invalid fragment");
        return;
      }
      const outcome = receiveFragment(this.partials(peer.connectionId), transport.data.params);
      if (outcome.status === "invalid") {
        this.drop(socket, 1008, `Invalid fragment: ${outcome.reason}`);
        return;
      }
      if (outcome.status === "partial") {
        await this.schedule();
        return;
      }
      if (outcome.status === "ignored") return;
      const whole = decode(outcome.raw, FRAGMENTS.messageBytes);
      if ("error" in whole) {
        this.send(socket, whole.error);
        return;
      }
      const inner = whole.batch ? undefined : callSchema.safeParse(whole.entries[0]);
      if (inner?.success && [FRAGMENT_METHOD, DISCARD_METHOD].includes(inner.data.method)) {
        this.drop(socket, 1008, "Invalid fragment");
        return;
      }
      await this.receiveMessage(socket, peer, whole);
      return;
    }
    await this.receiveMessage(socket, peer, decoded);
  }

  /** One whole message from the Mac: a frame, or a message reassembled from its fragments. */
  private async receiveMessage(socket: WebSocket, peer: Peer, decoded: Exclude<Decoded, { error: unknown }>): Promise<void> {
    if (!decoded.batch) {
      const reply = replySchema.safeParse(decoded.entries[0]);
      if (reply.success) {
        this.receiveReply(socket, reply.data);
        await this.schedule();
        return;
      }
      const call = callSchema.safeParse(decoded.entries[0]);
      if (call.success && peer.negotiated) {
        const taken = call.data.id === undefined
          ? await this.receiveHostNotification(socket, peer, call.data)
          : await this.receiveHostCall(socket, peer, call.data);
        if (taken) {
          await this.schedule();
          return;
        }
      }
    }
    const replies: Reply[] = [];
    for (const entry of decoded.entries) {
      const call = callSchema.safeParse(entry);
      if (!call.success) replies.push(failure(null, -32600, "Invalid Request"));
      // A notification has no reply, and the Mac sends none that need one.
      else if (call.data.id !== undefined) replies.push(await this.answer(socket, peer, call.data));
    }
    if (replies.length) {
      // The Mac reassembles fragments, so a single reply to it may be larger than one frame.
      const bounded = boundReplies(replies, decoded.batch, decoded.batch ? LIMITS.frameBytes : FRAGMENTS.messageBytes);
      this.send(socket, decoded.batch ? bounded : bounded[0]);
    }
    await this.schedule();
  }

  private async answer(socket: WebSocket, peer: Peer, call: Call): Promise<Reply> {
    if (call.method !== "axo.protocol.negotiate" && !this.peer(socket).negotiated)
      return failure(call.id!, -32001, "Negotiate first");
    try {
      const reply = await this.rpc.receive(call, { socket, peer });
      return replySchema.parse(reply);
    } catch {
      return failure(call.id!, -32003, "Admission failed");
    }
  }

  // ─── Lease, registration and shares ────────────────────────────────────────

  protected admittedDaemon(peer: Peer): Route {
    const route = this.route(peer.machineId);
    if (!route || route.connection_id !== peer.connectionId || route.lease_until <= Date.now() || peer.expiresAt <= Date.now())
      throw new JSONRPCErrorException("Stale lease", -32002);
    return route;
  }

  private async registerHost(params: unknown, { socket, peer }: CallerContext) {
    const route = this.admittedDaemon(peer);
    const parsed = hostV1Methods["axo.host.register"].safeParse(params);
    if (
      !parsed.success ||
      parsed.data.hostId !== peer.machineId ||
      (route.generation !== null && route.generation !== parsed.data.hostGeneration)
    )
      throw new JSONRPCErrorException("Invalid host registration", -32602);
    // Pin the boot generation before the account's await, including concurrent frames.
    this.ctx.storage.sql.exec("UPDATE route SET generation = ? WHERE connection_id = ?", parsed.data.hostGeneration, peer.connectionId);
    const host = await this.storeHostRegistration(parsed.data);
    const current = this.admittedDaemon(peer);
    if (current.generation !== parsed.data.hostGeneration || !this.socket(peer.connectionId) || this.peer(socket).expiresAt <= Date.now())
      throw new JSONRPCErrorException("Stale lease", -32002);
    this.ctx.storage.sql.exec(
      "UPDATE route SET generation = ?, ready = 1, lease_until = ? WHERE connection_id = ?",
      parsed.data.hostGeneration,
      Math.min(peer.expiresAt, Date.now() + LIMITS.leaseMs),
      peer.connectionId,
    );
    recordApiEvent({ event: "host_registered" });
    this.presenceChanged(parsed.data.hostGeneration, "online");
    return { host };
  }

  private async heartbeatHost(params: unknown, { peer }: CallerContext) {
    const route = this.admittedDaemon(peer);
    const parsed = hostV1Methods["axo.host.heartbeat"].safeParse(params);
    if (!parsed.success || !route.ready || parsed.data.hostId !== peer.machineId || parsed.data.hostGeneration !== route.generation)
      throw new JSONRPCErrorException("Invalid host heartbeat", -32602);
    const result = await this.storeHostHeartbeat(parsed.data);
    this.renewRoute(peer);
    return result;
  }

  /**
   * Publishes a conversation a host redacted (`/axo-share`): stores the snapshot in the
   * public-sessions bucket under a new ID and answers with its public URL. The publishing
   * identity and host are kept as object metadata, so a share can be traced and taken down.
   */
  private async publishShare(params: unknown, { peer }: CallerContext): Promise<SharePublishResult> {
    const route = this.admittedDaemon(peer);
    const parsed = sharePublishParamsSchema.safeParse(params);
    if (!parsed.success || !route.ready || parsed.data.hostId !== peer.machineId || parsed.data.hostGeneration !== route.generation)
      throw new JSONRPCErrorException("Invalid shared conversation", -32602);
    const shareId = newShareId();
    await this.env.PUBLIC_SESSIONS.put(`shares/${shareId}.json`, JSON.stringify(parsed.data.snapshot), {
      httpMetadata: { contentType: "application/json; charset=utf-8" },
      customMetadata: { principal: peer.identity, hostId: peer.machineId, publishedAt: new Date().toISOString() },
    });
    this.renewRoute(peer);
    recordApiEvent({ event: "share_published", messages: parsed.data.snapshot.messages.length });
    return { shareId, url: `${APP_ORIGIN}/s/${shareId}/${shareSlug(parsed.data.snapshot.title)}` };
  }

  protected renewRoute(peer: Peer): void {
    this.ctx.storage.sql.exec(
      "UPDATE route SET lease_until = ? WHERE connection_id = ?",
      Math.min(peer.expiresAt, Date.now() + LIMITS.leaseMs),
      peer.connectionId,
    );
  }

  /**
   * Sends one message: in one frame, or as fragments when it is larger (RFD0016, Transport). There
   * are no delivery credits (RFD0018, Flow control): each flow is paced by its own
   * acknowledgements, and nothing closes a socket because its reader is slow. A send fails,
   * leaving the socket open, only when the message is too large.
   */
  protected send(socket: WebSocket, value: unknown): boolean {
    const raw = JSON.stringify(value);
    if (this.peer(socket).expiresAt <= Date.now()) {
      this.drop(socket, 4001, "Access expired");
      return false;
    }
    const frames = byteLength(raw) <= LIMITS.frameBytes ? [raw] : splitMessage(raw, crypto.randomUUID());
    if (!frames) {
      recordApiEvent({ event: "relay_send_failed", reason: "too_large" });
      return false;
    }
    try {
      for (const frame of frames) socket.send(frame);
      return true;
    } catch {
      this.drop(socket, 1011, "Transport failed");
      return false;
    }
  }

  /** Partial messages from one socket, one SQLite row per fragment. */
  private partials(connectionId: string): PartialStore {
    const sql = this.ctx.storage.sql;
    return {
      partial(messageId) {
        const row = sql.exec<{ count: number; received: number; bytes: number }>(
          "SELECT MAX(count) AS count, COUNT(*) AS received, SUM(bytes) AS bytes FROM fragments_in WHERE connection_id = ? AND message_id = ?",
          connectionId, messageId,
        ).one();
        return row.received ? row : undefined;
      },
      has: (messageId, index) =>
        sql.exec("SELECT 1 FROM fragments_in WHERE connection_id = ? AND message_id = ? AND idx = ?", connectionId, messageId, index).toArray().length > 0,
      add(messageId, index, count, data, bytes) {
        sql.exec("INSERT INTO fragments_in (connection_id, message_id, idx, count, bytes, data, received_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          connectionId, messageId, index, count, bytes, data, Date.now());
      },
      discard(messageId) {
        sql.exec("DELETE FROM fragments_in WHERE connection_id = ? AND message_id = ?", connectionId, messageId);
        sql.exec("INSERT OR REPLACE INTO fragments_discarded (connection_id, message_id, discarded_at) VALUES (?, ?, ?)", connectionId, messageId, Date.now());
        sql.exec(`DELETE FROM fragments_discarded WHERE connection_id = ? AND message_id NOT IN (
          SELECT message_id FROM fragments_discarded WHERE connection_id = ? ORDER BY discarded_at DESC LIMIT ?)`,
          connectionId, connectionId, FRAGMENTS.discardedPerSocket);
      },
      discarded: (messageId) =>
        sql.exec("SELECT 1 FROM fragments_discarded WHERE connection_id = ? AND message_id = ?", connectionId, messageId).toArray().length > 0,
      take(messageId) {
        const rows = sql.exec<{ data: string }>(
          "SELECT data FROM fragments_in WHERE connection_id = ? AND message_id = ? ORDER BY idx", connectionId, messageId,
        ).toArray();
        sql.exec("DELETE FROM fragments_in WHERE connection_id = ? AND message_id = ?", connectionId, messageId);
        return rows.map((row) => row.data);
      },
      count: () =>
        sql.exec<{ count: number }>("SELECT COUNT(DISTINCT message_id) AS count FROM fragments_in WHERE connection_id = ?", connectionId).one().count,
    };
  }

  // ─── Ending a connection ───────────────────────────────────────────────────

  /** Ends `machineId`'s lease, if it has one: revoking a Mac whose socket is not registered yet. */
  protected endLease(machineId: string): void {
    const route = this.route(machineId);
    if (route) this.fence(route.connection_id);
  }

  /** Ends the lease of `connectionId`: its route goes, the host is offline, and its socket closes. */
  protected fence(connectionId: string): void {
    const route = this.routeByConnection(connectionId);
    this.ctx.storage.sql.exec("DELETE FROM route WHERE connection_id = ?", connectionId);
    if (route?.generation) this.presenceChanged(route.generation, "offline");
    this.socket(connectionId)?.close(4002, "Lease ended");
  }

  protected drop(socket: WebSocket, code: number, reason: string): void {
    const peer = this.peer(socket);
    recordApiEvent({ event: "connection_closed", role: "daemon", code });
    socket.close(code, reason);
    this.fence(peer.connectionId);
    this.ctx.storage.sql.exec("DELETE FROM fragments_in WHERE connection_id = ?", peer.connectionId);
    this.ctx.storage.sql.exec("DELETE FROM fragments_discarded WHERE connection_id = ?", peer.connectionId);
  }

  webSocketClose(socket: WebSocket): void {
    if (this.isOwned(socket)) this.drop(socket, 1000, "Disconnected");
  }
  webSocketError(socket: WebSocket): void {
    if (this.isOwned(socket)) this.drop(socket, 1011, "Transport failed");
  }

  /** Wakes the object at the next lease end, access expiry, or partial message timeout. */
  protected async schedule(): Promise<void> {
    const deadlines = this.sockets().map((socket) => this.peer(socket).expiresAt);
    for (const route of this.routes()) deadlines.push(route.lease_until);
    const stale = this.ctx.storage.sql
      .exec<{ last: number | null }>("SELECT MIN(last) AS last FROM (SELECT MAX(received_at) AS last FROM fragments_in GROUP BY connection_id, message_id)")
      .one().last;
    if (stale) deadlines.push(stale + FRAGMENTS.partialTimeoutMs);
    if (deadlines.length) await this.ctx.storage.setAlarm(Math.max(Date.now() + 1, Math.min(...deadlines)));
    else await this.ctx.storage.deleteAlarm();
  }

  async alarm(): Promise<void> {
    for (const route of this.routes())
      if (route.lease_until <= Date.now()) this.fence(route.connection_id);
    for (const socket of this.owned())
      if (this.peer(socket).expiresAt <= Date.now()) this.drop(socket, 4001, "Access expired");
    for (const row of this.ctx.storage.sql
      .exec<{ connection_id: string; message_id: string }>(
        "SELECT connection_id, message_id FROM fragments_in GROUP BY connection_id, message_id HAVING MAX(received_at) <= ?",
        Date.now() - FRAGMENTS.partialTimeoutMs,
      ).toArray())
      this.partials(row.connection_id).discard(row.message_id);
    await this.schedule();
  }
}

/** 128 random bits, URL-safe: what makes a share link unguessable. */
function newShareId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
