import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { parseAttachments, type PromptAttachment } from "./attachments.js";

/**
 * Prompts and stops from Axo clients (the phone, the web app, other Macs), as the Pi that owns
 * the Session takes them (RFD0024, RFD0033). This Pi is the only writer of its log, so a client
 * knows what its command did only from the log:
 *
 * - **Receipts.** Just before a client's prompt becomes a user message, an `axo.command` entry
 *   with its `commandId` is written, so clients match their pending prompts by id, never by text.
 * - **At most once.** A `commandId` seen before, in the log or held here, is answered as taken and
 *   prompts nothing: a client retries after an unknown outcome with the same id.
 * - **Queued in the log.** A prompt that can't go to Pi at once is written to the log as
 *   `axo.command.queued` before it is accepted, then held here. A Pi that exits, crashes or is
 *   restarted holds it again from the log, so an accepted prompt is never lost, and clients show
 *   it as queued from the log alone.
 * - **Follow-ups start the next turn; steers join this one.** A steer is handed to Pi at the end
 *   of a turn that goes on, right before Pi reads its steering queue, so its receipt is still the
 *   entry before its user message. Pi's own queue is never left holding a client's prompt: its
 *   terminal UI moves the queue into the editor on any stop, where the prompt is lost.
 * - **Stops name what the client saw.** A stop carries what the client knew of the run it showed
 *   running: a user record of it, the newest entry it held, or the commandIds of its own prompts.
 *   Any of them being part of the running run stops it; a run the client never saw any of goes
 *   on. The newest entry is always there, however long the run, and a commandId names a run the
 *   client started before any of its records reached it.
 */
export const RECEIPT_ENTRY = "axo.command";
/** A client's prompt, accepted and waiting for Pi: `{commandId, delivery, text, attachments}`. */
export const QUEUED_ENTRY = "axo.command.queued";

/** How many prompts may wait for Pi at once; more are refused as busy. */
export const MAX_HELD_PROMPTS = 32;
/**
 * Pi starts a run a few ticks after it is prompted, and reads as idle until then. A prompt
 * delivered that long ago whose run never started (Pi refused it) no longer holds up the next.
 */
export const RUN_START_GRACE_MS = 10_000;

/** When a prompt sent while Pi works reaches it: after this turn, or within it. */
export type Delivery = "followUp" | "steer";

/** What a client sent, as the log keeps it: attachments are files on this Mac, not bytes. */
export interface ClientPrompt {
  text: string;
  attachments: PromptAttachment[];
}

export interface CommandReceipt {
  commandId: string;
}

export interface QueuedCommand extends ClientPrompt {
  commandId: string;
  delivery: Delivery;
}

export interface RemoteCommandPi {
  isIdle(): boolean;
  entries(): readonly SessionEntry[];
  appendReceipt(receipt: CommandReceipt): void;
  appendQueued(command: QueuedCommand): void;
  /**
   * Hands `prompt` to Pi: as a new turn, or as a steer of the running one. A prompt starts a
   * run; an extension command (`/axo-share`) runs without one.
   */
  prompt(prompt: ClientPrompt, as: "turn" | "steer"): "run" | "command";
  abort(): void;
  now(): number;
}

export type PromptOutcome = "taken" | "held" | "busy";
/** Pi was idle, or the run going on is one the client did not see. */
export type StopOutcome = "stopped" | "idle" | "ignored";

/** What a client knew of the run it asked to stop; at least one is set. */
export interface StopRequest {
  /** A user record of the run, by entry id. */
  turnId?: string;
  /** The newest entry the client held. */
  seen?: string;
  /** The client's own prompts, sent or queued. */
  commandIds?: readonly string[];
}

interface HeldPrompt {
  commandId: string;
  delivery: Delivery;
  prompt: ClientPrompt;
}

export class RemoteCommands {
  private readonly seen = new Set<string>();
  private held: HeldPrompt[] = [];
  /** A steer handed to Pi whose user message has not been written yet. */
  private steering: HeldPrompt | null = null;
  /** Entries before the running run's first (its prompt's receipt, if a client sent it). */
  private turnStart: number | null = null;
  /** Where the entries of the prompt last handed to Pi begin, until its run starts. */
  private deliveredFrom: number | null = null;
  /** When the last prompt was handed to Pi, until its run starts. */
  private deliveredAt: number | null = null;

  constructor(private readonly pi: RemoteCommandPi) {}

  /**
   * Learns the commands already in the log when Pi starts or resumes the Session, and holds
   * again, in log order, every queued prompt that has no receipt yet. Call {@link resume} once
   * Pi can take them.
   */
  restore(): void {
    const receipts = new Set<string>();
    const queued: HeldPrompt[] = [];
    for (const entry of this.pi.entries()) {
      const commandId = receiptOf(entry);
      if (commandId !== null) receipts.add(commandId);
      const command = queuedOf(entry);
      if (command !== null) queued.push(command);
    }
    for (const commandId of receipts) this.seen.add(commandId);
    for (const command of queued) {
      if (receipts.has(command.commandId) || this.isHeld(command.commandId)) continue;
      this.seen.add(command.commandId);
      this.held.push(command);
    }
  }

