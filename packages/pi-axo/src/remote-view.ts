/**
 * Another Mac's Session, in a Pi on this Mac (RFD0024, RFD0026).
 *
 * Axod starts Pi with this extension in remote mode for a Session that runs on another Mac. Pi
 * draws it with its own components:
 *
 * - **History** is a session file built from this Mac's copy (a view), opened with Pi's
 *   `switchSession`. Each redraw opens a fresh view; the editor's text stays.
 * - **Live turns** play in this Pi: for each user message the other Mac writes, pi-axo starts a
 *   turn, the `axo-remote` provider answers with that Mac's assistant messages as they are
 *   written, and proxy tools wait for its tool results (see remote-mirror.ts). When the turn
 *   ends here, a redraw replaces it with the records themselves.
 *
 * Nothing runs on this Mac: no tool executes, and no turn starts but a mirrored one. What is
 * typed goes to the other Mac, which alone writes the log. A prompt is pending until its receipt,
 * which that Mac's pi-axo writes just before the prompt, shows in the copy; a prompt whose fate is
 * unknown is sent again with the same commandId, which that Mac takes at most once.
 *
 * `RemoteSession` is the model, free of Pi; `installRemoteView` wires it to Pi.
 */
import { randomUUID } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { AssistantMessageEventStream, Model, Api, SimpleStreamOptions } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { AxodCallError, callAxod } from "./axod-client.js";
import { RECEIPT_ENTRY } from "./remote-commands.js";
import { AssistantStream, MirrorTurn, type MirrorSource } from "./remote-mirror.js";

/** The provider whose one model is the other Mac. */
export const REMOTE_PROVIDER = "axo-remote";
const REMOTE_API = "axo-remote-mirror";
/** Opens a fresh view of the copy. Typed by hand, it redraws too. */
export const REDRAW_COMMAND = "axo-redraw";

const WATCH_TIMEOUT_MS = 15_000;
/** The whole copy, a page at a time: Pi draws all of it, as on the other Mac. */
const WATCH_WINDOW = Number.MAX_SAFE_INTEGER;
const COMMAND_TIMEOUT_MS = 40_000;
const RETRY_DELAY_MS = 3_000;
const MAX_RETRIES = 40;
/** How long a turn here may outlive the other Mac's before it is given up. */
const STALE_TURN_MS = 3_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

/** The tools Pi draws with their own renderers; any other name gets Pi's generic one. */
const BUILTIN_TOOLS = ["bash", "read", "edit", "write", "grep", "find", "ls"] as const;

export interface RemoteViewConfig {
  readonly socket: string;
  readonly hostId: string;
  readonly hostLabel: string;
  readonly sessionId: string;
}

/** Remote mode's environment, or null when this Pi runs a Session of this Mac. */
export function parseRemoteViewConfig(environment: NodeJS.ProcessEnv): RemoteViewConfig | null {
  const { AXO_SOCKET: socket, AXO_REMOTE_HOST_ID: hostId, AXO_REMOTE_SESSION_ID: sessionId } = environment;
  if (!socket || !hostId || !sessionId || !socket.startsWith("/")) return null;
  if (!UUID.test(hostId) || !UUID.test(sessionId)) return null;
  const hostLabel = environment.AXO_REMOTE_HOST_LABEL?.trim() || "the other Mac";
  return { socket, hostId: hostId.toLowerCase(), hostLabel, sessionId: sessionId.toLowerCase() };
}

// ─── The model ──────────────────────────────────────────────────────────────

type Json = Record<string, unknown>;

export interface PeerRecord {
  readonly cursor: number;
  readonly line: string;
}

/** What `axo.peer.session.watch` answers. */
export interface PeerSessionView {
  readonly version: number;
  readonly epoch: number | null;
  readonly cursor: number;
  readonly reset: boolean;
  readonly records: readonly PeerRecord[];
  readonly more: boolean;
  readonly progress: readonly { slot: string; snapshot: unknown }[];
  readonly status: string | null;
  readonly hostLabel: string;
  readonly hostOnline: boolean;
  readonly connected: boolean;
}

