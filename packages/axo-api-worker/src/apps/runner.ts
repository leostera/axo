import { RpcTarget } from "cloudflare:workers";
import { APPS_LIMITS, type ToolDefinition } from "@axo/protocol";

/**
 * Runs a apps script in a Dynamic Worker (RFD0016, One execution place).
 *
 * The script is an async JavaScript function. It runs in a Worker loaded for it with no network
 * of its own (`globalOutbound: null`) and no bindings; its only way out is the `codemode` proxy,
 * whose methods call back into the account's Durable Object through a `ToolDispatcher` handed to
 * it over RPC. The Durable Object enforces every limit: the Worker is trusted with nothing.
 */

export type ToolCaller = (service: string, tool: string, input: unknown) => Promise<unknown>;

export type ScriptOutcome =
  | { ok: true; result: unknown; logs: string[] }
  | { ok: false; error: string; limit?: string; logs: string[] };

/** A tool call refused by a limit; the script sees it as a thrown error naming the limit. */
export class LimitError extends Error {
  constructor(readonly limit: string, message: string) {
    super(message);
  }
}

/**
 * What the script's Worker calls back into. Counts calls against the script's limit, keeps at
 * most `concurrentCallsPerScript` running, and refuses everything once the script has ended.
 */
export class ToolDispatcher extends RpcTarget {
  private calls = 0;
  private running = 0;
  private readonly waiting: Array<() => void> = [];
  private closed = false;
  /** Set when a call broke a limit, so the script fails with it even if it caught the error. */
  limitBroken: LimitError | null = null;

  constructor(private readonly caller: ToolCaller | null) {
    super();
  }

  /** Inputs and outputs cross as JSON text, so nothing but plain data reaches either side. */
  async call(service: string, tool: string, inputJson: string): Promise<string> {
    if (this.closed) throw new Error("the script has ended");
    if (!this.caller) throw new Error("apps_search cannot call tools; use apps_run");
    if (this.calls >= APPS_LIMITS.callsPerScript) {
      this.limitBroken ??= new LimitError("callsPerScript", `a script may make at most ${APPS_LIMITS.callsPerScript} tool calls`);
      throw new Error(this.limitBroken.message);
    }
    this.calls += 1;
    let input: unknown;
    try {
      input = JSON.parse(inputJson);
    } catch {
      throw new Error("tool input must be JSON");
    }
    while (this.running >= APPS_LIMITS.concurrentCallsPerScript) await new Promise<void>((go) => this.waiting.push(go));
    if (this.closed) throw new Error("the script has ended");
    this.running += 1;
    try {
      return JSON.stringify((await this.caller(service, tool, input)) ?? null);
    } catch (error) {
      if (error instanceof LimitError) this.limitBroken ??= error;
      throw new Error(error instanceof Error ? error.message : String(error));
    } finally {
      this.running -= 1;
      this.waiting.shift()?.();
    }
  }

  close(): void {
    this.closed = true;
    for (const go of this.waiting.splice(0)) go();
  }
}

/** The script's Worker. `__SCRIPT__` is replaced with the script's source, as an expression. */
const WORKER_SOURCE = `import { WorkerEntrypoint } from "cloudflare:workers";
const show = (value) => typeof value === "string" ? value : (() => { try { return JSON.stringify(value); } catch { return String(value); } })();
export default class extends WorkerEntrypoint {
  async evaluate(dispatcher, toolsJson) {
    const logs = [];
    const log = (...values) => { if (logs.length < 200) logs.push(values.map(show).join(" ").slice(0, 4096)); };
    const console = { log, info: log, warn: log, error: log, debug: log };
    const tools = JSON.parse(toolsJson);
    const toolsOf = (service) => new Proxy({}, {
      get(_, tool) {
        if (typeof tool !== "string" || tool === "then") return undefined;
        return async (input = {}) => JSON.parse(await dispatcher.call(service, tool, JSON.stringify(input)));
      },
    });
    // codemode.apps.<app>.<tool>() reaches the apps Axo provides, as service "apps.<app>".
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
      return { ok: true, result: result === undefined ? null : JSON.parse(JSON.stringify(result)), logs };
    } catch (error) {
      return { ok: false, error: error instanceof Error ? (error.stack || error.message) : show(error), logs };
    }
  }
}
`;

export type Loader = Pick<WorkerLoader, "get">;

/**
 * Runs `script` with `tools` visible through `codemode.tools()` and `caller` behind every other
 * `codemode.<service>.<tool>()` and `codemode.apps.<app>.<tool>()`. A null caller runs a search: the script may read the tools but
 * call none. The run ends at its wall time, after which every call it makes is refused.
 */
export async function runScript(
  loader: Loader,
  script: string,
  tools: ToolDefinition[],
  caller: ToolCaller | null,
  wallMs: number = APPS_LIMITS.scriptWallMs,
): Promise<ScriptOutcome> {
  if (new TextEncoder().encode(script).byteLength > APPS_LIMITS.scriptBytes)
    return { ok: false, error: `a script may be at most ${APPS_LIMITS.scriptBytes} bytes`, limit: "scriptBytes", logs: [] };
  const source = WORKER_SOURCE.replace("__SCRIPT__", () => `\n${script}\n`);
  const name = `script:${await digest(source)}`;
  const worker = loader.get(name, () => ({
    compatibilityDate: "2026-10-09",
    mainModule: "script.js",
    modules: { "script.js": source },
    env: {},
    globalOutbound: null,
  }));
  const entrypoint = worker.getEntrypoint() as unknown as {
    evaluate(dispatcher: ToolDispatcher, toolsJson: string): Promise<ScriptOutcome>;
  };
  const dispatcher = new ToolDispatcher(caller);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timedOut = new Promise<ScriptOutcome>((resolve) => {
    timer = setTimeout(() => resolve({
      ok: false,
      error: `the script ran past its wall time of ${wallMs / 1000} seconds; calls in flight may have run`,
      limit: "scriptWallMs",
      logs: [],
    }), wallMs);
  });
  try {
    const outcome = await Promise.race([
      entrypoint.evaluate(dispatcher, JSON.stringify(tools)).then(plain).catch((error: unknown): ScriptOutcome => ({
        ok: false,
        error: `the script's Worker failed: ${error instanceof Error ? error.message : String(error)}`,
        logs: [],
      })),
      timedOut,
    ]);
    if (dispatcher.limitBroken && outcome.ok)
      return { ok: false, error: dispatcher.limitBroken.message, limit: dispatcher.limitBroken.limit, logs: outcome.logs };
    if (outcome.ok && JSON.stringify(outcome.result).length > APPS_LIMITS.resultBytes)
      return { ok: false, error: `a script's result may be at most ${APPS_LIMITS.resultBytes} bytes of JSON`, limit: "resultBytes", logs: outcome.logs };
    return outcome;
  } finally {
    clearTimeout(timer);
    dispatcher.close();
  }
}

/** RPC results arrive as proxies holding resources; this keeps plain data and lets them go. */
function plain(outcome: ScriptOutcome): ScriptOutcome {
  const copy = JSON.parse(JSON.stringify(outcome)) as ScriptOutcome;
  (outcome as Partial<Disposable>)[Symbol.dispose]?.();
  return copy;
}

async function digest(text: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return [...bytes.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
