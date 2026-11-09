import {
  CLIENT_METHODS,
  ELICITATION_METHODS,
  FRAGMENT_METHOD,
  clientElicitationRequestedParamsSchema,
  clientElicitationResolvedParamsSchema,
  elicitationResolveResultSchema,
  MemoryPartialStore,
  CLIENT_PROTOCOL,
  clientHelloResultSchema,
  clientHostHelloResultSchema,
  clientHostRenameResultSchema,
  clientLabelParamsSchema,
  clientPresenceParamsSchema,
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
  type ClientPresence,
  type ClientRecord,
  type ClientSession,
  type Elicitation,
  type ElicitationAnswer,
  type Sealed,
  type ElicitationResolved,
  type ProgressSnapshot,
  type SessionMetadata,
  type SessionStatus,
} from "@axo/protocol";
import {
  hostRefSchema,
  type hostV1Results,
  remoteSessionCreateResultSchema,
  remoteSessionCloseResultSchema,
  remoteWorkspaceListResultSchema,
  remoteLayoutSetResultSchema,
  remoteShellCreateResultSchema,
  remoteShellCloseResultSchema,
  remoteTerminalInputResultSchema,
  remotePromptResultSchema,
  remoteStopResultSchema,
  remoteRestartResultSchema,
  remoteCommandsResultSchema,
  remoteModelsResultSchema,
  remoteTerminalResizeResultSchema,
  type HostMethodParams,
} from "@axo/protocol/v1";
import { z } from "zod";
import type { DeviceProof } from "@axo/protocol";

/**
 * The account's client (RFD0018, RFD0032). It lists every host and Session of the account, keeps
 * them current, serves the records of the Sessions the app opens (acknowledging each batch once
 * it is handled, which is what lets the next one come), and carries commands to hosts. In
 * protocol 2 that is one WebSocket to the ClientDO at `/api/v1/account/client`; in protocol 3
 * that socket lists the hosts, and a socket on each host's HostDO carries the rest.
 */

export type HostRef = z.infer<typeof hostRefSchema>;
export type { Elicitation, ElicitationAnswer, ElicitationResolved };
export { answerMessage, devicePublicKey, keyFingerprint, newDeviceKey, sealInput, signAnswer } from "./seal.ts";
export type { DeviceProof } from "@axo/protocol";
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
  /** A Mac asks the person (RFD0029): show it until it is resolved. Sent again after each hello. */
  elicitationRequested?(hostId: string, elicitation: Elicitation): void;
  /** It was answered, here or elsewhere, or nobody answered in time: dismiss it. */
  elicitationResolved?(hostId: string, resolved: ElicitationResolved): void;
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
  "axo.remote.session.stop": remoteStopResultSchema,
  "axo.remote.session.restart": remoteRestartResultSchema,
  "axo.remote.session.commands": remoteCommandsResultSchema,
  "axo.remote.session.models": remoteModelsResultSchema,
  "axo.remote.session.model.set": remoteLayoutSetResultSchema,
  "axo.remote.terminal.resize": remoteTerminalResizeResultSchema,
  // Every remote method the protocol has must be here: `command` parses its result by method.
} as const satisfies Record<Extract<keyof typeof hostV1Results, `axo.remote.${string}`>, z.ZodType>;
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

export interface RemoteAxoApiOptions {
  /**
   * The protocol to speak (RFD0032). 3 opens a socket on each host's HostDO, and falls back to 2
   * for that connection when the cloud doesn't serve it yet. 2 carries everything on the
   * account socket.
   */
  protocol?: 2 | 3;
}

export class RemoteAxoApi {
  readonly baseUrl: URL;
  readonly protocol: 2 | 3;

  private readonly makeWebSocket: WebSocketFactory;

  constructor(baseUrl: string | URL, makeWebSocket: WebSocketFactory = (url) => new WebSocket(url), options: RemoteAxoApiOptions = {}) {
    this.makeWebSocket = makeWebSocket;
    this.protocol = options.protocol ?? CLIENT_PROTOCOL.direct;
    this.baseUrl = new URL(baseUrl);
    if (this.baseUrl.protocol !== "https:" && this.baseUrl.protocol !== "http:") {
      throw new TypeError("Axo API URL must use HTTP or HTTPS");
    }
    this.baseUrl.pathname = this.baseUrl.pathname.replace(/\/$/, "");
    this.baseUrl.search = "";
    this.baseUrl.hash = "";
  }

