import {
  hostListResultSchema,
  hostNotificationSchema,
  hostRefSchema,
  hostSessionsListResultSchema,
  hostSubscribeResultSchema,
  hostUnsubscribeResultSchema,
  remoteSessionCreateResultSchema,
  remoteTerminalInputResultSchema,
  remoteTerminalResizeResultSchema,
  type HostEvent,
  type HostMethodParams,
} from "@axo/protocol/v1";
import { z } from "zod";

export type Host = z.infer<typeof hostListResultSchema>["hosts"][number];
export type Session = z.infer<typeof hostSessionsListResultSchema>["sessions"][number];
export type HostRef = z.infer<typeof hostRefSchema>;
export type { HostEvent };

export class AxoApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly url: string,
  ) {
    super(message);
    this.name = "AxoApiError";
  }
}

export class AxoRpcError extends Error {
  constructor(
    message: string,
    readonly code: number,
  ) {
    super(message);
    this.name = "AxoRpcError";
  }
}

export interface WebSocketLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onopen: ((event: Event) => void) | null;
  onmessage: ((event: MessageEvent) => void) | null;
  onerror: ((event: Event) => void) | null;
  onclose: ((event: CloseEvent) => void) | null;
}

export type WebSocketFactory = (url: string) => WebSocketLike;
export type HostEventHandler = (event: HostEvent) => void;

const OPEN = 1;
const DEFAULT_TIMEOUT_MS = 10_000;
const rpcIdSchema = z.union([
  z.string().max(128),
  z.number().finite().min(-Number.MAX_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER),
  z.null(),
]);
const appRemoteResults = {
  "axo.remote.session.create": remoteSessionCreateResultSchema,
  "axo.remote.workspace.session.create": remoteSessionCreateResultSchema,
  "axo.remote.terminal.input": remoteTerminalInputResultSchema,
  "axo.remote.terminal.resize": remoteTerminalResizeResultSchema,
} as const;
type AppRemoteMethod = keyof typeof appRemoteResults;

const replySchema = z.union([
  z.object({ jsonrpc: z.literal("2.0"), id: rpcIdSchema, result: z.unknown() })
    .strict()
    .refine((value) => Object.hasOwn(value, "result")),
  z.object({
    jsonrpc: z.literal("2.0"),
    id: rpcIdSchema,
    error: z.object({
      code: z.number().int(),
      message: z.string().max(256),
      data: z.unknown().optional(),
    }).strict(),
  }).strict(),
]);

export class RemoteAxoApi {
  readonly baseUrl: URL;

  private readonly fetcher: typeof fetch;

  constructor(
    baseUrl: string | URL,
    fetcher?: typeof fetch,
    private readonly makeWebSocket: WebSocketFactory = (url) => new WebSocket(url),
  ) {
    this.fetcher = fetcher ?? globalThis.fetch.bind(globalThis);
    this.baseUrl = new URL(baseUrl);
    if (this.baseUrl.protocol !== "https:" && this.baseUrl.protocol !== "http:") {
      throw new TypeError("Axo API URL must use HTTP or HTTPS");
    }
    this.baseUrl.pathname = this.baseUrl.pathname.replace(/\/$/, "");
    this.baseUrl.search = "";
    this.baseUrl.hash = "";
  }

  async listHosts(signal?: AbortSignal): Promise<Host[]> {
    const response = await this.get("/api/v1/account/hosts", signal);
    return hostListResultSchema.parse(await response.json()).hosts;
  }

  async listHostSessions(reference: HostRef, signal?: AbortSignal): Promise<Session[]> {
    const host = hostRefSchema.parse(reference);
    const query = new URLSearchParams({ hostGeneration: host.hostGeneration });
    const response = await this.get(
      `/api/v1/account/hosts/${encodeURIComponent(host.hostId)}/sessions?${query}`,
      signal,
    );
    const result = hostSessionsListResultSchema.parse(await response.json());
    if (result.host.hostId !== host.hostId || result.host.hostGeneration !== host.hostGeneration) {
      throw new Error("Axo API returned metadata for a different host generation");
    }
    return result.sessions;
  }

  connectHost(
    reference: HostRef,
    onEvent: HostEventHandler,
    onClose?: (error: Error) => void,
  ): Promise<HostRelayConnection> {
    return HostRelayConnection.open(
      this.makeWebSocket(this.webSocketUrl(reference)),
      reference,
      onEvent,
      onClose,
    );
  }

  private async get(path: string, signal?: AbortSignal): Promise<Response> {
    const url = new URL(path, `${this.baseUrl.href}/`);
    let response: Response;
    try {
      response = await this.fetcher(url, {
        method: "GET",
        credentials: "include",
        cache: "no-store",
        headers: { Accept: "application/json" },
        signal,
      });
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new AxoApiError("Could not reach the Axo API", 0, url.href);
    }
    if (!response.ok) {
      throw new AxoApiError(
        response.status === 401 || response.status === 403
          ? "Axo API Access is required or has expired"
          : `Axo API request failed (${response.status})`,
        response.status,
        url.href,
      );
    }
    return response;
  }

  private webSocketUrl(reference: HostRef): string {
    const host = hostRefSchema.parse(reference);
    const url = new URL(
      `/api/v1/account/hosts/${encodeURIComponent(host.hostId)}/client`,
      this.baseUrl,
    );
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return url.href;
  }
}

export class HostRelayConnection {
  private nextId = 1;
  private readonly pending = new Map<
    number,
    {
      resolve: (value: unknown) => void;
      reject: (error: Error) => void;
      timeout: ReturnType<typeof setTimeout>;
    }
  >();
  private closedError: Error | null = null;
  private subscriptionId: string | null = null;

