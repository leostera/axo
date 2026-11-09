import type { ChatMessage, ChatTranscript } from "./transcript.ts";
import type { WaitingPrompt } from "./workbench.ts";
import { conversationRows } from "./pi-controls.ts";

/**
 * One chat's conversation as the screen lists it: rows that are made once and kept, in the order
 * they came (RFD0040, as the phone's in RFD0039).
 *
 * The transcript changes with every word of a reply; a screen that rendered it whole would render
 * every row each time. The feed holds each row as an object of its own instead. A change to the
 * transcript changes the rows it touches, in place, and adds the new ones. A row's view subscribes
 * to its row alone, so a reply being written renders that reply, and the list renders only when a
 * row is added or removed.
 *
 * Rows only ever go on the end, and keep their places. The exceptions are a page of older history,
 * which goes on the top; a message the person took back; and a transcript read again from the start
 * (a cut, or a reload), which starts the rows again.
 *
 * Whether a row shows is decided here, never by a view. A reply written while the chat is on screen
 * has its words let out by the feed's own clock, and the rows after it wait until they are all out.
 * Off screen (another chat, or the tab hidden, where a page gets no animation frames) nothing waits:
 * what arrives shows as it is.
 */
export class ConversationFeed {
  /** The rows, top to bottom. A new array only when a row is added or removed. */
  items: FeedItem[] = [];
  /** Whether messages come in at all: off where motion is reduced. */
  animates = true;

  private version = 0;
  private readonly listeners = new Set<() => void>();
  private transcript: ChatTranscript | null = null;
  private waiting: readonly WaitingPrompt[] = [];
  private byId = new Map<string, FeedItem>();
  private onScreen = false;
  private readonly reveal = new RevealState();
  private revealing: FeedItem[] = [];
  private clock: ReturnType<typeof setTimeout> | null = null;
  private lastTick = 0;

  /** `ticks`: whether the clock runs on its own; tests step it with `tick`. */
  constructor(private readonly ticks = true, private readonly now: () => number = () => performance.now()) {}

  /** For `useSyncExternalStore`: told when the set of rows changes, not when one of them does. */
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  /** The chat's transcript or its waiting messages changed. */
  update(transcript: ChatTranscript | null, waiting: readonly WaitingPrompt[]): void {
    this.transcript = transcript;
    this.waiting = waiting;
    this.rebuild();
  }

  /** The chat came on screen: everything it holds now is history, and just appears. */
  opened(): void {
    this.onScreen = true;
    this.reveal.forget();
    this.rebuild();
  }

  /** The chat left the screen: what is being let out shows whole, and what arrives just shows. */
  closed(): void {
    this.onScreen = false;
    this.rebuild();
  }

  get isOnScreen(): boolean { return this.onScreen; }

  /** Lets every reply being let out on by `ms`; those all out and final show as they are. */
  tick(ms: number): void {
    let done = false;
    let behind = false;
    for (const item of this.revealing) {
      const row = item.row;
      if (row.kind !== "message" || !row.reveal) continue;
      const text = row.message.text;
      const at = RevealPace.next(this.reveal.revealed(item.id), text, ms, row.reveal.hurry);
      this.reveal.progress.set(item.id, at);
      if (at >= text.length && row.reveal.final) {
        this.reveal.finished(item.id);
        done = true;
      } else {
        item.set(row, at);
        if (at < text.length) behind = true;
      }
    }
    if (done) this.rebuild();
    // All that has come is out and more is still to come: nothing to do until it does, and the
    // update that brings it starts the clock again.
    else if (!behind) this.runClock(false);
  }

  private runClock(revealing: boolean): void {
    if (!this.ticks) return;
    if (!revealing) {
      if (this.clock !== null) clearTimeout(this.clock);
      this.clock = null;
      return;
    }
    if (this.clock !== null) return;
    this.lastTick = this.now();
    const step = () => {
      const now = this.now();
      const elapsed = now - this.lastTick;
      this.lastTick = now;
      this.clock = unref(setTimeout(step, RevealPace.frameMs));
      this.tick(elapsed);
    };
    this.clock = unref(setTimeout(step, RevealPace.frameMs));
  }

  /** Stops the clock, for a feed no longer used. */
  dispose(): void { this.runClock(false); }

  private rebuild(): void {
    const transcript = this.transcript;
    const messages = transcript?.messages ?? [];
    const live = transcript?.live ?? [];
    const presenting = this.animates && this.onScreen;
    const shown = presenting
      ? this.reveal.shown(messages, live)
      : [...messages.map(message => ({ message, live: false, enter: false, reveal: null })),
        ...live.map(message => ({ message, live: true, enter: false, reveal: null }))];
    const working = Boolean(transcript?.working);
    const wanted: FeedRow[] = conversationRows(shown, this.waiting).map(row => row.kind === "message"
      ? {
        kind: "message", id: row.message.message.key, message: row.message.message, live: row.message.live,
        enter: row.message.enter, reveal: row.message.reveal,
        // Only a tool's row asks whether Pi is working, so only tools change as it starts and stops.
        working: row.message.message.role === "tool" && working,
      }
      : { kind: "waiting", id: `pending:${row.prompt.id}`, prompt: row.prompt });
    this.keep(wanted, transcript, shown.length < messages.length + live.length);

    this.revealing = this.items.filter(item => item.row.kind === "message" && item.row.reveal !== null);
    for (const item of this.items) {
      const out = item.row.kind === "message" && item.row.reveal ? this.reveal.revealed(item.id) : null;
      item.set(item.row, out);
    }
    this.runClock(this.revealing.length > 0);
  }

