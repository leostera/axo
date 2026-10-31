import {
  CLIENT_METHODS,
  FRAGMENT_METHOD,
  MemoryPartialStore,
  clientHelloResultSchema,
  clientHostsParamsSchema,
  clientOlderResultSchema,
  clientOpenResultSchema,
  clientProgressParamsSchema,
  clientRecordsParamsSchema,
  clientResetParamsSchema,
  clientSessionsParamsSchema,
  receiveFragment,
  splitMessage,
  type ClientHello,
  type ClientHost,
  type ClientOpenResult,
  type ClientRecord,
  type ClientSession,
  type ProgressSnapshot,
  type SessionMetadata,
  type SessionStatus,
} from "@axo/protocol";
import {
  hostRefSchema,
  remoteSessionCreateResultSchema,
  remoteSessionCloseResultSchema,
  remoteWorkspaceListResultSchema,
  remoteLayoutSetResultSchema,
  remoteShellCreateResultSchema,
  remoteShellCloseResultSchema,
  remoteTerminalInputResultSchema,
  remotePromptResultSchema,
  remoteTerminalResizeResultSchema,
  type HostMethodParams,
} from "@axo/protocol/v1";
import { z } from "zod";

/**
 * The account's client (RFD0018): one WebSocket to the ClientDO at `/api/v1/account/client`. It
 * lists every host and Session of the account, keeps them current, serves the records of the
 * Sessions the app opens (acknowledging each batch once it is handled, which is what lets the
 * next one come), and carries commands to hosts.
 */

export type HostRef = z.infer<typeof hostRefSchema>;
export type { ClientHello, ClientHost, ClientOpenResult, ClientRecord, ClientSession, ProgressSnapshot, SessionMetadata, SessionStatus };

export class AxoApiError extends Error {
  readonly status: number;
  readonly url: string;

  constructor(message: string, status: number, url: string) {
    super(message);
    this.status = status;
    this.url = url;
    this.name = "AxoApiError";
  }
}

export class AxoRpcError extends Error {
  readonly code: number;

  constructor(message: string, code: number) {
    super(message);
    this.code = code;
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

/** What the account's socket tells the app as it happens. */
export interface AccountEvents {
  /** The whole host list, whenever any host's presence changes. */
  hosts?(hosts: ClientHost[]): void;
  /** Sessions of one host that changed: listed, renamed, moved on, archived. */
  sessions?(hostId: string, sessions: ClientSession[]): void;
  /** The next records of an open Session, after `cursor - records.length`. */
  records?(sessionId: string, epoch: number, records: ClientRecord[]): void;
  /** A progress slot's newest snapshot, or null when it is cleared. */
  progress?(sessionId: string, slot: string, snapshot: unknown): void;
  /** The cloud copy was cut back: drop every record after `keep`; `epoch` follows. */
  reset?(sessionId: string, epoch: number, keep: number): void;
  /** The socket ended; open again to go on. */
  closed?(error: Error): void;
}

export interface OpenRequest {
  hostId: string;
  sessionId: string;
  /** What the app already holds: only the records after it come. */
  have?: { epoch: number; cursor: number };
  /** Without `have`: the last this many records. */
  window?: { last: number };
}

export interface OlderPage {
  epoch: number | null;
  records: ClientRecord[];
  /** The `before` of the next older page, or null at the start. */
  older: number | null;
}

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
  "axo.remote.workspace.list": remoteWorkspaceListResultSchema,
  "axo.remote.session.close": remoteSessionCloseResultSchema,
  "axo.remote.session.rename": remoteLayoutSetResultSchema,
  "axo.remote.session.layout.set": remoteLayoutSetResultSchema,
  "axo.remote.shell.create": remoteShellCreateResultSchema,
  "axo.remote.shell.close": remoteShellCloseResultSchema,
  "axo.remote.terminal.input": remoteTerminalInputResultSchema,
  "axo.remote.session.prompt": remotePromptResultSchema,
  "axo.remote.session.key": remotePromptResultSchema,
  "axo.remote.terminal.resize": remoteTerminalResizeResultSchema,
} as const;
export type AppRemoteMethod = keyof typeof appRemoteResults;
export type AppRemoteResult<Method extends AppRemoteMethod> = z.infer<(typeof appRemoteResults)[Method]>;

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
const notificationSchema = z.object({ jsonrpc: z.literal("2.0"), method: z.string(), params: z.unknown() }).strict();

export class RemoteAxoApi {
  readonly baseUrl: URL;

  private readonly makeWebSocket: WebSocketFactory;

  constructor(baseUrl: string | URL, makeWebSocket: WebSocketFactory = (url) => new WebSocket(url)) {
    this.makeWebSocket = makeWebSocket;
    this.baseUrl = new URL(baseUrl);
    if (this.baseUrl.protocol !== "https:" && this.baseUrl.protocol !== "http:") {
      throw new TypeError("Axo API URL must use HTTP or HTTPS");
    }
    this.baseUrl.pathname = this.baseUrl.pathname.replace(/\/$/, "");
    this.baseUrl.search = "";
    this.baseUrl.hash = "";
  }

  /** Opens the account's socket as `clientId` (one per tab or app instance) and says hello. */
  connect(clientId: string, events: AccountEvents): Promise<AccountConnection> {
    const url = new URL(`${this.baseUrl.pathname.replace(/\/$/, "")}/api/v1/account/client`, this.baseUrl);
    url.searchParams.set("clientId", clientId);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return AccountConnection.open(this.makeWebSocket(url.href), clientId, events);
  }
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

export class AccountConnection {
  hello!: ClientHello;

  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly partials = new MemoryPartialStore();
  private closedError: Error | null = null;

  private readonly socket: WebSocketLike;
  private readonly events: AccountEvents;