export type PendingState = "sending" | "sent" | "queued" | "uncertain";

/** The most of a client's own prompts one stop names (`axo_relay::MAX_STOP_COMMANDS`). */
const MAX_STOP_COMMANDS = 32;

/** What a client saw of the run it asks to stop; at least one is set. */
interface StopTarget {
  turnId?: string;
  seen?: string;
  commandIds?: string[];
}

export interface PendingPrompt {
  readonly commandId: string;
  readonly text: string;
  state: PendingState;
}

/** What applying a view changed. */
export interface ViewChange {
  /** The copy was cut back or replaced: everything drawn of it is stale. */
  readonly reset: boolean;
  readonly added: number;
}

/** How a send ended, for the caller to show. */
export type SendOutcome =
  | { kind: "accepted" }
  | { kind: "uncertain" }
  /** Refused on its first try: nothing ran, so the words go back in the editor. */
  | { kind: "refused"; message: string; offline: boolean };

/** What the model needs from Axod. */
export interface RemoteLink {
  command(method: string, params: Record<string, unknown>): Promise<unknown>;
}

function asObject(value: unknown): Json | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Json : null;
}

function parseEntry(line: string): Json | null {
  try {
    return asObject(JSON.parse(line));
  } catch {
    return null;
  }
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map(block => asObject(block))
    .filter((block): block is Json => block?.type === "text" && typeof block.text === "string")
    .map(block => block.text as string)
    .join("\n");
}

function roleOf(entry: Json | null): unknown {
  return entry?.type === "message" ? asObject(entry.message)?.role : undefined;
}

/** Errors that leave a command's outcome unknown: it may have reached the other Mac. */
function outcomeUnknown(error: unknown): boolean {
  if (error instanceof AxodCallError) return error.code === null || error.code === -32004;
  return true;
}

function errorCode(error: unknown): number | null {
  return error instanceof AxodCallError ? error.code : null;
}

export class RemoteSession {
  epoch: number | null = null;
  cursor = 0;
  version = 0;
  /** The copy's records, in order: record n (cursor n) is `records[n - 1]`. */
  records: string[] = [];
  /** The same, parsed. */
  entries: (Json | null)[] = [];
  /** Whether the whole copy has been read; until then nothing is drawn. */
  loaded = false;
  working = false;
  hostLabel: string;
  hostOnline = true;
  connected = true;
  progress = new Map<string, unknown>();
  pending: PendingPrompt[] = [];
  /** The entry id of the newest user message: the turn a stop names. */
  lastUserEntry: string | null = null;
  stopping = false;
  private receipt: string | null = null;
  private readonly delivered = new Set<string>();
  private readonly retries = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(
    private readonly config: RemoteViewConfig,
    private readonly link: RemoteLink,
    private readonly changed: () => void = () => {},
    private readonly retryDelayMs = RETRY_DELAY_MS,
    private readonly newId: () => string = randomUUID,
  ) {
    this.hostLabel = config.hostLabel;
  }

  /** Takes the next view of the copy. */
  apply(view: PeerSessionView): ViewChange {
    this.version = view.version;
    this.hostLabel = view.hostLabel || this.hostLabel;
    this.hostOnline = view.hostOnline;
    this.connected = view.connected;
    this.working = view.status === "working";
    if (!this.working) this.stopping = false;
    this.progress = new Map(view.progress.map(({ slot, snapshot }) => [slot, snapshot]));
    if (view.reset) {
      this.records = [];
      this.entries = [];
      this.receipt = null;
      this.lastUserEntry = null;
    }
    this.epoch = view.epoch;
    this.cursor = view.cursor;
    let added = 0;
    for (const record of view.records) {
      // Each record has its place; one already held, or past a gap, is not this copy's next.
      if (record.cursor !== this.records.length + 1) continue;
      const entry = parseEntry(record.line);
      this.records.push(record.line);
      this.entries.push(entry);
      added += 1;
      if (entry?.type === "custom" && entry.customType === RECEIPT_ENTRY) {
        const commandId = asObject(entry.data)?.commandId;
        if (typeof commandId === "string") this.receipt = commandId;
      } else if (roleOf(entry) === "user") {
        this.lastUserEntry = typeof entry?.id === "string" ? entry.id : null;
        if (this.receipt) this.delivered.add(this.receipt);
        this.receipt = null;
      }
    }
    this.loaded = !view.more;
    this.retireDelivered();
    return { reset: view.reset, added };
  }