  /**
   * Opens the account's socket as `clientId` (one per tab or app instance) and says hello. In
   * protocol 3 it also opens a socket on each host, and resolves once every host's index is in.
   */
  async connect(clientId: string, events: AccountEvents): Promise<AccountConnection> {
    if (this.protocol === CLIENT_PROTOCOL.direct) {
      try {
        return await AccountConnection.openDirect(this.socketTo("/api/v1/account/client", clientId), clientId, events,
          (hostId) => this.socketTo(`/api/v1/account/hosts/${encodeURIComponent(hostId)}/client`, clientId));
      } catch (error) {
        if (!(error instanceof ProtocolRefused)) throw error;
      }
    }
    return AccountConnection.open(this.socketTo("/api/v1/account/client", clientId), clientId, events);
  }

  private socketTo(path: string, clientId: string): WebSocketLike {
    const url = new URL(`${this.baseUrl.pathname.replace(/\/$/, "")}${path}`, this.baseUrl);
    url.searchParams.set("clientId", clientId);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    return this.makeWebSocket(url.href);
  }
}

/** Protocol 3 isn't served for this connection: the caller connects again with protocol 2. */
class ProtocolRefused extends Error {
  constructor(reason: string) {
    super(`Protocol 3 refused: ${reason}`);
    this.name = "ProtocolRefused";
  }
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: ReturnType<typeof setTimeout>;
};

/**
 * One JSON-RPC socket: requests with their replies, notifications, and messages larger than a
 * frame. Notifications go to `onNotification`; the first failure goes to `onClosed`, once.
 */
class Channel {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly partials = new MemoryPartialStore();
  private closedError: Error | null = null;
  onNotification: (method: string, params: unknown) => void = () => {};
  onClosed: (error: Error) => void = () => {};

  private readonly socket: WebSocketLike;

  constructor(socket: WebSocketLike) {
    this.socket = socket;
    socket.onmessage = (event) => this.receive(event.data);
    socket.onerror = () => this.fail(new Error("Axo API WebSocket failed"));
    socket.onclose = (event) => this.fail(new Error(event.reason || `WebSocket closed (${event.code})`));
  }

  get active(): boolean {
    return !this.closedError && this.socket.readyState === OPEN;
  }

