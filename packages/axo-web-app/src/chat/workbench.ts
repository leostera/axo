import { ConversationFeed } from "./feed.ts";
import { ChatCache, type ChatSnapshot } from "./cache.ts";
import type {
  AccountEvents,
  ClientHello,
  ClientHost,
  ClientOpenResult,
  ClientSession,
  Elicitation,
  ElicitationAnswer,
  HostRef,
  OlderPage,
  OpenRequest,
  SessionStatus,
} from "@axo/app";
import { sealInput, type DeviceProof } from "@axo/app";
import { ASSET_LIMITS, ELICITATION_ERRORS, assetTypeOf, type Attachment, type HostModel, type PiCommand, type PiModel, type PiRuntime, type Sealed, type ThinkingLevel } from "@axo/protocol";
import { safeFileName, type UploadAsset } from "./assets.ts";

/** The coding agents a chat can run, as a Mac names them (RFD0072). */
export type CodingAgent = "pi" | "codex" | "opencode" | "claude-code";
export const CODING_AGENTS: readonly { agent: CodingAgent; label: string }[] = [
  { agent: "pi", label: "Pi" },
  { agent: "codex", label: "Codex" },
  { agent: "opencode", label: "OpenCode" },
  { agent: "claude-code", label: "Claude Code" },
];
import { ChatTranscript, type Delivery, type TranscriptRecord } from "./transcript.ts";

/**
 * The browser's chats: a port of the phone's `PhoneWorkbench` and `HostWorkbenchModel`, on the
 * account's one socket (RFD0018). Every Mac and every chat is listed and kept current; the chat
 * on screen is open, so its new records arrive as they are written. A chat is a Session with an
 * agent in it; a new chat exists only once its first message is sent. History is read newest
 * first, a page at a time, and only as far back as the person scrolls.
 */

/** A chat as the menu and the conversation show it. */
export interface Session {
  readonly hostId: string;
  readonly sessionId: string;
  readonly name: string | null;
  readonly emoji: string | null;
  /** The last component of its folder on the Mac; never the path (RFD0038). */
  readonly folderName: string | null;
  readonly hasAgent: boolean;
  /** Unix seconds. */
  readonly createdAt: number | null;
  /** Unix seconds of the latest completed message. */
  readonly lastMessageAt: number | null;
  readonly archived: boolean;
  readonly status: SessionStatus | null;
  /** The model and thinking level its Pi runs, once Pi has said (RFD0033). */
  readonly pi?: PiRuntime;
}

/** A linked computer of the account, with its chats. */
export interface Host {
  readonly hostId: string;
  readonly hostGeneration: string;
  readonly label: string;
  readonly hostKind: string;
  /** Hardware model, when the host reports one. */
  readonly model?: HostModel;
  readonly status: "online" | "offline";
  readonly lastSeenAt: string;
  readonly sessions: Session[];
}

type CreatedSession = {
  sessionId: string;
  name?: string;
  emoji?: string | null;
  folderName?: string | null;
  createdAt?: number;
};

/** What the workbench needs of the account's socket (`AccountConnection`). */
export interface AccountLink {
  readonly hello: ClientHello;
  readonly active: boolean;
  refresh(): Promise<ClientHello>;
  renameHost(hostId: string, name: string): Promise<string>;
  open(request: OpenRequest): Promise<ClientOpenResult>;
  older(sessionId: string, before: number, limit: number): Promise<OlderPage>;
  closeSession(sessionId: string): void;
  resolveElicitation(hostId: string, elicitationId: string, action: ElicitationAnswer, device: DeviceProof | undefined, sealed?: Sealed): Promise<void>;
  command(method: "axo.remote.session.create", params: { target: HostRef; agent?: CodingAgent }): Promise<{ session: CreatedSession }>;
  command(method: "axo.remote.session.prompt", params: { target: HostRef; sessionId: string; text: string; commandId: string; attachments?: Attachment[]; delivery?: Delivery }): Promise<unknown>;
  command(method: "axo.remote.session.restart", params: { target: HostRef; sessionId: string }): Promise<unknown>;
  command(method: "axo.remote.session.commands", params: { target: HostRef; sessionId: string }): Promise<{ commands: PiCommand[] }>;
  command(method: "axo.remote.session.models", params: { target: HostRef; sessionId: string }): Promise<{ models: PiModel[] }>;
  command(method: "axo.remote.session.model.set", params: { target: HostRef; sessionId: string } & ModelChange): Promise<unknown>;
  command(method: "axo.remote.session.key", params: { target: HostRef; sessionId: string; key: "escape" | "enter" }): Promise<unknown>;
  command(method: "axo.remote.session.stop", params: { target: HostRef; sessionId: string; turnId?: string; seen?: string; commandIds?: string[] }): Promise<{ stopped: boolean }>;
  close(): void;
}

/** What the workbench needs of the account's API (`RemoteAxoApi`). */
export interface ChatBackend {
  connect(clientId: string, events: AccountEvents): Promise<AccountLink>;
}

/** This tab's client id: kept while the tab lives, and renewed when another tab took it. */
export interface ClientIdentity {
  current(): string;
  renew(): string;
}

export type Link = "connecting" | "connected" | "reconnecting" | "idle";

/** What a Mac's agent asks the person (RFD0029), until it is resolved. */
export interface AskedQuestion {
  readonly hostId: string;
  readonly elicitation: Elicitation;
  /** This tab sent an answer and waits to hear it was taken. */
  answering: ElicitationAnswer | null;
}

export type PendingState =
  /** On its way to the Mac. */
  | "sending"
  /** The Mac took it; the agent will record it shortly. */
  | "sent"
  /** Taken while the agent was busy: in the log, waiting for the reply to end or for its next step. */
  | "queued"
  /** The agent is still starting and could not take it yet: sent again, with its commandId, until it can. */
  | "waking"
  /** The Mac did not say whether it took it: it is sent again, with its commandId, until it does. */
  | "uncertain";

export interface PendingPrompt {
  /** Its commandId: the Mac takes it at most once, and its receipt in the log retires it. */
  readonly id: string;
  readonly text: string;
  /** Files already in the account's assets, fetched by the Mac before Pi gets the prompt (RFD0030). */
  readonly attachments: readonly Attachment[];
  /** Whether a busy agent takes it after its reply or at its next step. */
  readonly delivery: Delivery;
  state: PendingState;
}

/** A message the agent has not recorded yet, as the conversation shows it. */
export interface WaitingPrompt {
  /** Its commandId. */
  readonly id: string;
  readonly text: string;
  readonly files: readonly string[];
  readonly delivery: Delivery;
  readonly state: PendingState;
  /** Sent from this tab: it can be taken off the screen once its fate is unknown. */
  readonly mine: boolean;
}

/** A new model, thinking level, or both, for a Session's Pi. */
export type ModelChange = { model?: { provider: string; id: string }; thinkingLevel?: ThinkingLevel };

/** What a Session's Pi can run or switch to, as last read, while it is read, or why it could not be. */
export type Loadable<T> = { kind: "loading" } | { kind: "loaded"; items: T[] } | { kind: "failed"; message: string };