  /**
   * Brings the rows to `wanted` without moving one already held: a held row is changed where it
   * is, a new one goes on the end (or the top, before every held row: an older page).
   */
  private keep(wanted: FeedRow[], transcript: ChatTranscript | null, holding: boolean): void {
    const inTranscript = new Set([...(transcript?.messages ?? []), ...(transcript?.live ?? [])].map(message => message.key));
    // A recorded message the transcript no longer has: it was cut back or read again from the
    // start. Nothing held can be trusted to be in its place; the rows start again.
    const reset = this.items.some(item => item.row.kind === "message" && !item.row.live && !inTranscript.has(item.id));
    const before = this.items;
    if (reset) {
      this.items = [];
      this.byId = new Map();
    }

    const top: FeedItem[] = [];
    const bottom: FeedItem[] = [];
    let reachedHeld = false;
    const wantedIds = new Set<string>();
    for (const row of wanted) {
      wantedIds.add(row.id);
      const held = this.byId.get(row.id);
      if (held) {
        reachedHeld = true;
        if (!sameRow(held.row, row)) held.set(row, held.revealed);
      } else {
        const item = new FeedItem(row);
        this.byId.set(row.id, item);
        if (reachedHeld || this.items.length === 0) bottom.push(item);
        else top.push(item);
      }
    }
    const kept = this.items.filter(item => wantedIds.has(item.id) || stays(item, transcript, holding));
    for (const item of this.items) if (!kept.includes(item)) this.byId.delete(item.id);
    const next = [...top, ...kept, ...bottom];
    if (reset || next.length !== before.length || next.some((item, index) => item !== before[index])) {
      this.items = next;
      this.version += 1;
      for (const listener of this.listeners) listener();
    }
  }
}

/** Whether a row the conversation does not list now stays anyway: what it shows is still coming. */
function stays(item: FeedItem, transcript: ChatTranscript | null, holding: boolean): boolean {
  const row = item.row;
  // A reply whose live words were cleared before its record came: it stays as it was until the
  // record takes its place, while Pi works. One with no stamp to know its record by goes.
  if (row.kind === "message") return row.live && item.id.startsWith("reply:") && Boolean(transcript?.working);
  // Taken by the log, its message held back behind a reply still being let out: it stays until
  // that message shows in its place.
  return holding && Boolean(transcript?.delivered.has(row.prompt.id));
}

export type RowReveal = { final: boolean; hurry: boolean };

export type FeedRow =
  | {
    kind: "message"; id: string; message: ChatMessage; live: boolean;
    /** Rises in, once: written while the chat was on screen. */
    enter: boolean;
    /** Its words are let out by the feed's clock. */
    reveal: RowReveal | null;
    /** A tool's row only: whether Pi is working, which a running tool shows. */
    working: boolean;
  }
  | { kind: "waiting"; id: string; prompt: WaitingPrompt };

/** One row, made once and changed in place; its view subscribes to it alone. */
export class FeedItem {
  readonly id: string;
  row: FeedRow;
  /** How many characters of its words are out while they are let out; null when it shows whole. */
  revealed: number | null = null;
  private version = 0;
  private readonly listeners = new Set<() => void>();