  /** The newest user message whose turn the copy has not closed, or -1. */
  openTurn(): number {
    for (let index = this.entries.length - 1; index >= 0; index -= 1) {
      const entry = this.entries[index] ?? null;
      const role = roleOf(entry);
      if (role === "assistant" && asObject(entry?.message)?.stopReason !== "toolUse") return -1;
      if (role === "user") return index;
    }
    return -1;
  }

  private retireDelivered(): void {
    const landed = this.pending.filter(prompt => this.delivered.has(prompt.commandId));
    if (!landed.length) return;
    for (const prompt of landed) this.cancelRetry(prompt.commandId);
    this.pending = this.pending.filter(prompt => !this.delivered.has(prompt.commandId));
  }

  /** Sends what was typed to the other Mac, as a prompt with a fresh commandId. */
  async send(text: string): Promise<SendOutcome> {
    const prompt: PendingPrompt = { commandId: this.newId(), text, state: "sending" };
    this.pending = [...this.pending, prompt];
    this.changed();
    const outcome = await this.deliver(prompt, 0);
    if (outcome.kind === "refused") this.pending = this.pending.filter(candidate => candidate !== prompt);
    this.changed();
    return outcome;
  }

  private async deliver(prompt: PendingPrompt, attempt: number): Promise<SendOutcome> {
    let outcome: SendOutcome;
    try {
      await this.link.command("axo.remote.session.prompt", { sessionId: this.config.sessionId, text: prompt.text, commandId: prompt.commandId });
      outcome = { kind: "accepted" };
    } catch (error) {
      const offline = errorCode(error) === -32005;
      // A refusal after an unknown outcome proves nothing: the first try may still land.
      outcome = outcomeUnknown(error) || (attempt > 0 && offline)
        ? { kind: "uncertain" }
        : { kind: "refused", message: error instanceof Error ? error.message : String(error), offline };
    }
    if (!this.pending.includes(prompt)) return outcome;
    if (outcome.kind === "accepted") prompt.state = this.working ? "queued" : "sent";
    else if (outcome.kind === "uncertain" || attempt > 0) {
      prompt.state = "uncertain";
      if (attempt < MAX_RETRIES) this.scheduleRetry(prompt, attempt + 1);
    }
    return outcome;
  }

  private scheduleRetry(prompt: PendingPrompt, attempt: number): void {
    this.cancelRetry(prompt.commandId);
    this.retries.set(prompt.commandId, setTimeout(() => {
      this.retries.delete(prompt.commandId);
      if (!this.pending.includes(prompt)) return;
      void this.deliver(prompt, attempt).then(() => this.changed());
    }, this.retryDelayMs));
  }

  private cancelRetry(commandId: string): void {
    const timer = this.retries.get(commandId);
    if (timer !== undefined) clearTimeout(timer);
    this.retries.delete(commandId);
  }

  /**
   * Stops the run shown running, by what this copy saw of it: its user message, the newest entry
   * held (of the run however long it is), and this Mac's own prompts, which name a run before
   * any of its records arrive. A run none of these belong to carries on.
   */
  async stop(): Promise<boolean> {
    const target = this.stopTarget();
    if (!this.working || !target || this.stopping) return false;
    this.stopping = true;
    this.changed();
    try {
      await this.link.command("axo.remote.session.stop", { sessionId: this.config.sessionId, ...target });
      return true;
    } catch {
      this.stopping = false;
      this.changed();
      return false;
    }
  }

