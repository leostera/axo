import type { Host, HostEvent, HostRef, Session } from "@axo/app";
import type { PiEventPageResult } from "@axo/protocol";
import { ChatTranscript, type PiEventRecord } from "./transcript.ts";

/**
 * The browser's chats: a port of the phone's `PhoneWorkbench` and `HostWorkbenchModel`. One Mac
 * is open at a time and followed live; the others are shown as last listed. A chat is a Session
 * with Pi in it; a new chat exists only once its first message is sent. History is read newest
 * first, a page at a time, and only as far back as the person scrolls.
 */

export interface Workspace {
  readonly workspaceId: string;
  readonly name: string;
  /** The Home Workspace, which is listed first. */
  readonly home?: true;
}

/** What the workbench needs of a live connection to a Mac (`HostRelayConnection`). */
export interface MacConnection {
  readonly active: boolean;
  call(method: "axo.remote.workspace.list", params: { target: HostRef }): Promise<{ workspaces: Workspace[] }>;
  call(method: "axo.remote.session.create", params: { target: HostRef }): Promise<{ session: Session }>;
  call(method: "axo.remote.workspace.session.create", params: { target: HostRef; workspaceId: string }): Promise<{ session: Session }>;
  call(method: "axo.remote.session.prompt", params: { target: HostRef; sessionId: number; text: string }): Promise<unknown>;
  call(method: "axo.remote.session.key", params: { target: HostRef; sessionId: number; key: "escape" | "enter" }): Promise<unknown>;
  close(): void;
}

/** What the workbench needs of the account's API (`RemoteAxoApi`). */
export interface ChatBackend {
  listHosts(signal?: AbortSignal): Promise<Host[]>;
  listPiEvents(reference: HostRef, sessionId: number, before: number, limit: number, signal?: AbortSignal): Promise<PiEventPageResult>;
  connectHost(reference: HostRef, onEvent: (event: HostEvent) => void, onClose: (error: Error) => void): Promise<MacConnection>;
}

export type Link = "idle" | "connecting" | "connected" | "reconnecting" | "offline";

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
  | { kind: "loaded"; events: number; hasOlder: boolean }
  | { kind: "loadingOlder"; events: number }
  | { kind: "failed"; message: string };

/** How far back a chat's stored history has been read. */
interface StoredHistory {
  events: number;
  newestId: number;
  olderCursor: number | null;
}

export class Chat {
  transcript: ChatTranscript | null = null;
  pending: PendingPrompt[] = [];
  history: HistoryState = { kind: "none" };
  stopping = false;
  stored: StoredHistory | null = null;
}

/**
 * The open chat, or a new one waiting for its first message on the open Mac: in the Workspace
 * chosen for it, or with none chosen in the Mac's Home Workspace.
 */
export type Selection = { kind: "chat"; sessionId: number } | { kind: "new"; workspaceId: string | null };

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

export interface ChatMenuSection {
  readonly id: string;
  readonly title: string;
  readonly host: Host;
  readonly workspaceId: string | null;
  readonly chats: ChatMenuEntry[];
}

export const historyPageSize = 50;
const defaultReconnectDelays = [500, 1_000, 2_000, 5_000, 15_000];

export function isChat(session: Session): boolean {
  return session.hasAgent !== false;
}

export function chatTitle(session: Session | null | undefined): string {
  return session ? session.name ?? `Session ${session.sessionId}` : "New chat";
}

function activity(session: Session): number {
  const time = Date.parse(session.updatedAt);
  return Number.isNaN(time) ? 0 : time;
}

/** Last active first; among chats as recent, the newer one first. */
function moreRecent(a: ChatMenuEntry, b: ChatMenuEntry): number {
  return activity(b.session) - activity(a.session)
    || b.session.sessionId - a.session.sessionId
    || a.host.hostId.localeCompare(b.host.hostId);
}

/**
 * The menu's chats, grouped by Workspace: the open Mac's Home Workspace first, then the rest in
 * alphabetical order, so they stay where they are as chats come and go, and the chats within each
 * the most recently active first. The open Mac's Workspaces with no chat yet are listed in their
 * place. With several Macs a Workspace's title names its Mac.
 */