  constructor(row: FeedRow) {
    this.id = row.id;
    this.row = row;
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getVersion = (): number => this.version;

  set(row: FeedRow, revealed: number | null): void {
    if (row === this.row && revealed === this.revealed) return;
    this.row = row;
    this.revealed = revealed;
    this.version += 1;
    for (const listener of this.listeners) listener();
  }
}

/** Whether two rows show the same: the transcript rebuilds its messages, and an unchanged one keeps its row. */
function sameRow(a: FeedRow, b: FeedRow): boolean {
  if (a.kind !== b.kind) return false;
  if (a.kind === "waiting" || b.kind === "waiting") {
    if (a.kind !== "waiting" || b.kind !== "waiting") return false;
    const x = a.prompt, y = b.prompt;
    return x === y || (x.id === y.id && x.text === y.text && x.state === y.state && x.delivery === y.delivery
      && x.at === y.at && x.files.length === y.files.length && x.files.every((file, index) => file === y.files[index]));
  }
  return a.live === b.live && a.enter === b.enter && a.working === b.working
    && a.reveal?.final === b.reveal?.final && a.reveal?.hurry === b.reveal?.hurry && (a.reveal === null) === (b.reveal === null)
    && sameMessage(a.message, b.message);
}

function sameMessage(a: ChatMessage, b: ChatMessage): boolean {
  if (a === b) return true;
  return a.key === b.key && a.id === b.id && a.role === b.role && a.text === b.text && a.timestamp === b.timestamp
    && a.images.length === b.images.length && a.images.every((image, index) => image.src === b.images[index]?.src)
    && (a.files?.length ?? 0) === (b.files?.length ?? 0)
    && (a.tool === b.tool || (a.tool !== null && b.tool !== null && a.tool.callId === b.tool.callId
      && a.tool.status === b.tool.status && a.tool.output === b.tool.output && a.tool.outputTruncated === b.tool.outputTruncated
      && a.tool.command === b.tool.command && a.tool.subtitle === b.tool.subtitle && a.tool.name === b.tool.name));
}

type Shown = { message: ChatMessage; live: boolean; enter: boolean; reveal: RowReveal | null };

/**
 * How a message written while its chat is on screen comes in, as on the phone (ConversationReveal).
 *
 * What the chat opened with, and older pages read in above, are history and just appear. So does a
 * batch caught up at once, as after a reconnect: it was written while nobody watched. What is written
 * while the chat is on screen is presented: a reply (and its thinking), seen live or arriving on its
 * own, is let out a word at a time from its first live words through its record, and nothing after
 * it shows until all of it is out; anything else rises in. The person's own messages were on screen
 * already, as pending.
 */
class RevealState {
  private known = new Set<string>();
  private entering = new Set<string>();
  private revealingKeys = new Set<string>();
  private done = new Set<string>();
  readonly progress = new Map<string, number>();

  /** The chat came on screen again: what it holds is history. */
  forget(): void {
    this.known = new Set();
    this.entering = new Set();
    this.revealingKeys = new Set();
    this.done = new Set();
    this.progress.clear();
  }

  revealed(key: string): number { return this.progress.get(key) ?? 0; }

  finished(key: string): void {
    this.done.add(key);
    this.progress.delete(key);
  }

  shown(messages: readonly ChatMessage[], live: readonly ChatMessage[]): Shown[] {
    const all = [...messages.map(message => ({ message, live: false })), ...live.map(message => ({ message, live: true }))];
    if (this.known.size === 0) {
      // Just opened, or its history just came in: what is recorded is history.
      for (const message of messages) this.known.add(message.key);
    }
    let lastKnown = -1;
    all.forEach(({ message }, index) => { if (this.known.has(message.key)) lastKnown = index; });
    const arrived = all.filter(({ message }, index) => !this.known.has(message.key) && index > lastKnown && message.role !== "user");
    // Pieces of one record (thinking, words, tool calls) share its id before the `#`.
    const caughtUp = new Set(arrived.filter(({ live: isLive }) => !isLive).map(({ message }) => message.id.split("#")[0])).size > 1;
    for (const { message } of all) this.known.add(message.key);
    for (const { message, live: isLive } of arrived) {
      const text = message.role === "assistant" || message.role === "thinking";
      if (text && (isLive || !caughtUp)) this.revealingKeys.add(message.key);
      else if (!caughtUp) this.entering.add(message.key);
    }

    const shown: Shown[] = [];
    for (const [index, { message, live: isLive }] of all.entries()) {
      const revealing = this.revealingKeys.has(message.key) && !this.done.has(message.key);
      const more = index < all.length - 1;
      shown.push({
        message, live: isLive, enter: this.entering.has(message.key),
        reveal: revealing ? { final: !isLive || more, hurry: more } : null,
      });
      // What comes after a reply waits until all of it is out.
      if (revealing) break;
    }
    return shown;
  }
}

/**
 * The pace a reply's words are let out at: even, a word at a time, speeding up with the backlog so
 * what is shown never falls far behind what the Mac sent in its uneven bursts; faster still with
 * more waiting behind it. As on the phone (RevealPace).
 */
export const RevealPace = {
  charactersPerSecond: 90,
  catchUpSeconds: 0.6,
  hurriedCharactersPerSecond: 400,
  hurriedCatchUpSeconds: 0.15,
  /** How often what is shown moves on: smooth enough, without parsing a long reply every frame. */
  frameMs: 32,

  next(shown: number, text: string, ms: number, hurry: boolean): number {
    const length = text.length;
    const at = Math.min(shown, length);
    if (at >= length) return length;
    const backlog = length - at;
    const rate = hurry
      ? Math.max(RevealPace.hurriedCharactersPerSecond, backlog / RevealPace.hurriedCatchUpSeconds)
      : Math.max(RevealPace.charactersPerSecond, backlog / RevealPace.catchUpSeconds);
    return wordEnd(text, Math.min(length, at + Math.max(1, Math.round(rate * ms / 1000))));
  },
};

/** The end of the word `at` falls in, so a word never shows half written. */
function wordEnd(text: string, at: number): number {
  const space = text.slice(at).search(/\s/);
  return space < 0 ? text.length : at + space;
}

/** Node keeps running for a pending timer; the clock should not keep the model's tests alive. */
function unref<T>(timer: T): T {
  (timer as { unref?: () => void }).unref?.();
  return timer;
}
