import { z } from "zod";
import { APP_ACCOUNTS_MAX, APPS, type AppAccount, type AppName, type Connection, type ToolDefinition } from "@axo/protocol";
import { seal, unseal } from "../../auth/crypto";
import { GrantRefused } from "../oauth";
import { FLOW_LIFETIME_MS, startUrl } from "../third-party";
import { allowedUrl, ProviderError, ProviderOutcomeUnknown, type AppDefinition, type AppTool, type ProviderApi, type ProviderRequest } from "./app";
import { calendar } from "./calendar";
import { cloud } from "./cloud";
import { contacts } from "./contacts";
import { docs } from "./docs";
import { drive } from "./drive";
import { gmail } from "./gmail";
import { meet } from "./meet";
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
 * `codemode.apps.<app>.<tool>({ account, ... })`. Each app signs in with Axo's own client for its
 * provider, set on the Worker, and holds any number of provider accounts, each named by its
 * email. Every call names the account it acts as: nothing is read or sent from a guessed one.
 *
 * Grants are sealed with the account's key and never leave this Durable Object. Sign-in reuses
 * the connections callback and its checks: a flow is a one-time nonce that works for ten
 * minutes, only in a browser signed in to this account. Each provider account's grant carries a
 * generation, and a renewal lands only on the generation it renewed.
 */

export const APP_DEFINITIONS: Record<AppName, AppDefinition> = { gmail, calendar, drive, docs, sheets, slides, contacts, tasks, meet, cloud };

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
  private readonly refreshing = new Map<string, Promise<GoogleGrant | null>>();

  constructor(private readonly deps: AppsDeps) {
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_accounts (
      app TEXT NOT NULL, account TEXT NOT NULL, grant_sealed TEXT, grant_generation INTEGER NOT NULL DEFAULT 1,
      last_error TEXT, created_at REAL NOT NULL, PRIMARY KEY (app, account))`);
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
        permissions: [...definition.permissions],
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
      const signedIn = accounts.length ? ` Signed-in accounts: ${accounts.join(", ")}.` : " No account is signed in yet: a call returns a sign-in link to give the person.";
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
    if (!this.client(APP_DEFINITIONS[app])) throw new Error(`${APP_DEFINITIONS[app].title} is not set up on this Axo deployment`);
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
    const client = definition ? this.client(definition) : null;
    if (!client) return null;
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
    const client = definition ? this.client(definition) : null;
    if (!client) return { error: "this app is not set up on this Axo deployment" };
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
    const grant = row.grant_sealed ? await this.unseal(row.grant_sealed) : null;
    if (grant) this.deps.waitUntil(revokeGoogleGrant(grant, this.deps.fetcher).catch(() => undefined));
    return true;
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
    if (!this.client(definition)) throw new Error(`${definition.title} is not set up on this Axo deployment`);
    const parsed = inputOf(tool).safeParse(input ?? {});
    if (!parsed.success) throw new Error(`invalid input: ${z.prettifyError(parsed.error)}`.slice(0, 1024));
    const { account: named, ...rest } = parsed.data as { account: string } & Record<string, unknown>;
    const account = named.toLowerCase();
    // Errors reach the Session in at most 256 characters, so a sign-in link comes first.
    if (!this.row(app, account)) {
      const accounts = this.rows(app).map((r) => r.account);
      if (!accounts.length) throw new Error(`needs sign-in: ${await this.signInLink(app)} (open in a browser signed in to Axo)`);
      throw new Error(`no ${definition.title} account ${account.slice(0, 64)}; signed in: ${accounts.join(", ")}`);
    }
    for (let attempt = 0; ; attempt++) {
      const grant = await this.grant(app, account, attempt > 0);
      if (!grant || definition.requiredScopes.some((scope) => !grant.scopes.includes(scope)))
        throw new Error(`${account} needs sign-in: ${await this.signInLink(app)}`);
      try {
        return await tool.run(this.api(definition, tool, grant.accessToken), rest);
      } catch (error) {
        if (!(error instanceof Unauthorized)) throw error;
        if (attempt > 0) {
          this.dropGrant(app, account, this.row(app, account)?.grant_generation ?? 0, `${definition.title} refused the grant`);
          throw new Error(`${account} needs sign-in: ${definition.title} refused the grant`);
        }
      }
    }
  }

  private api(definition: AppDefinition, tool: AppTool, accessToken: string): ProviderApi {
    const fetcher = this.deps.fetcher;
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
        response = await fetcher(url, {
          method,
          headers: {
            ...options.headers,
            Accept: options.accept ?? "application/json",
            ...(body ? { "Content-Type": body.contentType } : {}),
            Authorization: `Bearer ${accessToken}`,
          },
          body: body?.data,
          redirect: "manual",
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
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
  private async grant(app: AppName, account: string, force: boolean): Promise<GoogleGrant | null> {
    const row = this.row(app, account);
    if (!row?.grant_sealed) return null;
    const grant = await this.unseal(row.grant_sealed);
    if (!grant) return null;
    const due = force || (grant.expiresAt !== null && grant.expiresAt - this.now() < EXPIRY_MARGIN_MS);
    if (!due) return grant;
    const client = this.client(APP_DEFINITIONS[app]);
    if (!grant.refreshToken || !client) {
      this.dropGrant(app, account, row.grant_generation, "the grant expired and cannot be renewed");
      return null;
    }
    const generation = row.grant_generation;
    const key = `${app}\0${account}#${generation}`;
    const running = this.refreshing.get(key);
    if (running) return running;
    const attempt = (async () => {
      try {
        const renewed = await refreshGoogleGrant(client, grant, this.deps.fetcher, this.now());
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

  /** The account stays listed, needing sign-in, so the person sees which one to sign in to again. */
  private dropGrant(app: AppName, account: string, generation: number, reason: string): void {
    this.deps.sql.exec("UPDATE app_accounts SET grant_sealed = NULL, last_error = ? WHERE app = ? AND account = ? AND grant_generation = ?", reason, app, account, generation);
  }

  private available(): AppName[] {
    return APPS.filter((app) => this.client(APP_DEFINITIONS[app]) !== null);
  }

  private client(definition: AppDefinition): GoogleClient | null {
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

  private seal(grant: GoogleGrant): Promise<string> {
    return seal(this.deps.secret, `apps-grant\0${this.deps.accountId}`, grant);
  }

  private async unseal(sealed: string): Promise<GoogleGrant | null> {
    return (await unseal(this.deps.secret, `apps-grant\0${this.deps.accountId}`, sealed, 65_536)) as GoogleGrant | null;
  }
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
