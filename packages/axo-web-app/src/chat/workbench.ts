import type {
  AccountEvents,
  ClientHello,
  ClientHost,
  ClientOpenResult,
  ClientSession,
  HostRef,
  OlderPage,
  OpenRequest,
  SessionStatus,
} from "@axo/app";
import { ChatTranscript, type TranscriptRecord } from "./transcript.ts";

/**
 * The browser's chats: a port of the phone's `PhoneWorkbench` and `HostWorkbenchModel`, on the
 * account's one socket (RFD0018). Every Mac and every chat is listed and kept current; the chat
 * on screen is open, so its new records arrive as they are written. A chat is a Session with an
 * agent in it; a new chat exists only once its first message is sent. History is read newest
 * first, a page at a time, and only as far back as the person scrolls.
 */

export interface Workspace {
  readonly workspaceId: string;
  readonly name: string;
  /** The Home Workspace, which is listed first. */
  readonly home?: true;
}

/** A chat as the menu and the conversation show it. */
export interface Session {
  readonly hostId: string;
  readonly sessionId: string;
  readonly name: string | null;
  readonly emoji: string | null;
  readonly workspaceId: string | null;
  readonly workspaceName: string | null;
  readonly hasAgent: boolean;
  /** Unix seconds. */
  readonly createdAt: number | null;
  /** Unix seconds of the latest completed message. */
  readonly lastMessageAt: number | null;
  readonly archived: boolean;
  readonly status: SessionStatus | null;
}

/** A Mac of the account, with its chats. */
export interface Host {
  readonly hostId: string;
  readonly hostGeneration: string;
  readonly label: string;
  readonly status: "online" | "offline";
  readonly lastSeenAt: string;
  readonly sessions: Session[];
}