export function chatMenu(hosts: readonly Host[], openHostId: string | null, workspaces: readonly Workspace[]): ChatMenuSection[] {
  const title = (workspace: string, host: Host) => hosts.length > 1 ? `${workspace} · ${host.label}` : workspace;
  const grouped = new Map<string, { title: string; host: Host; workspaceId: string | null; chats: ChatMenuEntry[] }>();
  for (const host of hosts) {
    for (const session of host.sessions) {
      if (!isChat(session)) continue;
      const workspace = session.workspaceName ?? "Chats";
      const key = `${host.hostId}/${workspace}`;
      const group = grouped.get(key) ?? { title: title(workspace, host), host, workspaceId: session.workspaceId ?? null, chats: [] };
      group.chats.push({ host, session });
      grouped.set(key, group);
    }
  }
  const sections: ChatMenuSection[] = [...grouped].map(([id, group]) => ({ id, ...group, chats: group.chats.sort(moreRecent) }));
  const open = hosts.find(host => host.hostId === openHostId);
  if (open) {
    for (const workspace of workspaces) {
      const id = `${open.hostId}/${workspace.name}`;
      if (!grouped.has(id)) sections.push({ id, title: title(workspace.name, open), host: open, workspaceId: workspace.workspaceId, chats: [] });
    }
  }
  const homeIds = new Set(open ? workspaces.filter(workspace => workspace.home).map(home => `${open.hostId}/${home.name}`) : []);
  const isHome = (section: ChatMenuSection) => homeIds.has(section.id) ? 0 : 1;
  return sections.sort((a, b) => isHome(a) - isHome(b) || alphabetical.compare(a.title, b.title) || a.id.localeCompare(b.id));
}

/** Chats active within this long are listed; older ones wait behind "Show older chats". */
export const recentChatWindowMs = 8 * 60 * 60 * 1000;

/**
 * The chats of a section worth listing before older ones are asked for: those active in the last
 * eight hours, any the agent is working in or needs the person for, and any `keep` names (the open
 * chat), most recently active first.
 */
export function recentChats(section: ChatMenuSection, now: number, keep: (entry: ChatMenuEntry) => boolean = () => false): ChatMenuEntry[] {
  return section.chats.filter(entry =>
    now - activity(entry.session) <= recentChatWindowMs
    || entry.session.status === "working"
    || entry.session.status === "needsAttention"
    || keep(entry));
}

/** As people read them: case and accents aside, numbers by value. */
const alphabetical = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

/** The request may have reached the Mac although no answer came back. */
function deliveryUncertain(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const code = (error as { code?: unknown }).code;
  if (typeof code === "number") return code === -32004 && error.message.includes("reconcile");
  return /timed out|closed|WebSocket/i.test(error.message);
}