  private constructor(socket: WebSocketLike, events: AccountEvents) {
    this.socket = socket;
    this.events = events;
    socket.onmessage = (event) => this.receive(event.data);
    socket.onerror = () => this.fail(new Error("Axo API WebSocket failed"));
    socket.onclose = (event) => this.fail(new Error(event.reason || `WebSocket closed (${event.code})`));
  }

  static async open(socket: WebSocketLike, clientId: string, events: AccountEvents): Promise<AccountConnection> {
    const connection = new AccountConnection(socket, events);
    try {
      await connection.waitUntilOpen();
      const hello = await connection.request(CLIENT_METHODS.hello, { protocolVersion: 2, clientId });
      connection.hello = clientHelloResultSchema.parse(hello);
      return connection;
    } catch (error) {
      connection.close();
      throw error;
    }
  }

  get active(): boolean {
    return !this.closedError && this.socket.readyState === OPEN;
  }

  /** Lists the account's hosts and Sessions again now: for a host paired a moment ago. */
  async refresh(): Promise<ClientHello> {
    return clientHelloResultSchema.parse(await this.request(CLIENT_METHODS.refresh, {}));
  }

  /** Opens a Session: the records after `have`, or its last `window`. Newer records follow as `records` events. */
  async open(request: OpenRequest): Promise<ClientOpenResult> {
    return clientOpenResultSchema.parse(await this.request(CLIENT_METHODS.open, request));
  }

  /** Records just before `before`, oldest first. */
  async older(sessionId: string, before: number, limit: number): Promise<OlderPage> {
    return clientOlderResultSchema.parse(await this.request(CLIENT_METHODS.older, { sessionId, before, limit }));
  }

  /** Stops following a Session's records. */
  closeSession(sessionId: string): void {
    this.notify(CLIENT_METHODS.close, { sessionId });
  }

  /** Runs a command on a host; it fails at once when the host is offline, and nothing is queued. */
  async command<Method extends AppRemoteMethod>(method: Method, params: HostMethodParams<Method>): Promise<AppRemoteResult<Method>> {
    const target = hostRefSchema.parse((params as { target: unknown }).target);
    const result = await this.request(CLIENT_METHODS.command, { hostId: target.hostId, method, params });
    return appRemoteResults[method].parse(result) as AppRemoteResult<Method>;
  }

  close(): void {
    if (!this.closedError) this.closedError = new Error("Axo API WebSocket is closed");
    this.rejectPending(this.closedError);
    this.partials.clear();
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
        reject(new Error("Could not connect to the Axo API; check your sign-in"));
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
        this.write({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error("Could not send Axo API request"));
      }
    });
  }

  private notify(method: string, params: unknown): void {
    if (!this.active) return;
    try {
      this.write({ jsonrpc: "2.0", method, params });
    } catch {
      // The socket is ending; its close says so.
    }
  }

  private write(message: unknown): void {
    const frames = splitMessage(JSON.stringify(message), crypto.randomUUID().replaceAll("-", ""));
    if (!frames) throw new Error("The message is too large to send");
    for (const frame of frames) this.socket.send(frame);
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
    const notification = notificationSchema.safeParse(value);
    if (notification.success && notification.data.method === FRAGMENT_METHOD) {
      const outcome = receiveFragment(this.partials, notification.data.params);
      if (outcome.status === "invalid") {
        this.fail(new Error(`Axo API sent an invalid fragment: ${outcome.reason}`));
        this.socket.close(1008, "Invalid fragment");
      } else if (outcome.status === "complete") {
        this.receive(outcome.raw);
      }
      return;
    }
    if (notification.success) return this.handle(notification.data.method, notification.data.params);
    const response = replySchema.safeParse(value);
    if (!response.success || typeof response.data.id !== "number") return;
    const pending = this.pending.get(response.data.id);
    if (!pending) return;
    clearTimeout(pending.timeout);
    this.pending.delete(response.data.id);
    if ("error" in response.data) pending.reject(new AxoRpcError(response.data.error.message, response.data.error.code));
    else pending.resolve(response.data.result);
  }

  private handle(method: string, params: unknown): void {
    switch (method) {
      case CLIENT_METHODS.hosts: {
        const parsed = clientHostsParamsSchema.safeParse(params);
        if (parsed.success) this.events.hosts?.(parsed.data.hosts);
        return;
      }
      case CLIENT_METHODS.sessions: {
        const parsed = clientSessionsParamsSchema.safeParse(params);
        if (parsed.success) this.events.sessions?.(parsed.data.hostId, parsed.data.sessions);
        return;
      }
      case CLIENT_METHODS.records: {
        const parsed = clientRecordsParamsSchema.safeParse(params);
        if (!parsed.success) return;
        const { sessionId, epoch, records, cursor } = parsed.data;
        try {
          this.events.records?.(sessionId, epoch, records);
        } finally {
          // The acknowledgement is what lets the next batch come.
          this.notify(CLIENT_METHODS.ack, { sessionId, cursor });
        }
        return;
      }
      case CLIENT_METHODS.progress: {
        const parsed = clientProgressParamsSchema.safeParse(params);
        if (parsed.success) this.events.progress?.(parsed.data.sessionId, parsed.data.slot, parsed.data.snapshot ?? null);
        return;
      }
      case CLIENT_METHODS.reset: {
        const parsed = clientResetParamsSchema.safeParse(params);
        if (parsed.success) this.events.reset?.(parsed.data.sessionId, parsed.data.epoch, parsed.data.keep);
        return;
      }
    }
  }

  private fail(error: Error): void {
    if (this.closedError) return;
    this.closedError = error;
    this.rejectPending(error);
    this.partials.clear();
    this.events.closed?.(error);
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