/** A file in the message box: uploading to the account, ready to send, or refused. */
export interface DraftAttachment {
  readonly id: string;
  readonly file: Blob;
  readonly name: string;
  readonly mimeType: string;
  readonly size: number;
  state: "uploading" | "ready" | "failed";
  uploaded: Attachment | null;
  error: string | null;
}

/** How long an uncertain message waits before it is sent again, and how often it is. */
export const RETRY_DELAY_MS = 3_000;
export const MAX_RETRIES = 40;
/** How long "Restarting…" shows when no listing ever shows the agent leave ready. */
export const RESTART_SETTLE_MS = 20_000;

export type HistoryState =
  | { kind: "none" }
  | { kind: "loading" }
  | { kind: "loaded"; records: number; hasOlder: boolean }
  | { kind: "loadingOlder"; records: number }
  | { kind: "failed"; message: string };

export class Chat {
  /** Cached records are a preview, replaced by a fresh socket snapshot before interaction. */
  cached = false;
  transcript: ChatTranscript | null = null;
  /** Its conversation's rows, kept while it is on screen (RFD0040). */
  readonly feed = new ConversationFeed();
  pending: PendingPrompt[] = [];
  history: HistoryState = { kind: "none" };
  stopping = false;
  humanTurnProtected = false;
  /** A restart was asked for and the agent is not ready again yet. */
  restarting = false;
  /** The restart has been seen to take the agent down (or start it); its next `ready` ends it. */
  restartLeftReady = false;
  /** The slash commands its Pi runs, read when the `/` list opens. */
  commands: Loadable<PiCommand> | null = null;
  /** The models its Pi can switch to, read when the model menu opens. */
  models: Loadable<PiModel> | null = null;
  /** The epoch the records held belong to. */
  epoch: number | null = null;
  /** The `before` of the next older page, or null when the start is held. */
  older: number | null = null;
  /** Only the newest open operation may install its snapshot. */
  openRequest: object | null = null;

  /**
   * The person's messages the agent has not recorded yet: the ones sent from here, then the ones the
   * log holds as queued (sent from another device, or before a reload), each once.
   */
  get waiting(): WaitingPrompt[] {
    const queued = this.transcript?.queued ?? [];
    const inLog = new Map(queued.map(prompt => [prompt.commandId, prompt]));
    const mine = new Set(this.pending.map(prompt => prompt.id));
    return [
      ...this.pending.map(prompt => {
        const logged = inLog.get(prompt.id);
        return {
          id: prompt.id, text: prompt.text, files: prompt.attachments.map(file => file.name), delivery: logged?.delivery ?? prompt.delivery,
          state: prompt.state === "sent" && logged ? "queued" as const : prompt.state,
          mine: true,
        };
      }),
      ...queued.filter(prompt => !mine.has(prompt.commandId)).map(prompt => ({
        id: prompt.commandId, text: prompt.text, files: prompt.files, delivery: prompt.delivery, state: "queued" as const, mine: false,
      })),
    ];
  }
}

/**
 * The open chat, or a new one waiting for its first message on the open Mac, in its home folder.
 */
export type Selection = { kind: "chat"; sessionId: string } | { kind: "new" };

export type SendOutcome =
  | { kind: "sent" }
  /** Nothing was sent; the words are back in the box and `failure` says why. */
  | { kind: "failed" }
  /** The connection dropped while sending: it may have arrived. Not sent again on its own. */
  | { kind: "uncertain" };

export type Answer = { kind: "yes" } | { kind: "no" } | { kind: "text"; text: string };

export interface ChatMenuEntry {
  readonly host: Host;
  readonly session: Session;
}

export const historyPageSize = 50;
const defaultReconnectDelays = [500, 1_000, 2_000, 5_000, 15_000];

export function isChat(session: Session): boolean {
  return session.hasAgent && !session.archived;
}

export function chatTitle(session: Session | null | undefined): string {
  return session ? session.name ?? "Session" : "New chat";
}

/**
 * When a chat was last active, in milliseconds: its latest completed message, or its creation for
 * a chat with none yet, as the Mac's recent list orders them. Activity is a finished message, not
 * streaming, so chats move when a turn produces something rather than on every token.
 */
export function lastActivity(session: Session): number {
  return Math.max(session.lastMessageAt ?? 0, session.createdAt ?? 0) * 1000;
}
const activity = lastActivity;

/** Last active first; among chats as recent, the newer one first. */
function moreRecent(a: ChatMenuEntry, b: ChatMenuEntry): number {
  return activity(b.session) - activity(a.session)
    || (b.session.createdAt ?? 0) - (a.session.createdAt ?? 0)
    || b.session.sessionId.localeCompare(a.session.sessionId)
    || a.host.hostId.localeCompare(b.host.hostId);
}

/** Every chat on every Mac, the most recently active first: the menu's recent list. */
export function recentChatList(hosts: readonly Host[]): ChatMenuEntry[] {
  return hosts.flatMap(host => host.sessions.filter(isChat).map(session => ({ host, session }))).sort(moreRecent);
}

/** A chat's key in the menu. */
export function chatKey(entry: ChatMenuEntry): string {
  return `${entry.host.hostId}/${entry.session.sessionId}`;
}

/** A short age for a row, as the Mac's sidebar shows: "now", "5m", "3h", "2d", "4w". */
export function shortAge(time: number, now: number): string {
  const elapsed = Math.max(0, Math.floor((now - time) / 1000));
  if (elapsed < 60) return "now";
  if (elapsed < 3_600) return `${Math.floor(elapsed / 60)}m`;
  if (elapsed < 86_400) return `${Math.floor(elapsed / 3_600)}h`;
  if (elapsed < 604_800) return `${Math.floor(elapsed / 86_400)}d`;
  return `${Math.floor(elapsed / 604_800)}w`;
}

/** The request may have reached the Mac although no answer came back. */
function deliveryUncertain(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const code = (error as { code?: unknown }).code;
  if (typeof code === "number") return code === -32004;
  return /timed out|closed|WebSocket/i.test(error.message);
}

/** The agent is starting and took nothing: the same commandId can go again. */
function agentWaking(error: unknown): boolean {
  return error instanceof Error && (error as { code?: unknown }).code === -32008;
}

function hostOffline(error: unknown): boolean {
  return error instanceof Error && (error as { code?: unknown }).code === -32005;
}

function describe(error: unknown): string {
  if (error instanceof Error && "status" in error && error.status === 401) return "Your sign-in expired. Sign in again.";
  return error instanceof Error ? error.message : String(error);
}

function sessionOf(session: ClientSession): Session {
  return { hostId: session.hostId, sessionId: session.sessionId, status: session.status, ...session.metadata };
}

function bySessionOrder(a: Session, b: Session): number {
  return (a.createdAt ?? 0) - (b.createdAt ?? 0) || a.sessionId.localeCompare(b.sessionId);
}

/** A client id for a tab: unguessable, and as the ClientDO names it. */
export function randomClientId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/** A client id that lives as long as the tab. */
export function tabClientIdentity(storage: Storage | null = globalThis.sessionStorage ?? null): ClientIdentity {
  const key = "axo.clientId";
  const renew = () => {
    const id = randomClientId();
    try { storage?.setItem(key, id); } catch { /* private mode: the id lives in memory */ }
    memory = id;
    return id;
  };
  let memory: string | null = null;
  try { memory = storage?.getItem(key) ?? null; } catch { /* no storage */ }
  return { current: () => memory ?? renew(), renew };
}

