import { RpcTarget } from "cloudflare:workers";
import { APPS_LIMITS, DEFAULT_APPS_RUN_LIMITS, type AppsRunLimits, type ToolDefinition } from "@axo/protocol";
import { LimitError, outputBytes, RunScope } from "./run-scope";
export { LimitError } from "./run-scope";

/** Dynamic Workers have no outbound network/bindings; the account owns every budget and call. */
export type ToolCaller = (service: string, tool: string, input: unknown, run: RunScope) => Promise<unknown>;
export type ScriptOutcome =
  | { ok: true; result: unknown; logs: string[] }
  | { ok: false; error: string; limit?: string; uncertain?: boolean; logs: string[] };

export class ToolDispatcher extends RpcTarget {
  private calls = 0;
  private running = 0;
  private readonly waiting: Array<() => void> = [];
  private closed = false;
  dispatched = 0;
  readonly logs: string[] = [];
  private logBytes = outputBytes(0, []);
  get pending(): number { return this.running + this.waiting.length; }
  constructor(private readonly caller: ToolCaller | null, private readonly run: RunScope) { super(); }

  /** Console output is charged at the account boundary, not trusted to the script's Worker. */
  log(line: unknown): void {
    this.run.check();
    if (typeof line !== "string") throw new Error("console output must be text");
    const added = new TextEncoder().encode(JSON.stringify(line)).byteLength + (this.logs.length ? 1 : 0);
    if (this.logBytes + added > this.run.limits.maxOutputBytes) this.outputLimit();
    this.logBytes += added;
    this.logs.push(line);
  }
  outputLimit(): never {
    throw this.run.fail("maxOutputBytes", "limits.maxOutputBytes exceeded by console output");
  }

  /** JSON only. Admission is charged before queueing, and closure is rechecked after every wait. */
  async call(service: string, tool: string, inputJson: string): Promise<string> {
    this.run.check();
    if (this.closed) throw new Error("the script has ended");
    if (!this.caller) throw new Error("apps_search cannot call tools; use apps_run");
    if (this.calls >= this.run.limits.maxToolCalls)
      throw this.run.fail("maxToolCalls", `limits.maxToolCalls permits at most ${this.run.limits.maxToolCalls} tool calls`);
    this.calls++;
    const input: unknown = JSON.parse(inputJson);
    const concurrency = Math.min(this.run.limits.maxConcurrentCalls, this.run.limits.maxToolCalls);
    while (!this.closed && this.running >= concurrency) await new Promise<void>(go => this.waiting.push(go));
    this.run.check();
    if (this.closed) throw new Error("the script has ended");
    this.running++;
    this.dispatched++;
    try {
      return JSON.stringify((await this.caller(service, tool, input, this.run)) ?? null);
    } catch (error) {
      if (error instanceof LimitError) {
        this.run.limitBroken ??= error;
        this.run.abort(error);
      }
      throw new Error(error instanceof Error ? error.message : String(error));
    } finally {
      this.running--;
      this.waiting.shift()?.();
    }
  }
  close(): void {
    this.closed = true;
    for (const go of this.waiting.splice(0)) go();
  }
}

const WORKER_SOURCE = `import { WorkerEntrypoint } from "cloudflare:workers";
const show = (value) => typeof value === "string" ? value : (() => { try { return JSON.stringify(value); } catch { return String(value); } })();
export default class extends WorkerEntrypoint {
  async evaluate(dispatcher, toolsJson, maxOutputBytes) {
    const logs = [];
    const encoder = new TextEncoder();
    let logBytes = 2;
    let overflow = false;
    let loggingError = null;
    const pendingLogs = [];
    const trackLog = (promise) => { pendingLogs.push(promise.catch(error => { loggingError = error; })); };
    const flushLogs = async () => { await Promise.all(pendingLogs); if (loggingError) throw loggingError; };
    const log = (...values) => {
      const line = values.map(show).join(" ");
      const bytes = encoder.encode(JSON.stringify(line)).byteLength + (logs.length ? 1 : 0);
      if (logBytes + bytes > maxOutputBytes) { overflow = true; trackLog(dispatcher.outputLimit()); throw new Error("limits.maxOutputBytes exceeded by console output"); }
      logBytes += bytes;
      logs.push(line);
      trackLog(dispatcher.log(line));
    };
    const console = { log, info: log, warn: log, error: log, debug: log };
    const tools = JSON.parse(toolsJson);
    const toolsOf = (service) => new Proxy({}, {
      get(_, tool) {
        if (typeof tool !== "string" || tool === "then") return undefined;
        return async (input = {}) => { await flushLogs(); return JSON.parse(await dispatcher.call(service, tool, JSON.stringify(input))); };
      },
    });
    const apps = new Proxy({}, {
      get(_, app) {
        if (typeof app !== "string" || app === "then") return undefined;
        return toolsOf("apps." + app);
      },
    });
    const codemode = new Proxy({}, {
      get(_, service) {
        if (service === "tools") return () => structuredClone(tools);
        if (service === "apps") return apps;
        if (typeof service !== "string" || service === "then") return undefined;
        return toolsOf(service);
      },
    });
    try {
      const fn = (__SCRIPT__);
      if (typeof fn !== "function") throw new TypeError("the script must be a function, such as async () => { ... }");
      const result = await fn();
      await flushLogs();
      if (overflow) return { ok: false, error: "limits.maxOutputBytes exceeded by console output", limit: "maxOutputBytes", logs };
      return { ok: true, result: result === undefined ? null : JSON.parse(JSON.stringify(result)), logs };
    } catch (error) {
      await flushLogs().catch(() => {});
      return { ok: false, error: error instanceof Error ? (error.stack || error.message) : show(error), ...(overflow ? {limit: "maxOutputBytes"} : {}), logs };
    }
  }
}
`;