  /** What a stop names (RFD0024, as amended); null when this copy saw nothing to name. */
  private stopTarget(): StopTarget | null {
    const turnId = this.lastUserEntry ?? undefined;
    const seen = this.newestEntry();
    const commandIds = this.pending.slice(-MAX_STOP_COMMANDS).map(prompt => prompt.commandId);
    if (turnId === undefined && seen === undefined && commandIds.length === 0) return null;
    return {
      ...(turnId === undefined ? {} : { turnId }),
      ...(seen === undefined ? {} : { seen }),
      ...(commandIds.length ? { commandIds } : {}),
    };
  }

  private newestEntry(): string | undefined {
    for (let index = this.entries.length - 1; index >= 0; index -= 1) {
      const id = this.entries[index]?.id;
      if (typeof id === "string") return id;
    }
    return undefined;
  }

  /** Answers the other Mac's question: yes is Enter there, no is Escape. */
  async answer(yes: boolean): Promise<void> {
    await this.link.command("axo.remote.session.key", { sessionId: this.config.sessionId, key: yes ? "enter" : "escape" });
  }

  dispose(): void {
    for (const timer of this.retries.values()) clearTimeout(timer);
    this.retries.clear();
  }
}

// ─── Views ──────────────────────────────────────────────────────────────────

export interface ViewHeader {
  /** The id Pi gives the view's session. */
  readonly id: string;
  /** This Mac's folder for the pane: Pi asks about a working directory it cannot find. */
  readonly cwd: string;
  /** The other Mac as a model: every turn here is answered by it, never by a real model. */
  readonly model: { readonly provider: string; readonly modelId: string };
}

/**
 * The first `end` records of the copy as a Pi session file. Only the header and the model
 * changes differ from the copy; every other entry is the other Mac's own line.
 */
export function buildView(records: readonly string[], end: number, header: ViewHeader, now = new Date()): string {
  const lines = [JSON.stringify({ type: "session", version: 3, id: header.id, timestamp: now.toISOString(), cwd: header.cwd })];
  for (const line of records.slice(0, end)) {
    const entry = parseEntry(line);
    if (!entry || entry.type === "session") continue;
    lines.push(entry.type === "model_change"
      ? JSON.stringify({ ...entry, provider: header.model.provider, modelId: header.model.modelId })
      : line);
  }
  return `${lines.join("\n")}\n`;
}

// ─── Wiring it to Pi ────────────────────────────────────────────────────────

const pendingLabels: Record<PendingState, (host: string) => string> = {
  sending: host => `Sending to ${host}…`,
  sent: host => `Sent to ${host}`,
  queued: host => `Queued on ${host} · runs after the current reply`,
  uncertain: host => `Not confirmed by ${host} yet · trying again`,
};

type Modules = {
  agent: typeof import("@earendil-works/pi-coding-agent");
  ai: typeof import("@earendil-works/pi-ai");
};

/** Pi's modules, loaded inside Pi, which provides them to its extensions. */
async function loadModules(): Promise<Modules> {
  const [agent, ai] = await Promise.all([import("@earendil-works/pi-coding-agent"), import("@earendil-works/pi-ai")]);
  return { agent, ai };
}

/** What a redraw draws, and what runs once it is on screen. */
interface Redraw {
  readonly end: number;
  readonly then?: () => void;
}

/**
 * Lives as long as the pane's Pi: `switchSession` builds a new extension runtime for each view,
 * and each one attaches to this controller (see `installRemoteView`).
 */