export class ChatWorkbench {
  hosts: Host[] = [];
  hostsPhase: "loading" | "cached" | "loaded" | "failed" = "loading";
  /** Explicit navigation supersedes a startup deep link, even while the socket is opening. */
  navigationRevision = 0;
  openHostId: string | null = null;
  link: Link = "idle";
  selection: Selection | null = null;
  /** The coding agent a new chat starts with (RFD0072); a Mac without it refuses the chat. */
  newChatAgent: CodingAgent = "pi";
  failure: string | null = null;
  isSending = false;
  /** Bumped on every change, for `useSyncExternalStore`. */
  version = 0;
  /** Whether the page is seen (see `setVisible`). */
  private visible = true;
  /** The feed of the chat on screen, kept by `keepFeed`. */
  private screenFeed: ConversationFeed | null = null;

  private readonly chats = new Map<string, Chat>();
  /** Terminal requests stay suppressed until their expiry, including reconnect/catch-up replay. */
  private readonly settledQuestions = new Map<string, number>();
  private readonly answersInFlight = new Map<string, { hostId: string; sessionId: string; result: Promise<boolean> }>();
  /** What the Macs ask, by elicitation id, oldest first (RFD0029). */
  private readonly asked = new Map<string, AskedQuestion>();
  private readonly drafts = new Map<string, string>();
  private readonly draftFiles = new Map<string, DraftAttachment[]>();
  private readonly listeners = new Set<() => void>();
  private connection: AccountLink | null = null;
  /** Each connection attempt's own number: what an older attempt finishes is ignored. */
  private generation = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempt = 0;
  /** The Sessions of each host, as last told. */
  private sessions = new Map<string, Map<string, Session>>();
  private listedHosts: ClientHost[] = [];
  /** The chat open on the socket: its new records arrive as they are written. */
  private opened: { hostId: string; sessionId: string } | null = null;

  private readonly backend: ChatBackend;
  private readonly identity: ClientIdentity;
  private readonly reconnectDelays: readonly number[];
  private readonly newId: () => string;
  private readonly retryDelay: number;
  private readonly retries = new Map<string, ReturnType<typeof setTimeout>>();
  private readonly restartTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private readonly uploadAsset: UploadAsset;
  private cache: ChatCache | null;
  private cacheTimer: ReturnType<typeof setTimeout> | null = null;
  private stopWatchingCache: (() => void) | null = null;


  constructor(
    backend: ChatBackend,
    identity: ClientIdentity = tabClientIdentity(),
    reconnectDelays: readonly number[] = defaultReconnectDelays,
    newId: () => string = () => crypto.randomUUID(),
    retryDelay: number = RETRY_DELAY_MS,
    uploadAsset: UploadAsset = () => Promise.reject(new Error("Attachments are unavailable here.")),
    cache: ChatCache | null = null,
  ) {
    this.uploadAsset = uploadAsset;
    this.backend = backend;
    this.identity = identity;
    this.reconnectDelays = reconnectDelays;
    this.newId = newId;
    this.retryDelay = retryDelay;
    this.cache = cache;
    const saved = cache?.read();
    if (saved) this.restoreCache(saved);
  }