type CreatedSession = {
  sessionId: string;
  name?: string;
  emoji?: string | null;
  workspaceId?: string | null;
  workspaceName?: string | null;
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
  command(method: "axo.remote.workspace.list", params: { target: HostRef }): Promise<{ workspaces: Workspace[] }>;
  command(method: "axo.remote.session.create", params: { target: HostRef }): Promise<{ session: CreatedSession }>;
  command(method: "axo.remote.workspace.session.create", params: { target: HostRef; workspaceId: string }): Promise<{ session: CreatedSession }>;
  command(method: "axo.remote.session.prompt", params: { target: HostRef; sessionId: string; text: string }): Promise<unknown>;
  command(method: "axo.remote.session.key", params: { target: HostRef; sessionId: string; key: "escape" | "enter" }): Promise<unknown>;
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

export type PendingState =
  /** On its way to the Mac. */
  | "sending"
  /** The Mac took it; the agent will record it shortly. */
  | "sent"
  /** Taken while the agent was busy: answered after the current reply. */
  | "queued"
  /** The connection ended before the Mac answered: it may or may not have arrived. */
  | "uncertain";

export interface PendingPrompt {
  readonly id: string;
  readonly text: string;
  state: PendingState;
}

export type HistoryState =
  | { kind: "none" }
  | { kind: "loading" }
  | { kind: "loaded"; records: number; hasOlder: boolean }
  | { kind: "loadingOlder"; records: number }
  | { kind: "failed"; message: string };

export class Chat {
  transcript: ChatTranscript | null = null;
  pending: PendingPrompt[] = [];
  history: HistoryState = { kind: "none" };
  stopping = false;
  /** The epoch the records held belong to. */
  epoch: number | null = null;
  /** The `before` of the next older page, or null when the start is held. */
  older: number | null = null;
}

/**
 * The open chat, or a new one waiting for its first message on the open Mac: in the Workspace
 * chosen for it, or with none chosen in the Mac's Home Workspace.
 */
export type Selection = { kind: "chat"; sessionId: string } | { kind: "new"; workspaceId: string | null };

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
  hostsPhase: "loading" | "loaded" | "failed" = "loading";
  openHostId: string | null = null;
  link: Link = "idle";
  workspaces: Workspace[] = [];
  selection: Selection | null = null;
  failure: string | null = null;
  isSending = false;
  /** Bumped on every change, for `useSyncExternalStore`. */
  version = 0;

  private readonly chats = new Map<string, Chat>();
  private readonly drafts = new Map<string, string>();
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

  constructor(
    backend: ChatBackend,
    identity: ClientIdentity = tabClientIdentity(),
    reconnectDelays: readonly number[] = defaultReconnectDelays,
    newId: () => string = () => crypto.randomUUID(),
  ) {
    this.backend = backend;
    this.identity = identity;
    this.reconnectDelays = reconnectDelays;
    this.newId = newId;
  }

  // MARK: - Observing

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  private changed(): void {
    this.version += 1;
    for (const listener of this.listeners) listener();
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
      void this.refreshWorkspaces();
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
    this.generation += 1;
    this.clearReconnect();
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
      if (chat?.transcript && session.status) {
        const working = session.status === "working";
        chat.transcript.settle(working);
        if (!working) chat.stopping = false;
      }
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
      status: host.online ? "online" : "offline",
      lastSeenAt: host.lastSeenAt,
      sessions: [...(this.sessions.get(host.hostId)?.values() ?? [])].sort(bySessionOrder),
    }));
    const selection = this.selection;
    if (selection?.kind === "chat" && this.openHost && !this.selectedSession && !this.chats.get(selection.sessionId)?.pending.length) {
      // The chat on screen is gone from its Mac.
      this.selection = { kind: "new", workspaceId: null };
    }
  }

  /** Opens a Mac: new chats start on it. */
  openMac(hostId: string): void {
    if (hostId === this.openHostId) return;
    this.openHostId = hostId;
    this.workspaces = [];
    this.selection = { kind: "new", workspaceId: null };
    this.closeOpened();
    this.failure = null;
    void this.refreshWorkspaces();
    this.changed();
  }

  async refreshWorkspaces(): Promise<Workspace[] | null> {
    const host = this.openHost;
    if (!host || host.status !== "online" || !this.connection?.active) return null;
    try {
      const { workspaces } = await this.connection.command("axo.remote.workspace.list", { target: this.reference(host) });
      if (host.hostId !== this.openHostId) return null;
      this.workspaces = workspaces;
      this.changed();
      return workspaces;
    } catch {
      return null;
    }
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
    this.changed();
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
   * Changes a chat, then retires the pending messages its newest user messages account for: the
   * one with the same words, or else the oldest the Mac has taken (the agent records them in order).
   */
  private changeChat(sessionId: string, change: (transcript: ChatTranscript) => void): void {
    const chat = this.chat(sessionId);
    const before = chat.pending.length ? new Set(chat.transcript?.messages.map(message => message.id) ?? []) : new Set<string>();
    chat.transcript ??= new ChatTranscript();
    change(chat.transcript);
    if (!chat.transcript.working) chat.stopping = false;
    if (!chat.pending.length) return;
    const pending = [...chat.pending];
    for (const message of chat.transcript.messages) {
      if (message.role !== "user" || before.has(message.id)) continue;
      const words = message.text.trim();
      const match = pending.findIndex(prompt => prompt.text === words);
      const oldest = pending.findIndex(prompt => prompt.state !== "sending");
      if (match >= 0) pending.splice(match, 1);
      else if (oldest >= 0) pending.splice(oldest, 1);
    }
    chat.pending = pending;
  }

  // MARK: - History

  /**
   * Opens a chat on the socket: from what is held when something is, or else its newest page.
   * Its new records then arrive as they are written.
   */
  async openChat(sessionId: string): Promise<void> {
    const session = this.openHost?.sessions.find(candidate => candidate.sessionId === sessionId);
    const hostId = session?.hostId ?? this.openHostId;
    const connection = this.connection;
    const chat = this.chat(sessionId);
    if (!hostId || !connection?.active) return;
    if (this.opened && this.opened.sessionId !== sessionId) connection.closeSession(this.opened.sessionId);
    this.opened = { hostId, sessionId };
    const held = chat.transcript && chat.epoch !== null ? { epoch: chat.epoch, cursor: chat.transcript.lastCursor } : null;
    if (!held) chat.history = { kind: "loading" };
    this.changed();
    try {
      const result = await connection.open(held ? { hostId, sessionId, have: held } : { hostId, sessionId, window: { last: historyPageSize } });
      if (this.opened?.sessionId !== sessionId || this.chats.get(sessionId) !== chat) return;
      if (!held) {
        chat.transcript = null;
        chat.older = result.older;
      }
      chat.epoch = result.epoch;
      this.changeChat(sessionId, transcript => {
        transcript.append(result.records);
        for (const { slot, snapshot } of result.progress) transcript.progress(slot, snapshot);
        const status = session?.status;
        if (status) transcript.settle(status === "working");
      });
      chat.history = { kind: "loaded", records: chat.transcript!.records.length, hasOlder: chat.older !== null };
    } catch (error) {
      if (this.opened?.sessionId === sessionId) chat.history = { kind: "failed", message: describe(error) };
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
      }
      chat.history = { kind: "loaded", records: chat.transcript?.records.length ?? 0, hasOlder: chat.older !== null };
    } catch (error) {
      chat.history = { kind: "loaded", records, hasOlder: true };
      this.failure = describe(error);
    }
    this.changed();
  }

  private closeOpened(): void {
    if (this.opened) this.connection?.closeSession(this.opened.sessionId);
    this.opened = null;
  }

  // MARK: - Selecting

  /** Shows a chat, on whichever Mac it is. */
  selectChat(hostId: string, sessionId: string): void {
    if (hostId !== this.openHostId) this.openMac(hostId);
    this.selection = { kind: "chat", sessionId };
    this.failure = null;
    if (this.opened?.sessionId !== sessionId) void this.openChat(sessionId);
    this.changed();
  }

  /** A new chat on `hostId` (the open Mac when not given), in `workspaceId` if chosen. */
  newChat(hostId: string | null = null, workspaceId: string | null = null): void {
    if (hostId && hostId !== this.openHostId) this.openMac(hostId);
    this.selection = { kind: "new", workspaceId };
    this.closeOpened();
    this.failure = null;
    this.changed();
  }

  /**
   * The Mac a new chat starts on, chosen by the message box: what is typed comes along, and the
   * Workspace goes back to the Mac's Home, since Workspaces are a Mac's own.
   */
  chooseHost(hostId: string): void {
    const selection = this.selection;
    if (selection?.kind !== "new" || hostId === this.openHostId || !this.hosts.some(host => host.hostId === hostId)) return;
    const text = this.draft(selection);
    this.setDraft("", selection);
    this.openMac(hostId);
    if (text) this.setDraft(text);
    this.changed();
  }

  dismissFailure(): void {
    this.failure = null;
    this.changed();
  }

  // MARK: - Drafts and sending

  private draftKey(selection: Selection): string {
    return selection.kind === "chat" ? `${this.openHostId}/chat/${selection.sessionId}` : `${this.openHostId}/new/${selection.workspaceId ?? ""}`;
  }

  draft(selection: Selection | null = this.selection): string {
    return selection ? this.drafts.get(this.draftKey(selection)) ?? "" : "";
  }

  setDraft(text: string, selection: Selection | null = this.selection): void {
    if (!selection) return;
    const key = this.draftKey(selection);
    if (text) this.drafts.set(key, text);
    else this.drafts.delete(key);
    this.changed();
  }

  /**
   * Sends what is typed. On a new chat the first message brings the chat into being: in the
   * Workspace chosen for it, or in the Mac's Home Workspace.
   */
  async send(): Promise<SendOutcome> {
    const selection = this.selection;
    if (this.isSending || !selection || !this.draft(selection).trim()) return { kind: "failed" };
    if (selection.kind === "chat") return this.sending(() => this.prompt(selection));
    return this.startChat(selection);
  }

  private startChat(draft: Extract<Selection, { kind: "new" }>): Promise<SendOutcome> {
    return this.sending(async () => {
      const host = this.openHost;
      if (!host || !this.ready()) return { kind: "failed" };
      const target = this.reference(host);
      let created: CreatedSession;
      try {
        ({ session: created } = draft.workspaceId
          ? await this.connection!.command("axo.remote.workspace.session.create", { target, workspaceId: draft.workspaceId })
          : await this.connection!.command("axo.remote.session.create", { target }));
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
          workspaceId: created.workspaceId ?? null,
          workspaceName: created.workspaceName ?? null,
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

  private ready(): boolean {
    const host = this.openHost;
    if (!host) return false;
    if (host.status !== "online") {
      this.report(`${host.label} is offline.`);
      return false;
    }
    if (!this.connection?.active) {
      this.report("Not connected yet. Try again in a moment.");
      return false;
    }
    return true;
  }

  private report(message: string): SendOutcome {
    this.failure = message;
    this.changed();
    return { kind: "failed" };
  }

  /** Sends a message to a chat. It shows as pending until the agent's own record of it arrives. */
  private async prompt(selection: Selection & { kind: "chat" }): Promise<SendOutcome> {
    const host = this.openHost;
    const text = this.draft(selection).trim();
    if (!host || !text || !this.ready()) return { kind: "failed" };
    const chat = this.chat(selection.sessionId);
    const pending: PendingPrompt = { id: this.newId(), text, state: "sending" };
    chat.pending = [...chat.pending, pending];
    this.setDraft("", selection);
    let outcome: SendOutcome;
    try {
      await this.connection!.command("axo.remote.session.prompt", { target: this.reference(host), sessionId: selection.sessionId, text });
      this.failure = null;
      outcome = { kind: "sent" };
    } catch (error) {
      outcome = deliveryUncertain(error) ? { kind: "uncertain" } : { kind: "failed" };
      this.failure = outcome.kind === "uncertain"
        ? `The connection to ${host.label} dropped while sending. Check the chat before sending again.`
        : `Not sent: ${describe(error)}`;
    }
    const index = chat.pending.findIndex(candidate => candidate.id === pending.id);
    if (index >= 0) {
      if (outcome.kind === "sent") chat.pending[index]!.state = chat.transcript?.working ? "queued" : "sent";
      else if (outcome.kind === "uncertain") chat.pending[index]!.state = "uncertain";
      else {
        chat.pending = chat.pending.filter(candidate => candidate.id !== pending.id);
        if (!this.draft(selection)) this.setDraft(text, selection);
      }
    }
    this.changed();
    return outcome;
  }

  /** Takes a message marked uncertain off the screen, once the person has checked. */
  dismissPending(sessionId: string, pendingId: string): void {
    const chat = this.chats.get(sessionId);
    if (!chat) return;
    chat.pending = chat.pending.filter(prompt => prompt.id !== pendingId);
    this.changed();
  }

  /** Stops the reply in progress, as Escape does on the Mac. */
  async stop(sessionId: string): Promise<void> {
    const host = this.openHost;
    const chat = this.chat(sessionId);
    if (!host || !chat.transcript?.working || chat.stopping || !this.ready()) return;
    chat.stopping = true;
    this.changed();
    try {
      await this.connection!.command("axo.remote.session.key", { target: this.reference(host), sessionId, key: "escape" });
    } catch (error) {
      chat.stopping = false;
      this.failure = describe(error);
    }
    this.changed();
  }

  /** Answers the agent's question: yes is Enter, no is Escape, words are sent as a prompt is. */
  async answer(sessionId: string, answer: Answer): Promise<void> {
    const host = this.openHost;
    if (!host || !this.chats.get(sessionId)?.transcript?.question || !this.ready()) return;
    const target = this.reference(host);
    try {
      if (answer.kind === "text") await this.connection!.command("axo.remote.session.prompt", { target, sessionId, text: answer.text });
      else await this.connection!.command("axo.remote.session.key", { target, sessionId, key: answer.kind === "yes" ? "enter" : "escape" });
      this.failure = null;
    } catch (error) {
      this.failure = describe(error);
    }
    this.changed();
  }
}
