import { z } from "zod";
import { APP_ACCOUNTS_MAX, APPS, type AppAccount, type AppName, type AppSignIn, type Connection, type ToolDefinition } from "@axo/protocol";
import { seal, unseal } from "../../auth/crypto";
import { GrantRefused } from "../oauth";
import { FLOW_LIFETIME_MS, startUrl } from "../third-party";
import { allowedUrl, ProviderError, ProviderOutcomeUnknown, type AppDefinition, type AppTool, type DeviceApp, type OAuthApp, type ProviderApi, type ProviderRequest, type TokenApp } from "./app";
import { calendar } from "./calendar";
import { chatgpt } from "./chatgpt";
import { cloud } from "./cloud";
import { contacts } from "./contacts";
import { docs } from "./docs";
import { drive } from "./drive";
import { gmail } from "./gmail";
import { hetzner } from "./hetzner";
import { meet } from "./meet";
import {
  DEVICE_CODE_LIFETIME_MS,
  DEVICE_VERIFICATION_URL,
  pollDeviceCode,
  refreshOpenAIGrant,
  requestDeviceCode,
  revokeOpenAIGrant,
  type OpenAIGrant,
} from "./openai";
import { requestTool } from "./request";
import { sheets } from "./sheets";
import { slides } from "./slides";
import { tasks } from "./tasks";
import {
  googleAuthorizationUrl,
  redeemGoogleCode,
  refreshGoogleGrant,
  revokeGoogleGrant,
  type GoogleClient,
  type GoogleGrant,
} from "./google";

/**
 * The account's apps (RFD0016, Apps): services Axo provides itself, such as Gmail, reached as
 * `codemode.apps.<app>.<tool>({ account, ... })`. An OAuth app signs in with Axo's own client for
 * its provider, set on the Worker; a token app takes a token the person pasted (Hetzner). Each
 * holds any number of provider accounts, each named by its email or by the person. Every call
 * names the account it acts as: nothing is read or sent from a guessed one.
 *
 * Grants and tokens are sealed with the account's key and never leave this Durable Object. Sign-in reuses
 * the connections callback and its checks: a flow is a one-time nonce that works for ten
 * minutes, only in a browser signed in to this account. Each provider account's grant carries a
 * generation, and a renewal lands only on the generation it renewed.
 */

export const APP_DEFINITIONS: Record<AppName, AppDefinition> = { gmail, calendar, drive, docs, sheets, slides, contacts, tasks, meet, cloud, hetzner, chatgpt };

/** Where a person adds an account to an app, or signs in to one again. */
export function appPage(app: AppName): string {
  return `https://axo.leostera.dev/app/settings/apps/${app}`;
}

/** A token the person pasted, as stored (sealed) for one account of a token app. */
type TokenCredential = { kind: "token"; fields: Record<string, string> };
/** A signed-in account's grant: Google's (stored before grants had a kind) or OpenAI's. */
type Grant = GoogleGrant | OpenAIGrant;

/** A device sign-in in progress, as the web app polls it. */
export type DeviceSignIn =
  | { state: "pending"; userCode: string; verificationUrl: string; intervalSeconds: number; expiresAt: string }
  | { state: "done"; account: string }
  | { state: "failed"; error: string };

/** Adding an account was refused: the token was not accepted, or the input was wrong. Nothing was stored. */
export class AppAccountRefused extends Error {}

/** An app's tools: its named ones, then `request`, for any endpoint of its API. */
const TOOLS = new Map<AppName, readonly AppTool[]>();
export function toolsOf(app: AppName): readonly AppTool[] {
  let tools = TOOLS.get(app);
  if (!tools) {
    const definition = APP_DEFINITIONS[app];
    tools = [...definition.tools, requestTool(definition)];
    TOOLS.set(app, tools);
  }
  return tools;
}

/** An access token this close to expiring is renewed before use. */
const EXPIRY_MARGIN_MS = 60_000;
const REQUEST_TIMEOUT_MS = 30_000;
/** A script has five minutes; one call may take most of them (a ChatGPT turn that thinks). */
const MAX_REQUEST_TIMEOUT_MS = 240_000;

type Row = {
  app: string;
  account: string;
  grant_sealed: string | null;
  grant_generation: number;
  last_error: string | null;
  created_at: number;
};

