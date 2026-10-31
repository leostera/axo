import { z } from "zod";
import {
  BASH_METHOD,
  CONNECTIONS_ERRORS,
  CONNECTIONS_LIMITS,
  CONNECTIONS_METHODS,
  bashResultSchema,
  connectionsParams,
  isConnectionsMethod,
  type BashResult,
  type Connection,
  type ConnectionsMethod,
  type ConnectionsParams,
  type ConnectionsResult,
  type ToolDefinition,
} from "@axo/protocol";
import { recordApiEvent } from "../observability";
import { CallLog } from "./call-log";
import { LimitError, runScript, type Loader, type ScriptOutcome, type ToolCaller } from "./runner";

/**
 * An account's connections (RFD0016): what `axo.connections.*` calls from its Macs reach. It
 * lives inside the account's AxoAccountManager and keeps all connections state there; a Mac's
 * socket owner (its HostDO) only forwards calls here and carries `bash` to a Mac for it.
 *
 * In this version the connections are the account's paired Macs, each with one tool, `bash`.
 */

/** What a HostDO forwards: the calling Mac, the boot it called from, and its request. */
export type ConnectionsCall = { hostId: string; hostGeneration: string; method: string; params: unknown };
export type CallOutcome = { result: unknown } | { error: { code: number; message: string } };

export type HostLink = { hostId: string; hostGeneration: string; label: string; linkedAt: number };

export type ConnectionsDeps = {
  sql: SqlStorage;
  secret: string;
  accountId: string;
  loader: Loader;
  /** The hosts the account owns now, oldest pairing first. */
  hosts(): HostLink[];
  presence(hostId: string): Promise<{ online: boolean; hostGeneration: string | null }>;
  callHost(hostId: string, request: { method: string; params: unknown; deadlineMs: number }): Promise<CallOutcome>;
};

/** Extra time a `bash` call waits beyond the command's own timeout, for the round trip. */
const BASH_GRACE_MS = 15_000;

