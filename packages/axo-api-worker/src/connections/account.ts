import { z } from "zod";
import {
  APPS_NAMESPACE,
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
import { ThirdPartyConnections } from "./third-party";
import { McpOutcomeUnknown } from "./mcp-client";
import type { Client } from "./oauth";
import { AppAccountRefused, AppConnections, appPage } from "./apps";
import { ProviderError, ProviderOutcomeUnknown } from "@axo/apps";
import type { GoogleClient } from "./apps/google";

/**
 * An account's connections (RFD0016): what `axo.connections.*` calls from its Macs reach. It
 * lives inside the account's AxoAccountManager and keeps all connections state there; a Mac's
 * socket owner (its HostDO) only forwards calls here and carries `bash` to a Mac for it.
 *
 * Connections are the account's paired Macs, each with one tool, `bash`, the remote MCP
 * servers it added (third-party connections), and the apps Axo provides (`apps.<app>`), the
 * last two called from here with grants kept here.
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
  /**
   * Google's client from the Worker's environment, from before OAuth clients were the person's:
   * used only while the account has set up none of its own (AppsDeps.legacyGoogle).
   */
  google: GoogleClient | null;
  fetcher: typeof fetch;
  waitUntil(promise: Promise<unknown>): void;
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
  readonly thirdParty: ThirdPartyConnections;
  readonly apps: AppConnections;

  constructor(private readonly deps: ConnectionsDeps) {
    this.log = new CallLog(deps.sql, deps.secret, deps.accountId);
    this.thirdParty = new ThirdPartyConnections({
      sql: deps.sql, secret: deps.secret, accountId: deps.accountId, fetcher: deps.fetcher, waitUntil: deps.waitUntil,
    });
    this.apps = new AppConnections({
      sql: deps.sql, secret: deps.secret, accountId: deps.accountId, legacyGoogle: deps.google, fetcher: deps.fetcher, waitUntil: deps.waitUntil,
      // Mac apps (1Password) run their commands on the account's Macs, as `bash` does.
      macs: () => this.named().map((entry) => entry.name),
      runOnMac: (mac, command, timeoutMs) => this.runOnMac(mac, command, timeoutMs),
    });
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
        const { limit, before, service } = params as ConnectionsParams<typeof CONNECTIONS_METHODS.log>;
        const result: ConnectionsResult<typeof CONNECTIONS_METHODS.log> = { records: await this.log.read(limit, before, service) };
        return { result };
      }
      case CONNECTIONS_METHODS.add: {
        const { name, url } = params as ConnectionsParams<typeof CONNECTIONS_METHODS.add>;
        return this.add(name, url);
      }
      case CONNECTIONS_METHODS.remove: {
        const { name, account } = params as ConnectionsParams<typeof CONNECTIONS_METHODS.remove>;
        return await this.remove(name, account);
      }
    }
  }

  /** Adds a third-party connection; its name may not be taken by any connection, Mac or not, nor be `apps`. */
  async add(name: string, url: string): Promise<CallOutcome> {
    if (name === APPS_NAMESPACE) return failure(CONNECTIONS_ERRORS.nameTaken, `${APPS_NAMESPACE} is reserved for the apps Axo provides`);
    if (this.named().some((entry) => entry.name === name) || this.thirdParty.has(name))
      return failure(CONNECTIONS_ERRORS.nameTaken, `a connection named ${name} already exists`);
    const { signInUrl } = await this.thirdParty.add(name, url);
    const connection = this.thirdParty.list().find((c) => c.name === name)!;
    const result: ConnectionsResult<typeof CONNECTIONS_METHODS.add> = { connection, signInUrl };
    return { result };
  }

  /** Removes a third-party connection, or signs one account out of an app. */
  async remove(name: string, account?: string): Promise<CallOutcome> {
    const app = AppConnections.appOf(name);
    if (app) {
      if (!account) return failure(-32602, `name the account to sign out of ${name}`);
      if (!(await this.apps.disconnect(app, account))) return failure(CONNECTIONS_ERRORS.notFound, `${account} is not signed in to ${name}`);
      const result: ConnectionsResult<typeof CONNECTIONS_METHODS.remove> = { removed: true };
      return { result };
    }
    if (this.named().some((entry) => entry.name === name))
      return failure(CONNECTIONS_ERRORS.notFound, `${name} is a Mac; unpair it to remove it`);
    if (!this.thirdParty.remove(name)) return failure(CONNECTIONS_ERRORS.notFound, `no connection named ${name}`);
    const result: ConnectionsResult<typeof CONNECTIONS_METHODS.remove> = { removed: true };
    return { result };
  }

  /**
   * Sets the OAuth client of a third-party connection, or of an app's provider (`apps.<app>`),
   * which needs a secret. An app's answer is its page, where the person adds an account.
   */
  async setClient(name: string, client: Client): Promise<{ signInUrl: string }> {
    const app = AppConnections.appOf(name);
    if (!app) return this.thirdParty.setClient(name, client);
    if (!client.clientSecret) throw new AppAccountRefused("Enter the client secret too");
    await this.apps.setClient(app, client.clientId, client.clientSecret);
    return { signInUrl: appPage(app) };
  }

  /** A fresh sign-in link for a third-party connection or an app. */
  async signInLink(name: string): Promise<string> {
    const app = AppConnections.appOf(name);
    return app ? this.apps.signInLink(app) : this.thirdParty.signInLink(name);
  }

  /** Sign-in flows are one-time nonces; an app's and a third-party's never collide. */
  async openFlow(nonce: string): Promise<{ authorizeUrl: string; name: string } | null> {
    return (await this.apps.openFlow(nonce)) ?? this.thirdParty.openFlow(nonce);
  }

  async completeFlow(nonce: string, code: string): Promise<{ name: string } | { error: string }> {
    return (await this.apps.completeFlow(nonce, code)) ?? this.thirdParty.completeFlow(nonce, code);
  }

  readLog(limit?: number, before?: string, service?: string) {
    return this.log.read(limit, before, service);
  }

  /** Replays the call log's hash chain, and checks the log against it. */
  verifyLog() {
    return this.log.verify();
  }

  async list(): Promise<ConnectionsResult<typeof CONNECTIONS_METHODS.list>> {
    const named = this.named();
    const connections = await Promise.all(named.map(async ({ name, host }): Promise<Connection> => {
      const presence = await this.deps.presence(host.hostId).catch(() => null);
      const online = Boolean(presence?.online && presence.hostGeneration === host.hostGeneration);
      return { kind: "host", name, hostId: host.hostId, state: online ? "online" : "offline" };
    }));
    return { connections: [...connections, ...this.thirdParty.list(), ...this.apps.list()] };
  }

  /** Every tool a script can reach, as `codemode.tools()` shows them. */
  tools(): ToolDefinition[] {
    return [...this.hostTools(), ...this.thirdParty.tools(), ...this.apps.tools()];
  }

  private hostTools(): ToolDefinition[] {
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
      call: `codemode.${name}.bash`,
    }));
  }

  /**
   * The Macs as services: each takes its label as a JavaScript-safe name, unique in the account.
   * A third-party connection keeps the name it was added with; a Mac whose label collides with
   * one gets a suffix.
   */
  private named(): Array<{ name: string; host: HostLink }> {
    const taken = new Set<string>([APPS_NAMESPACE, ...this.thirdParty.names()]);
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
      const app = AppConnections.appOf(service);
      if (app) return this.callApp(from, app, tool, input);
      const target = this.named().find((entry) => entry.name === service);
      if (!target && this.thirdParty.has(service)) return this.callThirdParty(from, service, tool, input);
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
      const outcome = await this.sendBash(target.host, service, callId, parsed.data.command, parsed.data.cwd, timeoutMs);
      if ("error" in outcome) {
        const unknown = outcome.error.code === CONNECTIONS_ERRORS.outcomeUnknown;
        await this.log.finish(callId, unknown ? "unknown" : "error", outcome.error.message);
        throw new Error(`${service}: ${outcome.error.message}`);
      }
      const result = bashResultSchema.safeParse(outcome.result);
      if (!result.success) {
        await this.log.finish(callId, "unknown", "the Mac's reply was not a bash result");
        throw new Error(`${service}: the Mac's reply was not a bash result; the command may have run`);
      }
      await this.log.finish(callId, "ok", null);
      return result.data satisfies BashResult;
    };
  }

  /** Sends one command down a Mac's socket and waits for its answer. Never retried: it may have run. */
  private async sendBash(host: HostLink, service: string, callId: string, command: string, cwd: string | undefined, timeoutMs: number): Promise<CallOutcome> {
    try {
      return await this.deps.callHost(host.hostId, {
        method: BASH_METHOD,
        params: { accountId: this.deps.accountId, callId, command, ...(cwd ? { cwd } : {}), timeoutMs },
        deadlineMs: timeoutMs + BASH_GRACE_MS,
      });
    } catch {
      return failure(CONNECTIONS_ERRORS.outcomeUnknown, `${service} did not answer; the command may have run`);
    }
  }

  /**
   * A Mac app's command, logged as the app's call (callApp), not as `bash`. The Mac is looked up
   * again, so one unpaired mid-script runs nothing.
   */
  private async runOnMac(mac: string, command: string, timeoutMs: number): Promise<BashResult> {
    const target = this.named().find((entry) => entry.name === mac);
    if (!target) throw new ProviderError(0, `no Mac named ${mac}`);
    const outcome = await this.sendBash(target.host, mac, crypto.randomUUID(), command, undefined, timeoutMs);
    if ("error" in outcome) {
      if (outcome.error.code === CONNECTIONS_ERRORS.outcomeUnknown) throw new ProviderOutcomeUnknown(`${mac}: ${outcome.error.message}`);
      throw new ProviderError(0, `${mac}: ${outcome.error.message}`);
    }
    const result = bashResultSchema.safeParse(outcome.result);
    if (!result.success) throw new ProviderOutcomeUnknown(`${mac}: the Mac's reply was not a command's result; it may have run`);
    return result.data;
  }

  /** Calls an app's tool from here, with the account's grant; logged before it is sent. */
  private async callApp(from: Caller, app: NonNullable<ReturnType<typeof AppConnections.appOf>>, tool: string, input: unknown): Promise<unknown> {
    const service = `${APPS_NAMESPACE}.${app}`;
    const callId = crypto.randomUUID();
    await this.log.start({ callId, sessionId: from.sessionId, hostId: from.hostId, service, tool, targetHostId: null, input });
    try {
      const output = await this.apps.call(app, tool, input);
      await this.log.finish(callId, "ok", null);
      return output;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.log.finish(callId, error instanceof ProviderOutcomeUnknown ? "unknown" : "error", message);
      throw new Error(`${service}.${tool}: ${message}`);
    }
  }

  /** Calls a third-party tool from here, with the account's grant; logged before it is sent. */
  private async callThirdParty(from: Caller, service: string, tool: string, input: unknown): Promise<unknown> {
    const callId = crypto.randomUUID();
    await this.log.start({ callId, sessionId: from.sessionId, hostId: from.hostId, service, tool, targetHostId: null, input });
    try {
      const output = await this.thirdParty.call(service, tool, input);
      await this.log.finish(callId, "ok", null);
      return output;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.log.finish(callId, error instanceof McpOutcomeUnknown ? "unknown" : "error", message);
      throw new Error(`${service}.${tool}: ${message}`);
    }
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