export type AppsDeps = {
  sql: SqlStorage;
  secret: string;
  accountId: string;
  /** Axo's Google client, or null when this deployment has none: Google apps are then not listed. */
  google: GoogleClient | null;
  fetcher: typeof fetch;
  waitUntil(promise: Promise<unknown>): void;
  now?: () => number;
};

/** The provider said the access token is no good: nothing ran, so the call may be sent again. */
class Unauthorized extends Error {}

const accountInput = z.string().min(3).max(320)
  .describe("The account to act as: the email of one of this app's signed-in accounts (see connections_list).");

export class AppConnections {
  private readonly refreshing = new Map<string, Promise<Grant | null>>();

  constructor(private readonly deps: AppsDeps) {
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_accounts (
      app TEXT NOT NULL, account TEXT NOT NULL, grant_sealed TEXT, grant_generation INTEGER NOT NULL DEFAULT 1,
      last_error TEXT, created_at REAL NOT NULL, PRIMARY KEY (app, account))`);
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_device_flows (
      id TEXT PRIMARY KEY, app TEXT NOT NULL, device_sealed TEXT NOT NULL, interval_s INTEGER NOT NULL, created_at REAL NOT NULL,
      polled_at REAL NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0)`);
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_flows (
      nonce TEXT PRIMARY KEY, app TEXT NOT NULL, verifier TEXT NOT NULL, created_at REAL NOT NULL,
      opened INTEGER NOT NULL DEFAULT 0, redeemed INTEGER NOT NULL DEFAULT 0)`);
    this.migrateSingleGrants();
  }

  /**
   * Grants from when an app held one account (`app_grants`, one row per app) become that
   * account's row; the old table is then left empty.
   */
  private migrateSingleGrants(): void {
    this.deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_grants (
      app TEXT PRIMARY KEY, grant_sealed TEXT, grant_generation INTEGER NOT NULL DEFAULT 0,
      account TEXT, last_error TEXT)`);
    this.deps.sql.exec(`INSERT OR IGNORE INTO app_accounts (app, account, grant_sealed, grant_generation, last_error, created_at)
      SELECT app, lower(account), grant_sealed, grant_generation, NULL, ? FROM app_grants WHERE grant_sealed IS NOT NULL AND account IS NOT NULL`, this.now());
    this.deps.sql.exec("DELETE FROM app_grants");
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }

  /** `apps.gmail` → `gmail`, for an app that exists; anything else → null. */
  static appOf(service: string): AppName | null {
    const app = /^apps\.(.+)$/.exec(service)?.[1];
    return app && (APPS as readonly string[]).includes(app) ? (app as AppName) : null;
  }

  /** The apps this deployment can sign in to, with their accounts; one without a client for its provider is not listed. */
  list(): Connection[] {
    return this.available().map((app): Connection => {
      const definition = APP_DEFINITIONS[app];
      const accounts = this.accounts(app);
      return {
        kind: "app",
        name: `apps.${app}`,
        title: definition.title,
        description: definition.description,
        provider: definition.providerTitle,
        category: definition.category,
        permissions: [...definition.permissions],
        signIn: signInOf(definition),
        state: accounts.some((a) => a.state === "ready") ? "ready" : "needsSignIn",
        accounts,
        tools: toolsOf(app).map((t) => t.name),
        lastError: null,
      };
    });
  }

  /** The signed-in accounts of one app, oldest first. */
  accounts(app: AppName): AppAccount[] {
    return this.rows(app).map((row) => ({ account: row.account, state: row.grant_sealed ? "ready" : "needsSignIn", lastError: row.last_error }));
  }

  /** The tools of every listed app, signed in or not: a call explains how to sign in. */
  tools(): ToolDefinition[] {
    return this.available().flatMap((app) => {
      const definition = APP_DEFINITIONS[app];
      const accounts = this.rows(app).filter((r) => r.grant_sealed).map((r) => r.account);
      const signedIn = accounts.length
        ? ` Signed-in accounts: ${accounts.join(", ")}.`
        : definition.signIn === "oauth"
          ? " No account is signed in yet: a call returns a sign-in link to give the person."
          : ` No account is added yet: the person adds one at ${appPage(app)}.`;
      return toolsOf(app).map((tool) => ({
        service: `apps.${app}`,
        name: tool.name,
        title: tool.name,
        description: `${tool.description} Every call names its account.${signedIn}`,
        inputSchema: z.toJSONSchema(inputOf(tool), { io: "input" }) as Record<string, unknown>,
        call: `codemode.apps.${app}.${tool.name}`,
      }));
    });
  }

  /** A sign-in link that adds an account to an app, or signs in to one again: Axo's own start page, once, in this account's browser. */
  async signInLink(app: AppName): Promise<string> {
    const definition = APP_DEFINITIONS[app];
    // A token app has no provider page to send the browser to: the person pastes a token on the app's page.
    if (definition.signIn !== "oauth") return appPage(app);
    if (!this.client(definition)) throw new Error(`${definition.title} is not set up on this Axo deployment`);
    const nonce = crypto.randomUUID();
    const verifier = randomVerifier();
    this.deps.sql.exec("DELETE FROM app_flows WHERE created_at < ?", this.now() - FLOW_LIFETIME_MS);
    this.deps.sql.exec("INSERT INTO app_flows (nonce, app, verifier, created_at) VALUES (?, ?, ?, ?)", nonce, app, verifier, this.now());
    return startUrl(nonce);
  }

  /** The browser opened an app's sign-in link: where to send it, once. Null if the nonce is not an app's. */
  async openFlow(nonce: string): Promise<{ authorizeUrl: string; name: string } | null> {
    const flow = this.flow(nonce);
    if (!flow || flow.opened) return null;
    this.deps.sql.exec("UPDATE app_flows SET opened = 1 WHERE nonce = ?", nonce);
    const definition = APP_DEFINITIONS[flow.app as AppName];
    const client = definition?.signIn === "oauth" ? this.client(definition) : null;
    if (!client || definition?.signIn !== "oauth") return null;
    const state = await seal(this.deps.secret, "connections-oauth-state", { accountId: this.deps.accountId, nonce });
    return { authorizeUrl: googleAuthorizationUrl(client, definition.scopes, await challengeOf(flow.verifier), state), name: `apps.${flow.app}` };
  }

  /**
   * The provider sent the browser back: redeems the code once and stores the grant under the
   * provider account's email, replacing an older grant for the same account. Null if the nonce
   * is not an app's.
   */
  async completeFlow(nonce: string, code: string): Promise<{ name: string } | { error: string } | null> {
    const flow = this.deps.sql.exec<{ app: string }>("SELECT app FROM app_flows WHERE nonce = ?", nonce).toArray()[0];
    if (!flow) return null;
    const live = this.flow(nonce);
    if (!live || !live.opened || live.redeemed) return { error: "this sign-in link was already used or has expired" };
    this.deps.sql.exec("UPDATE app_flows SET redeemed = 1 WHERE nonce = ?", nonce);
    const app = flow.app as AppName;
    const definition = APP_DEFINITIONS[app];
    const client = definition?.signIn === "oauth" ? this.client(definition) : null;
    if (!client || definition?.signIn !== "oauth") return { error: "this app is not set up on this Axo deployment" };
    let grant: GoogleGrant;
    try {
      grant = await redeemGoogleCode(client, code, live.verifier, this.deps.fetcher, this.now());
    } catch {
      return { error: `${definition.title} did not accept the sign-in` };
    }
    const refuse = (error: string) => {
      this.deps.waitUntil(revokeGoogleGrant(grant, this.deps.fetcher).catch(() => undefined));
      return { error };
    };
    if (definition.requiredScopes.some((scope) => !grant.scopes.includes(scope)))
      return refuse(`The sign-in did not grant ${definition.title} access. Sign in again and allow every permission asked for.`);
    const account = grant.email?.toLowerCase();
    if (!account) return refuse("Google did not say which account signed in; try again.");
    const known = this.rows(app).some((r) => r.account === account);
    if (!known && this.rows(app).length >= APP_ACCOUNTS_MAX) return refuse(`${definition.title} holds at most ${APP_ACCOUNTS_MAX} accounts; sign one out first.`);
    this.deps.sql.exec(`INSERT INTO app_accounts (app, account, grant_sealed, grant_generation, last_error, created_at) VALUES (?, ?, ?, 1, NULL, ?)
      ON CONFLICT (app, account) DO UPDATE SET grant_sealed = excluded.grant_sealed, grant_generation = app_accounts.grant_generation + 1, last_error = NULL`,
    app, account, await this.seal(grant), this.now());
    return { name: `apps.${app}` };
  }

  /** Signs one provider account out of an app: its grant is deleted here and revoked at the provider. */
  async disconnect(app: AppName, account: string): Promise<boolean> {
    const row = this.row(app, account.toLowerCase());
    if (!row) return false;
    this.deps.sql.exec("DELETE FROM app_accounts WHERE app = ? AND account = ?", app, row.account);
    // A token stays valid at the service: Axo can only forget it. The person deletes it there.
    const grant = row.grant_sealed && APP_DEFINITIONS[app].signIn !== "token" ? await this.unsealGrant(row.grant_sealed) : null;
    if (grant) this.deps.waitUntil((isOpenAI(grant) ? revokeOpenAIGrant(grant, this.deps.fetcher) : revokeGoogleGrant(grant, this.deps.fetcher)).catch(() => undefined));
    return true;
  }

  /**
   * Starts a device sign-in for an app that signs in that way (ChatGPT): a code the person
   * enters at the provider. The web app shows it and polls `pollDevice` with the returned flow.
   */
  async startDevice(app: AppName): Promise<{ flow: string } & Extract<DeviceSignIn, { state: "pending" }>> {
    const definition = APP_DEFINITIONS[app];
    if (definition.signIn !== "device") throw new AppAccountRefused(`${definition.title} does not sign in with a code`);
    const device = await requestDeviceCode(this.deps.fetcher);
    const id = crypto.randomUUID();
    this.deps.sql.exec("DELETE FROM app_device_flows WHERE created_at < ?", this.now() - DEVICE_CODE_LIFETIME_MS);
    this.deps.sql.exec("INSERT INTO app_device_flows (id, app, device_sealed, interval_s, created_at) VALUES (?, ?, ?, ?, ?)",
      id, app, await seal(this.deps.secret, `apps-device\0${this.deps.accountId}`, device), device.intervalSeconds, this.now());
    return { flow: id, ...this.pending(device.userCode, device.intervalSeconds, this.now()) };
  }

  /**
   * Asks the provider once whether the person entered the code, at most once per the interval
   * it asked for. Once they have, the grant is stored under the account's email, replacing an
   * older one for the same account, and the flow is spent.
   */
  async pollDevice(app: AppName, flowId: string): Promise<DeviceSignIn> {
    const definition = APP_DEFINITIONS[app];
    const flow = this.deps.sql.exec<{ app: string; device_sealed: string; interval_s: number; created_at: number; polled_at: number; done: number }>(
      "SELECT * FROM app_device_flows WHERE id = ? AND app = ? AND created_at >= ?", flowId, app, this.now() - DEVICE_CODE_LIFETIME_MS).toArray()[0];
    if (!flow || flow.done || definition.signIn !== "device") return { state: "failed", error: "This sign-in has ended. Start again." };
    const device = (await unseal(this.deps.secret, `apps-device\0${this.deps.accountId}`, flow.device_sealed)) as { deviceAuthId: string; userCode: string; intervalSeconds: number } | null;
    if (!device) return { state: "failed", error: "This sign-in has ended. Start again." };
    const pending = this.pending(device.userCode, flow.interval_s, flow.created_at);
    if (this.now() - flow.polled_at < flow.interval_s * 1000) return pending;
    this.deps.sql.exec("UPDATE app_device_flows SET polled_at = ? WHERE id = ?", this.now(), flowId);
    let grant: OpenAIGrant | null;
    try {
      grant = await pollDeviceCode(device, this.deps.fetcher, this.now());
    } catch (error) {
      if (!(error instanceof GrantRefused)) return pending;
      this.deps.sql.exec("UPDATE app_device_flows SET done = 1 WHERE id = ?", flowId);
      return { state: "failed", error: `${definition.providerTitle} did not accept the sign-in. Start again.` };
    }
    if (!grant) return pending;
    // The code is spent at the provider: whatever happens next, this flow is over.
    this.deps.sql.exec("UPDATE app_device_flows SET done = 1 WHERE id = ?", flowId);
    const account = grant.email?.toLowerCase();
    const refuse = (error: string): DeviceSignIn => {
      this.deps.waitUntil(revokeOpenAIGrant(grant!, this.deps.fetcher).catch(() => undefined));
      return { state: "failed", error };
    };
    if (!account) return refuse(`${definition.providerTitle} did not say which account signed in; try again.`);
    if (!grant.chatgptAccountId) return refuse("This account has no ChatGPT plan to use.");
    const known = this.rows(app).some((r) => r.account === account);
    if (!known && this.rows(app).length >= APP_ACCOUNTS_MAX) return refuse(`${definition.title} holds at most ${APP_ACCOUNTS_MAX} accounts; sign one out first.`);
    this.deps.sql.exec(`INSERT INTO app_accounts (app, account, grant_sealed, grant_generation, last_error, created_at) VALUES (?, ?, ?, 1, NULL, ?)
      ON CONFLICT (app, account) DO UPDATE SET grant_sealed = excluded.grant_sealed, grant_generation = app_accounts.grant_generation + 1, last_error = NULL`,
    app, account, await this.seal(grant), this.now());
    return { state: "done", account };
  }

  private pending(userCode: string, intervalSeconds: number, createdAt: number): Extract<DeviceSignIn, { state: "pending" }> {
    return { state: "pending", userCode, verificationUrl: DEVICE_VERIFICATION_URL, intervalSeconds, expiresAt: new Date(createdAt + DEVICE_CODE_LIFETIME_MS).toISOString() };
  }

  /**
   * Adds an account to a token app from what the person pasted on the app's page, or replaces
   * the token of one already added. The token is checked with one read call first; one the
   * service refuses is not stored. Returns the account's name: the service's own (an email) or,
   * for an app whose service has none, the one the person gave.
   */
  async addToken(app: AppName, named: string | null, fields: Record<string, string>): Promise<{ name: string; account: string }> {
    const definition = APP_DEFINITIONS[app];
    if (definition.signIn !== "token") throw new AppAccountRefused(`${definition.title} signs in with ${definition.providerTitle}, not a token`);
    const credential: TokenCredential = { kind: "token", fields: {} };
    for (const field of definition.token.fields) {
      const value = fields[field.name]?.trim();
      if (!value) throw new AppAccountRefused(`${field.label} is missing`);
      if (/[\r\n]/.test(value)) throw new AppAccountRefused(`${field.label} may not contain line breaks`);
      credential.fields[field.name] = value;
    }
    const unknown = Object.keys(fields).find((name) => !definition.token.fields.some((f) => f.name === name));
    if (unknown) throw new AppAccountRefused(`${definition.title} does not take ${unknown.slice(0, 64)}`);
    if (definition.token.named && !named) throw new AppAccountRefused("Name this account, such as \"personal\"");
    let identified: string | null;
    try {
      identified = await definition.token.identify(this.api(definition, CHECK_TOOL, definition.token.authorize(credential.fields)));
    } catch (error) {
      if (error instanceof Unauthorized) throw new AppAccountRefused(`${definition.title} did not accept this token`);
      if (error instanceof ProviderError) throw new AppAccountRefused(`${definition.title} did not accept this token: ${error.message}`.slice(0, 300));
      throw error;
    }
    const account = (definition.token.named ? named : identified ?? named)?.toLowerCase();
    if (!account || account.length < 3) throw new AppAccountRefused("Name this account, such as \"personal\"");
    const known = this.rows(app).some((r) => r.account === account);
    if (!known && this.rows(app).length >= APP_ACCOUNTS_MAX) throw new AppAccountRefused(`${definition.title} holds at most ${APP_ACCOUNTS_MAX} accounts; remove one first.`);
    this.deps.sql.exec(`INSERT INTO app_accounts (app, account, grant_sealed, grant_generation, last_error, created_at) VALUES (?, ?, ?, 1, NULL, ?)
      ON CONFLICT (app, account) DO UPDATE SET grant_sealed = excluded.grant_sealed, grant_generation = app_accounts.grant_generation + 1, last_error = NULL`,
    app, account, await this.seal(credential), this.now());
    return { name: `apps.${app}`, account };
  }

  /**
   * Runs an app's tool as the account the input names, with that account's grant. A 401
   * renews the grant once and the call is sent again, since it did not run. A call to a tool
   * that is not idempotent and got no answer fails as may-have-run.
   */
  async call(app: AppName, toolName: string, input: unknown): Promise<unknown> {
    const definition = APP_DEFINITIONS[app];
    const tool = toolsOf(app).find((t) => t.name === toolName);
    if (!tool) throw new Error(`apps.${app} has no tool named ${toolName}; it has ${toolsOf(app).map((t) => t.name).join(", ")}`);
    if (!this.isAvailable(definition)) throw new Error(`${definition.title} is not set up on this Axo deployment`);
    const parsed = inputOf(tool).safeParse(input ?? {});
    if (!parsed.success) throw new Error(`invalid input: ${z.prettifyError(parsed.error)}`.slice(0, 1024));
    const { account: named, ...rest } = parsed.data as { account: string } & Record<string, unknown>;
    const account = named.toLowerCase();
    // Errors reach the Session in at most 256 characters, so a sign-in link comes first.
    if (!this.row(app, account)) {
      const accounts = this.rows(app).map((r) => r.account);
      if (!accounts.length && definition.signIn !== "oauth") throw new Error(`no ${definition.title} account yet; the person adds one at ${appPage(app)}`);
      if (!accounts.length) throw new Error(`needs sign-in: ${await this.signInLink(app)} (open in a browser signed in to Axo)`);
      throw new Error(`no ${definition.title} account ${account.slice(0, 64)}; signed in: ${accounts.join(", ")}`);
    }
    if (definition.signIn === "token") return this.callWithToken(definition, tool, account, rest);
    for (let attempt = 0; ; attempt++) {
      const grant = await this.grant(app, account, attempt > 0);
      if (!grant || !grantFits(definition, grant))
        throw new Error(`${account} needs sign-in: ${await this.signInLink(app)}`);
      try {
        return await tool.run(this.api(definition, tool, authorization(grant)), rest);
      } catch (error) {
        if (!(error instanceof Unauthorized)) throw error;
        if (attempt > 0) {
          this.dropGrant(app, account, this.row(app, account)?.grant_generation ?? 0, `${definition.title} refused the grant`);
          throw new Error(`${account} needs sign-in: ${definition.title} refused the grant`);
        }
      }
    }
  }

  /** A token app's call: a refused token is dropped, since only the person can issue a new one. */
  private async callWithToken(definition: TokenApp, tool: AppTool, account: string, input: Record<string, unknown>): Promise<unknown> {
    const row = this.row(definition.name, account);
    const credential = row?.grant_sealed ? await this.unsealToken(row.grant_sealed) : null;
    if (!row || !credential) throw new Error(`${account}'s token needs adding again at ${appPage(definition.name)}`);
    try {
      return await tool.run(this.api(definition, tool, definition.token.authorize(credential.fields)), input);
    } catch (error) {
      if (!(error instanceof Unauthorized)) throw error;
      this.dropGrant(definition.name, account, row.grant_generation, `${definition.title} refused the token`);
      throw new Error(`${account}: ${definition.title} refused the token; add a new one at ${appPage(definition.name)}`);
    }
  }

  /** The provider's API with `auth`, the headers that carry the credential, on every request. */
  private api(definition: AppDefinition, tool: AppTool, auth: Record<string, string>): ProviderApi {
    const fetcher = this.deps.fetcher;
    const authNames = new Set(Object.keys(auth).map((name) => name.toLowerCase()));
    const send = async (method: string, path: string, options: ProviderRequest = {}): Promise<Response> => {
      let url: URL;
      try {
        url = new URL(path, definition.apiOrigin);
      } catch {
        throw new ProviderError(0, `not a URL: ${path.slice(0, 100)}`);
      }
      // The grant goes only to the app's own API.
      if (!allowedUrl(definition, url)) throw new ProviderError(0, `${definition.title} calls only reach ${definition.hosts.join(", ")}`);
      for (const [key, value] of Object.entries(options.query ?? {})) {
        if (value === undefined) continue;
        for (const item of Array.isArray(value) ? value : [value]) url.searchParams.append(key, item);
      }
      // Only a write that is not safe to repeat can leave its outcome unknown; a failed read ran nothing that matters.
      const risky = method !== "GET" && !tool.idempotent;
      const body = options.raw ?? (options.body === undefined ? undefined : { contentType: "application/json", data: JSON.stringify(options.body) });
      let response: Response;
      try {
        // No header of a call's own may stand in for the credential's.
        const own = Object.entries(options.headers ?? {}).filter(([name]) => !authNames.has(name.toLowerCase()) && name.toLowerCase() !== "authorization");
        response = await fetcher(url, {
          method,
          headers: {
            ...Object.fromEntries(own),
            Accept: options.accept ?? "application/json",
            ...(body ? { "Content-Type": body.contentType } : {}),
            ...auth,
          },
          body: body?.data,
          redirect: "manual",
          signal: AbortSignal.timeout(Math.min(options.timeoutMs ?? REQUEST_TIMEOUT_MS, MAX_REQUEST_TIMEOUT_MS)),
        });
      } catch {
        if (risky) throw new ProviderOutcomeUnknown(`${definition.title} did not answer; it may have run`);
        throw new ProviderError(0, `${definition.title} did not answer`);
      }
      if (response.status === 401) {
        await response.body?.cancel();
        throw new Unauthorized();
      }
      if (response.status >= 500 && risky) {
        await response.body?.cancel();
        throw new ProviderOutcomeUnknown(`${definition.title} failed (HTTP ${response.status}); it may have run`);
      }
      if (!response.ok) {
        const text = await response.text();
        throw new ProviderError(response.status, `${definition.title}: ${providerMessage(text) ?? `HTTP ${response.status}`}`);
      }
      return response;
    };
    return {
      async request(method, path, options) {
        const text = await (await send(method, path, options)).text();
        return text ? (JSON.parse(text) as unknown) : null;
      },
      async requestBytes(method, path, options) {
        return (await send(method, path, options)).arrayBuffer();
      },
      async requestRaw(method, path, options) {
        const response = await send(method, path, options);
        return { status: response.status, contentType: response.headers.get("Content-Type") ?? "", body: await response.arrayBuffer() };
      },
    };
  }

  /**
   * One account's current grant, renewed first if it is about to expire or `force`. One
   * renewal runs per account; it names the generation it renews, and lands only if that is
   * still current.
   */
  private async grant(app: AppName, account: string, force: boolean): Promise<Grant | null> {
    const row = this.row(app, account);
    if (!row?.grant_sealed) return null;
    const grant = await this.unsealGrant(row.grant_sealed);
    if (!grant) return null;
    const due = force || (grant.expiresAt !== null && grant.expiresAt - this.now() < EXPIRY_MARGIN_MS);
    if (!due) return grant;
    const definition = APP_DEFINITIONS[app];
    const client = definition.signIn === "oauth" ? this.client(definition) : null;
    if (!grant.refreshToken || (!client && !isOpenAI(grant))) {
      this.dropGrant(app, account, row.grant_generation, "the grant expired and cannot be renewed");
      return null;
    }
    const generation = row.grant_generation;
    const key = `${app}\0${account}#${generation}`;
    const running = this.refreshing.get(key);
    if (running) return running;
    if (isOpenAI(grant)) return this.renewOpenAI(app, account, generation, grant, key);
    const attempt = (async () => {
      try {
        const renewed = await refreshGoogleGrant(client!, grant, this.deps.fetcher, this.now());
        const landed = this.deps.sql.exec("UPDATE app_accounts SET grant_sealed = ? WHERE app = ? AND account = ? AND grant_generation = ?",
          await this.seal(renewed), app, account, generation).rowsWritten > 0;
        return landed ? renewed : null;
      } catch (error) {
        // Google does not rotate refresh tokens, so a renewal that got no answer keeps the grant.
        if (error instanceof GrantRefused) this.dropGrant(app, account, generation, "Google refused to renew the grant");
        else throw new Error("renewing the grant got no answer; try again");
        return null;
      } finally {
        this.refreshing.delete(key);
      }
    })();
    this.refreshing.set(key, attempt);
    return attempt;
  }

  /**
   * Renews a ChatGPT grant. OpenAI rotates refresh tokens, so a renewal that got no answer may
   * have spent the only one: the grant is dropped and the person signs in again.
   */
  private renewOpenAI(app: AppName, account: string, generation: number, grant: OpenAIGrant, key: string): Promise<Grant | null> {
    const attempt = (async () => {
      try {
        const renewed = await refreshOpenAIGrant(grant, this.deps.fetcher, this.now());
        const landed = this.deps.sql.exec("UPDATE app_accounts SET grant_sealed = ? WHERE app = ? AND account = ? AND grant_generation = ?",
          await this.seal(renewed), app, account, generation).rowsWritten > 0;
        return landed ? renewed : null;
      } catch (error) {
        this.dropGrant(app, account, generation, error instanceof GrantRefused ? "OpenAI refused to renew the sign-in" : "renewing the sign-in got no answer");
        return null;
      } finally {
        this.refreshing.delete(key);
      }
    })();
    this.refreshing.set(key, attempt);
    return attempt;
  }

  /** The account stays listed, needing sign-in, so the person sees which one to sign in to again. */
  private dropGrant(app: AppName, account: string, generation: number, reason: string): void {
    this.deps.sql.exec("UPDATE app_accounts SET grant_sealed = NULL, last_error = ? WHERE app = ? AND account = ? AND grant_generation = ?", reason, app, account, generation);
  }

  private available(): AppName[] {
    return APPS.filter((app) => this.isAvailable(APP_DEFINITIONS[app]));
  }

  /** An OAuth app needs Axo's client for its provider on this deployment; a token app needs nothing. */
  private isAvailable(definition: AppDefinition): boolean {
    return definition.signIn !== "oauth" || this.client(definition) !== null;
  }

  private client(definition: OAuthApp): GoogleClient | null {
    return definition.provider === "google" ? this.deps.google : null;
  }

  private rows(app: string): Row[] {
    return this.deps.sql.exec<Row>("SELECT * FROM app_accounts WHERE app = ? ORDER BY created_at, account", app).toArray();
  }

  private row(app: string, account: string): Row | undefined {
    return this.deps.sql.exec<Row>("SELECT * FROM app_accounts WHERE app = ? AND account = ?", app, account).toArray()[0];
  }

  private flow(nonce: string) {
    return this.deps.sql.exec<{ app: string; verifier: string; opened: number; redeemed: number }>(
      "SELECT * FROM app_flows WHERE nonce = ? AND created_at >= ?", nonce, this.now() - FLOW_LIFETIME_MS,
    ).toArray()[0];
  }

  private seal(credential: Grant | TokenCredential): Promise<string> {
    return seal(this.deps.secret, `apps-grant\0${this.deps.accountId}`, credential);
  }

  /** An OAuth grant; a token is never one. */
  private async unsealGrant(sealed: string): Promise<Grant | null> {
    const value = (await unseal(this.deps.secret, `apps-grant\0${this.deps.accountId}`, sealed, 65_536)) as (GoogleGrant & { kind?: undefined }) | OpenAIGrant | TokenCredential | null;
    return value && value.kind !== "token" ? value : null;
  }

  private async unsealToken(sealed: string): Promise<TokenCredential | null> {
    const value = (await unseal(this.deps.secret, `apps-grant\0${this.deps.accountId}`, sealed, 65_536)) as TokenCredential | { kind?: undefined } | null;
    return value?.kind === "token" ? value : null;
  }
}

