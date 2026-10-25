import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import {
  LIMITS,
  callSchema,
  decode,
  failure,
  success,
  negotiateSchema,
  registrationSchema,
  remoteMethods,
  replySchema,
  results,
  type Call,
  type Reply,
  type RpcId,
  createProfileServer,
  JSONRPCErrorException,
  type JSONRPCServer,
  type TypedJSONRPCServer,
  type ServiceMethods,
  type Registered,
  type Heartbeat,
  type RemoteMethod,
} from "@axo/protocol";
import {
  hostDataEventSchema,
  hostPresenceEventSchema,
  hostNotificationSchema,
  hostRelayNotificationSchema,
  hostV1Methods,
  hostV1Results,
  type HostMethod,
  type HostSnapshot,
} from "@axo/protocol/v1";
import { peerSchema, type Peer, type CallerContext } from "./relay/peer";
import type { Route, Group, Pending } from "./relay/records";
import { recordApiEvent } from "./observability";
import { boundReplyGroup } from "./relay/replies";

type HostRegistrationMethods = {
  "axo.host.register": (
    params: z.input<typeof hostV1Methods["axo.host.register"]>,
  ) => z.output<typeof hostV1Results["axo.host.register"]>;
  "axo.host.heartbeat": (
    params: z.input<typeof hostV1Methods["axo.host.heartbeat"]>,
  ) => z.output<typeof hostV1Results["axo.host.heartbeat"]>;
  "axo.host.sessions.publish": (
    params: z.input<typeof hostV1Methods["axo.host.sessions.publish"]>,
  ) => z.output<typeof hostV1Results["axo.host.sessions.publish"]>;
};

const hostRemoteMethods = {
  "axo.remote.session.create": hostV1Methods["axo.remote.session.create"],
  "axo.remote.workspace.session.create": hostV1Methods["axo.remote.workspace.session.create"],
  "axo.remote.session.close": hostV1Methods["axo.remote.session.close"],
  "axo.remote.shell.create": hostV1Methods["axo.remote.shell.create"],
  "axo.remote.shell.close": hostV1Methods["axo.remote.shell.close"],
  "axo.remote.session.layout.set": hostV1Methods["axo.remote.session.layout.set"],
  "axo.remote.terminal.input": hostV1Methods["axo.remote.terminal.input"],
  "axo.remote.terminal.resize": hostV1Methods["axo.remote.terminal.resize"],
} as const;
type HostRemoteMethod = keyof typeof hostRemoteMethods;

/**
 * Inbound frame budget per socket per second. A host streams terminal output as one frame
 * per PTY read, so an interactive shell alone exceeds a client-sized budget; the budget still
 * bounds a host to about 38 MiB/s of 64 KiB frames.
 */
export const INBOUND_FRAMES_PER_SECOND = { client: 30, daemon: 600 } as const;
function framesPerSecond(role: "client" | "daemon"): number {
  return INBOUND_FRAMES_PER_SECOND[role];
}

