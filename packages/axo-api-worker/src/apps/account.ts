import { z } from "zod";
import {
  APPS_NAMESPACE,
  BASH_METHOD,
  ASSETS_NAMESPACE,
  BASH_NAMESPACE,
  COMPUTER_METHOD,
  COMPUTER_NAMESPACE,
  COMPUTER_STATUS_METHOD,
  HOSTS_NAMESPACE,
  RESERVED_NAMES,
  computerResultSchema,
  computerStatusSchema,
  type ComputerResult,
  type ComputerStatus,
  SIGN_IN_METHOD,
  signInResultSchema,
  APPS_ERRORS,
  APPS_LIMITS,
  APPS_METHODS,
  appSlug,
  bashResultSchema,
  appsParams,
  isAppsMethod,
  type BashResult,
  type AppMacSignIn,
  type AppLink,
  type AppLinkRequest,
  type AppName,
  type AppPhoneSignIn,
  type AppPhoneSignInRequest,
  type AccountApp,
  type AppsMethod,
  type AppsParams,
  type AppsResult,
  type ToolDefinition,
} from "@axo/protocol";
import { recordApiEvent } from "../observability";
import { CallLog } from "./call-log";
import { assetToolDefinitions, callAssetTool, isAssetTool } from "./assets-tools";
import type { AccountAssets } from "../assets/store";
import { LimitError, runScript, type Loader, type ScriptOutcome, type ToolCaller } from "./runner";
import { ThirdPartyApps, type OpenedFlow } from "./third-party";
import { McpOutcomeUnknown } from "./mcp-client";
import type { Client } from "./oauth";
import { AppAccountRefused, BuiltinApps, appPage, type DeviceSignIn, type MacSignInCallback } from "./builtin";
import { ProviderError, ProviderOutcomeUnknown, type LinkedDevice } from "@axo/apps";
import type { GoogleClient } from "./builtin/google";

/**
 * An account's apps (RFD0016): what `axo.apps.*` calls from its Macs reach. It
 * lives inside the account's AxoAccountManager and keeps all apps state there; a Mac's
 * socket owner (its HostDO) only forwards calls here and carries `bash` to a Mac for it.
 *
 * Apps are the account's paired Macs, reached with the Mac as an argument through
 * `hosts.list`, `bash.run` and `computer.run` (RFD0028), the remote MCP servers it added
 * (third-party apps), and the apps Axo provides (`apps.<app>`), the last two called from
 * here with grants kept here.
 */

/** What a HostDO forwards: the calling Mac, the boot it called from, and its request. */
export type AppsCall = { hostId: string; hostGeneration: string; method: string; params: unknown };
export type CallOutcome = { result: unknown } | { error: { code: number; message: string } };

export type HostLink = { hostId: string; hostGeneration: string; label: string; linkedAt: number };

export type AppsDeps = {
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
  /** A linked app's device (WhatsApp's), its own Durable Object, by the ID the account gave it. */
  linked?: (app: AppName, device: string) => LinkedDevice;
  /** The account's assets (RFD0030): `codemode.assets`, and where app tools save files they fetch. */
  assets?: AccountAssets;
};

/** Extra time a `bash` call waits beyond the command's own timeout, for the round trip. */
const BASH_GRACE_MS = 15_000;

/** How long `hosts.list` waits for each online Mac to say whether it can do computer use. */
const STATUS_DEADLINE_MS = 3_000;
/** The longest a computer call waits on the Mac: the person may be asked, for up to 5 minutes. */
const COMPUTER_MAX_MS = 5 * 60_000 + 30_000;
/** Below this much script time left, a computer call is not started. */
const COMPUTER_MIN_MS = 5_000;

/** `"self"` names the Mac the script was started from. */
const hostField = z.string().min(1).max(64).describe('A Mac\'s name from codemode.hosts.list(), or "self" for the Mac this script was started from.');

