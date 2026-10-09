import { DurableObject } from "cloudflare:workers";
import { z } from "zod";
import { authorize, type Principal } from "./access";
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
  uuid,
  type Call,
  type Reply,
  type RpcId,
  type Registration,
  type RemoteMethod,
  createProfileServer,
  serveProfileMessage,
  JSONRPCErrorException,
  type JSONRPCServer,
  type TypedJSONRPCServer,
  type ServiceMethods,
  type Registered,
  type Heartbeat,
} from "@axo/protocol";

interface Peer extends Principal {
  connectionId: string;
  machineId: string;
  negotiated: boolean;
  window: number;
  calls: number;
  outgoing: number[];
}
type CallerContext = { socket: WebSocket; peer: Peer };
type Route = {
  connection_id: string;
  machine_id: string;
  generation: string | null;
  lease_until: number;
  ready: number;
};
type Group = {
  group_id: string;
  connection_id: string;
  batch: number;
  remaining: number;
  replies: string;
};
type Pending = {
  hop_id: string;
  group_id: string;
  original_id: string;
  connection_id: string;
  method: RemoteMethod;
  generation: string;
  deadline: number;
};
type MachineRow = {
  machine_id: string;
  principal: string;
  label: string;
  generation: string;
};
const peerSchema = z
  .object({
    role: z.enum(["client", "daemon"]),
    identity: z.string().min(1).max(256),
    expiresAt: z.number().finite(),
    connectionId: uuid,
    machineId: uuid,
    negotiated: z.boolean(),
    window: z.number(),
    calls: z.number().int().nonnegative(),
    outgoing: z.array(z.number().int().min(0).max(LIMITS.frameBytes)).max(32),
  })
  .strict();

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const path = new URL(request.url).pathname;
    const match = /^\/v1\/machines\/([^/]+)\/(daemon|client)$/.exec(path);
    if (path !== "/v1/rpc" && !match)
      return new Response("Not found", { status: 404 });
    const role = match?.[2] === "daemon" ? "daemon" : "client";
    let principal: Principal;
    try {
      principal = await authorize(request, role, env);
    } catch {
      return new Response("Access required", { status: 401 });
    }
    if (path === "/v1/rpc") {
      if (request.method !== "POST")
        return new Response("POST required", { status: 405 });
      const raw = await boundedBody(request);
      if (raw === null) return new Response("Frame limit", { status: 413 });
      const server = createProfileServer<Principal>();
      const typed: TypedJSONRPCServer<
        Pick<ServiceMethods, "axo.machine.list">,
        Principal
      > = server;
      typed.addMethod("axo.machine.list", async (params, caller) => {
        if (
          !z
            .object({})
            .strict()
            .safeParse(params ?? {}).success
        )
          throw new JSONRPCErrorException("Invalid params", -32602);
        const machines =
          await ctx.exports.MachineDirectory.getByName("private-fleet").list();
        if (caller.expiresAt <= Date.now())
          throw new JSONRPCErrorException("Access expired", -32002);
        return { machines };
      });
      const reply = await serveProfileMessage(server, raw, principal);
      return reply ? json(reply) : new Response(null, { status: 204 });
    }
    const machine = uuid.safeParse(match![1]);
    if (!machine.success)
      return new Response("Invalid machine", { status: 400 });
    if (
      request.method !== "GET" ||
      request.headers.get("Upgrade")?.toLowerCase() !== "websocket"
    )
      return new Response("WebSocket required", { status: 426 });
    if (request.headers.has("Origin"))
      return new Response("Native connections only", { status: 403 });
    const admission = await ctx.exports.MachineDirectory.getByName(
      "private-fleet",
    ).admit(machine.data, principal);
    if (admission !== "admitted")
      return new Response(admission, {
        status:
          admission === "capacity" ? 429 : admission === "conflict" ? 403 : 404,
      });
    if (principal.expiresAt <= Date.now())
      return new Response("Access expired", { status: 401 });
    // Construct fresh headers: public callers cannot spoof internal caller context.
    return ctx.exports.MachineRelay.getByName(machine.data).fetch(
      new Request("https://machine.internal/", {
        headers: {
          Upgrade: "websocket",
          "X-Axo-Role": role,
          "X-Axo-Identity": principal.identity,
          "X-Axo-Expiry": String(principal.expiresAt),
          "X-Axo-Machine": machine.data,
        },
      }),
    );
  },
} satisfies ExportedHandler<Env>;

