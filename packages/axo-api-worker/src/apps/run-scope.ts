import { DEFAULT_APPS_RUN_LIMITS, type AppsRunLimits } from "@axo/protocol";

/** A budget refusal remains terminal even if script code catches its thrown error. */
export class LimitError extends Error {
  constructor(readonly limit: string, message: string) { super(message); }
}
export const RUN_CLEANUP_MS = 10_000;

/** One fixed deadline and owner for an invocation, never shared across concurrent scripts. */
export class RunScope {
  readonly limits: Readonly<AppsRunLimits>;
  readonly deadline: number;
  private readonly controller = new AbortController();
  private readonly cancelers = new Set<() => Promise<unknown>>();
  private ended = false;
  limitBroken: LimitError | null = null;

  constructor(limits: Readonly<AppsRunLimits> = DEFAULT_APPS_RUN_LIMITS, private readonly now: () => number = Date.now) {
    this.limits = Object.freeze({ ...limits });
    this.deadline = this.now() + limits.timeoutMs;
  }
  get signal(): AbortSignal { return this.controller.signal; }
  get closed(): boolean { return this.ended || this.signal.aborted; }
  remainingMs(): number {
    if (this.closed) throw this.signal.reason ?? new Error("the script has ended");
    const remaining = Math.floor(this.deadline - this.now());
    if (remaining < 1) throw this.fail("timeoutMs", "the script exhausted limits.timeoutMs");
    return remaining;
  }
  check(): void { this.remainingMs(); }
  fail(limit: keyof AppsRunLimits, message: string): LimitError {
    this.limitBroken ??= new LimitError(limit, message);
    this.abort(this.limitBroken);
    return this.limitBroken;
  }
  abort(reason: Error): void { this.controller.abort(reason); }
  /** Register before dispatch, remove after receipt; the owner cancels anything still active. */
  onCancel(cancel: () => Promise<unknown>): () => void {
    this.check();
    this.cancelers.add(cancel);
    return () => { this.cancelers.delete(cancel); };
  }
  async close(): Promise<void> {
    if (this.ended) return;
    this.ended = true;
    const cancelers = [...this.cancelers];
    this.cancelers.clear();
    this.controller.abort(new Error("the script has ended"));
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        Promise.allSettled(cancelers.map(cancel => Promise.resolve().then(cancel))),
        new Promise<void>(resolve => { timer = setTimeout(resolve, RUN_CLEANUP_MS); }),
      ]);
    } finally { clearTimeout(timer); }
  }
}

/** Count the actual response envelope, not UTF-16 code units or the result alone. */
export function outputBytes(result: unknown, logs: string[]): number {
  return new TextEncoder().encode(JSON.stringify({ result, logs })).byteLength;
}