  private constructor(
    private readonly socket: WebSocketLike,
    readonly reference: HostRef,
    private readonly onEvent: HostEventHandler,
    private readonly onClose?: (error: Error) => void,
  ) {
    socket.onmessage = (event) => this.receive(event.data);
    socket.onerror = () => this.fail(new Error("Axo API WebSocket failed"));
    socket.onclose = (event) => {
      const reason = event.reason || `WebSocket closed (${event.code})`;
      this.fail(new Error(reason));
    };
  }

  static async open(
    socket: WebSocketLike,
    reference: HostRef,
    onEvent: HostEventHandler,
    onClose?: (error: Error) => void,
  ): Promise<HostRelayConnection> {
    const parsedReference = hostRefSchema.parse(reference);
    const connection = new HostRelayConnection(socket, parsedReference, onEvent, onClose);
    try {
      await connection.waitUntilOpen();
      await connection.request("axo.protocol.negotiate", { protocolVersion: 1 });
      const response = await connection.request(
        "axo.host.subscribe",
        parsedReference,
      );
      connection.subscriptionId = hostSubscribeResultSchema.parse(response).subscriptionId;
      return connection;
    } catch (error) {
      connection.close();
      throw error;
    }
  }

  async call<Method extends AppRemoteMethod>(
    method: Method,
    params: HostMethodParams<Method>,
  ): Promise<z.infer<(typeof appRemoteResults)[Method]>> {
    // The Access-protected Worker validates each v1 request before routing it to Axod.
    const result = await this.request(method, params);
    return appRemoteResults[method].parse(result) as z.infer<(typeof appRemoteResults)[Method]>;
  }

  get active(): boolean {
    return !this.closedError && this.socket.readyState === OPEN;
  }

  async unsubscribe(): Promise<void> {
    if (!this.subscriptionId || !this.active) return;
    const id = this.subscriptionId;
    this.subscriptionId = null;
    try {
      const result = await this.request("axo.host.unsubscribe", { subscriptionId: id });
      hostUnsubscribeResultSchema.parse(result);
    } catch {
      // Closing the socket also releases the subscription; no command is replayed.
    }
  }

  close(): void {
    if (!this.closedError) this.closedError = new Error("Axo API WebSocket is closed");
    this.rejectPending(this.closedError);
    if (this.socket.readyState === OPEN) this.socket.close(1000, "Client closed");
  }

  private waitUntilOpen(): Promise<void> {
    if (this.socket.readyState === OPEN) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.socket.close(1000, "Connection timeout");
        reject(new Error("Axo API WebSocket connection timed out"));
      }, DEFAULT_TIMEOUT_MS);
      const previousOpen = this.socket.onopen;
      this.socket.onopen = (event) => {
        clearTimeout(timeout);
        previousOpen?.(event);
        resolve();
      };
      const previousError = this.socket.onerror;
      this.socket.onerror = (event) => {
        clearTimeout(timeout);
        previousError?.(event);
        reject(new Error("Could not connect to the Axo API; check API Access"));
      };
      const previousClose = this.socket.onclose;
      this.socket.onclose = (event) => {
        clearTimeout(timeout);
        previousClose?.(event);
        reject(new Error(event.reason || "Axo API WebSocket closed before connecting"));
      };
    });
  }

  private request(method: string, params: unknown): Promise<unknown> {
    if (!this.active) return Promise.reject(this.closedError ?? new Error("Axo API WebSocket is not open"));
    if (this.pending.size >= 32) return Promise.reject(new Error("Too many Axo API requests are pending"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Axo API request timed out: ${method}`));
      }, DEFAULT_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timeout });
      try {
        this.socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error("Could not send Axo API request"));
      }
    });
  }

  private receive(raw: unknown): void {
    if (typeof raw !== "string") {
      this.fail(new Error("Axo API sent a non-text message"));
      this.socket.close(1003, "Text required");
      return;
    }
    let value: unknown;
    try {
      value = JSON.parse(raw);
    } catch {
      this.fail(new Error("Axo API sent invalid JSON"));
      this.socket.close(1002, "Invalid JSON");
      return;
    }

    try {
      const notification = hostNotificationSchema.safeParse(value);
      if (notification.success) {
        const { subscriptionId, event } = notification.data.params;
        if (
          event.hostId === this.reference.hostId &&
          event.hostGeneration === this.reference.hostGeneration &&
          (!this.subscriptionId || subscriptionId === this.subscriptionId)
        ) {
          this.onEvent(event);
        }
      } else {
        const response = replySchema.safeParse(value);
        if (response.success && response.data.id !== null) {
          const pending = this.pending.get(response.data.id as number);
          if (pending) {
            clearTimeout(pending.timeout);
            this.pending.delete(response.data.id as number);
            if ("error" in response.data) {
              pending.reject(new AxoRpcError(response.data.error.message, response.data.error.code));
            } else {
              pending.resolve(response.data.result);
            }
          }
        }
      }
    } finally {
      // The relay applies bounded delivery credits to replies and event notifications alike.
      if (this.socket.readyState === OPEN) {
        this.socket.send(JSON.stringify({
          jsonrpc: "2.0",
          method: "axo.transport.ack",
          params: { frames: 1 },
        }));
      }
    }
  }

  private fail(error: Error): void {
    if (this.closedError) return;
    this.closedError = error;
    this.rejectPending(error);
    this.onClose?.(error);
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