  /** Delivers what is held, if Pi is idle: after {@link restore}, or a restart. */
  resume(): void {
    if (this.ready()) this.deliverNext();
  }

  prompt(commandId: string, prompt: ClientPrompt, delivery: Delivery = "followUp"): PromptOutcome {
    if (this.seen.has(commandId)) return "taken";
    if (this.held.length >= MAX_HELD_PROMPTS) return "busy";
    this.seen.add(commandId);
    const command = { commandId, delivery, prompt };
    // An idle Pi with nothing waiting takes it now: the receipt and the user message are the log.
    if (this.held.length === 0 && this.ready()) {
      this.deliver(command);
      return "taken";
    }
    // Written before the client hears it was accepted.
    this.pi.appendQueued({ commandId, delivery, ...prompt });
    this.held.push(command);
    if (this.ready()) this.deliverNext();
    return this.isHeld(commandId) ? "held" : "taken";
  }

  stop(request: StopRequest): StopOutcome {
    if (this.pi.isIdle()) return "idle";
    const entries = this.pi.entries();
    // A run this extension did not see start (it was reloaded mid-run) began at the last user record.
    const run = entries.slice(this.turnStart ?? Math.max(0, entries.findLastIndex(isUserMessage)));
    const commandIds = new Set(request.commandIds ?? []);
    const seen = run.some(entry =>
      (request.turnId !== undefined && isUserMessage(entry) && entry.id === request.turnId)
      || (request.seen !== undefined && entry.id === request.seen)
      || (commandIds.size > 0 && commandIds.has(receiptOf(entry) ?? "")));
    if (!seen) return "ignored";
    this.pi.abort();
    return "stopped";
  }

  /** A run starts: what it writes from here on is its own, and so is its prompt's receipt. */
  runStarted(): void {
    this.turnStart = this.deliveredAt !== null && this.deliveredFrom !== null ? this.deliveredFrom : this.pi.entries().length;
    this.deliveredAt = null;
    this.deliveredFrom = null;
  }

  /**
   * A turn of the running run ended. Unless it was stopped or failed, the oldest held steer
   * joins the run: Pi reads its steering queue right after this, before its next model call.
   * One at a time, so each receipt is the entry before its own user message.
   */
  turnEnded(stopped: boolean): void {
    if (stopped || this.steering !== null || this.pi.isIdle()) return;
    const index = this.held.findIndex(command => command.delivery === "steer");
    if (index < 0) return;
    const [command] = this.held.splice(index, 1);
    this.steering = command!;
    this.pi.appendReceipt({ commandId: command!.commandId });
    this.pi.prompt(command!.prompt, "steer");
  }

  /** Pi wrote a user message: a steer handed to it has arrived. */
  userMessageWritten(): void {
    this.steering = null;
  }

  /**
   * Pi will not go on by itself. A steer it never took (the run stopped first) is delivered
   * again, first; then the next held prompt starts a turn.
   */
  settled(): void {
    this.turnStart = null;
    this.deliveredAt = null;
    this.deliveredFrom = null;
    if (this.steering !== null) {
      this.held.unshift(this.steering);
      this.steering = null;
    }
    this.deliverNext();
  }

  get heldCount(): number {
    return this.held.length;
  }

  private isHeld(commandId: string): boolean {
    return this.held.some(command => command.commandId === commandId);
  }

  private ready(): boolean {
    if (!this.pi.isIdle()) return false;
    return this.deliveredAt === null || this.pi.now() - this.deliveredAt >= RUN_START_GRACE_MS;
  }

  private deliverNext(): void {
    const next = this.held.shift();
    if (next !== undefined) this.deliver(next);
  }

  private deliver(command: HeldPrompt): void {
    this.deliveredAt = this.pi.now();
    this.deliveredFrom = this.pi.entries().length;
    this.pi.appendReceipt({ commandId: command.commandId });
    // A command starts no run, so nothing would release the prompts held behind it.
    if (this.pi.prompt(command.prompt, "turn") === "command") {
      this.deliveredAt = null;
      this.deliveredFrom = null;
      this.deliverNext();
    }
  }
}

function receiptOf(entry: SessionEntry): string | null {
  if (entry.type !== "custom" || entry.customType !== RECEIPT_ENTRY) return null;
  const data = entry.data as Partial<CommandReceipt> | undefined;
  return typeof data?.commandId === "string" ? data.commandId : null;
}

function queuedOf(entry: SessionEntry): HeldPrompt | null {
  if (entry.type !== "custom" || entry.customType !== QUEUED_ENTRY) return null;
  const data = entry.data as Partial<QueuedCommand> | undefined;
  if (typeof data?.commandId !== "string" || typeof data.text !== "string") return null;
  const delivery: Delivery = data.delivery === "steer" ? "steer" : "followUp";
  // Files on this Mac, checked as the bridge checks them; a malformed list keeps the text alone.
  const attachments = data.attachments === undefined ? [] : parseAttachments(data.attachments) ?? [];
  return { commandId: data.commandId, delivery, prompt: { text: data.text, attachments } };
}

function isUserMessage(entry: SessionEntry): boolean {
  return entry.type === "message" && entry.message.role === "user";
}