function describe(error: unknown): string {
  if (error instanceof Error && "status" in error && error.status === 401) return "Your sign-in expired. Sign in again.";
  return error instanceof Error ? error.message : String(error);
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

  private readonly chats = new Map<number, Chat>();
  private readonly drafts = new Map<string, string>();
  private readonly listeners = new Set<() => void>();
  private connection: MacConnection | null = null;
  /** Each connection attempt's own number: what an older attempt finishes is ignored. */
  private generation = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  private readonly backend: ChatBackend;
  private readonly reconnectDelays: readonly number[];
  private readonly newId: () => string;

  constructor(
    backend: ChatBackend,
    reconnectDelays: readonly number[] = defaultReconnectDelays,
    newId: () => string = () => crypto.randomUUID(),
  ) {
    this.backend = backend;
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

  chat(sessionId: number): Chat {
    let chat = this.chats.get(sessionId);
    if (!chat) {
      chat = new Chat();
      this.chats.set(sessionId, chat);
    }
    return chat;
  }

  sections(): ChatMenuSection[] {
    return chatMenu(this.hosts, this.openHostId, this.workspaces);
  }

  // MARK: - Macs

  /** Reads the account's Macs. The first time, opens one: the first online, or else the first. */
  async refreshHosts(signal?: AbortSignal): Promise<void> {
    try {
      const listed = await this.backend.listHosts(signal);
      if (signal?.aborted) return;
      this.hosts = listed.map(host => {
        // The open Mac's chats come from its live events, which may be newer than the listing.
        const open = host.hostId === this.openHostId && this.link === "connected" ? this.openHost : null;
        return open && open.hostGeneration === host.hostGeneration ? { ...host, sessions: open.sessions } : host;
      });
      this.hostsPhase = "loaded";
      const open = this.openHost;
      if (!open) {
        const next = listed.find(host => host.status === "online") ?? listed[0];
        if (next) this.openMac(next.hostId);
      } else if (open.status === "online" && (this.link === "offline" || this.link === "idle")) {
        this.connect();
      }
    } catch (error) {
      if (signal?.aborted) return;
      if (this.hostsPhase !== "loaded") this.hostsPhase = "failed";
      this.failure = describe(error);
    }
    this.changed();
  }

  /** Opens a Mac: follows it live and starts a new chat on it. */
  openMac(hostId: string): void {
    if (hostId === this.openHostId && this.link !== "offline" && this.link !== "idle") return;
    this.disconnect();
    this.openHostId = hostId;
    this.chats.clear();
    this.workspaces = [];
    this.selection = { kind: "new", workspaceId: null };
    this.failure = null;
    this.connect();
    this.changed();
  }

  private connect(): void {
    const host = this.openHost;
    this.clearReconnect();
    if (!host || host.status !== "online") {
      this.link = "offline";
      return;
    }
    const generation = ++this.generation;
    const reference: HostRef = { hostId: host.hostId, hostGeneration: host.hostGeneration };
    this.link = this.link === "reconnecting" ? "reconnecting" : "connecting";
    void this.backend.connectHost(
      reference,
      event => { if (generation === this.generation) this.apply(event); },
      () => { if (generation === this.generation) this.connectionLost(); },
    ).then(connection => {
      if (generation !== this.generation) {
        connection.close();
        return;
      }
      this.connection = connection;
      const recovering = this.link === "reconnecting";
      this.link = "connected";
      this.failure = null;
      this.reconnectAttempt = 0;
      void this.refreshWorkspaces();
      if (recovering) void this.catchUp();
      else if (this.selection?.kind === "chat") void this.loadHistory(this.selection.sessionId);
      this.changed();
    }, error => {
      if (generation !== this.generation) return;
      this.failure = describe(error);
      this.scheduleReconnect();
      this.changed();
    });
  }

  private reconnectAttempt = 0;

  private connectionLost(): void {
    this.connection = null;
    this.scheduleReconnect();
    this.changed();
  }

  /** Tries again with growing pauses. Events missed meanwhile are in the stored history. */
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

  /** After a gap: the open chat reads its newest history again, the others will when opened. */
  private async catchUp(): Promise<void> {
    const selected = this.selection?.kind === "chat" ? this.selection.sessionId : null;
    for (const [id, chat] of this.chats) if (id !== selected) chat.history = { kind: "none" };
    for (const session of this.openHost?.sessions ?? []) {
      const chat = this.chats.get(session.sessionId);
      if (!chat?.transcript || !session.status) continue;
      const working = session.status === "working";
      chat.transcript.settle(working);
      if (!working) chat.stopping = false;
    }
    await this.refreshHosts();
    if (selected !== null) await this.loadHistory(selected);
  }

  async refreshWorkspaces(): Promise<Workspace[] | null> {
    const host = this.openHost;
    if (!host || !this.connection?.active) return null;
    try {
      const { workspaces } = await this.connection.call("axo.remote.workspace.list", { target: this.reference(host) });
      if (host.hostId !== this.openHostId) return null;
      this.workspaces = workspaces;
      this.changed();
      return workspaces;
    } catch {
      return null;
    }
  }

  private disconnect(): void {
    this.generation += 1;
    this.clearReconnect();
    this.connection?.close();
    this.connection = null;
    this.link = "idle";
    this.reconnectAttempt = 0;
  }

  dispose(): void {
    this.disconnect();
    this.listeners.clear();
  }

  private reference(host: Host): HostRef {
    return { hostId: host.hostId, hostGeneration: host.hostGeneration };
  }

  // MARK: - Events

  apply(event: HostEvent): void {
    if (event.hostId !== this.openHostId) return;
    if (event.type === "host.presence") {
      this.updateOpenHost(host => ({ ...host, status: event.status, stale: event.status === "offline", lastSeenAt: event.observedAt }));
      this.changed();
      return;
    }
    const data = event.event;
    switch (data.type) {
      case "session.snapshot":
        this.updateOpenHost(host => {
          const index = host.sessions.findIndex(session => session.sessionId === data.snapshot.sessionId);
          const sessions = index < 0
            ? [...host.sessions, data.snapshot].sort((a, b) => a.sessionId - b.sessionId)
            : host.sessions.map((session, at) => at === index ? data.snapshot : session);
          return { ...host, sessions };
        });
        break;
      case "session.removed":
        this.updateOpenHost(host => ({ ...host, sessions: host.sessions.filter(session => session.sessionId !== data.sessionId) }));
        this.chats.delete(data.sessionId);
        if (this.selection?.kind === "chat" && this.selection.sessionId === data.sessionId) this.selection = { kind: "new", workspaceId: null };
        break;
      case "pi.event":
        this.changeChat(data.sessionId, transcript => transcript.apply(data));
        break;
      default:
        // The browser follows chats, not terminals.
        return;
    }
    this.changed();
  }

  private updateOpenHost(change: (host: Host) => Host): void {
    this.hosts = this.hosts.map(host => host.hostId === this.openHostId ? change(host) : host);
  }

  /**
   * Changes a chat, then retires the pending messages its newest user messages account for: the
   * one with the same words, or else the oldest the Mac has taken (the agent records them in order).
   */
  private changeChat(sessionId: number, change: (transcript: ChatTranscript) => void): void {
    const chat = this.chat(sessionId);
    const before = chat.pending.length ? new Set(chat.transcript?.messages.map(message => message.id) ?? []) : new Set<string>();
    chat.transcript ??= new ChatTranscript();
    change(chat.transcript);
    if (!chat.transcript.working) chat.stopping = false;
    if (!chat.pending.length) return;
    const messages = chat.transcript.messages;
    let start = 0;
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      if (before.has(messages[index]!.id)) {
        start = index + 1;
        break;
      }
    }
    const pending = [...chat.pending];
    for (const message of messages.slice(start)) {
      if (message.role !== "user") continue;
      const words = message.text.trim();
      const match = pending.findIndex(prompt => prompt.text === words);
      const oldest = pending.findIndex(prompt => prompt.state !== "sending");
      if (match >= 0) pending.splice(match, 1);
      else if (oldest >= 0) pending.splice(oldest, 1);
    }
    chat.pending = pending;
  }

  // MARK: - History

  /** Reads the newest page of a chat's stored conversation, in front of what arrived live. */
  async loadHistory(sessionId: number): Promise<void> {
    const host = this.openHost;
    const chat = this.chat(sessionId);
    if (!host || chat.history.kind === "loading" || chat.history.kind === "loadingOlder") return;
    chat.history = { kind: "loading" };
    this.changed();
    try {
      const page = await this.backend.listPiEvents(this.reference(host), sessionId, 0, historyPageSize);
      if (this.chats.get(sessionId) !== chat) return;
      const parsed = ChatTranscript.fromHistory(records(page));
      const newest = page.events[0]?.id ?? 0;
      const stored = chat.stored;
      // A page reaching back to what was read before goes on from it; one that does not starts again.
      const reachesBack = stored !== null && (page.events.at(-1)?.id ?? Number.MAX_SAFE_INTEGER) <= stored.newestId;
      chat.stored = stored && reachesBack
        ? { events: stored.events + page.events.filter(event => event.id > stored.newestId).length, newestId: Math.max(newest, stored.newestId), olderCursor: stored.olderCursor }
        : { events: page.events.length, newestId: newest, olderCursor: page.next };
      this.changeChat(sessionId, transcript => transcript.mergeNewest(parsed, reachesBack));
      chat.history = { kind: "loaded", events: chat.stored.events, hasOlder: chat.stored.olderCursor !== null };
    } catch (error) {
      chat.history = { kind: "failed", message: describe(error) };
    }
    this.changed();
  }

  /** Reads the page before the oldest one shown; nothing when this is the beginning. */
  async loadOlderHistory(sessionId: number): Promise<void> {
    const host = this.openHost;
    const chat = this.chat(sessionId);
    const stored = chat.stored;
    if (!host || chat.history.kind !== "loaded" || !chat.history.hasOlder || stored?.olderCursor == null) return;
    const events = chat.history.events;
    chat.history = { kind: "loadingOlder", events };
    this.changed();
    try {
      const page = await this.backend.listPiEvents(this.reference(host), sessionId, stored.olderCursor, historyPageSize);
      if (this.chats.get(sessionId) !== chat) return;
      chat.stored = { events: stored.events + page.events.length, newestId: stored.newestId, olderCursor: page.next };
      this.changeChat(sessionId, transcript => transcript.prependOlder(ChatTranscript.fromHistory(records(page))));
      chat.history = { kind: "loaded", events: chat.stored.events, hasOlder: page.next !== null };
    } catch (error) {
      chat.history = { kind: "loaded", events, hasOlder: true };
      this.failure = describe(error);
    }
    this.changed();
  }

  // MARK: - Selecting

  /** Opens a chat, on whichever Mac it is. */
  selectChat(hostId: string, sessionId: number): void {
    if (hostId !== this.openHostId) this.openMac(hostId);
    this.selection = { kind: "chat", sessionId };
    this.failure = null;
    const chat = this.chat(sessionId);
    if (chat.history.kind === "none" || chat.history.kind === "failed") void this.loadHistory(sessionId);
    this.changed();
  }

  /** A new chat on `hostId` (the open Mac when not given), in `workspaceId` if chosen. */
  newChat(hostId: string | null = null, workspaceId: string | null = null): void {
    if (hostId && hostId !== this.openHostId) this.openMac(hostId);
    this.selection = { kind: "new", workspaceId };
    this.failure = null;
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
      let session: Session;
      try {
        ({ session } = draft.workspaceId
          ? await this.connection!.call("axo.remote.workspace.session.create", { target, workspaceId: draft.workspaceId })
          : await this.connection!.call("axo.remote.session.create", { target }));
      } catch (error) {
        return this.report(`Could not start the chat: ${describe(error)}`);
      }
      this.apply({ type: "host.data", hostId: host.hostId, hostGeneration: host.hostGeneration, event: { type: "session.snapshot", snapshot: session } } as HostEvent);
      // The words move to the chat they started; a refusal leaves them in its box.
      const chat: Selection = { kind: "chat", sessionId: session.sessionId };
      this.setDraft(this.draft(draft), chat);
      this.setDraft("", draft);
      this.selection = chat;
      this.chat(session.sessionId).history = { kind: "loaded", events: 0, hasOlder: false };
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
      this.report(`Not connected to ${host.label} yet. Try again in a moment.`);
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
      await this.connection!.call("axo.remote.session.prompt", { target: this.reference(host), sessionId: selection.sessionId, text });
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
  dismissPending(sessionId: number, pendingId: string): void {
    const chat = this.chats.get(sessionId);
    if (!chat) return;
    chat.pending = chat.pending.filter(prompt => prompt.id !== pendingId);
    this.changed();
  }

  /** Stops the reply in progress, as Escape does on the Mac. */
  async stop(sessionId: number): Promise<void> {
    const host = this.openHost;
    const chat = this.chat(sessionId);
    if (!host || !chat.transcript?.working || chat.stopping || !this.ready()) return;
    chat.stopping = true;
    this.changed();
    try {
      await this.connection!.call("axo.remote.session.key", { target: this.reference(host), sessionId, key: "escape" });
    } catch (error) {
      chat.stopping = false;
      this.failure = describe(error);
    }
    this.changed();
  }

  /** Answers Pi's question: yes is Enter, no is Escape, words are sent as a prompt is. */
  async answer(sessionId: number, answer: Answer): Promise<void> {
    const host = this.openHost;
    if (!host || !this.chats.get(sessionId)?.transcript?.question || !this.ready()) return;
    const target = this.reference(host);
    try {
      if (answer.kind === "text") await this.connection!.call("axo.remote.session.prompt", { target, sessionId, text: answer.text });
      else await this.connection!.call("axo.remote.session.key", { target, sessionId, key: answer.kind === "yes" ? "enter" : "escape" });
      this.failure = null;
    } catch (error) {
      this.failure = describe(error);
    }
    this.changed();
  }
}

/** A page comes newest first; a transcript is built oldest first. */
function records(page: PiEventPageResult): PiEventRecord[] {
  return [...page.events].reverse();
}