class RemoteController implements MirrorSource {
  readonly session: RemoteSession;
  private pi: ExtensionAPI | null = null;
  private ctx: ExtensionContext | null = null;
  private modules: Modules | null = null;
  private watching = false;
  private stopped = false;
  /** The turn playing here, if any. */
  private mirror: MirrorTurn | null = null;
  /** The user message of the latest turn played here, so it is not played twice. */
  private mirroredUser = -1;
  private redrawing: Redraw | null = null;
  /** How many records of the copy the screen shows, or -1 when it shows none of this copy. */
  private shownEnd = -1;
  private views = 0;
  private viewPath: string | null = null;
  /** When the other Mac was first seen idle while a turn plays here. */
  private otherSince: number | null = null;
  /** When the copy or its progress last changed. */
  private lastChange = 0;
  /** How many records the copy had when it was first read whole: later ones arrived live. */
  private firstLoadEnd: number | null = null;
  private readonly proxied = new Set<string>(BUILTIN_TOOLS);
  private readonly failedTools = new Set<string>();
  private readonly waiters = new Set<() => void>();
  private readonly timer: ReturnType<typeof setInterval>;

  constructor(private readonly config: RemoteViewConfig, link: RemoteLink) {
    this.session = new RemoteSession(config, link, () => this.refresh());
    this.timer = setInterval(() => this.tick(), 1_000);
    this.timer.unref?.();
  }

  private get modelId(): string {
    return this.config.hostLabel;
  }

  private get viewDirectory(): string {
    return join(tmpdir(), "axo-remote", this.config.sessionId);
  }

  // ── MirrorSource: the copy, for the turn playing here ──

  get length(): number {
    return this.session.entries.length;
  }

  entry(index: number): Json | null {
    return this.session.entries[index] ?? null;
  }

  liveMessage(): Json | null {
    return asObject(asObject(this.session.progress.get("message"))?.message);
  }

  toolProgress(toolCallId: string): Json | null {
    return asObject(this.session.progress.get(toolCallId));
  }

  changed(ms: number, signal?: AbortSignal): Promise<void> {
    return new Promise(resolve => {
      const done = () => {
        clearTimeout(timeout);
        this.waiters.delete(done);
        signal?.removeEventListener("abort", done);
        resolve();
      };
      const timeout = setTimeout(done, ms);
      this.waiters.add(done);
      signal?.addEventListener("abort", done, { once: true });
    });
  }

  private wake(): void {
    for (const waiter of [...this.waiters]) waiter();
  }

  // ── One extension runtime: the first, then one per view ──

