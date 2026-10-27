/**
 * What the bridge sends for each Pi event, shaped to cross the wire.
 *
 * Axod forwards an event of at most 60 000 bytes and skips a larger one, so a payload that can
 * grow without bound (a long reply, a command's output, a file a tool wrote) is cut down here:
 * long strings are shortened, and the message says it was (`truncated: true`). Pi's own
 * transcript on the Mac keeps everything.
 *
 * Progress events (`message.update`, `tool.update`) arrive per token or per line, and each
 * repeats everything so far. They are sent at most every `PROGRESS_INTERVAL_MS`, the latest
 * winning, and a pending one is dropped once its message or tool has finished.
 */

/** Below Axod's 60 000 byte limit, with room for the event's envelope. */
export const EVENT_DATA_BUDGET_BYTES = 56_000;
export const PROGRESS_INTERVAL_MS = 200;

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

function byteLength(value: unknown): number {
  const encoded = JSON.stringify(value);
  return encoded === undefined ? 0 : Buffer.byteLength(encoded, "utf8");
}

/** Signatures are opaque provider tokens, often larger than the text they sign. */
const DROPPED_KEYS = new Set(["thinkingSignature", "textSignature", "signature"]);

function shorten(value: unknown, limit: number): { value: Json; cut: boolean } {
  if (typeof value === "string") {
    if (value.length <= limit) return { value, cut: false };
    return { value: `${value.slice(0, limit)}…`, cut: true };
  }
  if (Array.isArray(value)) {
    let cut = false;
    const items = value.map(item => {
      const shortened = shorten(item, limit);
      cut ||= shortened.cut;
      return shortened.value;
    });
    return { value: items, cut };
  }
  if (typeof value === "object" && value !== null) {
    let cut = false;
    const object: { [key: string]: Json } = {};
    for (const [key, item] of Object.entries(value)) {
      if (DROPPED_KEYS.has(key) || item === undefined || typeof item === "function") continue;
      const shortened = shorten(item, limit);
      cut ||= shortened.cut;
      object[key] = shortened.value;
    }
    return { value: object, cut };
  }
  if (typeof value === "number" || typeof value === "boolean" || value === null) return { value, cut: false };
  return { value: null, cut: false };
}

/**
 * `value` within `budget` bytes: unchanged if it fits (bar signatures), else with every string
 * cut to the longest length that fits. `truncated` says whether anything was cut.
 */
export function fit(value: unknown, budget = EVENT_DATA_BUDGET_BYTES): { value: Json; truncated: boolean } {
  const whole = shorten(value, Number.MAX_SAFE_INTEGER);
  if (byteLength(whole.value) <= budget) return { value: whole.value, truncated: false };
  for (const limit of [32_000, 16_000, 8_000, 4_000, 2_000, 1_000, 500, 200, 80]) {
    const shortened = shorten(value, limit);
    if (byteLength(shortened.value) <= budget) return { value: shortened.value, truncated: true };
  }
  return { value: null, truncated: true };
}

/** A message for the wire, marked `truncated` when its text had to be cut. */
export function fitMessage(message: unknown): Json {
  const fitted = fit(message);
  if (!fitted.truncated || typeof fitted.value !== "object" || fitted.value === null || Array.isArray(fitted.value)) {
    return fitted.value;
  }
  return { ...fitted.value, truncated: true };
}

/** Pi's event payloads, as far as the shaping needs to know them. */
interface MessageEvent { type?: string; message?: unknown }
interface ToolEvent { toolCallId?: string; toolName?: string; args?: unknown; partialResult?: unknown; result?: unknown; isError?: boolean }
interface TurnEndEvent { turnIndex?: number; messageEntryId?: string; toolResultEntryIds?: unknown; outcome?: unknown }

export function messageEvent(event: MessageEvent): Json {
  return { type: event.type ?? null, message: fitMessage(event.message) };
}

export function toolEvent(event: ToolEvent): Json {
  const fitted = fit({
    toolCallId: event.toolCallId ?? null,
    toolName: event.toolName ?? null,
    ...(event.args === undefined ? {} : { args: event.args }),
    ...(event.partialResult === undefined ? {} : { partialResult: event.partialResult }),
    ...(event.result === undefined ? {} : { result: event.result }),
    ...(event.isError === undefined ? {} : { isError: event.isError }),
  });
  if (!fitted.truncated || typeof fitted.value !== "object" || fitted.value === null || Array.isArray(fitted.value)) {
    return fitted.value;
  }
  return { ...fitted.value, truncated: true };
}

/** The turn's messages already went out one by one (`message.end`); only the turn's facts remain. */
export function turnEndEvent(event: TurnEndEvent): Json {
  return fit({
    turnIndex: event.turnIndex ?? null,
    messageEntryId: event.messageEntryId ?? null,
    toolResultEntryIds: event.toolResultEntryIds ?? null,
    outcome: event.outcome ?? null,
  }).value;
}

/**
 * Sends progress at most every `interval` ms per key, the latest value winning. `finish(key)`
 * drops what is pending for a key, for when its final event is about to go out.
 */
export class ProgressThrottle {
  private readonly pending = new Map<string, { timer: ReturnType<typeof setTimeout> | undefined; data: Json | undefined }>();

  constructor(
    private readonly send: (name: string, data: Json) => void,
    private readonly interval = PROGRESS_INTERVAL_MS,
  ) {}

  offer(name: string, key: string, data: Json): void {
    const slot = this.pending.get(`${name}\u0000${key}`);
    if (slot === undefined) {
      // The first update goes out at once; later ones wait for the interval.
      this.send(name, data);
      this.schedule(name, key);
      return;
    }
    slot.data = data;
  }

  finish(name: string, key: string): void {
    const id = `${name}\u0000${key}`;
    const slot = this.pending.get(id);
    if (slot?.timer !== undefined) clearTimeout(slot.timer);
    this.pending.delete(id);
  }

  finishAll(): void {
    for (const slot of this.pending.values()) if (slot.timer !== undefined) clearTimeout(slot.timer);
    this.pending.clear();
  }

  private schedule(name: string, key: string): void {
    const id = `${name}\u0000${key}`;
    const slot: { timer: ReturnType<typeof setTimeout> | undefined; data: Json | undefined } = { timer: undefined, data: undefined };
    slot.timer = setTimeout(() => {
      const data = slot.data;
      this.pending.delete(id);
      if (data !== undefined) {
        this.send(name, data);
        this.schedule(name, key);
      }
    }, this.interval);
    slot.timer.unref?.();
    this.pending.set(id, slot);
  }
}