export class AxoHostRelay extends DurableObject<Env> {
  private readonly rpc: JSONRPCServer<CallerContext>;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.prepareRoutes();
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS groups (group_id TEXT PRIMARY KEY, connection_id TEXT NOT NULL, batch INTEGER NOT NULL, remaining INTEGER NOT NULL, replies TEXT NOT NULL)",
    );
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS pending (hop_id TEXT PRIMARY KEY, group_id TEXT NOT NULL, original_id TEXT NOT NULL, connection_id TEXT NOT NULL, machine_id TEXT NOT NULL, method TEXT NOT NULL, generation TEXT NOT NULL, deadline REAL NOT NULL)",
    );
    this.preparePending();
    this.discardDisconnectedCorrelations();
    this.rpc = this.createRpcServer();
  }
  private createRpcServer(): JSONRPCServer<CallerContext> {
    const server = createProfileServer<CallerContext>();
    const typed: TypedJSONRPCServer<
      Pick<
        ServiceMethods,
        | "axo.protocol.negotiate"
        | "axo.machine.register"
        | "axo.machine.heartbeat"
      > & HostRegistrationMethods,
      CallerContext
    > = server;
    typed.addMethod("axo.protocol.negotiate", (params, { socket }) => {
      if (!negotiateSchema.safeParse(params).success)
        throw new JSONRPCErrorException("Invalid version", -32602);
      const current = this.peer(socket);
      current.negotiated = true;
      socket.serializeAttachment(current);
      return {
        protocolVersion: 1,
        methods: [
          ...(this.supportsLegacyMachineMethods() ? ["axo.machine.register", "axo.machine.heartbeat"] : []),
          ...Object.keys(remoteMethods),
          ...Object.keys(hostV1Methods).filter((method) =>
            method !== "axo.host.list" && method !== "axo.host.sessions.list",
          ),
        ],
        deliveryCredits: { frames: 32, bytes: 131072 },
      };
    });
    typed.addMethod("axo.machine.register", (params, caller) =>
      this.register(params, caller),
    );
    typed.addMethod("axo.machine.heartbeat", (params, caller) =>
      this.heartbeat(params, caller),
    );
    typed.addMethod("axo.host.register", (params, caller) =>
      this.registerHost(params, caller),
    );
    typed.addMethod("axo.host.heartbeat", (params, caller) =>
      this.heartbeatHost(params, caller),
    );
    typed.addMethod("axo.host.sessions.publish", (params, caller) =>
      this.publishHostSessions(params, caller),
    );
    return server;
  }
  private prepareRoutes(): void {
    const sql = this.ctx.storage.sql;
    const columns = sql.exec<{ name: string }>("PRAGMA table_info(route)").toArray();
    if (columns.length === 0) {
      sql.exec("CREATE TABLE route (machine_id TEXT PRIMARY KEY, connection_id TEXT NOT NULL UNIQUE, generation TEXT, lease_until REAL NOT NULL, ready INTEGER NOT NULL)");
      return;
    }
    if (columns.some((column) => column.name === "singleton")) {
      this.ctx.storage.transactionSync(() => {
        sql.exec("ALTER TABLE route RENAME TO legacy_route");
        sql.exec("CREATE TABLE route (machine_id TEXT PRIMARY KEY, connection_id TEXT NOT NULL UNIQUE, generation TEXT, lease_until REAL NOT NULL, ready INTEGER NOT NULL)");
        sql.exec("INSERT INTO route (machine_id, connection_id, generation, lease_until, ready) SELECT machine_id, connection_id, generation, lease_until, ready FROM legacy_route");
        sql.exec("DROP TABLE legacy_route");
      });
    }
  }
  private preparePending(): void {
    const sql = this.ctx.storage.sql;
    const columns = sql.exec<{ name: string }>("PRAGMA table_info(pending)").toArray();
    if (!columns.some((column) => column.name === "machine_id")) {
      this.ctx.storage.transactionSync(() => {
        sql.exec("ALTER TABLE pending ADD COLUMN machine_id TEXT NOT NULL DEFAULT ''");
        sql.exec(`UPDATE pending SET machine_id = COALESCE((
          SELECT machine_id FROM route WHERE route.connection_id = pending.connection_id
        ), '') WHERE machine_id = ''`);
      });
    }
    sql.exec("CREATE INDEX IF NOT EXISTS pending_by_machine ON pending(machine_id, deadline)");
  }
  private discardDisconnectedCorrelations() {
    const connected = new Set(
      this.ctx.getWebSockets().map((socket) => this.peer(socket).connectionId),
    );
    const sql = this.ctx.storage.sql;
    for (const row of sql
      .exec<{ connection_id: string }>(
        "SELECT DISTINCT connection_id FROM groups",
      )
      .toArray()) {
      if (connected.has(row.connection_id)) continue;
      sql.exec(
        "DELETE FROM pending WHERE group_id IN (SELECT group_id FROM groups WHERE connection_id = ?)",
        row.connection_id,
      );
      sql.exec("DELETE FROM groups WHERE connection_id = ?", row.connection_id);
    }
    for (const route of this.routes())
      if (!connected.has(route.connection_id)) this.fence(route.connection_id);
  }
  private peer(socket: WebSocket): Peer {
    return peerSchema.parse(socket.deserializeAttachment());
  }
  private sockets(role?: Peer["role"]) {
    return this.ctx.getWebSockets().filter((socket) => {
      const peer = this.peer(socket);
      return peer.expiresAt > Date.now() && (!role || peer.role === role);
    });
  }
  private socket(id: string) {
    return this.sockets().find(
      (socket) => this.peer(socket).connectionId === id,
    );
  }
  private route(machineId?: string): Route | undefined {
    const sql = this.ctx.storage.sql;
    return machineId
      ? sql.exec<Route>("SELECT * FROM route WHERE machine_id = ?", machineId).toArray()[0]
      : sql.exec<Route>("SELECT * FROM route LIMIT 1").toArray()[0];
  }
  private routeByConnection(connectionId: string): Route | undefined {
    return this.ctx.storage.sql.exec<Route>(
      "SELECT * FROM route WHERE connection_id = ?",
      connectionId,
    ).toArray()[0];
  }
  private routes(): Route[] {
    return this.ctx.storage.sql.exec<Route>("SELECT * FROM route").toArray();
  }
  private active(machineId?: string): { route: Route; socket: WebSocket } | undefined {
    const route = this.route(machineId);
    if (!route?.ready || route.lease_until <= Date.now()) return;
    const socket = this.socket(route.connection_id);
    if (socket) return { route, socket };
  }
  presence(machineId?: string) {
    const active = this.active(machineId);
    return {
      online: !!active,
      hostGeneration: active?.route.generation ?? null,
    };
  }

  protected async authorizeRelayPeer(_request: Request, _peer: Peer): Promise<boolean> {
    return true;
  }
  protected supportsLegacyMachineMethods(): boolean { return true; }

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
      outgoing: [],
    });
    if (!parsed.success || parsed.data.expiresAt <= now)
      return new Response("Invalid internal identity", { status: 403 });
    const peer = parsed.data;
    if (!(await this.authorizeRelayPeer(request, peer)))
      return new Response("Host is not authorized", { status: 403 });
    if (
      peer.role === "client" &&
      this.sockets("client").filter((socket) => this.peer(socket).machineId === peer.machineId).length >= LIMITS.clientsPerMachine
    )
      return new Response("Client capacity", { status: 429 });
    if (peer.role === "daemon") {
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
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(peer);
    await this.schedule();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(
    socket: WebSocket,
    raw: string | ArrayBuffer,
  ): Promise<void> {
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
    // Acknowledged FIFO delivery credits bound server-side slow-consumer queues.
    const ack = callSchema.safeParse(decoded.entries[0]);
    if (
      !decoded.batch &&
      ack.success &&
      ack.data.method === "axo.transport.ack" &&
      ack.data.id === undefined
    ) {
      const count = z
        .object({ frames: z.number().int().min(1).max(32) })
        .strict()
        .safeParse(ack.data.params);
      if (!count.success || count.data.frames > peer.outgoing.length) {
        this.drop(socket, 1008, "Invalid credit");
        return;
      }
      peer.outgoing.splice(0, count.data.frames);
      socket.serializeAttachment(peer);
      return;
    }
    if (Date.now() - peer.window >= 1000) {
      peer.window = Date.now();
      peer.calls = 0;
    }
    peer.calls += decoded.entries.length;
    socket.serializeAttachment(peer);
    if (peer.calls > framesPerSecond(peer.role)) {
      this.drop(socket, 1008, "Rate limit");
      return;
    }
    if (peer.role === "daemon" && !decoded.batch) {
      const notificationCall = callSchema.safeParse(decoded.entries[0]);
      if (notificationCall.success && notificationCall.data.method === "axo.host.event") {
        const notification = hostRelayNotificationSchema.safeParse(decoded.entries[0]);
        if (!notification.success || notificationCall.data.id !== undefined) {
          this.drop(socket, 1008, "Invalid host event");
          return;
        }
        await this.receiveHostEvent(socket, peer, notification.data.params);
        await this.schedule();
        return;
      }
      const reply = replySchema.safeParse(decoded.entries[0]);
      if (reply.success) {
        this.receiveReply(socket, reply.data);
        await this.schedule();
        return;
      }
    }
    const entries = decoded.entries.map((entry) => callSchema.safeParse(entry));
    const count = entries.filter(
      (entry) => !entry.success || entry.data.id !== undefined,
    ).length;
    if (!count) return; // Valid notifications have no replies and cannot execute mutations.
    if (
      this.ctx.storage.sql
        .exec<{ count: number }>(
          "SELECT COUNT(*) AS count FROM groups WHERE connection_id = ?",
          peer.connectionId,
        )
        .one().count +
        count >
      LIMITS.pendingPerClient
    ) {
      this.drop(socket, 1008, "Pending capacity");
      return;
    }
    const groupId = crypto.randomUUID();
    this.ctx.storage.sql.exec(
      "INSERT INTO groups VALUES (?, ?, ?, ?, '[]')",
      groupId,
      peer.connectionId,
      decoded.batch ? 1 : 0,
      count,
    );
    for (const entry of entries) {
      if (!entry.success) {
        this.complete(groupId, failure(null, -32600, "Invalid Request"));
        continue;
      }
      if (entry.data.id === undefined) continue;
      try {
        await this.receiveCall(socket, peer, groupId, entry.data);
      } catch {
        this.complete(
          groupId,
          failure(entry.data.id, -32003, "Admission failed"),
        );
      }
    }
    await this.schedule();
  }

  private async receiveCall(
    socket: WebSocket,
    peer: Peer,
    groupId: string,
    call: Call,
  ): Promise<void> {
    const id = call.id!;
    if (
      call.method !== "axo.protocol.negotiate" &&
      !this.peer(socket).negotiated
    ) {
      this.complete(groupId, failure(id, -32001, "Negotiate first"));
      return;
    }
    if (call.method === "axo.protocol.negotiate" || peer.role === "daemon") {
      const reply = await this.rpc.receive(call, { socket, peer });
      if (reply) this.complete(groupId, replySchema.parse(reply));
      return;
    }
    if (call.method === "axo.host.subscribe") {
      await this.subscribeHost(socket, peer, groupId, call);
      return;
    }
    if (call.method === "axo.host.unsubscribe") {
      this.unsubscribeHost(socket, peer, groupId, call);
      return;
    }
    if (Object.hasOwn(hostRemoteMethods, call.method)) {
      await this.forwardHostRemoteCall(socket, peer, groupId, call);
      return;
    }
    if (!Object.hasOwn(remoteMethods, call.method)) {
      this.complete(groupId, failure(id, -32601, "Method not found"));
      return;
    }
    const method = call.method as RemoteMethod;
    const parsed = remoteMethods[method].safeParse(call.params);
    if (!parsed.success) {
      this.complete(groupId, failure(id, -32602, "Invalid params"));
      return;
    }
    const active = this.active(peer.machineId);
    if (
      parsed.data.target.machineId !== peer.machineId ||
      (active && active.route.machine_id !== peer.machineId)
    ) {
      this.complete(groupId, failure(id, -32002, "Wrong machine"));
      return;
    }
    if (!active) {
      this.complete(
        groupId,
        failure(id, -32005, "Machine offline; nothing queued"),
      );
      return;
    }
    if (parsed.data.target.hostGeneration !== active.route.generation) {
      this.complete(groupId, failure(id, -32002, "Stale host"));
      return;
    }
    const sql = this.ctx.storage.sql;
    if (
      sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pending WHERE machine_id = ?", peer.machineId).one()
        .count >= LIMITS.pendingPerMachine ||
      sql
        .exec<{ count: number }>(
          "SELECT COUNT(*) AS count FROM pending WHERE group_id IN (SELECT group_id FROM groups WHERE connection_id = ?)",
          peer.connectionId,
        )
        .one().count >= LIMITS.pendingPerClient
    ) {
      this.complete(groupId, failure(id, -32006, "Pending capacity"));
      return;
    }
    const hopId = crypto.randomUUID();
    const deadline = Math.min(
      Date.now() + LIMITS.deadlineMs,
      peer.expiresAt,
      active.route.lease_until,
    );
    sql.exec(
      "INSERT INTO pending (hop_id, group_id, original_id, connection_id, machine_id, method, generation, deadline) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      hopId,
      groupId,
      JSON.stringify(id),
      active.route.connection_id,
      peer.machineId,
      method,
      active.route.generation!,
      deadline,
    );
    await this.ctx.storage.sync();
    if (
      this.active(peer.machineId)?.route.connection_id !== active.route.connection_id ||
      !this.socket(peer.connectionId) ||
      deadline <= Date.now()
    ) {
      this.finishPending(
        hopId,
        failure(id, -32004, "Outcome unknown; reconcile commandId"),
      );
      return;
    }
    if (!this.send(active.socket, { ...call, id: hopId, params: parsed.data }))
      this.finishPending(
        hopId,
        failure(id, -32004, "Outcome unknown; reconcile commandId"),
      );
  }

  private async subscribeHost(
    socket: WebSocket,
    peer: Peer,
    groupId: string,
    call: Call,
  ): Promise<void> {
    const parsed = hostV1Methods["axo.host.subscribe"].safeParse(call.params);
    if (!parsed.success) {
      this.complete(groupId, failure(call.id!, -32602, "Invalid params"));
      return;
    }
    const target = parsed.data;
    const active = this.active(peer.machineId);
    if (target.hostId !== peer.machineId || (active && active.route.machine_id !== target.hostId)) {
      this.complete(groupId, failure(call.id!, -32002, "Wrong host"));
      return;
    }
    if (!active) {
      this.complete(groupId, failure(call.id!, -32005, "Host offline; nothing queued"));
      return;
    }
    if (target.hostGeneration !== active.route.generation) {
      this.complete(groupId, failure(call.id!, -32002, "Stale host"));
      return;
    }
    if (peer.hostSubscriptions.length >= 64) {
      this.complete(groupId, failure(call.id!, -32006, "Subscription capacity"));
      return;
    }

    const subscriptionId = crypto.randomUUID();
    peer.hostSubscriptions.push({
      subscriptionId,
      hostGeneration: target.hostGeneration,
    });
    socket.serializeAttachment(peer);
    this.complete(groupId, success(call.id!, { subscriptionId }));
    const presence = hostPresenceEventSchema.parse({
      type: "host.presence",
      hostId: target.hostId,
      hostGeneration: target.hostGeneration,
      status: "online",
      observedAt: new Date().toISOString(),
    });
    this.sendHostEvent(socket, subscriptionId, presence);
  }

  private unsubscribeHost(
    socket: WebSocket,
    peer: Peer,
    groupId: string,
    call: Call,
  ): void {
    const parsed = hostV1Methods["axo.host.unsubscribe"].safeParse(call.params);
    if (!parsed.success) {
      this.complete(groupId, failure(call.id!, -32602, "Invalid params"));
      return;
    }
    const previousLength = peer.hostSubscriptions.length;
    peer.hostSubscriptions = peer.hostSubscriptions.filter(
      (subscription) => subscription.subscriptionId !== parsed.data.subscriptionId,
    );
    socket.serializeAttachment(peer);
    if (peer.hostSubscriptions.length === previousLength) {
      this.complete(groupId, failure(call.id!, -32004, "Subscription not found"));
      return;
    }
    this.complete(groupId, success(call.id!, { unsubscribed: true }));
  }

  private sendHostEvent(socket: WebSocket, subscriptionId: string, event: unknown): void {
    const notification = hostNotificationSchema.safeParse({
      jsonrpc: "2.0",
      method: "axo.host.event",
      params: { subscriptionId, event },
    });
    if (notification.success) this.send(socket, notification.data);
  }

  private broadcastHostPresence(
    hostId: string,
    hostGeneration: string,
    status: "online" | "offline",
  ): void {
    const event = hostPresenceEventSchema.parse({
      type: "host.presence",
      hostId,
      hostGeneration,
      status,
      observedAt: new Date().toISOString(),
    });
    for (const socket of this.sockets("client")) {
      const peer = this.peer(socket);
      if (!peer.negotiated || peer.machineId !== hostId) continue;
      for (const subscription of peer.hostSubscriptions) {
        if (status === "offline" && subscription.hostGeneration !== hostGeneration) continue;
        this.sendHostEvent(socket, subscription.subscriptionId, event);
      }
    }
  }

  private async receiveHostEvent(
    socket: WebSocket,
    peer: Peer,
    event: unknown,
  ): Promise<void> {
    const parsed = hostDataEventSchema.safeParse(event);
    const route = this.active(peer.machineId)?.route;
    if (
      !parsed.success ||
      peer.role !== "daemon" ||
      !route ||
      route.connection_id !== peer.connectionId ||
      route.machine_id !== parsed.data.hostId ||
      route.generation !== parsed.data.hostGeneration
    ) {
      this.drop(socket, 1008, "Invalid host event");
      return;
    }
    try {
      await this.storeHostEvent(parsed.data, peer.identity);
    } catch {
      this.drop(socket, 1008, "Host event rejected");
      return;
    }

    for (const client of this.sockets("client")) {
      const clientPeer = this.peer(client);
      if (!clientPeer.negotiated || clientPeer.machineId !== parsed.data.hostId) continue;
      for (const subscription of clientPeer.hostSubscriptions) {
        if (subscription.hostGeneration !== parsed.data.hostGeneration) continue;
        this.sendHostEvent(client, subscription.subscriptionId, parsed.data);
      }
    }
  }

  private async forwardHostRemoteCall(
    socket: WebSocket,
    peer: Peer,
    groupId: string,
    call: Call,
  ): Promise<void> {
    const method = call.method as HostRemoteMethod;
    const parsed = hostRemoteMethods[method].safeParse(call.params);
    if (!parsed.success) {
      this.complete(groupId, failure(call.id!, -32602, "Invalid params"));
      return;
    }
    const active = this.active(peer.machineId);
    if (
      parsed.data.target.hostId !== peer.machineId ||
      (active && active.route.machine_id !== peer.machineId)
    ) {
      this.complete(groupId, failure(call.id!, -32002, "Wrong host"));
      return;
    }
    if (!active) {
      this.complete(groupId, failure(call.id!, -32005, "Host offline; nothing queued"));
      return;
    }
    if (parsed.data.target.hostGeneration !== active.route.generation) {
      this.complete(groupId, failure(call.id!, -32002, "Stale host"));
      return;
    }
    const sql = this.ctx.storage.sql;
    if (
      sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pending WHERE machine_id = ?", peer.machineId).one().count >= LIMITS.pendingPerMachine ||
      sql.exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM pending WHERE group_id IN (SELECT group_id FROM groups WHERE connection_id = ?)",
        peer.connectionId,
      ).one().count >= LIMITS.pendingPerClient
    ) {
      this.complete(groupId, failure(call.id!, -32006, "Pending capacity"));
      return;
    }
    const hopId = crypto.randomUUID();
    const deadline = Math.min(
      Date.now() + LIMITS.deadlineMs,
      peer.expiresAt,
      active.route.lease_until,
    );
    sql.exec(
      "INSERT INTO pending (hop_id, group_id, original_id, connection_id, machine_id, method, generation, deadline) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      hopId,
      groupId,
      JSON.stringify(call.id),
      active.route.connection_id,
      peer.machineId,
      method,
      active.route.generation!,
      deadline,
    );
    await this.ctx.storage.sync();
    if (
      this.active(peer.machineId)?.route.connection_id !== active.route.connection_id ||
      !this.socket(peer.connectionId) ||
      deadline <= Date.now()
    ) {
      this.finishPending(hopId, failure(call.id!, -32004, "Outcome unknown; reconcile commandId"));
      return;
    }
    if (!this.send(active.socket, { ...call, id: hopId, params: parsed.data })) {
      this.finishPending(hopId, failure(call.id!, -32004, "Outcome unknown; reconcile commandId"));
    }
  }

  protected async storeHostRegistration(registration: unknown, principal: string): Promise<HostSnapshot> {
    return this.ctx.exports.AxoHostDirectory
      .getByName("private-fleet")
      .registerHost(registration, principal);
  }
  protected async storeHostHeartbeat(reference: unknown, principal: string): Promise<{ acknowledged: true; lastSeenAt: string }> {
    return this.ctx.exports.AxoHostDirectory
      .getByName("private-fleet")
      .heartbeatHost(reference, principal);
  }
  protected async storeHostSessions(publication: unknown, principal: string): Promise<{ storedAt: string }> {
    return this.ctx.exports.AxoHostDirectory
      .getByName("private-fleet")
      .publishHostSessions(publication, principal);
  }
  protected async storeHostEvent(event: unknown, principal: string): Promise<void> {
    await this.ctx.exports.AxoHostDirectory
      .getByName("private-fleet")
      .applyHostEvent(event, principal);
  }
  private admittedDaemon(peer: Peer): Route {
    const route = this.route(peer.machineId);
    if (peer.role !== "daemon")
      throw new JSONRPCErrorException("Method not found", -32601);
    if (
      !route ||
      route.connection_id !== peer.connectionId ||
      route.lease_until <= Date.now() ||
      peer.expiresAt <= Date.now()
    )
      throw new JSONRPCErrorException("Stale lease", -32002);
    return route;
  }
  private async register(
    params: unknown,
    { socket, peer }: CallerContext,
  ): Promise<Registered> {
    if (!this.supportsLegacyMachineMethods())
      throw new JSONRPCErrorException("Method not found", -32601);
    const route = this.admittedDaemon(peer);
    const parsed = registrationSchema.safeParse(params);
    if (
      !parsed.success ||
      parsed.data.machineId !== peer.machineId ||
      (route.generation !== null &&
        route.generation !== parsed.data.hostGeneration)
    )
      throw new JSONRPCErrorException("Invalid registration", -32602);
    // Pin the boot generation before the directory await, including concurrent frames.
    this.ctx.storage.sql.exec(
      "UPDATE route SET generation = ? WHERE connection_id = ?",
      parsed.data.hostGeneration,
      peer.connectionId,
    );
    await this.ctx.exports.AxoHostDirectory.getByName("private-fleet").register(
      parsed.data,
      peer.identity,
    );
    const current = this.admittedDaemon(peer);
    if (
      current.generation !== parsed.data.hostGeneration ||
      !this.socket(peer.connectionId) ||
      this.peer(socket).expiresAt <= Date.now()
    )
      throw new JSONRPCErrorException("Stale lease", -32002);
    this.ctx.storage.sql.exec(
      "UPDATE route SET generation = ?, ready = 1, lease_until = ? WHERE connection_id = ?",
      parsed.data.hostGeneration,
      Math.min(peer.expiresAt, Date.now() + LIMITS.leaseMs),
      peer.connectionId,
    );
    recordApiEvent({ event: "host_registered" });
    return {
      leaseId: peer.connectionId,
      hostGeneration: parsed.data.hostGeneration,
      leaseExpiresAt: this.admittedDaemon(peer).lease_until,
    };
  }
  private heartbeat(params: unknown, { peer }: CallerContext): Heartbeat {
    if (!this.supportsLegacyMachineMethods())
      throw new JSONRPCErrorException("Method not found", -32601);
    const route = this.admittedDaemon(peer);
    if (
      !route.ready ||
      !z
        .object({ leaseId: z.literal(peer.connectionId) })
        .strict()
        .safeParse(params).success
    )
      throw new JSONRPCErrorException("Invalid heartbeat", -32602);
    this.ctx.storage.sql.exec(
      "UPDATE route SET lease_until = ? WHERE connection_id = ?",
      Math.min(peer.expiresAt, Date.now() + LIMITS.leaseMs),
      peer.connectionId,
    );
    return { leaseId: peer.connectionId, leaseExpiresAt: this.admittedDaemon(peer).lease_until };
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

    this.ctx.storage.sql.exec(
      "UPDATE route SET generation = ? WHERE connection_id = ?",
      parsed.data.hostGeneration,
      peer.connectionId,
    );
    const host = await this.storeHostRegistration(parsed.data, peer.identity);
    const current = this.admittedDaemon(peer);
    if (
      current.generation !== parsed.data.hostGeneration ||
      !this.socket(peer.connectionId) ||
      this.peer(socket).expiresAt <= Date.now()
    )
      throw new JSONRPCErrorException("Stale lease", -32002);
    this.ctx.storage.sql.exec(
      "UPDATE route SET generation = ?, ready = 1, lease_until = ? WHERE connection_id = ?",
      parsed.data.hostGeneration,
      Math.min(peer.expiresAt, Date.now() + LIMITS.leaseMs),
      peer.connectionId,
    );
    recordApiEvent({ event: "host_registered" });
    this.broadcastHostPresence(parsed.data.hostId, parsed.data.hostGeneration, "online");
    return { host };
  }

  private async heartbeatHost(params: unknown, { peer }: CallerContext) {
    const route = this.admittedDaemon(peer);
    const parsed = hostV1Methods["axo.host.heartbeat"].safeParse(params);
    if (
      !parsed.success ||
      !route.ready ||
      parsed.data.hostId !== peer.machineId ||
      parsed.data.hostGeneration !== route.generation
    )
      throw new JSONRPCErrorException("Invalid host heartbeat", -32602);

    const result = await this.storeHostHeartbeat(parsed.data, peer.identity);
    this.renewRoute(peer);
    return result;
  }

  private async publishHostSessions(params: unknown, { peer }: CallerContext) {
    const route = this.admittedDaemon(peer);
    const parsed = hostV1Methods["axo.host.sessions.publish"].safeParse(params);
    if (
      !parsed.success ||
      !route.ready ||
      parsed.data.hostId !== peer.machineId ||
      parsed.data.hostGeneration !== route.generation
    )
      throw new JSONRPCErrorException("Invalid host session publication", -32602);

    const result = await this.storeHostSessions(parsed.data, peer.identity);
    this.renewRoute(peer);
    return result;
  }

  private renewRoute(peer: Peer): void {
    this.ctx.storage.sql.exec(
      "UPDATE route SET lease_until = ? WHERE connection_id = ?",
      Math.min(peer.expiresAt, Date.now() + LIMITS.leaseMs),
      peer.connectionId,
    );
  }

  private receiveReply(socket: WebSocket, reply: Reply): void {
    if (typeof reply.id !== "string") return;
    const pending = this.ctx.storage.sql
      .exec<Pending>("SELECT * FROM pending WHERE hop_id = ?", reply.id)
      .toArray()[0];
    const active = this.active(this.peer(socket).machineId);
    if (
      !pending ||
      !active ||
      active.socket !== socket ||
      pending.connection_id !== active.route.connection_id
    )
      return;
    const id = JSON.parse(pending.original_id) as RpcId;
    if (pending.deadline <= Date.now()) {
      this.finishPending(
        reply.id,
        failure(id, -32004, "Outcome unknown; reconcile commandId"),
      );
      return;
    }
    if ("result" in reply) {
      if (Object.hasOwn(hostV1Results, pending.method)) {
        const result = hostV1Results[pending.method as HostMethod].safeParse(reply.result);
        if (!result.success) {
          this.finishPending(
            reply.id,
            failure(id, -32004, "Invalid daemon outcome; reconcile commandId"),
          );
          return;
        }
      } else {
        const result = results[pending.method as RemoteMethod].safeParse(reply.result);
        if (!result.success) {
          this.finishPending(
            reply.id,
            failure(id, -32004, "Invalid daemon outcome; reconcile commandId"),
          );
          return;
        }
        // The response source is current; historical terminal records legitimately retain
        // their original runtime generation and must never be promoted to current ownership.
        if (result.data.hostGeneration !== pending.generation) {
          this.finishPending(
            reply.id,
            failure(id, -32004, "Stale daemon outcome; reconcile commandId"),
          );
          return;
        }
      }
    }
    // Only schema-validated metadata responses cross this adapter; no terminal bytes.
    this.finishPending(
      reply.id,
      "error" in reply
        ? failure(id, reply.error.code, "Daemon rejected operation")
        : success(id, reply.result),
    );
  }
  private finishPending(hopId: string, reply: Reply) {
    const pending = this.ctx.storage.sql
      .exec<Pending>("SELECT * FROM pending WHERE hop_id = ?", hopId)
      .toArray()[0];
    if (!pending) return;
    recordApiEvent({
      event: "relay_reply",
      method: pending.method,
      outcome:
        "error" in reply && reply.error.code === -32004 ? "unknown" : "reply",
    });
    this.ctx.storage.sql.exec("DELETE FROM pending WHERE hop_id = ?", hopId);
    this.complete(pending.group_id, reply);
  }
  private complete(groupId: string, reply: Reply) {
    const sql = this.ctx.storage.sql;
    const group = sql
      .exec<Group>("SELECT * FROM groups WHERE group_id = ?", groupId)
      .toArray()[0];
    if (!group) return;
    const replies = JSON.parse(group.replies) as Reply[];
    replies.push(reply);
    const bounded = boundReplyGroup(replies, group.batch !== 0);
    if (group.remaining > 1) {
      sql.exec(
        "UPDATE groups SET remaining = remaining - 1, replies = ? WHERE group_id = ?",
        bounded.stored,
        groupId,
      );
      return;
    }
    sql.exec("DELETE FROM groups WHERE group_id = ?", groupId);
    const socket = this.socket(group.connection_id);
    if (socket) this.send(socket, group.batch ? bounded.replies : bounded.replies[0]);
  }
  private send(socket: WebSocket, value: unknown): boolean {
    const raw = JSON.stringify(value);
    const bytes = new TextEncoder().encode(raw).byteLength;
    const peer = this.peer(socket);
    if (
      peer.expiresAt <= Date.now() ||
      bytes > LIMITS.frameBytes ||
      peer.outgoing.length >= 32 ||
      peer.outgoing.reduce((a, b) => a + b, 0) + bytes > 131072
    ) {
      this.drop(socket, 1008, "Delivery capacity");
      return false;
    }
    peer.outgoing.push(bytes);
    socket.serializeAttachment(peer);
    try {
      socket.send(raw);
      return true;
    } catch {
      this.drop(socket, 1011, "Transport failed");
      return false;
    }
  }
  protected closeHostRelay(machineId: string): void {
    for (const socket of this.sockets("client")) {
      if (this.peer(socket).machineId === machineId) this.drop(socket, 4003, "Host revoked");
    }
    const route = this.route(machineId);
    if (route) this.fence(route.connection_id);
  }
  protected fence(connectionId: string) {
    const sql = this.ctx.storage.sql;
    const previousRoute = this.routeByConnection(connectionId);
    const rows = sql
      .exec<Pending>(
        "SELECT * FROM pending WHERE connection_id = ?",
        connectionId,
      )
      .toArray();
    for (const pending of rows)
      this.finishPending(
        pending.hop_id,
        failure(
          JSON.parse(pending.original_id) as RpcId,
          -32004,
          "Outcome unknown; reconcile commandId",
        ),
      );
    sql.exec("DELETE FROM route WHERE connection_id = ?", connectionId);
    if (
      previousRoute?.connection_id === connectionId &&
      previousRoute.generation
    ) {
      this.broadcastHostPresence(
        previousRoute.machine_id,
        previousRoute.generation,
        "offline",
      );
    }
    const socket = this.socket(connectionId);
    if (socket) socket.close(4002, "Lease ended");
  }
  private drop(socket: WebSocket, code: number, reason: string) {
    const peer = this.peer(socket);
    recordApiEvent({ event: "connection_closed", role: peer.role, code });
    socket.close(code, reason);
    if (peer.role === "daemon") this.fence(peer.connectionId);
    this.ctx.storage.sql.exec(
      "DELETE FROM pending WHERE group_id IN (SELECT group_id FROM groups WHERE connection_id = ?)",
      peer.connectionId,
    );
    this.ctx.storage.sql.exec(
      "DELETE FROM groups WHERE connection_id = ?",
      peer.connectionId,
    );
  }
  webSocketClose(socket: WebSocket) {
    this.drop(socket, 1000, "Disconnected");
  }
  webSocketError(socket: WebSocket) {
    this.drop(socket, 1011, "Transport failed");
  }
  private async schedule() {
    const deadlines = this.sockets().map(
      (socket) => this.peer(socket).expiresAt,
    );
    for (const route of this.routes()) deadlines.push(route.lease_until);
    const pending = this.ctx.storage.sql
      .exec<{ deadline: number }>(
        "SELECT MIN(deadline) AS deadline FROM pending",
      )
      .one().deadline;
    if (pending) deadlines.push(pending);
    if (deadlines.length)
      await this.ctx.storage.setAlarm(
        Math.max(Date.now() + 1, Math.min(...deadlines)),
      );
    else await this.ctx.storage.deleteAlarm();
  }
  async alarm() {
    for (const route of this.routes())
      if (route.lease_until <= Date.now()) this.fence(route.connection_id);
    for (const socket of this.ctx.getWebSockets())
      if (this.peer(socket).expiresAt <= Date.now())
        this.drop(socket, 4001, "Access expired");
    for (const pending of this.ctx.storage.sql
      .exec<Pending>("SELECT * FROM pending WHERE deadline <= ?", Date.now())
      .toArray())
      this.finishPending(
        pending.hop_id,
        failure(
          JSON.parse(pending.original_id) as RpcId,
          -32004,
          "Outcome unknown; reconcile commandId",
        ),
      );
    await this.schedule();
  }
}