function json(value: unknown): Response {
  return Response.json(value, {
    headers: { "Cache-Control": "private, no-store" },
  });
}
async function boundedBody(request: Request): Promise<string | null> {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0;
  let text = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return text + decoder.decode();
      size += value.byteLength;
      if (size > LIMITS.frameBytes) {
        await reader.cancel();
        return null;
      }
      text += decoder.decode(value, { stream: true });
    }
  } catch {
    return null;
  } finally {
    reader.releaseLock();
  }
}

export class MachineDirectory extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS machines (machine_id TEXT PRIMARY KEY, principal TEXT NOT NULL, label TEXT NOT NULL, generation TEXT NOT NULL)",
    );
  }
  admit(
    machineId: string,
    principal: Principal,
  ): "admitted" | "capacity" | "conflict" | "unregistered" {
    uuid.parse(machineId);
    const sql = this.ctx.storage.sql;
    const old = sql
      .exec<MachineRow>(
        "SELECT * FROM machines WHERE machine_id = ?",
        machineId,
      )
      .toArray()[0];
    if (principal.role === "client")
      return old?.label ? "admitted" : "unregistered";
    if (old)
      return old.principal === principal.identity ? "admitted" : "conflict";
    if (
      sql
        .exec<{ count: number }>("SELECT COUNT(*) AS count FROM machines")
        .one().count >= LIMITS.machines
    )
      return "capacity";
    // Reserve before creating a relay object, but never publish an unregistered machine.
    sql.exec(
      "INSERT INTO machines VALUES (?, ?, '', '')",
      machineId,
      principal.identity,
    );
    return "admitted";
  }
  register(registration: Registration, principal: string): void {
    const input = registrationSchema.parse(registration);
    const sql = this.ctx.storage.sql;
    const old = sql
      .exec<MachineRow>(
        "SELECT * FROM machines WHERE machine_id = ?",
        input.machineId,
      )
      .toArray()[0];
    if (old && old.principal !== principal)
      throw new Error("Machine principal conflict");
    if (
      !old &&
      sql
        .exec<{ count: number }>("SELECT COUNT(*) AS count FROM machines")
        .one().count >= LIMITS.machines
    )
      throw new Error("Machine capacity");
    sql.exec(
      "INSERT INTO machines VALUES (?, ?, ?, ?) ON CONFLICT(machine_id) DO UPDATE SET label = excluded.label, generation = excluded.generation",
      input.machineId,
      principal,
      input.label,
      input.hostGeneration,
    );
  }
  async list() {
    const rows = this.ctx.storage.sql
      .exec<MachineRow>(
        "SELECT * FROM machines WHERE label <> '' ORDER BY machine_id LIMIT 16",
      )
      .toArray();
    return Promise.all(
      rows.map(async (row) => ({
        machineId: row.machine_id,
        label: row.label,
        ...(await this.ctx.exports.MachineRelay.getByName(
          row.machine_id,
        ).presence()),
      })),
    );
  }
}