  async attach(pi: ExtensionAPI): Promise<void> {
    this.pi = pi;
    this.ctx = null;
    this.modules ??= await loadModules();
    const { ai } = this.modules;
    const controller = this;

    pi.registerProvider(REMOTE_PROVIDER, {
      name: this.config.hostLabel,
      baseUrl: "axo://remote",
      apiKey: "axo",
      api: REMOTE_API as Api,
      models: [{
        id: this.modelId, name: this.config.hostLabel, reasoning: true, input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        // Large enough that this Pi never compacts: the other Mac decides that.
        contextWindow: 100_000_000, maxTokens: 1_000_000,
      }],
      streamSimple: (model: Model<Api>, _context: unknown, options?: SimpleStreamOptions): AssistantMessageEventStream => {
        const stream = ai.createAssistantMessageEventStream();
        const message = new AssistantStream(stream, { api: model.api, provider: model.provider, id: model.id });
        void controller.answer(message, options?.signal).catch(error =>
          message.stop(error instanceof Error ? error.message : String(error)));
        return stream;
      },
    } as Parameters<ExtensionAPI["registerProvider"]>[1]);

    for (const name of this.proxied) this.registerProxy(name);

    pi.registerCommand(REDRAW_COMMAND, {
      description: `Draw this Session again from ${this.config.hostLabel}'s copy`,
      handler: async (_args, ctx) => { await this.openView(ctx); },
    });
    pi.registerCommand("yes", {
      description: "Answer yes to the other Mac's question",
      handler: async () => { await this.session.answer(true); },
    });
    pi.registerCommand("no", {
      description: "Answer no to the other Mac's question",
      handler: async () => { await this.session.answer(false); },
    });

    pi.on("session_start", async (_event, ctx) => {
      this.ctx = ctx;
      const model = ctx.modelRegistry.find(REMOTE_PROVIDER, this.modelId);
      if (model) await pi.setModel(model);
      pi.setActiveTools([...this.proxied]);
      ctx.ui.setTitle(`${this.config.hostLabel} · Axo`);
      // Escape asks the other Mac to stop; the turn here ends when its record says so.
      ctx.ui.onTerminalInput(data => {
        if (data !== "\u001b" || !this.session.working) return undefined;
        void this.session.stop();
        return { consume: true };
      });
      this.refresh();
      if (!this.watching) void this.watch();
    });

    pi.on("input", async (event, ctx) => {
      if (event.source === "extension") return { action: "continue" };
      const text = event.text.trim();
      if (!text) return { action: "handled" };
      void this.session.send(text).then(outcome => {
        if (outcome.kind !== "refused") return;
        if (!ctx.ui.getEditorText()) ctx.ui.setEditorText(text);
        ctx.ui.notify(outcome.offline ? `${this.session.hostLabel} is offline; nothing was sent.` : `Not sent: ${outcome.message}`, "warning");
      });
      return { action: "handled" };
    });

    // Only a turn the other Mac took runs here.
    pi.on("before_agent_start", (_event, ctx) => {
      if (!this.mirror) ctx.abort();
    });
    pi.on("tool_call", event => this.mirror && this.proxied.has(event.toolName)
      ? undefined
      : { block: true, reason: `This Session runs on ${this.session.hostLabel}; nothing runs here.` });
    pi.on("tool_result", event => this.failedTools.delete(event.toolCallId) ? { isError: true } : undefined);
    pi.on("agent_end", () => {
      if (!this.mirror) return;
      this.mirror = null;
      this.reconcile();
    });

    pi.on("session_shutdown", event => {
      // A new view replaces this runtime; only quitting ends the pane.
      if (event.reason === "quit") this.dispose();
    });
  }

  /** A tool here is the other Mac's: it waits for that Mac's result and draws it as Pi would. */
  private registerProxy(name: string): void {
    const pi = this.pi;
    const agent = this.modules?.agent;
    if (!pi || !agent) return;
    const cwd = process.cwd();
    const builtins: Record<string, (cwd: string) => unknown> = {
      bash: agent.createBashToolDefinition, read: agent.createReadToolDefinition, edit: agent.createEditToolDefinition,
      write: agent.createWriteToolDefinition, grep: agent.createGrepToolDefinition, find: agent.createFindToolDefinition,
      ls: agent.createLsToolDefinition,
    };
    const base = (builtins[name]?.(cwd) ?? {
      name, label: name, description: `${name}, on ${this.config.hostLabel}`,
      parameters: Type.Object({}, { additionalProperties: true }),
    }) as Json;
    pi.registerTool({
      ...base,
      name,
      execute: async (toolCallId: string, _params: unknown, signal?: AbortSignal, onUpdate?: (partial: never) => void) => {
        const mirror = this.mirror;
        if (!mirror) throw new Error(`This Session runs on ${this.session.hostLabel}; nothing runs here.`);
        const result = await mirror.toolResult(toolCallId, signal, partial => onUpdate?.(partial as never));
        if (!result) throw new Error(`Stopped on ${this.session.hostLabel}`);
        if (result.isError) this.failedTools.add(toolCallId);
        return { content: result.content, details: result.details };
      },
    } as unknown as Parameters<ExtensionAPI["registerTool"]>[0]);
  }

  private ensureProxy(name: string): void {
    if (this.proxied.has(name)) return;
    this.proxied.add(name);
    this.registerProxy(name);
    this.pi?.setActiveTools([...this.proxied]);
  }

