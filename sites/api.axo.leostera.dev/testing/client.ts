import WebSocket from "ws";
import {
  replySchema,
  JSONRPCClient,
  createJSONRPCRequest,
  failure,
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

  private constructor(
    socket: WebSocket,
    private credits: boolean,
  ) {
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
    if (this.credits)
      this.send({
        jsonrpc: "2.0",
        method: "axo.transport.ack",
        params: { frames: 1 },
      });
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
    credits = true,
  ) {
    const socket = new WebSocket(
      `${url.replace(/^http/, "ws")}v1/machines/${machine}/${role}`,
      {
        headers: { "Cf-Access-Jwt-Assertion": assertion },
        maxPayload: 65_536,
        followRedirects: false,
      },
    );
    const peer = new Peer(socket, credits);
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
  send(value: unknown) {
    this.socket.send(typeof value === "string" ? value : JSON.stringify(value));
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
      protocolVersion: 1,
    });
    if (!("result" in reply)) throw new Error("Negotiation failed");
  }
  close() {
    this.socket.terminate();
  }
}