export class MachineRelay extends DurableObject<Env> {
  private readonly rpc: JSONRPCServer<CallerContext>;
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS route (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), connection_id TEXT NOT NULL, machine_id TEXT NOT NULL, generation TEXT, lease_until REAL NOT NULL, ready INTEGER NOT NULL)",
    );
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS groups (group_id TEXT PRIMARY KEY, connection_id TEXT NOT NULL, batch INTEGER NOT NULL, remaining INTEGER NOT NULL, replies TEXT NOT NULL)",
    );
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS pending (hop_id TEXT PRIMARY KEY, group_id TEXT NOT NULL, original_id TEXT NOT NULL, connection_id TEXT NOT NULL, method TEXT NOT NULL, generation TEXT NOT NULL, deadline REAL NOT NULL)",
    );
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
      >,
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
        methods: Object.keys(remoteMethods),
        deliveryCredits: { frames: 32, bytes: 131072 },
      };
    });
    typed.addMethod("axo.machine.register", (params, caller) =>
      this.register(params, caller),
    );
    typed.addMethod("axo.machine.heartbeat", (params, caller) =>
      this.heartbeat(params, caller),
    );
    return server;
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
    const route = this.route();
    if (route && !connected.has(route.connection_id))
      this.fence(route.connection_id);
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
  private route(): Route | undefined {
    return this.ctx.storage.sql
      .exec<Route>("SELECT * FROM route WHERE singleton = 1")
      .toArray()[0];
  }
  private active(): { route: Route; socket: WebSocket } | undefined {
    const route = this.route();
    if (!route?.ready || route.lease_until <= Date.now()) return;
    const socket = this.socket(route.connection_id);
    if (socket) return { route, socket };
  }
  presence() {
    const active = this.active();
    return {
      online: !!active,
      hostGeneration: active?.route.generation ?? null,
    };
  }

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
    if (
      peer.role === "client" &&
      this.sockets("client").length >= LIMITS.clientsPerMachine
    )
      return new Response("Client capacity", { status: 429 });
    if (peer.role === "daemon") {
      const old = this.route();
      if (old && old.lease_until > now && this.socket(old.connection_id))
        return new Response("Duplicate machine connection", { status: 409 });
      if (old) this.fence(old.connection_id);
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO route VALUES (1, ?, ?, NULL, ?, 0)",
        peer.connectionId,
        peer.machineId,
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
    if (peer.calls > 30) {
      this.drop(socket, 1008, "Rate limit");
      return;
    }
    if (peer.role === "daemon" && !decoded.batch) {
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
    const active = this.active();
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
      sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pending").one()
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
      "INSERT INTO pending VALUES (?, ?, ?, ?, ?, ?, ?)",
      hopId,
      groupId,
      JSON.stringify(id),
      active.route.connection_id,
      method,
      active.route.generation!,
      deadline,
    );
    await this.ctx.storage.sync();
    if (
      this.active()?.route.connection_id !== active.route.connection_id ||
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

  private admittedDaemon(peer: Peer): Route {
    const route = this.route();
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
    await this.ctx.exports.MachineDirectory.getByName("private-fleet").register(
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
    return {
      leaseId: peer.connectionId,
      hostGeneration: parsed.data.hostGeneration,
    };
  }
  private heartbeat(params: unknown, { peer }: CallerContext): Heartbeat {
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
    return { leaseId: peer.connectionId };
  }

  private receiveReply(socket: WebSocket, reply: Reply): void {
    if (typeof reply.id !== "string") return;
    const pending = this.ctx.storage.sql
      .exec<Pending>("SELECT * FROM pending WHERE hop_id = ?", reply.id)
      .toArray()[0];
    const active = this.active();
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
      const result = results[pending.method].safeParse(reply.result);
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
    const encoded = JSON.stringify(replies);
    if (new TextEncoder().encode(encoded).byteLength > LIMITS.frameBytes) {
      const socket = this.socket(group.connection_id);
      if (socket) this.drop(socket, 1009, "Response limit");
      return;
    }
    if (group.remaining > 1) {
      sql.exec(
        "UPDATE groups SET remaining = remaining - 1, replies = ? WHERE group_id = ?",
        encoded,
        groupId,
      );
      return;
    }
    sql.exec("DELETE FROM groups WHERE group_id = ?", groupId);
    const socket = this.socket(group.connection_id);
    if (socket) this.send(socket, group.batch ? replies : replies[0]);
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
  private fence(connectionId: string) {
    const sql = this.ctx.storage.sql;
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
    const socket = this.socket(connectionId);
    if (socket) socket.close(4002, "Lease ended");
  }
  private drop(socket: WebSocket, code: number, reason: string) {
    const peer = this.peer(socket);
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
    const route = this.route();
    if (route) deadlines.push(route.lease_until);
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
    const route = this.route();
    if (route && route.lease_until <= Date.now())
      this.fence(route.connection_id);
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