  waitUntilOpen(): Promise<void> {
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

  request(method: string, params: unknown): Promise<unknown> {
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

  notify(method: string, params: unknown): void {
    if (!this.active) return;
    try {
      this.write({ jsonrpc: "2.0", method, params });
    } catch {
      // The socket is ending; its close says so.
    }
  }

  close(): void {
    if (!this.closedError) this.closedError = new Error("Axo API WebSocket is closed");
    this.rejectPending(this.closedError);
    this.partials.clear();
    if (this.socket.readyState === OPEN) this.socket.close(1000, "Client closed");
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
    if (notification.success) return this.onNotification(notification.data.method, notification.data.params);
    const response = replySchema.safeParse(value);
    if (!response.success || typeof response.data.id !== "number") return;
    const pending = this.pending.get(response.data.id);
    if (!pending) return;
    clearTimeout(pending.timeout);
    this.pending.delete(response.data.id);
    if ("error" in response.data) pending.reject(new AxoRpcError(response.data.error.message, response.data.error.code));
    else pending.resolve(response.data.result);
  }

  private fail(error: Error): void {
    if (this.closedError) return;
    this.closedError = error;
    this.rejectPending(error);
    this.partials.clear();
    this.onClosed(error);
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

/** A host's socket in protocol 3: its index and presence as last heard. */
type HostLink = {
  channel: Channel;
  presence: ClientPresence;
  sessions: Map<string, ClientSession>;
};

/** Each connection a client makes is numbered above the last, across instances (RFD0032, newerConnectionWins). */
let lastConnection = 0;
function nextConnection(): number {
  lastConnection = Math.max(lastConnection + 1, Date.now() * 1000);
  return lastConnection;
}

/**
 * The account's connection. In protocol 2 one socket, to the ClientDO, carries everything. In
 * protocol 3 (RFD0032) that socket lists the hosts, and a socket on each host's HostDO carries
 * its index, records, progress, what it asks, and commands; this class routes by host, and
 * merges each host's presence into the host list. Either way the app sees the same calls and
 * events, and any socket that closes closes the connection.
 */
export class AccountConnection {
  hello!: ClientHello;

  private readonly account: Channel;
  private readonly events: AccountEvents;
  private readonly links = new Map<string, HostLink>();
  /** Which host each open Session is on, in protocol 3. */
  private readonly opened = new Map<string, string>();
  /** The account's host list as it last said, before presence is merged in. */
  private accountHosts: ClientHost[] = [];
  private direct = false;
  private connection = 0;
  private openHost: ((hostId: string) => WebSocketLike) | null = null;
  private closed = false;

  private constructor(socket: WebSocketLike, events: AccountEvents) {
    this.account = new Channel(socket);
    this.events = events;
    this.account.onNotification = (method, params) => this.handle(method, params, null);
    this.account.onClosed = (error) => this.fail(error);
  }

  /** Protocol 2: the account socket carries everything. */
  static async open(socket: WebSocketLike, clientId: string, events: AccountEvents): Promise<AccountConnection> {
    const connection = new AccountConnection(socket, events);
    try {
      await connection.account.waitUntilOpen();
      const hello = await connection.account.request(CLIENT_METHODS.hello, { protocolVersion: CLIENT_PROTOCOL.relayed, clientId });
      connection.hello = clientHelloResultSchema.parse(hello);
      return connection;
    } catch (error) {
      connection.close();
      throw error;
    }
  }

  /**
   * Protocol 3. Throws `ProtocolRefused` when the account socket refuses hello 3 (older code) or
   * a host socket fails before its index arrives: the caller connects again with protocol 2.
   */
  static async openDirect(socket: WebSocketLike, clientId: string, events: AccountEvents, openHost: (hostId: string) => WebSocketLike): Promise<AccountConnection> {
    const connection = new AccountConnection(socket, events);
    connection.direct = true;
    connection.connection = nextConnection();
    connection.openHost = openHost;
    try {
      await connection.account.waitUntilOpen();
      const hello = await connection.account.request(CLIENT_METHODS.hello, { protocolVersion: CLIENT_PROTOCOL.direct, clientId })
        .catch((error: unknown) => {
          throw error instanceof AxoRpcError && error.code === -32602 ? new ProtocolRefused("the account socket speaks protocol 2") : error;
        });
      connection.accountHosts = clientHelloResultSchema.parse(hello).hosts;
      await Promise.all(connection.accountHosts.map((host) => connection.link(host.hostId, clientId)));
      connection.hello = connection.listing();
      for (const [hostId, elicitation] of connection.askedAtHello) events.elicitationRequested?.(hostId, elicitation);
      connection.askedAtHello = [];
      return connection;
    } catch (error) {
      connection.close();
      throw error;
    }
  }

  /** What hosts asked while their index came in, sent once the listing has gone, as protocol 2 does. */
  private askedAtHello: Array<[string, Elicitation]> = [];
  private clientId = "";

  get active(): boolean {
    return !this.closed && this.account.active && [...this.links.values()].every((link) => link.channel.active);
  }

  /** Lists the account's hosts and Sessions again now: for a host paired a moment ago. */
  async refresh(): Promise<ClientHello> {
    const listing = clientHelloResultSchema.parse(await this.account.request(CLIENT_METHODS.refresh, {}));
    if (!this.direct) return listing;
    this.accountHosts = listing.hosts;
    await this.follow();
    return this.listing();
  }

  /** Names a Mac of the account; an empty name goes back to what the Mac reports. Returns the name shown. */
  async renameHost(hostId: string, name: string): Promise<string> {
    return clientHostRenameResultSchema.parse(await this.account.request(CLIENT_METHODS.renameHost, { hostId, name })).label;
  }

  /** Opens a Session: the records after `have`, or its last `window`. Newer records follow as `records` events. */
  async open(request: OpenRequest): Promise<ClientOpenResult> {
    if (this.direct) this.opened.set(request.sessionId, request.hostId);
    return clientOpenResultSchema.parse(await this.channelOf(request.hostId).request(CLIENT_METHODS.open, request));
  }

  /** Records just before `before`, oldest first. */
  async older(sessionId: string, before: number, limit: number): Promise<OlderPage> {
    return clientOlderResultSchema.parse(await this.channelOfSession(sessionId).request(CLIENT_METHODS.older, { sessionId, before, limit }));
  }

  /** Stops following a Session's records. */
  closeSession(sessionId: string): void {
    const channel = this.direct ? this.links.get(this.opened.get(sessionId) ?? "")?.channel : this.account;
    this.opened.delete(sessionId);
    channel?.notify(CLIENT_METHODS.close, { sessionId });
  }

  /** Runs a command on a host; it fails at once when the host is offline, and nothing is queued. */
  async command<Method extends AppRemoteMethod>(method: Method, params: HostMethodParams<Method>): Promise<AppRemoteResult<Method>> {
    const target = hostRefSchema.parse((params as { target: unknown }).target);
    const result = await this.channelOf(target.hostId).request(CLIENT_METHODS.command, { hostId: target.hostId, method, params });
    return appRemoteResults[method].parse(result) as AppRemoteResult<Method>;
  }

  /**
   * Answers what a Mac asks (RFD0029). The Mac takes the first answer; a later one fails with
   * `ELICITATION_ERRORS.notPending`.
   */
  async resolveElicitation(hostId: string, elicitationId: string, action: ElicitationAnswer, device: DeviceProof, sealed?: Sealed): Promise<void> {
    elicitationResolveResultSchema.parse(await this.channelOf(hostId).request(ELICITATION_METHODS.resolve, { hostId, elicitationId, action, device, ...(sealed ? { sealed } : {}) }));
  }

  close(): void {
    this.closed = true;
    this.account.close();
    for (const link of this.links.values()) link.channel.close();
  }

  // ─── Protocol 3 ────────────────────────────────────────────────────────────

  /** Opens a host's socket and says hello; resolves with its index in. */
  private async link(hostId: string, clientId = this.clientId): Promise<void> {
    this.clientId = clientId;
    const channel = new Channel(this.openHost!(hostId));
    const link: HostLink = { channel, presence: { online: false, hostGeneration: null }, sessions: new Map() };
    this.links.set(hostId, link);
    let ready = false;
    channel.onNotification = (method, params) => this.handle(method, params, hostId);
    channel.onClosed = (error) => {
      if (ready) this.fail(error);
    };
    try {
      await channel.waitUntilOpen();
      const hello = clientHostHelloResultSchema.parse(await channel.request(CLIENT_METHODS.hello, { protocolVersion: CLIENT_PROTOCOL.direct, clientId, connection: this.connection }));
      link.presence = { online: hello.online, hostGeneration: hello.hostGeneration };
      for (const session of hello.sessions) link.sessions.set(session.sessionId, session);
      ready = true;
    } catch (error) {
      this.links.delete(hostId);
      channel.close();
      // At connect, a host that doesn't serve protocol 3 sends the whole connection back to 2.
      if (this.hello) throw error;
      throw new ProtocolRefused(`host ${hostId}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  /**
   * The account's hosts changed: links to new ones, lets go of removed ones. A new host whose
   * socket fails closes the connection, so the app connects again, as after any lost socket.
   */
  private async follow(): Promise<void> {
    const listed = new Set(this.accountHosts.map((host) => host.hostId));
    for (const [hostId, link] of this.links) {
      if (listed.has(hostId)) continue;
      this.links.delete(hostId);
      link.channel.close();
    }
    try {
      await Promise.all([...listed].filter((hostId) => !this.links.has(hostId)).map((hostId) => this.link(hostId)));
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error));
      this.fail(failure);
      throw failure;
    }
  }

  /** Hosts with each link's presence, and every link's Sessions. */
  private listing(): ClientHello {
    return { hosts: this.hosts(), sessions: [...this.links.values()].flatMap((link) => [...link.sessions.values()]) };
  }

  private hosts(): ClientHost[] {
    return this.accountHosts.map((host) => {
      const presence = this.links.get(host.hostId)?.presence;
      return presence ? { ...host, online: presence.online, hostGeneration: presence.hostGeneration ?? host.hostGeneration } : host;
    });
  }

  private channelOf(hostId: string): Channel {
    if (!this.direct) return this.account;
    const link = this.links.get(hostId);
    // Nothing went anywhere: the ClientDO's answer for a host it can't reach. Not -32602, which
    // the app reads as a Mac too old for the fields it sent.
    if (!link) throw new AxoRpcError("Host offline; nothing queued", -32005);
    return link.channel;
  }

  private channelOfSession(sessionId: string): Channel {
    return this.direct ? this.channelOf(this.opened.get(sessionId) ?? "") : this.account;
  }

  // ─── Events ────────────────────────────────────────────────────────────────

  /** A notification from the account socket (`hostId` null) or a host's. */
  private handle(method: string, params: unknown, hostId: string | null): void {
    const link = hostId === null ? undefined : this.links.get(hostId);
    const channel = link?.channel ?? this.account;
    switch (method) {
      case CLIENT_METHODS.hosts: {
        const parsed = clientHostsParamsSchema.safeParse(params);
        if (!parsed.success) return;
        if (!this.direct) return this.events.hosts?.(parsed.data.hosts);
        if (hostId !== null) return;
        this.accountHosts = parsed.data.hosts;
        void this.follow().then(() => this.events.hosts?.(this.hosts()), () => undefined);
        return;
      }
      case CLIENT_METHODS.presence: {
        const parsed = clientPresenceParamsSchema.safeParse(params);
        if (!parsed.success || !link) return;
        link.presence = parsed.data;
        this.events.hosts?.(this.hosts());
        return;
      }
      case CLIENT_METHODS.label: {
        const parsed = clientLabelParamsSchema.safeParse(params);
        if (!parsed.success || hostId === null) return;
        this.accountHosts = this.accountHosts.map((host) => (host.hostId === hostId ? { ...host, label: parsed.data.label } : host));
        this.events.hosts?.(this.hosts());
        return;
      }
      case CLIENT_METHODS.sessions: {
        const parsed = clientSessionsParamsSchema.safeParse(params);
        if (!parsed.success) return;
        for (const session of parsed.data.sessions) link?.sessions.set(session.sessionId, session);
        this.events.sessions?.(parsed.data.hostId, parsed.data.sessions);
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
          channel.notify(CLIENT_METHODS.ack, { sessionId, cursor });
        }
        return;
      }
      case CLIENT_METHODS.progress: {
        const parsed = clientProgressParamsSchema.safeParse(params);
        if (parsed.success) this.events.progress?.(parsed.data.sessionId, parsed.data.slot, parsed.data.snapshot ?? null);
        return;
      }
      case ELICITATION_METHODS.requested: {
        const parsed = clientElicitationRequestedParamsSchema.safeParse(params);
        if (!parsed.success) return;
        // While the hosts' indexes come in, what they ask waits for the listing, as in protocol 2.
        if (this.direct && !this.hello) this.askedAtHello.push([parsed.data.hostId, parsed.data.elicitation]);
        else this.events.elicitationRequested?.(parsed.data.hostId, parsed.data.elicitation);
        return;
      }
      case ELICITATION_METHODS.resolved: {
        const parsed = clientElicitationResolvedParamsSchema.safeParse(params);
        if (parsed.success) {
          const { hostId: from, ...resolved } = parsed.data;
          this.askedAtHello = this.askedAtHello.filter(([, elicitation]) => elicitation.id !== resolved.id);
          this.events.elicitationResolved?.(from, resolved);
        }
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
    if (this.closed) return;
    this.closed = true;
    this.account.close();
    for (const link of this.links.values()) link.channel.close();
    this.events.closed?.(error);
  }
}
