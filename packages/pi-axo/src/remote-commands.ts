import type { SessionEntry } from "@earendil-works/pi-coding-agent";

/**
 * Prompts and stops from Axo clients (the phone, the web app, other Macs), as the Pi that owns
 * the Session takes them (RFD0024). This Pi is the only writer of its log, so a client knows what
 * its command did only from the log:
 *
 * - **Receipts.** Before a client's prompt becomes a user message, an `axo.command` entry with its
 *   `commandId` is written, so clients match their pending prompts by id, never by text.
 * - **At most once.** A `commandId` seen before, in the log or held here, is answered as taken and
 *   prompts nothing: a client retries after an unknown outcome with the same id.
 * - **Held, not queued in Pi.** A prompt that arrives during a turn waits here and starts the
 *   next turn. Pi's own queue would not do: its terminal UI moves the queue into the editor on
 *   any stop, where the prompt is lost to the client that sent it.
 * - **Stops name their turn.** A stop carries the id of a user record of the turn the client
 *   showed running, and stops nothing if another turn runs now.
 */
export const RECEIPT_ENTRY = "axo.command";

/** How many prompts may wait for Pi at once; more are refused as busy. */
export const MAX_HELD_PROMPTS = 32;
/**
 * Pi starts a run a few ticks after it is prompted, and reads as idle until then. A prompt
 * delivered that long ago whose run never started (Pi refused it) no longer holds up the next.
 */
export const RUN_START_GRACE_MS = 10_000;

export interface CommandReceipt {
  commandId: string;
}

export interface RemoteCommandPi {
  isIdle(): boolean;
  entries(): readonly SessionEntry[];
  appendReceipt(receipt: CommandReceipt): void;
  prompt(text: string): void;
  abort(): void;
  now(): number;
}

export type PromptOutcome = "taken" | "held" | "busy";
export type StopOutcome = "stopped" | "ignored";

interface HeldPrompt {
  commandId: string;
  text: string;
}

export class RemoteCommands {
  private readonly seen = new Set<string>();
  private readonly held: HeldPrompt[] = [];
  /** Entries before the running turn's first: its user records come after. */
  private turnStart: number | null = null;
  /** When the last prompt was handed to Pi, until its run starts. */
  private deliveredAt: number | null = null;

  constructor(private readonly pi: RemoteCommandPi) {}

  /** Learns the commands already in the log, when Pi starts or resumes the Session. */
  restore(): void {
    for (const entry of this.pi.entries()) {
      const commandId = receiptOf(entry);
      if (commandId !== null) this.seen.add(commandId);
    }
  }

  prompt(commandId: string, text: string): PromptOutcome {
    if (this.seen.has(commandId)) return "taken";
    if (this.held.length >= MAX_HELD_PROMPTS) return "busy";
    this.seen.add(commandId);
    this.held.push({ commandId, text });
    // An idle Pi takes the oldest held prompt now, which is this one unless a delivery failed.
    if (this.ready()) this.deliverNext();
    return this.held.some(prompt => prompt.commandId === commandId) ? "held" : "taken";
  }

  stop(turnId: string): StopOutcome {
    if (this.pi.isIdle() || this.turnStart === null) return "ignored";
    const ofThisTurn = this.pi.entries().slice(this.turnStart).some(entry => isUserMessage(entry) && entry.id === turnId);
    if (!ofThisTurn) return "ignored";
    this.pi.abort();
    return "stopped";
  }

  /** A run starts: what it writes from here on is its own. */
  runStarted(): void {
    this.deliveredAt = null;
    this.turnStart = this.pi.entries().length;
  }

  /** Pi will not go on by itself: the next held prompt starts a turn. */
  settled(): void {
    this.turnStart = null;
    this.deliveredAt = null;
    this.deliverNext();
  }

  get heldCount(): number {
    return this.held.length;
  }

  private ready(): boolean {
    if (!this.pi.isIdle()) return false;
    return this.deliveredAt === null || this.pi.now() - this.deliveredAt >= RUN_START_GRACE_MS;
  }

  private deliverNext(): void {
    const next = this.held.shift();
    if (next === undefined) return;
    this.deliveredAt = this.pi.now();
    this.pi.appendReceipt({ commandId: next.commandId });
    this.pi.prompt(next.text);
  }
}

function receiptOf(entry: SessionEntry): string | null {
  if (entry.type !== "custom" || entry.customType !== RECEIPT_ENTRY) return null;
  const data = entry.data as Partial<CommandReceipt> | undefined;
  return typeof data?.commandId === "string" ? data.commandId : null;
}

function isUserMessage(entry: SessionEntry): boolean {
  return entry.type === "message" && entry.message.role === "user";
}