/** The call that checks a token before it is stored: a read, so a lost answer ran nothing. */
const CHECK_TOOL: AppTool = { name: "add_account", description: "", input: z.object({}), idempotent: true, run: async () => null };

function isOpenAI(grant: Grant): grant is OpenAIGrant {
  return (grant as { kind?: string }).kind === "openai";
}

/** Whether a grant is one this app can use: Google's must hold every scope the app needs. */
function grantFits(definition: OAuthApp | DeviceApp, grant: Grant): boolean {
  if (definition.signIn === "device") return isOpenAI(grant);
  return !isOpenAI(grant) && definition.requiredScopes.every((scope) => grant.scopes.includes(scope));
}

/** The headers that carry a grant. ChatGPT also needs the ChatGPT account (workspace) it acts in. */
function authorization(grant: Grant): Record<string, string> {
  if (!isOpenAI(grant)) return { Authorization: `Bearer ${grant.accessToken}` };
  return { Authorization: `Bearer ${grant.accessToken}`, "chatgpt-account-id": grant.chatgptAccountId ?? "", originator: "axo" };
}

/** How the web app's Add account works for an app. */
function signInOf(definition: AppDefinition): AppSignIn {
  if (definition.signIn === "oauth") return { kind: "oauth" };
  if (definition.signIn === "device") return { kind: "device" };
  const { helpUrl, named, fields } = definition.token;
  return { kind: "token", helpUrl, named, fields: fields.map((f) => ({ ...f })) };
}

/** A tool's input as scripts see it: `account` first, then the tool's own fields. */
function inputOf(tool: AppTool): z.ZodObject {
  return z.object({ account: accountInput }).extend(tool.input.shape).strict();
}

/** Google's error answer, `{ error: { message } }`, as one short line. */
function providerMessage(text: string): string | null {
  try {
    const message = (JSON.parse(text) as { error?: { message?: unknown } }).error?.message;
    return typeof message === "string" ? message.replace(/\s+/g, " ").slice(0, 300) : null;
  } catch {
    return null;
  }
}

function randomVerifier(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function challengeOf(verifier: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  return btoa(String.fromCharCode(...digest)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
