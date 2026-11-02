/**
 * Another Mac's Session, in a Pi on this Mac (RFD0024).
 *
 * Axod starts `pi --no-session` with this extension in remote mode for a Session that runs on
 * another Mac. This Pi runs no model and no tool, and writes no file: it draws this Mac's copy
 * of the Session as Axod's peers socket keeps it, and sends what is typed to the Mac that runs
 * the Session, which alone writes its log. A prompt is pending until its receipt, which that
 * Mac's pi-axo writes just before the prompt, shows in the copy; a prompt whose fate is unknown
 * is sent again with the same commandId, which that Mac takes at most once.
 *
 * `RemoteSession` is the model, free of Pi; `installRemoteView` draws it with Pi's own message
 * components and wires Pi's input to it.
 */
import { randomUUID } from "node:crypto";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import type { Component } from "@earendil-works/pi-tui";
import { AxodCallError, callAxod } from "./axod-client.js";
import { RECEIPT_ENTRY } from "./remote-commands.js";

/** pi-axo exits with this so the pane starts Pi again and draws the copy afresh. */
export const REDRAW_EXIT_CODE = 75;
/** The custom entry each drawn record is: never sent to a model, since none runs here. */
export const REMOTE_RECORD_ENTRY = "axo.remote.record";

const WATCH_TIMEOUT_MS = 15_000;
const WATCH_WINDOW = 400;
const COMMAND_TIMEOUT_MS = 40_000;
const RETRY_DELAY_MS = 3_000;
const MAX_RETRIES = 40;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

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

export interface PendingPrompt {
  readonly commandId: string;
  readonly text: string;
  state: PendingState;
}

/** A record worth drawing: Pi's own entry, parsed. */
export type Drawable =
  | { kind: "user"; id: string; text: string }
  | { kind: "assistant"; id: string; message: Record<string, unknown> }
  | { kind: "toolResult"; id: string; toolName: string; text: string; isError: boolean }
  | { kind: "bash"; id: string; command: string; output: string }
  | { kind: "note"; id: string; text: string };

/** What applying a view asks of the screen. */
export interface ViewChange {
  /** The copy was cut back or replaced, and this screen already drew it: start over. */
  readonly redraw: boolean;
  readonly draw: readonly Drawable[];
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

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map(block => asObject(block))
    .filter((block): block is Record<string, unknown> => block?.type === "text" && typeof block.text === "string")
    .map(block => block.text as string)
    .join("\n");
}