  /** The provider: the other Mac's next assistant message of the turn playing here. */
  private async answer(message: AssistantStream, signal?: AbortSignal): Promise<void> {
    const mirror = this.mirror;
    if (!mirror) return message.stop(`This Session runs on ${this.session.hostLabel}; nothing runs here.`);
    const step = await mirror.step(signal, live => message.follow(live));
    if (step.kind === "assistant") {
      for (const block of Array.isArray(step.message.content) ? step.message.content : []) {
        const call = asObject(block);
        if (call?.type === "toolCall" && typeof call.name === "string") this.ensureProxy(call.name);
      }
      return message.finish(step.message);
    }
    // A steer, another prompt or a stop: the turn here ends, and the redraw shows what was.
    mirror.giveUp();
    message.stop(step.kind === "desync" ? `${this.session.hostLabel} moved on` : `Stopped on ${this.session.hostLabel}`);
  }

  // ── Following the copy ──

  private async watch(): Promise<void> {
    this.watching = true;
    while (!this.stopped) {
      try {
        const view = await callAxod(this.config.socket, "axo.peer.session.watch", {
          hostId: this.config.hostId, sessionId: this.config.sessionId,
          epoch: this.session.epoch, cursor: this.session.cursor, version: this.session.version,
          timeoutMs: WATCH_TIMEOUT_MS, window: WATCH_WINDOW,
        }, WATCH_TIMEOUT_MS + 10_000) as PeerSessionView;
        const changedVersion = view.version !== this.session.version;
        const change = this.session.apply(view);
        if (changedVersion) this.lastChange = Date.now();
        if (this.session.loaded) this.firstLoadEnd ??= this.session.records.length;
        if (change.reset) {
          // Everything drawn of the old copy is stale, the turn playing here included.
          this.shownEnd = -1;
          this.mirroredUser = -1;
          this.firstLoadEnd = this.session.loaded ? this.session.records.length : null;
          this.giveUpTurn();
        }
        this.wake();
        this.refresh();
        this.reconcile();
        if (view.more) continue;
      } catch {
        await new Promise(resolve => setTimeout(resolve, 1_000));
      }
    }
  }

  /**
   * Brings the screen up to the copy: plays the open turn, if the other Mac is in one, else
   * draws every record. Runs whenever something changes; does nothing while a turn plays here.
   */
  private reconcile(): void {
    const ctx = this.ctx;
    if (this.stopped || !this.session.loaded || this.redrawing || this.mirror || !ctx) return;
    if (!this.isIdle(ctx)) return;
    const total = this.session.records.length;
    const open = this.session.openTurn();
    // A turn the copy leaves open plays if the other Mac is in it: its status says so, or its
    // prompt arrived while this pane watched (the status can lag the records).
    const live = open >= 0 && (this.session.working || open >= (this.firstLoadEnd ?? total));
    if (live && open !== this.mirroredUser) {
      // Draw up to its user message, then play the turn from there.
      if (this.shownEnd === open) this.playTurn(open);
      else this.redraw({ end: open, then: () => this.playTurn(open) });
    } else if (this.shownEnd !== total) {
      this.redraw({ end: total });
    }
  }

  private isIdle(ctx: ExtensionContext): boolean {
    try {
      return ctx.isIdle();
    } catch {
      return false;
    }
  }

  private playTurn(userIndex: number): void {
    const pi = this.pi;
    const message = asObject(this.session.entries[userIndex]?.message);
    if (!pi || !message) return;
    this.mirror = new MirrorTurn(this, userIndex);
    this.mirroredUser = userIndex;
    this.otherSince = null;
    const content = Array.isArray(message.content)
      ? message.content.filter(block => asObject(block)?.type === "text" || asObject(block)?.type === "image")
      : [{ type: "text", text: textOf(message.content) }];
    pi.sendUserMessage(content.length ? content as never : " ");
  }

  /** Ends the turn playing here; the redraw that follows shows the records. */
  private giveUpTurn(): void {
    if (!this.mirror) return;
    this.mirror.giveUp();
    this.wake();
    try {
      this.ctx?.abort();
    } catch {
      // The runtime is being replaced; its turn ends with it.
    }
  }