const bashInputSchema = z.object({
  command: z.string().min(1).max(CONNECTIONS_LIMITS.scriptBytes),
  cwd: z.string().regex(/^\//, "cwd must be an absolute path").max(4096).optional(),
  timeoutMs: z.number().int().min(1).max(CONNECTIONS_LIMITS.bashMaxTimeoutMs).optional(),
}).strict();

type Caller = { hostId: string; sessionId: string };

export class AccountConnections {
  private readonly log: CallLog;

  constructor(private readonly deps: ConnectionsDeps) {
    this.log = new CallLog(deps.sql, deps.secret, deps.accountId);
  }

  async call(call: ConnectionsCall): Promise<CallOutcome> {
    const host = this.deps.hosts().find((h) => h.hostId === call.hostId);
    if (!host || host.hostGeneration !== call.hostGeneration) return failure(-32002, "Stale host");
    if (!isConnectionsMethod(call.method)) return failure(-32601, "Method not found");
    const parsed = connectionsParams[call.method].safeParse(call.params);
    if (!parsed.success) return failure(-32602, `Invalid params: ${z.prettifyError(parsed.error)}`.slice(0, 512));
    const caller = { hostId: call.hostId, sessionId: (parsed.data as { sessionId: string }).sessionId };
    const started = Date.now();
    let outcome: CallOutcome;
    try {
      outcome = await this.dispatch(call.method, parsed.data, caller);
    } catch (error) {
      outcome = failure(-32603, error instanceof Error ? error.message.slice(0, 512) : "Internal error");
    }
    recordApiEvent({
      event: "connections_call",
      method: call.method,
      outcome: "result" in outcome ? "result" : String(outcome.error.code),
      durationMs: Date.now() - started,
    });
    return outcome;
  }

  private async dispatch(method: ConnectionsMethod, params: unknown, caller: Caller): Promise<CallOutcome> {
    switch (method) {
      case CONNECTIONS_METHODS.list:
        return { result: await this.list() };
      case CONNECTIONS_METHODS.search: {
        const { code } = params as ConnectionsParams<typeof CONNECTIONS_METHODS.search>;
        return scriptOutcome(await runScript(this.deps.loader, code, this.tools(), null), (o) => ({ result: o.result }));
      }
      case CONNECTIONS_METHODS.execute: {
        const { code } = params as ConnectionsParams<typeof CONNECTIONS_METHODS.execute>;
        const deadline = Date.now() + CONNECTIONS_LIMITS.scriptWallMs;
        const outcome = await runScript(this.deps.loader, code, this.tools(), this.caller(caller, deadline));
        return scriptOutcome(outcome, (o) => ({ result: o.result, logs: o.logs }));
      }
      case CONNECTIONS_METHODS.log: {
        const { limit, before } = params as ConnectionsParams<typeof CONNECTIONS_METHODS.log>;
        const result: ConnectionsResult<typeof CONNECTIONS_METHODS.log> = { records: await this.log.read(limit, before) };
        return { result };
      }
      case CONNECTIONS_METHODS.add:
      case CONNECTIONS_METHODS.remove:
        return failure(-32601, "Third-party connections are not available yet; only host connections are");
    }
  }

  async list(): Promise<ConnectionsResult<typeof CONNECTIONS_METHODS.list>> {
    const named = this.named();
    const connections = await Promise.all(named.map(async ({ name, host }): Promise<Connection> => {
      const presence = await this.deps.presence(host.hostId).catch(() => null);
      const online = Boolean(presence?.online && presence.hostGeneration === host.hostGeneration);
      return { kind: "host", name, hostId: host.hostId, state: online ? "online" : "offline" };
    }));
    return { connections };
  }

  /** Every tool a script can reach, as `codemode.tools()` shows them. */
  tools(): ToolDefinition[] {
    return this.named().map(({ name, host }) => ({
      service: name,
      name: "bash",
      title: "bash",
      description:
        `Runs one non-interactive command on the Mac "${host.label}" as the user axod runs as, with its login shell, ` +
        "and returns { exitCode, signal, stdout, stderr, stdoutTruncated, stderrTruncated, timedOut, durationMs }. " +
        `Each output stream keeps ${CONNECTIONS_LIMITS.bashOutputBytes} bytes, then is marked truncated. ` +
        `timeoutMs defaults to ${CONNECTIONS_LIMITS.bashDefaultTimeoutMs} and may be at most ${CONNECTIONS_LIMITS.bashMaxTimeoutMs}.`,
      inputSchema: z.toJSONSchema(bashInputSchema) as Record<string, unknown>,
    }));
  }

  /** The Macs as services: each takes its label as a JavaScript-safe name, unique in the account. */
  private named(): Array<{ name: string; host: HostLink }> {
    const taken = new Set<string>();
    return this.deps.hosts().map((host) => {
      const base = serviceName(host.label);
      let name = base;
      for (let n = 2; taken.has(name); n++) name = `${base}_${n}`;
      taken.add(name);
      return { name, host };
    });
  }

  /**
   * Dispatches a script's tool calls. The target is looked up again for every call, so a Mac
   * unpaired mid-script runs nothing after it. Each call is logged before it is sent and never
   * retried: a call that got no answer may have run.
   */
  private caller(from: Caller, deadline: number): ToolCaller {
    return async (service, tool, input) => {
      const target = this.named().find((entry) => entry.name === service);
      if (!target) throw new Error(`no connection named ${service}`);
      if (tool !== "bash") throw new Error(`${service} has no tool named ${tool}; a Mac has only bash`);
      const parsed = bashInputSchema.safeParse(input);
      if (!parsed.success) throw new Error(`${service}.bash: ${z.prettifyError(parsed.error)}`);
      const remaining = deadline - Date.now();
      if (remaining <= 1_000) throw new LimitError("scriptWallMs", "the script has no time left for another command");
      const timeoutMs = Math.min(parsed.data.timeoutMs ?? CONNECTIONS_LIMITS.bashDefaultTimeoutMs, remaining);
      const callId = crypto.randomUUID();
      await this.log.start({
        callId,
        sessionId: from.sessionId,
        hostId: from.hostId,
        service,
        tool,
        targetHostId: target.host.hostId,
        input: { command: parsed.data.command, cwd: parsed.data.cwd ?? null, timeoutMs },
      });
      let outcome: CallOutcome;
      try {
        outcome = await this.deps.callHost(target.host.hostId, {
          method: BASH_METHOD,
          params: { accountId: this.deps.accountId, callId, command: parsed.data.command, ...(parsed.data.cwd ? { cwd: parsed.data.cwd } : {}), timeoutMs },
          deadlineMs: timeoutMs + BASH_GRACE_MS,
        });
      } catch {
        outcome = failure(CONNECTIONS_ERRORS.outcomeUnknown, `${service} did not answer; the command may have run`);
      }
      if ("error" in outcome) {
        const unknown = outcome.error.code === CONNECTIONS_ERRORS.outcomeUnknown;
        this.log.finish(callId, unknown ? "unknown" : "error", outcome.error.message);
        throw new Error(`${service}: ${outcome.error.message}`);
      }
      const result = bashResultSchema.safeParse(outcome.result);
      if (!result.success) {
        this.log.finish(callId, "unknown", "the Mac's reply was not a bash result");
        throw new Error(`${service}: the Mac's reply was not a bash result; the command may have run`);
      }
      this.log.finish(callId, "ok", null);
      return result.data satisfies BashResult;
    };
  }
}

/** A label as a service name: lowercase letters, digits and `_`, not starting with a digit. */
export function serviceName(label: string): string {
  const name = label.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 48);
  if (!name) return "mac";
  return /^[0-9]/.test(name) ? `mac_${name}` : name;
}

function failure(code: number, message: string): CallOutcome {
  return { error: { code, message } };
}

function scriptOutcome(outcome: ScriptOutcome, result: (ok: Extract<ScriptOutcome, { ok: true }>) => unknown): CallOutcome {
  if (outcome.ok) return { result: result(outcome) };
  const logs = outcome.logs.length ? `\n\nconsole output:\n${outcome.logs.join("\n")}` : "";
  const code = outcome.limit ? CONNECTIONS_ERRORS.limitExceeded : CONNECTIONS_ERRORS.scriptFailed;
  return failure(code, `${outcome.error}${logs}`.slice(0, 16_384));
}