  // MARK: - Observing

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  private changed(persist = true): void {
    if (persist && this.cache) {
      if (this.cacheTimer) clearTimeout(this.cacheTimer);
      this.cacheTimer = setTimeout(() => this.flushCache(), 300);
    }
    this.keepFeed();
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  private restoreCache(saved: ChatSnapshot): void {
    this.applyListing(saved.listing);
    this.hostsPhase = "cached";
    for (const savedChat of saved.chats) {
      const chat = this.chat(savedChat.sessionId);
      chat.transcript = new ChatTranscript();
      chat.transcript.append(savedChat.records);
      chat.transcript.settle(false);
      chat.cached = true;
      // Never use browser data as a trusted epoch/cursor: open a fresh window on reconnect.
      chat.epoch = null;
      chat.history = { kind: "loaded", records: savedChat.records.length, hasOlder: false };
    }
    for (const [key, text] of saved.drafts) this.drafts.set(key, text);
    if (saved.selected) {
      this.openHostId = saved.selected.hostId;
      this.selection = saved.selected.sessionId ? { kind: "chat", sessionId: saved.selected.sessionId } : { kind: "new" };
    }
    this.keepFeed();
  }

  /** Flush on pagehide as well as the debounce: refreshing must not lose the last update. */
  flushCache(): void {
    if (this.cacheTimer) clearTimeout(this.cacheTimer);
    this.cacheTimer = null;
    if (!this.cache) return;
    const sessions: ClientSession[] = [...this.sessions.values()].flatMap(rows => [...rows.values()].map(session => {
      const { hostId, sessionId, status, ...metadata } = session;
      return { hostId, sessionId, status: null, epoch: null, head: 0, metadata };
    }));
    const chats = [...this.chats.entries()].flatMap(([sessionId, chat]) => {
      const session = sessions.find(row => row.sessionId === sessionId);
      return session && chat.transcript ? [{ hostId: session.hostId, sessionId, records: chat.transcript.records }] : [];
    });
    this.cache.write({ listing: { hosts: this.listedHosts, sessions }, chats,
      selected: this.openHostId ? { hostId: this.openHostId, sessionId: this.selection?.kind === "chat" ? this.selection.sessionId : null } : null,
      drafts: [...this.drafts] });
  }

  forgetCache(): void {
    this.stopWatchingCache?.();
    this.stopWatchingCache = null;
    if (this.cacheTimer) clearTimeout(this.cacheTimer);
    this.cacheTimer = null;
    this.cache?.clear();
    this.cache = null; // In-flight socket callbacks must not repopulate a signed-out account.
  }

  /** Whether the page is seen: a hidden tab lets nothing out, and shows what arrives as it is. */
  setVisible(visible: boolean): void {
    if (visible === this.visible) return;
    this.visible = visible;
    this.changed();
  }

  /**
   * Keeps the rows of the chat on screen: brought up to date with every change, and told when it
   * comes on screen or leaves it. The other chats' rows are not kept; one that comes on screen
   * starts from what it holds, as history.
   */
  private keepFeed(): void {
    const selection = this.selection;
    const chat = selection?.kind === "chat" ? this.chats.get(selection.sessionId) ?? null : null;
    const feed = chat && this.visible ? chat.feed : null;
    if (feed !== this.screenFeed) {
      this.screenFeed?.closed();
      this.screenFeed = feed;
      if (chat && feed) {
        feed.animates = !reducedMotion();
        feed.update(chat.transcript, chat.waiting);
        feed.opened();
      }
      return;
    }
    if (chat && feed) feed.update(chat.transcript, chat.waiting);
  }

  get openHost(): Host | null {
    return this.hosts.find(host => host.hostId === this.openHostId) ?? null;
  }

  get selectedSession(): Session | null {
    const selection = this.selection;
    if (selection?.kind !== "chat") return null;
    return this.openHost?.sessions.find(session => session.sessionId === selection.sessionId) ?? null;
  }

  chat(sessionId: string): Chat {
    let chat = this.chats.get(sessionId);
    if (!chat) {
      chat = new Chat();
      this.chats.set(sessionId, chat);
    }
    return chat;
  }

  // MARK: - The account's socket

  /** Connects, and stays connected until `dispose`. */
  start(): void {
    if (this.link !== "idle") return;
    this.stopWatchingCache = this.cache?.watchClear(() => this.forgetCache()) ?? null;
    this.connect();
    this.changed();
  }

  private connect(): void {
    this.clearReconnect();
    const generation = ++this.generation;
    const mine = <T extends unknown[]>(handle: (...args: T) => void) =>
      (...args: T) => { if (generation === this.generation) handle(...args); };
    this.link = this.link === "reconnecting" ? "reconnecting" : "connecting";
    void this.backend.connect(this.identity.current(), {
      hosts: mine(hosts => this.listHosts(hosts)),
      sessions: mine((hostId, sessions) => this.updateSessions(hostId, sessions)),
      records: mine((sessionId, epoch, records) => this.receiveRecords(sessionId, epoch, records)),
      progress: mine((sessionId, slot, snapshot) => this.receiveProgress(sessionId, slot, snapshot)),
      reset: mine((sessionId, epoch, keep) => this.receiveReset(sessionId, epoch, keep)),
      elicitationRequested: mine((hostId, elicitation) => {
        for (const [id, expiry] of this.settledQuestions) if (expiry <= Date.now()) this.settledQuestions.delete(id);
        if (this.settledQuestions.has(elicitation.id)) return;
        this.chat(elicitation.sessionId).humanTurnProtected = true;
        if (!this.asked.has(elicitation.id)) this.asked.set(elicitation.id, { hostId, elicitation, answering: null });
        this.changed();
      }),
      elicitationResolved: mine((_hostId, resolved) => {
        const known = this.asked.get(resolved.id);
        if (known) this.settledQuestions.set(resolved.id, known.elicitation.expiresAt);
        if (this.asked.delete(resolved.id)) this.changed();
      }),
      closed: mine(error => this.connectionLost(error)),
    }).then(connection => {
      if (generation !== this.generation) {
        connection.close();
        return;
      }
      this.connection = connection;
      this.link = "connected";
      this.failure = null;
      this.reconnectAttempt = 0;
      this.applyListing(connection.hello);
      if (!this.openHost) {
        const next = this.hosts.find(host => host.status === "online") ?? this.hosts[0];
        if (next) this.openMac(next.hostId);
      }
      // What was open before the gap opens again from what is held.
      const opened = this.opened;
      this.opened = null;
      const selection = this.selection;
      if (selection?.kind === "chat") void this.openChat(selection.sessionId);
      else if (opened) this.chat(opened.sessionId).history = { kind: "none" };
      this.changed();
    }, error => {
      if (generation !== this.generation) return;
      if (this.hostsPhase === "loading") this.hostsPhase = "failed";
      this.failure = describe(error);
      this.scheduleReconnect();
      this.changed();
    });
  }

  private connectionLost(error: Error): void {
    this.connection = null;
    // What is still asked comes again with the next hello.
    this.asked.clear();
    // Another tab with this tab's id took the socket: this tab takes a new one.
    if (error.message === "Replaced") this.identity.renew();
    this.scheduleReconnect();
    this.changed();
  }

  /** Tries again with growing pauses. Records written meanwhile come when the chat opens again. */
  private scheduleReconnect(): void {
    this.link = "reconnecting";
    this.clearReconnect();
    const delay = this.reconnectDelays[Math.min(this.reconnectAttempt, this.reconnectDelays.length - 1)] ?? 15_000;
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
      this.changed();
    }, delay);
  }

  private clearReconnect(): void {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  dispose(): void {
    this.stopWatchingCache?.();
    this.stopWatchingCache = null;
    this.flushCache();
    this.screenFeed?.dispose();
    this.generation += 1;
    this.clearReconnect();
    for (const timer of this.retries.values()) clearTimeout(timer);
    this.retries.clear();
    for (const timer of this.restartTimers.values()) clearTimeout(timer);
    this.restartTimers.clear();
    this.connection?.close();
    this.connection = null;
    this.link = "idle";
    this.listeners.clear();
  }

  private reference(host: Host): HostRef {
    return { hostId: host.hostId, hostGeneration: host.hostGeneration };
  }

  // MARK: - Macs and their chats

  /**
   * Names a Mac, for this account everywhere: the network's name for it is rarely what anyone
   * calls it. An empty name goes back to that. Says whether it was saved.
   */
  async renameHost(hostId: string, name: string): Promise<boolean> {
    const connection = this.connection;
    if (!connection?.active) {
      this.failure = "Not connected; try again in a moment.";
      this.changed();
      return false;
    }
    try {
      const label = await connection.renameHost(hostId, name);
      this.listedHosts = this.listedHosts.map(host => host.hostId === hostId ? { ...host, label } : host);
      this.rebuildHosts();
      this.changed();
      return true;
    } catch (error) {
      this.failure = `Could not rename the Mac: ${describe(error)}`;
      this.changed();
      return false;
    }
  }

  /** Lists the account's hosts again now: for a Mac paired a moment ago. */
  async refreshHosts(): Promise<void> {
    const connection = this.connection;
    if (!connection?.active) return;
    try {
      const listing = await connection.refresh();
      if (connection !== this.connection) return;
      this.applyListing(listing);
      this.changed();
    } catch {
      // The next refresh, or the socket's own updates, will do.
    }
  }

  private applyListing(listing: ClientHello): void {
    this.sessions = new Map();
    this.listHosts(listing.hosts, false);
    for (const session of listing.sessions) this.storeSession(session);
    this.rebuildHosts();
    this.hostsPhase = "loaded";
  }

  private listHosts(hosts: ClientHost[], notify = true): void {
    this.listedHosts = hosts;
    for (const hostId of this.sessions.keys()) if (!hosts.some(host => host.hostId === hostId)) this.sessions.delete(hostId);
    if (!notify) return;
    this.rebuildHosts();
    this.changed();
  }

  private updateSessions(hostId: string, sessions: ClientSession[]): void {
    for (const session of sessions) {
      if (session.hostId !== hostId) continue;
      this.storeSession(session);
      const chat = this.chats.get(session.sessionId);
      if (chat && (session.status === "ready" || session.status === "unavailable") && this.questions(session.sessionId).length === 0
        && ![...this.answersInFlight.values()].some(answer => answer.sessionId === session.sessionId)) chat.humanTurnProtected = false;
      if (chat?.transcript && session.status) {
        const working = session.status === "working";
        chat.transcript.settle(working);
        if (!working) chat.stopping = false;
      }
      // A restart is over once the agent has gone down or started, and is ready again. A listing still
      // saying ready from before the restart does not end it.
      if (chat?.restarting && session.status && session.status !== "ready") chat.restartLeftReady = true;
      if (chat?.restarting && chat.restartLeftReady && session.status === "ready") this.endRestart(chat);
    }
    this.rebuildHosts();
    this.changed();
  }

  private storeSession(session: ClientSession): void {
    const sessions = this.sessions.get(session.hostId) ?? new Map<string, Session>();
    sessions.set(session.sessionId, sessionOf(session));
    this.sessions.set(session.hostId, sessions);
  }

  private rebuildHosts(): void {
    this.hosts = this.listedHosts.map(host => ({
      hostId: host.hostId,
      hostGeneration: host.hostGeneration,
      label: host.label,
      hostKind: host.hostKind,
      ...(host.model ? { model: host.model } : {}),
      status: host.online ? "online" : "offline",
      lastSeenAt: host.lastSeenAt,
      sessions: [...(this.sessions.get(host.hostId)?.values() ?? [])].sort(bySessionOrder),
    }));
    if (this.openHostId && !this.hosts.some(host => host.hostId === this.openHostId)) {
      this.openHostId = null;
      this.selection = null;
      this.closeOpened();
    }
    const selection = this.selection;
    if (selection?.kind === "chat" && this.openHost && !this.selectedSession && !this.chats.get(selection.sessionId)?.pending.length) {
      // The chat on screen is gone from its Mac.
      this.selection = { kind: "new" };
    }
  }

  /** Opens a Mac: new chats start on it. */
  openMac(hostId: string): void {
    if (hostId === this.openHostId) return;
    this.openHostId = hostId;
    this.selection = { kind: "new" };
    this.closeOpened();
    this.failure = null;
    this.changed();
  }

  // MARK: - Records

  private receiveRecords(sessionId: string, epoch: number, records: TranscriptRecord[]): void {
    const chat = this.chats.get(sessionId);
    if (!chat?.transcript || this.opened?.sessionId !== sessionId) return;
    if (chat.epoch !== null && chat.epoch !== epoch) return;
    chat.epoch = epoch;
    if (records[0] && records[0].cursor > chat.transcript.lastCursor + 1) {
      // A batch that does not follow what is held: open again from what is held.
      void this.openChat(sessionId);
      return;
    }
    this.changeChat(sessionId, transcript => transcript.append(records));
    this.settleHistory(chat);
    this.changed();
  }

  private receiveProgress(sessionId: string, slot: string, snapshot: unknown): void {
    const chat = this.chats.get(sessionId);
    if (!chat?.transcript) return;
    chat.transcript.progress(slot, snapshot);
    this.changed(false);
  }

  private receiveReset(sessionId: string, epoch: number, keep: number): void {
    const chat = this.chats.get(sessionId);
    if (!chat?.transcript) return;
    chat.epoch = epoch;
    const first = chat.transcript.firstCursor;
    chat.transcript.cut(keep);
    // A cut below everything held leaves the records before it to be read as older history.
    if (chat.transcript.firstCursor === null && first !== null) chat.older = keep > 0 ? keep + 1 : null;
    this.settleHistory(chat);
    this.changed();
  }

  private settleHistory(chat: Chat): void {
    if (chat.history.kind === "loaded") chat.history = { kind: "loaded", records: chat.transcript?.records.length ?? 0, hasOlder: chat.older !== null };
  }

  /**
   * Changes a chat, then retires the pending messages the log now holds: the ones whose receipt,
   * written by the Mac just before their user message, carries their commandId (RFD0024).
   */
  private changeChat(sessionId: string, change: (transcript: ChatTranscript) => void): void {
    const chat = this.chat(sessionId);
    chat.transcript ??= new ChatTranscript();
    change(chat.transcript);
    if (!chat.transcript.working) chat.stopping = false;
    if (!chat.pending.length) return;
    const delivered = chat.transcript.delivered;
    const landed = chat.pending.filter(prompt => delivered.has(prompt.id));
    if (!landed.length) return;
    for (const prompt of landed) this.cancelRetry(prompt.id);
    chat.pending = chat.pending.filter(prompt => !delivered.has(prompt.id));
  }

  // MARK: - History

  /** Jump means no presentation backlog, including records still being fetched from the socket. */
  async jumpToLatest(sessionId: string): Promise<void> {
    if (this.selection?.kind !== "chat" || this.selection.sessionId !== sessionId) return;
    this.chat(sessionId).feed.fastForward();
    this.changed(false);
    await this.openChat(sessionId);
  }

  /** Opens from the held cursor (or newest page); subsequent records follow on the socket. */
  async openChat(sessionId: string): Promise<void> {
    const session = this.openHost?.sessions.find(candidate => candidate.sessionId === sessionId);
    const hostId = session?.hostId ?? this.openHostId;
    const connection = this.connection;
    const chat = this.chat(sessionId);
    if (!hostId || !connection?.active) return;
    const request = {};
    chat.openRequest = request;
    if (this.opened && this.opened.sessionId !== sessionId) connection.closeSession(this.opened.sessionId);
    this.opened = { hostId, sessionId };
    const held = !chat.cached && chat.transcript && chat.epoch !== null ? { epoch: chat.epoch, cursor: chat.transcript.lastCursor } : null;
    if (!held) chat.history = { kind: "loading" };
    this.changed();
    try {
      const result = await connection.open(held ? { hostId, sessionId, have: held } : { hostId, sessionId, window: { last: historyPageSize } });
      if (this.opened?.sessionId !== sessionId || this.chats.get(sessionId) !== chat || chat.openRequest !== request) return;
      if (!held || result.epoch !== held.epoch) {
        chat.transcript = null;
        chat.older = result.older;
      }
      chat.epoch = result.epoch;
      chat.cached = false;
      this.changeChat(sessionId, transcript => {
        transcript.append(result.records);
        for (const { slot, snapshot } of result.progress) transcript.progress(slot, snapshot);
        const status = session?.status;
        if (status) transcript.settle(status === "working");
      });
      chat.feed.restoreHistory(chat.transcript, chat.waiting);
      chat.history = { kind: "loaded", records: chat.transcript!.records.length, hasOlder: chat.older !== null };
    } catch (error) {
      if (this.opened?.sessionId === sessionId && chat.openRequest === request) chat.history = { kind: "failed", message: describe(error) };
    }
    this.changed();
  }

  /** Reads the page before the oldest one shown; nothing when this is the beginning. */
  async loadOlderHistory(sessionId: string): Promise<void> {
    const chat = this.chat(sessionId);
    const connection = this.connection;
    if (!connection?.active || chat.history.kind !== "loaded" || chat.older === null || this.opened?.sessionId !== sessionId) return;
    const records = chat.history.records;
    chat.history = { kind: "loadingOlder", records };
    this.changed();
    try {
      const page = await connection.older(sessionId, chat.older, historyPageSize);
      if (this.chats.get(sessionId) !== chat) return;
      if (page.epoch === chat.epoch) {
        chat.older = page.older;
        this.changeChat(sessionId, transcript => transcript.prepend(page.records));
        chat.feed.restoreHistory(chat.transcript, chat.waiting);
      }
      chat.history = { kind: "loaded", records: chat.transcript?.records.length ?? 0, hasOlder: chat.older !== null };
    } catch (error) {
      chat.history = { kind: "loaded", records, hasOlder: true };
      this.failure = describe(error);
    }
    this.changed();
  }

  private closeOpened(): void {
    if (this.opened) {
      this.chat(this.opened.sessionId).openRequest = null;
      this.connection?.closeSession(this.opened.sessionId);
    }
    this.opened = null;
  }

  // MARK: - Selecting

  /** Shows a chat, on whichever Mac it is. */
  selectChat(hostId: string, sessionId: string): void {
    this.navigationRevision += 1;
    if (hostId !== this.openHostId) this.openMac(hostId);
    this.selection = { kind: "chat", sessionId };
    const chat = this.chat(sessionId);
    this.chats.delete(sessionId);
    this.chats.set(sessionId, chat);
    this.failure = null;
    if (this.opened?.sessionId !== sessionId) void this.openChat(sessionId);
    this.changed();
  }

  /** A new chat on `hostId` (the open Mac when not given). */
  newChat(hostId: string | null = null): void {
    this.navigationRevision += 1;
    if (hostId && hostId !== this.openHostId) this.openMac(hostId);
    this.selection = { kind: "new" };
    this.closeOpened();
    this.failure = null;
    this.changed();
  }

  /**
   * The Mac a new chat starts on, chosen by the message box: what is typed comes along.
   */
  chooseHost(hostId: string): void {
    const selection = this.selection;
    if (selection?.kind !== "new" || hostId === this.openHostId || !this.hosts.some(host => host.hostId === hostId)) return;
    this.navigationRevision += 1;
    const text = this.draft(selection);
    const files = this.attachments(selection);
    this.setDraft("", selection);
    this.setAttachments([], selection);
    this.openMac(hostId);
    if (text) this.setDraft(text);
    this.setAttachments(files);
    this.changed();
  }

  /** The coding agent the new chat starts with. */
  chooseAgent(agent: CodingAgent): void {
    if (agent === this.newChatAgent || !CODING_AGENTS.some(choice => choice.agent === agent)) return;
    this.newChatAgent = agent;
    this.changed();
  }

  dismissFailure(): void {
    this.failure = null;
    this.changed();
  }

  // MARK: - Drafts and sending

  private draftKey(selection: Selection): string {
    return selection.kind === "chat" ? `${this.openHostId}/chat/${selection.sessionId}` : `${this.openHostId}/new`;
  }

  draft(selection: Selection | null = this.selection): string {
    return selection ? this.drafts.get(this.draftKey(selection)) ?? "" : "";
  }

  setDraft(text: string, selection: Selection | null = this.selection): void {
    if (!selection) return;
    const key = this.draftKey(selection);
    if (text) {
      this.drafts.delete(key);
      this.drafts.set(key, text);
    } else this.drafts.delete(key);
    this.changed();
  }

  /** The files in the message box. */
  attachments(selection: Selection | null = this.selection): readonly DraftAttachment[] {
    return selection ? this.draftFiles.get(this.draftKey(selection)) ?? [] : [];
  }

  private setAttachments(files: readonly DraftAttachment[], selection: Selection | null = this.selection): void {
    if (!selection) return;
    const key = this.draftKey(selection);
    if (files.length) this.draftFiles.set(key, [...files]);
    else this.draftFiles.delete(key);
    this.changed();
  }

  /** Adds files to the message box and uploads each to the account at once. */
  attach(files: readonly { file: Blob; name: string }[]): void {
    const selection = this.selection;
    if (!selection) return;
    const room = ASSET_LIMITS.attachmentsPerPrompt - this.attachments(selection).length;
    if (files.length > room) this.report(`A message can carry at most ${ASSET_LIMITS.attachmentsPerPrompt} files.`);
    const added = files.slice(0, Math.max(0, room)).map(({ file, name }): DraftAttachment => {
      const tooLarge = file.size > ASSET_LIMITS.assetBytes;
      return {
        id: this.newId(),
        file,
        name: safeFileName(name),
        mimeType: assetTypeOf(file.type),
        size: file.size,
        state: tooLarge ? "failed" : "uploading",
        uploaded: null,
        error: tooLarge ? "Files can be at most 100 MB." : null,
      };
    });
    if (!added.length) return;
    this.setAttachments([...this.attachments(selection), ...added], selection);
    for (const attachment of added) if (attachment.state === "uploading") void this.upload(attachment);
  }

  private async upload(attachment: DraftAttachment): Promise<void> {
    try {
      attachment.uploaded = await this.uploadAsset(attachment.file, attachment.name);
      attachment.state = "ready";
    } catch (error) {
      attachment.state = "failed";
      attachment.error = describe(error);
    }
    this.changed();
  }

  /** Takes a file out of the message box; an uploaded one stays in the account. */
  detach(id: string): void {
    this.setAttachments(this.attachments().filter(attachment => attachment.id !== id));
  }

  /** Whether what is in the box can go: words or files, and no file still on its way. */
  get canSendDraft(): boolean {
    const files = this.attachments();
    if (files.some(file => file.state !== "ready")) return false;
    return this.draft().trim().length > 0 || files.length > 0;
  }

  /**
   * Sends what is typed. On a new chat the first message brings the chat into being, in the
   * Mac's home folder.
   */
  async send(delivery: Delivery = "interrupt"): Promise<SendOutcome> {
    const selection = this.selection;
    if (this.isSending || !selection || !this.canSendDraft) return { kind: "failed" };
    if (selection.kind === "chat") return this.sending(async () => {
      const hostId = this.openHostId;
      const answers = [...this.answersInFlight.values()].filter(answer => answer.hostId === hostId && answer.sessionId === selection.sessionId);
      const results = await Promise.all(answers.map(answer => answer.result));
      if (results.some(result => !result) || this.openHostId !== hostId
        || this.selection?.kind !== "chat" || this.selection.sessionId !== selection.sessionId) return { kind: "failed" };
      const chat = this.chat(selection.sessionId);
      // An unseen run should not be interrupted just because its history is still loading.
      const protectedTurn = chat.cached || chat.transcript === null || chat.humanTurnProtected || this.questions(selection.sessionId).length > 0;
      return this.prompt(selection, delivery === "interrupt" && protectedTurn ? "followUp" : delivery);
    });
    return this.startChat(selection);
  }

  private startChat(draft: Extract<Selection, { kind: "new" }>): Promise<SendOutcome> {
    return this.sending(async () => {
      const host = this.openHost;
      if (!host || !this.ready()) return { kind: "failed" };
      const target = this.reference(host);
      let created: CreatedSession;
      try {
        // Pi is left unsaid, so that a Mac older than the picker still takes the chat.
        const agent = this.newChatAgent;
        ({ session: created } = await this.connection!.command("axo.remote.session.create",
          agent === "pi" ? { target } : { target, agent }));
      } catch (error) {
        return this.report(`Could not start the chat: ${describe(error)}`);
      }
      // Listed at once; the host's own listing replaces this when it arrives.
      this.storeSession({
        hostId: host.hostId,
        sessionId: created.sessionId,
        epoch: null,
        head: 0,
        status: "starting",
        metadata: {
          name: created.name ?? null,
          emoji: created.emoji ?? null,
          folderName: created.folderName ?? null,
          hasAgent: true,
          createdAt: created.createdAt ?? Math.floor(Date.now() / 1000),
          lastMessageAt: null,
          archived: false,
        },
      });
      this.rebuildHosts();
      // The words move to the chat they started; a refusal leaves them in its box.
      const chat: Selection = { kind: "chat", sessionId: created.sessionId };
      this.setDraft(this.draft(draft), chat);
      this.setDraft("", draft);
      this.setAttachments(this.attachments(draft), chat);
      this.setAttachments([], draft);
      this.selection = chat;
      void this.openChat(created.sessionId);
      return this.prompt(chat);
    });
  }

  private async sending(work: () => Promise<SendOutcome>): Promise<SendOutcome> {
    this.isSending = true;
    this.changed();
    try {
      return await work();
    } finally {
      this.isSending = false;
      this.changed();
    }
  }

  /** Live authenticated metadata authorizes a destination; a display-history fetch does not. */
  get canSendToSelection(): boolean {
    return this.link === "connected" && this.hostsPhase === "loaded" && this.connection?.active === true
      && this.openHost?.status === "online" && this.selection !== null
      && (this.selection.kind === "new" || Boolean(this.selectedSession && isChat(this.selectedSession)));
  }

  private ready(): boolean {
    if (!this.connection?.active || this.link !== "connected" || this.hostsPhase !== "loaded") {
      this.report("Not connected yet. Your message stays in its draft.");
      return false;
    }
    const host = this.openHost;
    if (!host) return false;
    if (host.status !== "online") {
      this.report(`${host.label} is offline.`);
      return false;
    }
    if (!this.canSendToSelection) {
      this.report("This chat is no longer available. Your message was not sent.");
      return false;
    }
    return true;
  }

  private report(message: string): SendOutcome {
    this.failure = message;
    this.changed();
    return { kind: "failed" };
  }

  /**
   * Sends a message to a chat, with its commandId. It shows as pending until its receipt arrives
   * in the log; one whose fate is unknown is sent again with the same id, which the Mac takes at
   * most once.
   */
  private async prompt(selection: Selection & { kind: "chat" }, delivery: Delivery = "interrupt"): Promise<SendOutcome> {
    const host = this.openHost;
    const text = this.draft(selection).trim();
    const files = this.attachments(selection);
    if (!host || !this.canSendDraft || !this.ready()) return { kind: "failed" };
    const chat = this.chat(selection.sessionId);
    const attachments = files.flatMap(file => file.uploaded ? [file.uploaded] : []);
    const pending: PendingPrompt = { id: this.newId(), text, attachments, delivery, state: "sending" };
    chat.pending = [...chat.pending, pending];
    this.setDraft("", selection);
    this.setAttachments([], selection);
    const outcome = await this.deliver(host, selection.sessionId, pending);
    if (outcome.kind === "failed") {
      // Refused on its first try: nothing ran, so the words and files come back to the box.
      chat.pending = chat.pending.filter(candidate => candidate.id !== pending.id);
      if (!this.draft(selection)) this.setDraft(text, selection);
      if (!this.attachments(selection).length) this.setAttachments(files, selection);
    }
    this.changed();
    return outcome;
  }

  /** One try at sending a pending message; an unknown outcome schedules the next. */
  private async deliver(host: Host, sessionId: string, pending: PendingPrompt, attempt = 0): Promise<SendOutcome> {
    let outcome: SendOutcome;
    try {
      const params = {
        target: this.reference(host), sessionId, text: pending.text, commandId: pending.id,
        ...(pending.attachments.length ? { attachments: [...pending.attachments] } : {}),
      };
      // A follow-up goes without a delivery, as Macs before RFD0033 take it.
      await this.connection!.command("axo.remote.session.prompt", {
        ...params, ...(pending.delivery === "followUp" ? {} : { delivery: pending.delivery }),
      }).catch(error => {
        // A Mac from before interrupts refuses one before it reaches Pi: it goes as a follow-up.
        if (pending.delivery !== "interrupt" || (error as { code?: unknown }).code !== -32602) throw error;
        return this.connection!.command("axo.remote.session.prompt", params);
      });
      this.failure = null;
      outcome = { kind: "sent" };
    } catch (error) {
      // A refusal after an unknown outcome proves nothing: the first try may still land.
      const waking = agentWaking(error);
      const unknown = waking || deliveryUncertain(error) || (attempt > 0 && hostOffline(error));
      outcome = unknown ? { kind: "uncertain" } : { kind: "failed" };
      this.failure = waking ? null : unknown
        ? `${host.label} has not said whether it got your message; trying again.`
        : `Not sent: ${describe(error)}`;
      if (waking) {
        const current = this.chats.get(sessionId)?.pending.find(candidate => candidate.id === pending.id);
        // A try that may have landed stays uncertain: only a first answer says nothing was kept.
        if (current && current.state !== "uncertain") {
          current.state = "waking";
          if (attempt < MAX_RETRIES) this.scheduleRetry(host, sessionId, current, attempt + 1);
          return { kind: "sent" };
        }
      }
    }
    const current = this.chats.get(sessionId)?.pending.find(candidate => candidate.id === pending.id);
    if (!current) return outcome;
    if (outcome.kind === "sent") current.state = this.chats.get(sessionId)?.transcript?.working ? "queued" : "sent";
    else if (outcome.kind === "uncertain") {
      current.state = "uncertain";
      if (attempt < MAX_RETRIES) this.scheduleRetry(host, sessionId, current, attempt + 1);
    }
    return outcome;
  }

  private scheduleRetry(host: Host, sessionId: string, pending: PendingPrompt, attempt: number): void {
    this.cancelRetry(pending.id);
    this.retries.set(pending.id, setTimeout(() => {
      this.retries.delete(pending.id);
      const still = this.chats.get(sessionId)?.pending.some(candidate => candidate.id === pending.id);
      if (!still) return;
      if (!this.ready()) return this.scheduleRetry(host, sessionId, pending, attempt);
      void this.deliver(host, sessionId, pending, attempt).then(() => this.changed());
    }, this.retryDelay));
  }

  private cancelRetry(pendingId: string): void {
    const timer = this.retries.get(pendingId);
    if (timer !== undefined) clearTimeout(timer);
    this.retries.delete(pendingId);
  }

  /** Takes a message marked uncertain off the screen, once the person has checked. */
  dismissPending(sessionId: string, pendingId: string): void {
    const chat = this.chats.get(sessionId);
    if (!chat) return;
    this.cancelRetry(pendingId);
    chat.pending = chat.pending.filter(prompt => prompt.id !== pendingId);
    this.changed();
  }

  /**
   * Stops the run the chat shows running, named by everything this tab saw of it: its newest user
   * message, the newest record held (there however long the run), and the messages sent from here,
   * which name a run before any of its records arrive. A run none of them belongs to, one that
   * started elsewhere since, carries on (RFD0024). A stop that stopped nothing ends at once, so the
   * next tap tries again with what has arrived by then.
   */
  async stop(sessionId: string): Promise<void> {
    const host = this.openHost;
    const chat = this.chat(sessionId);
    const transcript = chat.transcript;
    if (chat.cached || !host || !transcript?.working || chat.stopping || !this.ready()) return;
    const turnId = transcript.lastUserEntry ?? undefined;
    const seen = transcript.records.at(-1)?.id ?? undefined;
    const commandIds = chat.pending.map(prompt => prompt.id).slice(-32);
    if (!turnId && !seen && !commandIds.length) return;
    chat.stopping = true;
    this.changed();
    const target = this.reference(host);
    const ask = (params: { turnId?: string; seen?: string; commandIds?: string[] }) =>
      this.connection!.command("axo.remote.session.stop", { target, sessionId, ...params });
    try {
      const { stopped } = await ask({
        ...(turnId ? { turnId } : {}), ...(seen ? { seen } : {}), ...(commandIds.length ? { commandIds } : {}),
      }).catch(error => {
        // A Mac from before 0.28 knows only turnId.
        if ((error as { code?: unknown }).code === -32602 && turnId) return ask({ turnId });
        throw error;
      });
      // Nothing ran that this tab saw: Pi says it is idle, or a newer run goes on.
      if (!stopped) chat.stopping = false;
    } catch (error) {
      chat.stopping = false;
      this.failure = describe(error);
    }
    this.changed();
  }

  /**
   * Restarts the chat's agent on the same conversation (RFD0033). A reply it is writing stops; the
   * messages waiting for it are in the log, so they survive. "Restarting…" shows until it is ready.
   */
  async restart(sessionId: string): Promise<void> {
    const host = this.openHost;
    const chat = this.chat(sessionId);
    if (!host || chat.restarting || !this.ready()) return;
    chat.restarting = true;
    chat.restartLeftReady = false;
    // A restart so quick no listing shows it leaving ready is over by then.
    this.restartTimers.set(sessionId, setTimeout(() => {
      if (chat.restarting) this.endRestart(chat);
      this.changed();
    }, RESTART_SETTLE_MS));
    chat.commands = null;
    chat.models = null;
    this.changed();
    try {
      await this.connection!.command("axo.remote.session.restart", { target: this.reference(host), sessionId });
    } catch (error) {
      this.endRestart(chat);
      this.failure = `Could not restart the agent: ${describe(error)}`;
    }
    this.changed();
  }

  private endRestart(chat: Chat): void {
    chat.restarting = false;
    chat.restartLeftReady = false;
    for (const [sessionId, timer] of this.restartTimers) {
      if (this.chats.get(sessionId) !== chat) continue;
      clearTimeout(timer);
      this.restartTimers.delete(sessionId);
    }
  }

  /** Reads the slash commands the chat's Pi runs, each time the `/` list opens: they change as skills do. */
  async loadCommands(sessionId: string): Promise<void> {
    await this.load(sessionId, "commands", async (target) =>
      (await this.connection!.command("axo.remote.session.commands", { target, sessionId })).commands);
  }

  /** Reads the models the chat's Pi can switch to, each time the model menu opens. */
  async loadModels(sessionId: string): Promise<void> {
    await this.load(sessionId, "models", async (target) =>
      (await this.connection!.command("axo.remote.session.models", { target, sessionId })).models);
  }

  private async load<K extends "commands" | "models">(sessionId: string, key: K, read: (target: HostRef) => Promise<(K extends "commands" ? PiCommand : PiModel)[]>): Promise<void> {
    const host = this.openHost;
    const chat = this.chat(sessionId);
    if (!host || host.status !== "online" || !this.connection?.active) {
      chat[key] = { kind: "failed", message: `${host?.label ?? "The Mac"} is offline.` };
      this.changed();
      return;
    }
    // What was read last stays on screen while it is read again.
    if (chat[key]?.kind !== "loaded") chat[key] = { kind: "loading" };
    this.changed();
    try {
      const items = await read(this.reference(host));
      chat[key] = { kind: "loaded", items } as Chat[K];
    } catch (error) {
      chat[key] = { kind: "failed", message: describe(error) };
    }
    this.changed();
  }

  /**
   * Switches the chat's Pi to another model or thinking level. What it runs then comes back with
   * the chat's listing, from Pi itself, so the box only ever names what Pi says it runs.
   */
  async setModel(sessionId: string, change: ModelChange): Promise<boolean> {
    const host = this.openHost;
    if (!host || !this.ready()) return false;
    try {
      await this.connection!.command("axo.remote.session.model.set", { target: this.reference(host), sessionId, ...change });
      return true;
    } catch (error) {
      const code = (error as { code?: unknown }).code;
      this.failure = code === -32007 ? "Pi is not signed in to that model's provider on your Mac."
        : code === -32602 ? "Pi does not have that model." : `Could not switch the model: ${describe(error)}`;
      this.changed();
      return false;
    }
  }

  /** What the Macs ask now, oldest first; with `sessionId`, only what that chat's agent asks. */
  questions(sessionId?: string): AskedQuestion[] {
    const all = [...this.asked.values()];
    return sessionId === undefined ? all : all.filter(question => question.elicitation.sessionId === sessionId);
  }

  /**
   * Answers what a Mac asks. The card stays until the Mac says it is settled; an answer that came
   * too late (another device answered, or it expired) removes it.
   */
  async answerQuestion(elicitationId: string, action: ElicitationAnswer, values?: Record<string, string>): Promise<void> {
    const question = this.asked.get(elicitationId);
    if (!question || question.answering || this.answersInFlight.has(elicitationId)) return;
    this.chat(question.elicitation.sessionId).humanTurnProtected = true;
    const result = this.performAnswer(elicitationId, action, values).catch(error => {
      this.failure = describe(error); this.changed(); return false;
    });
    this.answersInFlight.set(elicitationId, { hostId: question.hostId, sessionId: question.elicitation.sessionId, result });
    try { await result; } finally { this.answersInFlight.delete(elicitationId); }
  }

  private async performAnswer(elicitationId: string, action: ElicitationAnswer, values?: Record<string, string>): Promise<boolean> {
    const question = this.asked.get(elicitationId);
    if (!question || question.answering || !this.connection) return false;
    const input = question.elicitation.input;
    let sealed: Sealed | undefined;
    if (input && action === "accept") {
      // The authenticated account route supplies the host key (RFD0079).
      if (!values) return false;
      question.answering = action;
      this.changed();
      try {
        sealed = await sealInput(input.key, elicitationId, input.origin, values);
      } catch (error) {
        question.answering = null;
        this.failure = describe(error);
        this.changed();
        return false;
      }
    }
    question.answering = action;
    this.changed();
    try {
      await this.connection.resolveElicitation(question.hostId, elicitationId, action, undefined, sealed);
      this.failure = null;
      this.changed();
      return true;
    } catch (error) {
      question.answering = null;
      if ((error as { code?: number }).code === ELICITATION_ERRORS.notPending) {
        this.asked.delete(elicitationId);
        this.changed();
        return true;
      }
      this.failure = describe(error);
    }
    this.changed();
    return false;
  }

  /** Answers the agent's question: yes is Enter, no is Escape, words are sent as a prompt is. */
  async answer(sessionId: string, answer: Answer): Promise<void> {
    const host = this.openHost;
    if (!host || this.chats.get(sessionId)?.cached || !this.chats.get(sessionId)?.transcript?.question || !this.ready()) return;
    const target = this.reference(host);
    try {
      if (answer.kind === "text") await this.connection!.command("axo.remote.session.prompt", { target, sessionId, text: answer.text, commandId: this.newId() });
      else await this.connection!.command("axo.remote.session.key", { target, sessionId, key: answer.kind === "yes" ? "enter" : "escape" });
      this.failure = null;
    } catch (error) {
      this.failure = describe(error);
    }
    this.changed();
  }
}

/** Whether the person asked for less motion; never in a place with no window (the model's tests). */
function reducedMotion(): boolean {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}