  private redraw(redraw: Redraw): void {
    this.redrawing = redraw;
    this.pi?.sendUserMessage(`/${REDRAW_COMMAND}`, { expandPromptTemplates: true });
  }

  /** Opens a fresh view: what a redraw asked for, or the whole copy when typed by hand. */
  private async openView(ctx: ExtensionCommandContext): Promise<void> {
    const redraw = this.redrawing ?? { end: this.session.records.length };
    this.redrawing = redraw;
    const previous = this.viewPath;
    this.views += 1;
    const path = join(this.viewDirectory, `view-${this.views}.jsonl`);
    try {
      mkdirSync(this.viewDirectory, { recursive: true });
      writeFileSync(path, buildView(this.session.records, redraw.end, {
        id: this.config.sessionId, cwd: process.cwd(),
        model: { provider: REMOTE_PROVIDER, modelId: this.modelId },
      }));
      const result = await ctx.switchSession(path, {
        withSession: async () => {
          this.viewPath = path;
          this.shownEnd = redraw.end;
          if (previous) rmSync(previous, { force: true });
        },
      });
      if (result.cancelled) throw new Error("Pi kept the current view");
    } catch (error) {
      rmSync(path, { force: true });
      try {
        ctx.ui.notify(`Could not draw ${this.config.hostLabel}'s Session: ${error instanceof Error ? error.message : String(error)}`, "error");
      } catch {
        // The view was half replaced; the next change redraws.
      }
      this.redrawing = null;
      return;
    }
    this.redrawing = null;
    if (redraw.then) redraw.then();
    else this.reconcile();
  }

  /** Every second: gives up a turn the other Mac has left, and retries what had to wait. */
  private tick(): void {
    if (this.mirror && !this.session.working) {
      this.otherSince ??= Date.now();
      if (Date.now() - Math.max(this.otherSince, this.lastChange) > STALE_TURN_MS) this.giveUpTurn();
    } else {
      this.otherSince = null;
    }
    this.reconcile();
  }

  private refresh(): void {
    const ui = this.ctx?.ui;
    if (!ui) return;
    const host = this.session.hostLabel;
    const question = asObject(this.session.progress.get("question"));
    const lines: string[] = [];
    if (question) {
      const title = typeof question.title === "string" ? question.title : "The agent is asking something";
      lines.push(`? ${title}`, "  /yes or /no to answer, or type a reply");
    }
    for (const prompt of this.session.pending) lines.push(`↑ ${prompt.text.split("\n")[0]}  · ${pendingLabels[prompt.state](host)}`);
    ui.setWidget("axo-remote-pending", lines.length ? lines : undefined);
    const state = !this.session.connected ? "this Mac is offline"
      : !this.session.hostOnline ? `${host} is offline`
        : this.session.stopping ? "stopping…"
          : this.session.working ? "working · Esc to stop" : "ready";
    ui.setStatus("axo-remote", `On ${host} · ${state}`);
  }

  private dispose(): void {
    this.stopped = true;
    clearInterval(this.timer);
    this.session.dispose();
    this.wake();
    rmSync(this.viewDirectory, { recursive: true, force: true });
  }
}

const CONTROLLER = Symbol.for("axo.pi-axo.remote-view");

/**
 * Remote mode. Called once per extension runtime: Pi builds a new one for every view, and each
 * attaches to the pane's one controller.
 */
export async function installRemoteView(pi: ExtensionAPI, config: RemoteViewConfig, link?: RemoteLink): Promise<void> {
  const global = globalThis as { [CONTROLLER]?: RemoteController };
  const controller = global[CONTROLLER] ??= new RemoteController(config, link ?? {
    command: (method, params) => callAxod(config.socket, "axo.peer.command", { hostId: config.hostId, method, params }, COMMAND_TIMEOUT_MS),
  });
  await controller.attach(pi);
}