export type Loader = Pick<WorkerLoader, "get">;
type Evaluation = Promise<ScriptOutcome> & Partial<Disposable>;
type ScriptEntrypoint = Partial<Disposable> & {
  evaluate(dispatcher: ToolDispatcher, toolsJson: string, maxOutputBytes: number): Evaluation;
};
export async function runScript(
  loader: Loader, script: string, tools: ToolDefinition[], caller: ToolCaller | null,
  limits: Readonly<AppsRunLimits> = DEFAULT_APPS_RUN_LIMITS,
): Promise<ScriptOutcome> {
  if (new TextEncoder().encode(script).byteLength > APPS_LIMITS.scriptBytes)
    return { ok: false, error: `a script may be at most ${APPS_LIMITS.scriptBytes} bytes`, limit: "scriptBytes", logs: [] };
  const run = new RunScope(limits);
  const dispatcher = new ToolDispatcher(caller, run);
  const source = WORKER_SOURCE.replace("__SCRIPT__", () => `\n${script}\n`);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let evaluation: Evaluation | undefined;
  let entrypoint: ScriptEntrypoint | undefined;
  const aborted = new Promise<ScriptOutcome>(resolve => {
    run.signal.addEventListener("abort", () => {
      dispatcher.close();
      resolve({ ok: false, error: run.limitBroken?.message ?? "the script has ended", limit: run.limitBroken?.limit, logs: [] });
    }, { once: true });
  });
  try {
    timer = setTimeout(() => run.fail("timeoutMs", `limits.timeoutMs exceeded (${limits.timeoutMs} ms)`), run.remainingMs());
    const worker = loader.get(`script:${await digest(source)}`, () => ({
      compatibilityDate: "2026-10-09", mainModule: "script.js", modules: { "script.js": source }, env: {}, globalOutbound: null,
    }));
    entrypoint = worker.getEntrypoint() as unknown as ScriptEntrypoint;
    run.check();
    evaluation = entrypoint.evaluate(dispatcher, JSON.stringify(tools), limits.maxOutputBytes);
    let outcome = await Promise.race([
      evaluation.then(plain).catch((error: unknown): ScriptOutcome => ({ ok: false,
        error: `the script's Worker failed: ${error instanceof Error ? error.message : String(error)}`, uncertain: dispatcher.dispatched > 0, logs: [] })),
      aborted,
    ]);
    outcome.logs = [...dispatcher.logs];
    if (run.limitBroken) outcome = { ok: false, error: run.limitBroken.message, limit: run.limitBroken.limit, logs: outcome.logs };
    if (outcome.ok && outputBytes(outcome.result, outcome.logs) > limits.maxOutputBytes)
      outcome = { ok: false, error: `limits.maxOutputBytes exceeded (${limits.maxOutputBytes} UTF-8 JSON bytes including logs)`, limit: "maxOutputBytes", logs: [] };
    if (outcome.ok && dispatcher.pending)
      outcome = { ok: false, error: "the script returned with unawaited tool calls", uncertain: true, logs: outcome.logs };
    if (!outcome.ok && dispatcher.pending) outcome.uncertain = true;
    if (!outcome.ok && dispatcher.dispatched && (outcome.limit || outcome.uncertain))
      outcome.error = `dispatched actions may have run; check before retrying. ${outcome.error}`;
    return outcome;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, error: dispatcher.dispatched ? `dispatched actions may have run; check before retrying. ${message}` : message,
      limit: run.limitBroken?.limit, uncertain: dispatcher.dispatched > 0, logs: [] };
  } finally {
    clearTimeout(timer);
    dispatcher.close();
    // Close admission before releasing the sandbox. Host/process cleanup has a separate bound.
    try { await run.close(); }
    finally {
      disposeRpc(evaluation);
      disposeRpc(entrypoint);
    }
  }
}

function disposeRpc(resource: Partial<Disposable> | undefined): void {
  // An already-settled/cancelled RPC may be gone. Disposal must never bypass owned cleanup.
  try { resource?.[Symbol.dispose]?.(); } catch { /* admission is closed regardless */ }
}

function plain(outcome: unknown): ScriptOutcome {
  try {
    const value: unknown = JSON.parse(JSON.stringify(outcome));
    if (value === null || typeof value !== "object" || !("ok" in value)) throw new Error("invalid script Worker outcome");
    // The sandbox is untrusted: console records and budget violations come only from the account.
    if (value.ok === true && "result" in value) return { ok: true, result: value.result, logs: [] };
    if (value.ok === false && "error" in value && typeof value.error === "string")
      return { ok: false, error: value.error.slice(0, 16_384), logs: [] };
    throw new Error("invalid script Worker outcome");
  } finally { disposeRpc(outcome as Partial<Disposable>); }
}
async function digest(text: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return [...bytes.slice(0, 16)].map(b => b.toString(16).padStart(2, "0")).join("");
}