/** The receipt a record is, or a drawable, or nothing to show. */
export function readRecord(line: string): { kind: "receipt"; commandId: string } | { kind: "draw"; drawable: Drawable } | { kind: "user"; id: string; drawable: Drawable } | null {
  let entry: Record<string, unknown> | null;
  try {
    entry = asObject(JSON.parse(line));
  } catch {
    return null;
  }
  if (!entry) return null;
  const id = typeof entry.id === "string" ? entry.id : randomUUID();
  if (entry.type === "custom" && entry.customType === RECEIPT_ENTRY) {
    const commandId = asObject(entry.data)?.commandId;
    return typeof commandId === "string" ? { kind: "receipt", commandId } : null;
  }
  if (entry.type === "compaction") return { kind: "draw", drawable: { kind: "note", id, text: "Earlier messages were compacted." } };
  if (entry.type === "custom_message" && entry.display === true) {
    const text = textOf(entry.content);
    return text ? { kind: "draw", drawable: { kind: "note", id, text } } : null;
  }
  if (entry.type !== "message") return null;
  const message = asObject(entry.message);
  if (!message) return null;
  switch (message.role) {
    case "user": {
      const drawable: Drawable = { kind: "user", id, text: textOf(message.content) };
      return { kind: "user", id, drawable };
    }
    case "assistant":
      return { kind: "draw", drawable: { kind: "assistant", id, message } };
    case "toolResult":
      return {
        kind: "draw",
        drawable: {
          kind: "toolResult", id,
          toolName: typeof message.toolName === "string" ? message.toolName : "tool",
          text: textOf(message.content), isError: message.isError === true,
        },
      };
    case "bashExecution":
      return {
        kind: "draw",
        drawable: { kind: "bash", id, command: String(message.command ?? ""), output: String(message.output ?? "") },
      };
    case "custom": {
      const text = message.display === false ? "" : textOf(message.content);
      return text ? { kind: "draw", drawable: { kind: "note", id, text } } : null;
    }
    default:
      return null;
  }
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
  /** Whether anything of the copy is on screen, so a reset must start the screen over. */
  drawn = false;
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
    if (view.reset && this.drawn) return { redraw: true, draw: [] };
    this.epoch = view.epoch;
    this.cursor = view.cursor;
    const draw: Drawable[] = [];
    for (const record of view.records) {
      const read = readRecord(record.line);
      if (!read) continue;
      if (read.kind === "receipt") {
        this.receipt = read.commandId;
        continue;
      }
      if (read.kind === "user") {
        this.lastUserEntry = read.id;
        if (this.receipt) this.delivered.add(this.receipt);
        this.receipt = null;
      }
      draw.push(read.drawable);
    }
    if (draw.length) this.drawn = true;
    this.retireDelivered();
    return { redraw: false, draw };
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

  /** Stops the turn shown running, by its user message; a later turn carries on. */
  async stop(): Promise<boolean> {
    const turnId = this.lastUserEntry;
    if (!this.working || !turnId || this.stopping) return false;
    this.stopping = true;
    this.changed();
    try {
      await this.link.command("axo.remote.session.stop", { sessionId: this.config.sessionId, turnId });
      return true;
    } catch {
      this.stopping = false;
      this.changed();
      return false;
    }
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

// ─── Drawing with Pi ────────────────────────────────────────────────────────

const OUTPUT_LINES = 12;

function lastLines(text: string, count: number): string {
  const lines = text.replace(/\s+$/u, "").split("\n");
  return lines.length > count ? [`… ${lines.length - count} earlier lines`, ...lines.slice(-count)].join("\n") : lines.join("\n");
}

function toolCallSummary(block: Record<string, unknown>): string {
  const name = typeof block.name === "string" ? block.name : "tool";
  const args = asObject(block.arguments) ?? {};
  const command = typeof args.command === "string" ? args.command : typeof args.path === "string" ? args.path : null;
  const detail = command ?? JSON.stringify(args);
  return `${name} ${detail.length > 200 ? `${detail.slice(0, 200)}…` : detail}`;
}

/** Pi's own terminal components, loaded inside Pi, which provides them to its extensions. */
type Components = typeof import("@earendil-works/pi-coding-agent") & typeof import("@earendil-works/pi-tui");

async function loadComponents(): Promise<Components> {
  const [agent, tui] = await Promise.all([import("@earendil-works/pi-coding-agent"), import("@earendil-works/pi-tui")]);
  return { ...agent, ...tui };
}

/** Draws one record as Pi draws its own: user and assistant messages with Pi's components. */
export function renderDrawable(ui: Components, drawable: Drawable, expanded: boolean, theme: Theme): Component | undefined {
  const { AssistantMessageComponent, Box, Container, getMarkdownTheme, Spacer, Text, UserMessageComponent } = ui;
  switch (drawable.kind) {
    case "user":
      return new UserMessageComponent(drawable.text, getMarkdownTheme());
    case "assistant": {
      const container = new Container();
      container.addChild(new AssistantMessageComponent(drawable.message as never, false, getMarkdownTheme()));
      const content = Array.isArray(drawable.message.content) ? drawable.message.content : [];
      for (const block of content.map(asObject)) {
        if (block?.type !== "toolCall") continue;
        const box = new Box(1, 0, text => theme.bg("toolPendingBg", text));
        box.addChild(new Text(theme.fg("toolTitle", theme.bold(toolCallSummary(block))), 0, 0));
        container.addChild(new Spacer(1));
        container.addChild(box);
      }
      return container;
    }
    case "toolResult": {
      if (!drawable.text.trim()) return undefined;
      const box = new Box(1, 0, text => theme.bg(drawable.isError ? "toolErrorBg" : "toolSuccessBg", text));
      const body = expanded ? drawable.text : lastLines(drawable.text, OUTPUT_LINES);
      box.addChild(new Text(theme.fg("toolOutput", body), 0, 0));
      return box;
    }
    case "bash": {
      const box = new Box(1, 0, text => theme.bg("toolSuccessBg", text));
      box.addChild(new Text(`${theme.fg("bashMode", "$")} ${theme.bold(drawable.command)}`, 0, 0));
      if (drawable.output.trim()) box.addChild(new Text(theme.fg("toolOutput", expanded ? drawable.output : lastLines(drawable.output, OUTPUT_LINES)), 0, 0));
      return box;
    }
    case "note":
      return new Text(theme.fg("muted", drawable.text), 1, 0);
  }
}

const pendingLabels: Record<PendingState, (host: string) => string> = {
  sending: host => `Sending to ${host}…`,
  sent: host => `Sent to ${host}`,
  queued: host => `Queued on ${host} · runs after the current reply`,
  uncertain: host => `Not confirmed by ${host} yet · trying again`,
};

function draftFile(config: RemoteViewConfig): string {
  return join(tmpdir(), `axo-remote-${config.sessionId}.json`);
}

/** What a restart carries over: the editor's words and the prompts still pending. */
interface Carried {
  draft: string;
  pending: PendingPrompt[];
}

function takeCarried(config: RemoteViewConfig): Carried | null {
  try {
    const carried = JSON.parse(readFileSync(draftFile(config), "utf8")) as Carried;
    rmSync(draftFile(config), { force: true });
    return carried;
  } catch {
    return null;
  }
}

export function installRemoteView(pi: ExtensionAPI, config: RemoteViewConfig, link?: RemoteLink): void {
  const axod: RemoteLink = link ?? {
    command: (method, params) => callAxod(config.socket, "axo.peer.command", { hostId: config.hostId, method, params }, COMMAND_TIMEOUT_MS),
  };
  let ui: ExtensionContext["ui"] | null = null;
  let stopped = false;
  let redrawing = false;
  let refresh = () => {};
  const session = new RemoteSession(config, axod, () => refresh());
  const carried = takeCarried(config);
  if (carried) {
    // Sent before the restart: still pending, and sent again until the copy shows them.
    for (const prompt of carried.pending) session.pending.push({ ...prompt, state: "uncertain" });
  }

  let components: Components | null = null;
  pi.registerEntryRenderer<Drawable>(REMOTE_RECORD_ENTRY, (entry, options, theme) =>
    entry.data && components ? renderDrawable(components, entry.data, options.expanded, theme) : undefined);

  refresh = () => {
    if (!ui) return;
    const host = session.hostLabel;
    const live = session.progress.get("message");
    const message = asObject(asObject(live)?.message);
    const drawn = components;
    ui.setWidget("axo-remote-live", message && drawn
      ? () => new drawn.AssistantMessageComponent(message as never, false, drawn.getMarkdownTheme())
      : undefined);
    const tools = [...session.progress.entries()].filter(([slot]) => slot !== "message" && slot !== "question");
    const question = asObject(session.progress.get("question"));
    const lines: string[] = [];
    for (const [, snapshot] of tools) {
      const tool = asObject(snapshot);
      const name = typeof tool?.toolName === "string" ? tool.toolName : "tool";
      lines.push(`⚙ ${host} is running ${name}…`);
    }
    if (question) {
      const title = typeof question.title === "string" ? question.title : "The agent is asking something";
      lines.push(`? ${title}`, "  /yes or /no to answer, or type a reply");
    }
    for (const prompt of session.pending) lines.push(`↑ ${prompt.text.split("\n")[0]}  · ${pendingLabels[prompt.state](host)}`);
    ui.setWidget("axo-remote-pending", lines.length ? lines : undefined);
    const state = !session.connected ? "this Mac is offline"
      : !session.hostOnline ? `${host} is offline`
        : session.stopping ? "stopping…"
          : session.working ? "working · Esc to stop" : "ready";
    ui.setStatus("axo-remote", `On ${host} · ${state}`);
    ui.setWorkingVisible?.(false);
  };

  const watch = async (ctx: ExtensionContext) => {
    while (!stopped) {
      try {
        const view = await callAxod(config.socket, "axo.peer.session.watch", {
          hostId: config.hostId, sessionId: config.sessionId,
          epoch: session.epoch, cursor: session.cursor, version: session.version,
          timeoutMs: WATCH_TIMEOUT_MS, window: WATCH_WINDOW,
        }, WATCH_TIMEOUT_MS + 10_000) as PeerSessionView;
        const change = session.apply(view);
        if (change.redraw) {
          redrawing = true;
          writeFileSync(draftFile(config), JSON.stringify({ draft: ctx.ui.getEditorText(), pending: session.pending } satisfies Carried));
          ctx.shutdown();
          return;
        }
        for (const drawable of change.draw) pi.appendEntry(REMOTE_RECORD_ENTRY, drawable);
        refresh();
        if (view.more) continue;
      } catch {
        await new Promise(resolve => setTimeout(resolve, 1_000));
      }
    }
  };

  pi.on("session_start", async (_event, ctx) => {
    components = await loadComponents();
    ui = ctx.ui;
    // Nothing runs here: no tools, and no turn is ever started (see `input`).
    pi.setActiveTools([]);
    ctx.ui.setTitle(`${config.hostLabel} · Axo`);
    if (carried?.draft) ctx.ui.setEditorText(carried.draft);
    ctx.ui.onTerminalInput(data => {
      if (data !== "\u001b" || !session.working) return undefined;
      void session.stop();
      return { consume: true };
    });
    refresh();
    void watch(ctx);
  });

  pi.on("input", async (event, ctx) => {
    if (event.source === "extension") return { action: "continue" };
    const text = event.text.trim();
    if (!text) return { action: "handled" };
    void session.send(text).then(outcome => {
      if (outcome.kind !== "refused") return;
      if (!ctx.ui.getEditorText()) ctx.ui.setEditorText(text);
      ctx.ui.notify(outcome.offline ? `${session.hostLabel} is offline; nothing was sent.` : `Not sent: ${outcome.message}`, "warning");
    });
    return { action: "handled" };
  });

  // Should anything start a turn here anyway, it does nothing.
  pi.on("before_agent_start", (_event, ctx) => {
    ctx.abort();
  });
  pi.on("tool_call", () => ({ block: true, reason: `This Session runs on ${session.hostLabel}; nothing runs here.` }));

  pi.registerCommand("yes", {
    description: "Answer yes to the other Mac's question",
    handler: async () => { await session.answer(true); },
  });
  pi.registerCommand("no", {
    description: "Answer no to the other Mac's question",
    handler: async () => { await session.answer(false); },
  });

  pi.on("session_shutdown", () => {
    stopped = true;
    session.dispose();
    // Pi exits 0 after this; the pane starts Pi again only on this exit code.
    if (redrawing) process.exit(REDRAW_EXIT_CODE);
  });
}