const bashInputSchema = z.object({
  host: hostField,
  command: z.string().min(1).max(APPS_LIMITS.scriptBytes),
  cwd: z.string().regex(/^\//, "cwd must be an absolute path").max(4096).optional(),
  timeoutMs: z.number().int().min(1).max(APPS_LIMITS.bashMaxTimeoutMs).optional(),
}).strict();

const computerInputSchema = z.object({
  host: hostField,
  tool: z.string().regex(/^[a-z][a-z0-9_]{0,63}$/).describe("A computer-use tool, as the local `computer` tool takes it: get_window_state, click, type_text, run_steps, ..."),
  args: z.record(z.string(), z.unknown()).optional().describe("The tool's input."),
  confirm: z.boolean().optional().describe("true asks the person before this call runs, whatever the Mac's check says. It never approves: the call runs only if they allow it."),
}).strict();

/** What `hosts.list` answers for each Mac. */
export type HostEntry = {
  name: string;
  label: string;
  online: boolean;
  kind: "macos";
  self: boolean;
  computerUse: ComputerStatus | null;
};

type Caller = { hostId: string; sessionId: string };

export class AccountApps {
  private readonly log: CallLog;
  readonly thirdParty: ThirdPartyApps;
  readonly apps: BuiltinApps;

  constructor(private readonly deps: AppsDeps) {
    this.log = new CallLog(deps.sql, deps.secret, deps.accountId);
    this.thirdParty = new ThirdPartyApps({
      sql: deps.sql, secret: deps.secret, accountId: deps.accountId, fetcher: deps.fetcher, waitUntil: deps.waitUntil,
    });
    this.apps = new BuiltinApps({
      sql: deps.sql, secret: deps.secret, accountId: deps.accountId, legacyGoogle: deps.google, fetcher: deps.fetcher, waitUntil: deps.waitUntil,
      assets: deps.assets,
      // Mac apps (1Password) run their commands on the account's Macs, as `bash` does.
      macs: () => this.named().map((entry) => entry.name),
      runOnMac: (mac, command, timeoutMs) => this.runOnMac(mac, command, timeoutMs),
      signInOnMac: (mac, request) => this.signInOnMac(mac, request),
      linked: deps.linked,
    });
  }

  async call(call: AppsCall): Promise<CallOutcome> {
    const host = this.deps.hosts().find((h) => h.hostId === call.hostId);
    if (!host || host.hostGeneration !== call.hostGeneration) return failure(-32002, "Stale host");
    if (!isAppsMethod(call.method)) return failure(-32601, "Method not found");
    const parsed = appsParams[call.method].safeParse(call.params);
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
      event: "apps_call",
      method: call.method,
      outcome: "result" in outcome ? "result" : String(outcome.error.code),
      durationMs: Date.now() - started,
    });
    return outcome;
  }

  private async dispatch(method: AppsMethod, params: unknown, caller: Caller): Promise<CallOutcome> {
    switch (method) {
      case APPS_METHODS.list:
        return { result: await this.list() };
      case APPS_METHODS.search: {
        const { code } = params as AppsParams<typeof APPS_METHODS.search>;
        return scriptOutcome(await runScript(this.deps.loader, code, this.tools(), null), (o) => ({ result: o.result }));
      }
      case APPS_METHODS.execute: {
        const { code } = params as AppsParams<typeof APPS_METHODS.execute>;
        const deadline = Date.now() + APPS_LIMITS.scriptWallMs;
        const outcome = await runScript(this.deps.loader, code, this.tools(), this.caller(caller, deadline));
        return scriptOutcome(outcome, (o) => ({ result: o.result, logs: o.logs }));
      }
      case APPS_METHODS.log: {
        const { limit, before, service } = params as AppsParams<typeof APPS_METHODS.log>;
        const result: AppsResult<typeof APPS_METHODS.log> = { records: await this.log.read(limit, before, service) };
        return { result };
      }
      case APPS_METHODS.add: {
        const { name, url } = params as AppsParams<typeof APPS_METHODS.add>;
        return this.add(name, url);
      }
      case APPS_METHODS.remove: {
        const { name, account } = params as AppsParams<typeof APPS_METHODS.remove>;
        return await this.remove(name, account);
      }
    }
  }

  /**
   * Adds a remote MCP server under what the person called it ("emdash: leostera.com"); scripts
   * reach it by that name's slug (emdash_leostera_com). The same server may be added again under
   * another name, for another account with it.
   */
  async add(title: string, url: string): Promise<CallOutcome> {
    const name = appSlug(title);
    if (!name) return failure(-32602, "a name needs a letter or a digit");
    if (RESERVED_NAMES.includes(name)) return failure(APPS_ERRORS.nameTaken, `${name} is reserved for what Axo provides; choose another name`);
    if (this.thirdParty.has(name))
      return failure(APPS_ERRORS.nameTaken, name === title ? `an app named ${name} already exists` : `an app named ${name} already exists (the name of "${title}"); choose another name`);
    const { signInUrl } = await this.thirdParty.add(name, url, title.trim() === name ? null : title.trim());
    const app = this.thirdParty.list().find((c) => c.name === name)!;
    const result: AppsResult<typeof APPS_METHODS.add> = { app, signInUrl };
    return { result };
  }

  /** Removes a third-party connection, or signs one account out of an app. */
  async remove(name: string, account?: string): Promise<CallOutcome> {
    const app = BuiltinApps.appOf(name);
    if (app) {
      if (!account) return failure(-32602, `name the account to sign out of ${name}`);
      if (!(await this.apps.disconnect(app, account))) return failure(APPS_ERRORS.notFound, `${account} is not signed in to ${name}`);
      const result: AppsResult<typeof APPS_METHODS.remove> = { removed: true };
      return { result };
    }
    if (!this.thirdParty.remove(name)) return failure(APPS_ERRORS.notFound, `no app named ${name}`);
    const result: AppsResult<typeof APPS_METHODS.remove> = { removed: true };
    return { result };
  }

  /**
   * Sets the OAuth client of a third-party connection, or of an app's provider (`apps.<app>`),
   * which needs a secret. An app's answer is its page, where the person adds an account.
   */
  async setClient(name: string, client: Client): Promise<{ signInUrl: string }> {
    const app = BuiltinApps.appOf(name);
    if (!app) return this.thirdParty.setClient(name, client);
    if (!client.clientSecret) throw new AppAccountRefused("Enter the client secret too");
    await this.apps.setClient(app, client.clientId, client.clientSecret);
    return { signInUrl: appPage(app) };
  }

  /**
   * Adds an account to a token app (`apps.<app>`) from what the person pasted on its page. A
   * refusal (the service did not take the token, a field is missing) is an answer, not a failure.
   */
  async addAppToken(name: string, account: string | null, fields: Record<string, string>): Promise<{ name: string; account: string } | { error: string }> {
    const app = BuiltinApps.appOf(name);
    if (!app) return { error: `${name} is not an app` };
    try {
      return await this.apps.addToken(app, account, fields);
    } catch (error) {
      if (error instanceof AppAccountRefused) return { error: error.message.slice(0, 300) };
      throw error;
    }
  }

  /** Starts an app's device sign-in (ChatGPT): the code the person enters at the provider. */
  async startAppDevice(name: string): Promise<({ flow: string } & Extract<DeviceSignIn, { state: "pending" }>) | { error: string }> {
    const app = BuiltinApps.appOf(name);
    if (!app) return { error: `${name} is not an app` };
    try {
      return await this.apps.startDevice(app);
    } catch (error) {
      if (error instanceof AppAccountRefused) return { error: error.message.slice(0, 300) };
      throw error;
    }
  }

  /** Whether the person entered a device sign-in's code yet. */
  async pollAppDevice(name: string, flow: string): Promise<DeviceSignIn> {
    const app = BuiltinApps.appOf(name);
    if (!app) return { state: "failed", error: `${name} is not an app` };
    return this.apps.pollDevice(app, flow);
  }

  /** A fresh sign-in link for a third-party connection or an app. */
  async signInLink(name: string): Promise<string> {
    const app = BuiltinApps.appOf(name);
    return app ? this.apps.signInLink(app) : this.thirdParty.signInLink(name);
  }

  /** Sign-in flows are one-time nonces; an app's and a third-party's never collide. */
  async openFlow(nonce: string): Promise<OpenedFlow | null> {
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

  async list(): Promise<AppsResult<typeof APPS_METHODS.list>> {
    const named = this.named();
    const apps = await Promise.all(named.map(async ({ name, host }): Promise<AccountApp> => {
      const presence = await this.deps.presence(host.hostId).catch(() => null);
      const online = Boolean(presence?.online && presence.hostGeneration === host.hostGeneration);
      return { kind: "host", name, hostId: host.hostId, state: online ? "online" : "offline" };
    }));
    return { apps: [...apps, ...this.thirdParty.list(), ...this.apps.list()] };
  }

  /** Every tool a script can reach, as `codemode.tools()` shows them. */
  tools(): ToolDefinition[] {
    return [...this.hostTools(), ...(this.deps.assets ? assetToolDefinitions() : []), ...this.thirdParty.tools(), ...this.apps.tools()];
  }

  /** The Macs' namespaces: one definition each, the Mac an argument (RFD0028). */
  private hostTools(): ToolDefinition[] {
    const macs = this.named().map((entry) => `${entry.name} ("${entry.host.label}")`).join(", ") || "none yet";
    return [
      {
        service: HOSTS_NAMESPACE,
        name: "list",
        title: "List the account's Macs",
        description:
          `The account's Macs (${macs}): [{ name, label, online, kind, self, computerUse }]. name is what bash.run and computer.run take; ` +
          "self is the Mac this script was started from; computerUse, for an online Mac, says whether it can be driven now " +
          "({ available, accessibility, screenRecording, locked }), or is null if the Mac did not say. " +
          "A locked Mac refuses computer calls until the person unlocks it; bash.run still works there.",
        inputSchema: z.toJSONSchema(z.object({}).strict()) as Record<string, unknown>,
        call: `codemode.${HOSTS_NAMESPACE}.list`,
      },
      {
        service: BASH_NAMESPACE,
        name: "run",
        title: "Run a command on a Mac",
        description:
          "Runs one non-interactive command on one of the account's Macs as the user axod runs as, with its login shell, " +
          "and returns { exitCode, signal, stdout, stderr, stdoutTruncated, stderrTruncated, timedOut, durationMs }. " +
          `Each output stream keeps ${APPS_LIMITS.bashOutputBytes} bytes, then is marked truncated. ` +
          `timeoutMs defaults to ${APPS_LIMITS.bashDefaultTimeoutMs} and may be at most ${APPS_LIMITS.bashMaxTimeoutMs}.`,
        inputSchema: z.toJSONSchema(bashInputSchema) as Record<string, unknown>,
        call: `codemode.${BASH_NAMESPACE}.run`,
      },
      {
        service: COMPUTER_NAMESPACE,
        name: "run",
        title: "Drive a Mac's apps",
        description:
          "Runs one computer-use tool on one of the account's Macs, as the local `computer` tool does: read a window with get_window_state, " +
          "take a screenshot, act with click, type_text, run_steps, ... Returns the tool's { content, structuredContent, isError }; images " +
          "(screenshots) come as { type: \"image\", attachment } in the account's assets, and the agent sees them when the script returns them. " +
          "An action that may be destructive or hard to undo is checked on that Mac and, if flagged, the person is asked first (up to 5 minutes); " +
          "it runs only if they allow it. For a password, login or one-time code use request_input ({ pid, window_id, fields: [{ kind, label? }], " +
          "submit? }): the person types it on their own device, it goes to that Mac encrypted, and you get only a receipt.",
        inputSchema: z.toJSONSchema(computerInputSchema) as Record<string, unknown>,
        call: `codemode.${COMPUTER_NAMESPACE}.run`,
      },
    ];
  }

  /**
   * The Macs by name: each takes its label as a JavaScript-safe name, unique among the account's
   * Macs. Reserved names get a suffix, so `self` and the namespaces never name a Mac.
   */
  private named(): Array<{ name: string; host: HostLink }> {
    const taken = new Set<string>([...RESERVED_NAMES, "self"]);
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
      const app = BuiltinApps.appOf(service);
      if (app) return this.callApp(from, app, tool, input);
      if (service === HOSTS_NAMESPACE) {
        if (tool !== "list") throw new Error(`hosts has no tool named ${tool}; it has list`);
        return this.hostsList(from);
      }
      if (service === COMPUTER_NAMESPACE) {
        if (tool !== "run") throw new Error(`computer has no tool named ${tool}; call computer.run({ host, tool, args })`);
        return this.runComputer(from, input, deadline);
      }
      if (service === ASSETS_NAMESPACE) return this.callAssets(from, tool, input);
      if (service !== BASH_NAMESPACE) {
        if (this.thirdParty.has(service)) return this.callThirdParty(from, service, tool, input);
        if (this.named().some((entry) => entry.name === service))
          throw new Error(`${service} is a Mac: call codemode.bash.run({ host: "${service}", command }) or codemode.computer.run({ host: "${service}", tool, args })`);
        throw new Error(`no app named ${service}`);
      }
      if (tool !== "run") throw new Error(`bash has no tool named ${tool}; call bash.run({ host, command })`);
      const parsed = bashInputSchema.safeParse(input);
      if (!parsed.success) throw new Error(`bash.run: ${z.prettifyError(parsed.error)}`);
      const target = await this.resolveHost(parsed.data.host, from);
      const remaining = deadline - Date.now();
      if (remaining <= 1_000) throw new LimitError("scriptWallMs", "the script has no time left for another command");
      const timeoutMs = Math.min(parsed.data.timeoutMs ?? APPS_LIMITS.bashDefaultTimeoutMs, remaining);
      const callId = crypto.randomUUID();
      await this.log.start({
        callId,
        sessionId: from.sessionId,
        hostId: from.hostId,
        service,
        tool,
        targetHostId: target.host.hostId,
        input: { host: target.name, command: parsed.data.command, cwd: parsed.data.cwd ?? null, timeoutMs },
      });
      const outcome = await this.sendBash(target.host, target.name, callId, parsed.data.command, parsed.data.cwd, timeoutMs);
      if ("error" in outcome) {
        const unknown = outcome.error.code === APPS_ERRORS.outcomeUnknown;
        await this.log.finish(callId, unknown ? "unknown" : "error", outcome.error.message);
        throw new Error(`bash.run on ${target.name}: ${outcome.error.message}`);
      }
      const result = bashResultSchema.safeParse(outcome.result);
      if (!result.success) {
        await this.log.finish(callId, "unknown", "the Mac's reply was not a bash result");
        throw new Error(`bash.run on ${target.name}: the Mac's reply was not a bash result; the command may have run`);
      }
      await this.log.finish(callId, "ok", null);
      return result.data satisfies BashResult;
    };
  }

  /**
   * A Mac by the name `hosts.list` gives it, or `self`. Unknown fails listing the Macs; offline
   * fails naming the online ones, before anything is logged or sent.
   */
  private async resolveHost(name: string, from: Caller): Promise<{ name: string; host: HostLink }> {
    const named = this.named();
    const target = name === "self" ? named.find((entry) => entry.host.hostId === from.hostId) : named.find((entry) => entry.name === name);
    if (!target) throw new Error(`no Mac named ${name}; the account's Macs: ${named.map((entry) => entry.name).join(", ") || "none"}`);
    if (!(await this.isOnline(target.host))) {
      const online = (await Promise.all(named.map(async (entry) => ((await this.isOnline(entry.host)) ? entry.name : null)))).filter(Boolean);
      throw new Error(`${target.name} is offline; online now: ${online.join(", ") || "none"}`);
    }
    return target;
  }

  private async isOnline(host: HostLink): Promise<boolean> {
    const presence = await this.deps.presence(host.hostId).catch(() => null);
    return Boolean(presence?.online && presence.hostGeneration === host.hostGeneration);
  }

  /** Every Mac with whether it is online and, if it is, whether it can do computer use now. */
  private async hostsList(from: Caller): Promise<HostEntry[]> {
    return Promise.all(this.named().map(async ({ name, host }): Promise<HostEntry> => {
      const online = await this.isOnline(host);
      return { name, label: host.label, online, kind: "macos", self: host.hostId === from.hostId, computerUse: online ? await this.computerStatus(host) : null };
    }));
  }

  /** A Mac's computer-use grants; null when it did not say (an older Axo, or no answer in time). */
  private async computerStatus(host: HostLink): Promise<ComputerStatus | null> {
    try {
      const outcome = await this.deps.callHost(host.hostId, {
        method: COMPUTER_STATUS_METHOD,
        params: { accountId: this.deps.accountId },
        deadlineMs: STATUS_DEADLINE_MS,
      });
      if ("error" in outcome) return null;
      const status = computerStatusSchema.safeParse(outcome.result);
      return status.success ? status.data : null;
    } catch {
      return null;
    }
  }

  /**
   * One computer-use tool on a Mac. The Mac's gate decides whether to ask the person, and asks in
   * the calling Session; logged before it is sent and never retried: it may have run.
   */
  private async runComputer(from: Caller, input: unknown, deadline: number): Promise<ComputerResult> {
    const parsed = computerInputSchema.safeParse(input);
    if (!parsed.success) throw new Error(`computer.run: ${z.prettifyError(parsed.error)}`);
    const target = await this.resolveHost(parsed.data.host, from);
    const remaining = deadline - Date.now() - BASH_GRACE_MS;
    if (remaining < COMPUTER_MIN_MS) throw new LimitError("scriptWallMs", "the script has no time left for a computer call");
    const timeoutMs = Math.min(COMPUTER_MAX_MS, remaining);
    const callId = crypto.randomUUID();
    const { tool, args = {}, confirm = false } = parsed.data;
    await this.log.start({
      callId, sessionId: from.sessionId, hostId: from.hostId, service: COMPUTER_NAMESPACE, tool,
      targetHostId: target.host.hostId, input: { host: target.name, tool, args, confirm },
    });
    const caller = this.deps.hosts().find((host) => host.hostId === from.hostId);
    let outcome: CallOutcome;
    try {
      outcome = await this.deps.callHost(target.host.hostId, {
        method: COMPUTER_METHOD,
        params: { accountId: this.deps.accountId, callId, tool, args, confirm, sessionId: from.sessionId, from: caller?.label ?? "another Mac", timeoutMs },
        deadlineMs: timeoutMs + BASH_GRACE_MS,
      });
    } catch {
      outcome = failure(APPS_ERRORS.outcomeUnknown, "did not answer; the action may have run");
    }
    if ("error" in outcome) {
      const old = outcome.error.code === -32601;
      const unknown = outcome.error.code === APPS_ERRORS.outcomeUnknown;
      const message = old ? "runs an Axo too old for computer use from other Macs; update Axo there" : outcome.error.message;
      await this.log.finish(callId, unknown ? "unknown" : "error", message);
      throw new Error(`computer.run on ${target.name}: ${message}`);
    }
    const result = computerResultSchema.safeParse(outcome.result);
    if (!result.success) {
      await this.log.finish(callId, "unknown", "the Mac's reply was not a computer result");
      throw new Error(`computer.run on ${target.name}: the Mac's reply was not a computer result; the action may have run`);
    }
    await this.log.finish(callId, result.data.isError ? "error" : "ok", result.data.isError ? "the tool answered an error" : null);
    return result.data;
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
      return failure(APPS_ERRORS.outcomeUnknown, `${service} did not answer; the command may have run`);
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
      if (outcome.error.code === APPS_ERRORS.outcomeUnknown) throw new ProviderOutcomeUnknown(`${mac}: ${outcome.error.message}`);
      throw new ProviderError(0, `${mac}: ${outcome.error.message}`);
    }
    const result = bashResultSchema.safeParse(outcome.result);
    if (!result.success) throw new ProviderOutcomeUnknown(`${mac}: the Mac's reply was not a command's result; it may have run`);
    return result.data;
  }

  /**
   * Has a Mac run a loopback sign-in (an app's TokenSignIn.mac): it opens the page in the
   * person's browser and answers with the redirect's code. The code is never logged.
   */
  private async signInOnMac(mac: string, request: { authorizeUrl: string; ports: readonly number[]; path: string; state: string; timeoutMs: number }): Promise<MacSignInCallback> {
    const target = this.named().find((entry) => entry.name === mac);
    if (!target) throw new ProviderError(0, `no Mac named ${mac}`);
    let outcome: CallOutcome;
    try {
      outcome = await this.deps.callHost(target.host.hostId, {
        method: SIGN_IN_METHOD,
        params: { accountId: this.deps.accountId, callId: crypto.randomUUID(), ...request, ports: [...request.ports] },
        deadlineMs: request.timeoutMs + BASH_GRACE_MS,
      });
    } catch {
      throw new ProviderError(0, `${mac} did not answer`);
    }
    if ("error" in outcome) {
      // An axod from before sign-ins answers that it has no such method.
      const old = outcome.error.code === -32601;
      throw new ProviderError(0, old ? `${mac} runs an Axo too old to sign in; update Axo there` : `${mac}: ${outcome.error.message}`);
    }
    const result = signInResultSchema.safeParse(outcome.result);
    if (!result.success) throw new ProviderError(0, `${mac}'s reply was not a sign-in`);
    return result.data;
  }

  /** Starts a token app's sign-in on one of the account's Macs (Kraken). */
  async startAppMacSignIn(name: string, mac: string, preset: string, account: string | null): Promise<({ flow: string } & AppMacSignIn) | { error: string }> {
    const app = BuiltinApps.appOf(name);
    if (!app) return { error: `${name} is not an app` };
    try {
      return await this.apps.startMacSignIn(app, mac, preset, account);
    } catch (error) {
      if (error instanceof AppAccountRefused) return { error: error.message.slice(0, 300) };
      throw error;
    }
  }

  /** Whether a sign-in on a Mac finished. */
  async pollAppMacSignIn(name: string, flow: string): Promise<AppMacSignIn> {
    const app = BuiltinApps.appOf(name);
    if (!app) return { state: "failed", error: `${name} is not an app` };
    return this.apps.pollMacSignIn(app, flow);
  }

  /** One step of a phone app's sign-in (Telegram): the number, the code, then a password. */
  async appPhoneSignIn(name: string, request: AppPhoneSignInRequest): Promise<AppPhoneSignIn> {
    const app = BuiltinApps.appOf(name);
    if (!app) return { state: "failed", error: `${name} is not an app` };
    try {
      return await this.apps.phoneSignIn(app, request);
    } catch (error) {
      if (error instanceof AppAccountRefused) return { state: "failed", error: error.message.slice(0, 300) };
      throw error;
    }
  }

  /** One step of linking a linked app's device (WhatsApp): start, then where it stands. */
  async appLink(name: string, request: AppLinkRequest): Promise<AppLink> {
    const app = BuiltinApps.appOf(name);
    if (!app) return { state: "failed", error: `${name} is not an app` };
    try {
      return await this.apps.link(app, request);
    } catch (error) {
      if (error instanceof AppAccountRefused) return { state: "failed", error: error.message.slice(0, 300) };
      throw error;
    }
  }

  /** Calls an app's tool from here, with the account's grant; logged before it is sent. */
  private async callApp(from: Caller, app: NonNullable<ReturnType<typeof BuiltinApps.appOf>>, tool: string, input: unknown): Promise<unknown> {
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

  /** A `codemode.assets` call, logged as the others are. Saves are made as the calling Mac. */
  private async callAssets(from: Caller, tool: string, input: unknown): Promise<unknown> {
    const assets = this.deps.assets;
    if (!assets) throw new Error("this Axo deployment keeps no assets");
    if (!isAssetTool(tool)) throw new Error(`assets has no tool named ${tool}; it has list, get, read and save`);
    const callId = crypto.randomUUID();
    await this.log.start({ callId, sessionId: from.sessionId, hostId: from.hostId, service: ASSETS_NAMESPACE, tool, targetHostId: null, input });
    try {
      const output = await callAssetTool(assets, tool, input, `host:${from.hostId}`);
      await this.log.finish(callId, "ok", null);
      return output;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.log.finish(callId, "error", message);
      throw error;
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
  const code = outcome.limit ? APPS_ERRORS.limitExceeded : APPS_ERRORS.scriptFailed;
  return failure(code, `${outcome.error}${logs}`.slice(0, 16_384));
}
