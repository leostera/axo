import WebSocket from "ws";
import { accessHeaders } from "./access-headers";
import {
  FRAGMENT_METHOD,
  MemoryPartialStore,
  receiveFragment,
  replySchema,
  splitMessage,
  JSONRPCClient,
  createJSONRPCRequest,
  failure,
  localEndpointSchema,
  type LocalEndpoint,
} from "@axo/protocol";

/** Dummy client: actual network WebSockets, no direct DO admission or retry queue. */
export class Peer {
  readonly socket: WebSocket;
  private queued: unknown[] = [];
  private readonly rpc: JSONRPCClient;
  private readonly pendingIds = new Set<string | number>();
  private waiters: Array<{
    resolve: (value: unknown) => void;
    reject: (reason: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }> = [];

  /** The server sends messages larger than a frame as fragments (RFD0016, Transport). */
  private readonly partials = new MemoryPartialStore();
  private constructor(socket: WebSocket) {
    this.socket = socket;
    this.rpc = new JSONRPCClient(
      (request: unknown) => this.send(request),
      () => crypto.randomUUID(),
    );
    socket.on("message", (raw) => this.receive(raw.toString()));
    socket.on("close", () => this.rejectWaiters());
  }
  private receive(raw: string) {
    let value: unknown;
    try {
      value = JSON.parse(raw);
    } catch {
      this.socket.close(1002);
      return;
    }
    const fragment = value as { method?: unknown; params?: unknown } | null;
    if (fragment?.method === FRAGMENT_METHOD) {
      const outcome = receiveFragment(this.partials, fragment.params);
      if (outcome.status === "invalid") {
        this.socket.close(1002);
        return;
      }
      if (outcome.status !== "complete") return;
      value = JSON.parse(outcome.raw);
    }
    const responses = Array.isArray(value) ? value : [value];
    const unmatched: unknown[] = [];
    for (const response of responses) {
      const parsed = replySchema.safeParse(response);
      if (
        parsed.success &&
        parsed.data.id !== null &&
        this.pendingIds.has(parsed.data.id)
      )
        this.rpc.receive(parsed.data);
      else unmatched.push(response);
    }
    if (!unmatched.length) return;
    value = Array.isArray(value) ? unmatched : unmatched[0];
    const waiter = this.waiters.shift();
    if (waiter) {
      clearTimeout(waiter.timer);
      waiter.resolve(value);
      return;
    }
    if (this.queued.length >= 128) {
      this.socket.close(1008);
      return;
    }
    this.queued.push(value);
  }
  private rejectWaiters() {
    this.rpc.rejectAllPendingRequests(
      "Connection closed; outcome may be unknown",
    );
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error("Disconnected: outcome may be unknown"));
    }
  }
  static async connect(
    url: string,
    assertion: string,
    machine: string,
    role: "client" | "daemon",
  ) {
    const socket = new WebSocket(
      `${url.replace(/^http/, "ws")}v1/machines/${machine}/${role}`,
      {
        headers: accessHeaders(assertion),
        maxPayload: 65_536,
        followRedirects: false,
      },
    );
    return Peer.open(socket);
  }
  /** A host's socket on the account path, served by its HostDO (RFD0018). */
  static async connectHostDaemon(
    url: string,
    accountId: string,
    hostId: string,
    headers: Record<string, string>,
  ) {
    const socket = new WebSocket(`${url.replace(/^http/, "ws")}api/v1/accounts/${accountId}/hosts/${hostId}/daemon`, {
      headers,
      maxPayload: 65_536,
      followRedirects: false,
    });
    return Peer.open(socket);
  }
  /** A client's one socket, served by its ClientDO (RFD0018). */
  static async connectClient(url: string, clientId: string, headers: Record<string, string>) {
    const socket = new WebSocket(`${url.replace(/^http/, "ws")}api/v1/account/client?clientId=${clientId}`, {
      headers,
      maxPayload: 65_536,
      followRedirects: false,
    });
    return Peer.open(socket);
  }
  static async connectHost(
    url: string,
    assertion: string,
    host: string,
    role: "client" | "daemon",
    origin?: string,
  ) {
    const socket = new WebSocket(
      `${url.replace(/^http/, "ws")}v1/hosts/${host}/${role}`,
      {
        headers: {
          ...accessHeaders(assertion),
          ...(origin ? { Origin: origin } : {}),
        },
        maxPayload: 65_536,
        followRedirects: false,
      },
    );
    return Peer.open(socket);
  }
  static async connectLocal(discovery: LocalEndpoint) {
    const endpoint = localEndpointSchema.parse(discovery);
    return Peer.open(
      new WebSocket(endpoint.endpoint, {
        maxPayload: 65_536,
        followRedirects: false,
      }),
    );
  }
  private static async open(socket: WebSocket) {
    const peer = new Peer(socket);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        socket.terminate();
        reject(new Error("Connect deadline"));
      }, 5000);
      socket.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      socket.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
    return peer;
  }
  /** Sends one message, as fragments when it is larger than a frame. Raw strings go as they are. */
  send(value: unknown) {
    if (typeof value === "string") return this.socket.send(value);
    for (const frame of splitMessage(JSON.stringify(value), crypto.randomUUID().replaceAll("-", "")) ?? [])
      this.socket.send(frame);
  }
  next(): Promise<unknown> {
    if (this.queued.length) return Promise.resolve(this.queued.shift());
    if (this.socket.readyState !== WebSocket.OPEN)
      return Promise.reject(new Error("Disconnected: outcome may be unknown"));
    if (this.waiters.length >= 32)
      return Promise.reject(new Error("Pending capacity"));
    return new Promise((resolve, reject) => {
      const waiter = {
        resolve,
        reject,
        timer: setTimeout(() => {
          this.waiters = this.waiters.filter((value) => value !== waiter);
          reject(new Error("Reply deadline; outcome may be unknown"));
        }, 12000),
      };
      this.waiters.push(waiter);
    });
  }
  // Library correlation supports concurrent calls; raw next/send remain fixture-only helpers.
  // Generated string IDs avoid the upstream client's null-ID advanced-call limitation.
  async call(
    method: string,
    params: unknown,
    id: string | number = crypto.randomUUID(),
  ) {
    if (this.pendingIds.size >= 32 || this.pendingIds.has(id))
      throw new Error("Pending ID capacity/conflict");
    this.pendingIds.add(id);
    try {
      const request = createJSONRPCRequest(id, method, params);
      const response = await this.rpc
        .timeout(12000, (id) =>
          failure(id, -32004, "Outcome unknown; reconcile commandId"),
        )
        .requestAdvanced(request);
      const reply = replySchema.parse(response);
      if (reply.id !== id) throw new Error("Mismatched response ID");
      if ("error" in reply && reply.error.code === 0)
        return failure(id, -32004, "Outcome unknown; reconcile commandId");
      return reply;
    } finally {
      this.pendingIds.delete(id);
    }
  }
  async negotiate() {
    const reply = await this.call("axo.protocol.negotiate", {
      protocolVersion: 2,
    });
    if (!("result" in reply)) throw new Error("Negotiation failed");
  }
  close() {
    this.socket.terminate();
  }
}
