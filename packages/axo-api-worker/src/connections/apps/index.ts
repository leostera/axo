import { z } from "zod";
import { APPS, type AppName, type Connection, type ToolDefinition } from "@axo/protocol";
import { seal, unseal } from "../../auth/crypto";
import { GrantRefused } from "../oauth";
import { FLOW_LIFETIME_MS, startUrl } from "../third-party";
import { ProviderError, ProviderOutcomeUnknown, type AppDefinition, type AppTool, type ProviderApi } from "./app";
import { gmail } from "./gmail";
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
 * `codemode.apps.<app>.<tool>()`. Each app signs in with Axo's own client for its provider, set
 * on the Worker; the grant is sealed with the account's key and never leaves this Durable Object.
 *
 * Sign-in reuses the connections callback and its checks: a flow is a one-time nonce that works
 * for ten minutes, only in a browser signed in to this account. Grants carry a generation like
 * third-party grants, and a renewal lands only on the generation it renewed.
 */

export const APP_DEFINITIONS: Record<AppName, AppDefinition> = { gmail };

/** An access token this close to expiring is renewed before use. */
const EXPIRY_MARGIN_MS = 60_000;
const REQUEST_TIMEOUT_MS = 30_000;

type Row = {
  app: string;
  grant_sealed: string | null;
  grant_generation: number;
  account: string | null;
  last_error: string | null;
};

export type AppsDeps = {
  sql: SqlStorage;
  secret: string;
  accountId: string;
  /** Axo's Google client, or null when this deployment has none: Google apps are then unavailable. */
  google: GoogleClient | null;
  fetcher: typeof fetch;
  waitUntil(promise: Promise<unknown>): void;
  now?: () => number;
};

/** The provider said the access token is no good: nothing ran, so the call may be sent again. */
class Unauthorized extends Error {}

export class AppConnections {
  private readonly refreshing = new Map<string, Promise<GoogleGrant | null>>();

  constructor(private readonly deps: AppsDeps) {
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_grants (
      app TEXT PRIMARY KEY, grant_sealed TEXT, grant_generation INTEGER NOT NULL DEFAULT 0,
      account TEXT, last_error TEXT)`);
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_flows (
      nonce TEXT PRIMARY KEY, app TEXT NOT NULL, verifier TEXT NOT NULL, created_at REAL NOT NULL,
      opened INTEGER NOT NULL DEFAULT 0, redeemed INTEGER NOT NULL DEFAULT 0)`);
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }

  /** `apps.gmail` → `gmail`, for an app that exists; anything else → null. */
  static appOf(service: string): AppName | null {
    const app = /^apps\.(.+)$/.exec(service)?.[1];
    return app && (APPS as readonly string[]).includes(app) ? (app as AppName) : null;
  }

  /** The apps this deployment can sign in to; one without a client for its provider is not listed. */
  list(): Connection[] {
    return APPS.filter((app) => this.client(APP_DEFINITIONS[app]) !== null).map((app): Connection => {
      const definition = APP_DEFINITIONS[app];
      const row = this.row(app);
      return {
        kind: "app",
        name: `apps.${app}`,
        title: definition.title,
        state: row?.grant_sealed ? "ready" : "needsSignIn",
        account: row?.grant_sealed ? row.account : null,
        tools: definition.tools.length,
        lastError: row?.last_error ?? null,
      };
    });
  }

  /** The tools of every app this deployment can sign in to, signed in or not: a call explains how to sign in. */
  tools(): ToolDefinition[] {
    return APPS.flatMap((app) => {
      const definition = APP_DEFINITIONS[app];
      if (!this.client(definition)) return [];
      return definition.tools.map((tool) => ({
        service: `apps.${app}`,
        name: tool.name,
        title: tool.name,
        description: tool.description,
        inputSchema: z.toJSONSchema(tool.input, { io: "input" }) as Record<string, unknown>,
      }));
    });
  }

  /** A sign-in link for an app: Axo's own start page, which works once, in this account's browser. */
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

  /** The provider sent the browser back: redeems the code once. Null if the nonce is not an app's. */
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
      this.setError(app, `${definition.title} did not accept the sign-in`);
      return { error: `${definition.title} did not accept the sign-in` };
    }
    const missing = definition.requiredScopes.filter((scope) => !grant.scopes.includes(scope));
    if (missing.length) {
      this.deps.waitUntil(revokeGoogleGrant(grant, this.deps.fetcher).catch(() => undefined));
      this.setError(app, `the sign-in did not grant ${definition.title} access; tick every box on Google's consent page`);
      return { error: `The sign-in did not grant ${definition.title} access. Sign in again and allow every permission asked for.` };
    }
    this.deps.sql.exec(`INSERT INTO app_grants (app, grant_sealed, grant_generation, account, last_error) VALUES (?, ?, 1, ?, NULL)
      ON CONFLICT (app) DO UPDATE SET grant_sealed = excluded.grant_sealed, grant_generation = app_grants.grant_generation + 1,
      account = excluded.account, last_error = NULL`, app, await this.seal(grant), grant.email);
    return { name: `apps.${app}` };
  }

  /** Signs the account out of an app: the grant is deleted here and revoked at the provider. */
  async disconnect(app: AppName): Promise<boolean> {
    const row = this.row(app);
    if (!row?.grant_sealed) return false;
    const grant = await this.unseal(row.grant_sealed);
    this.deps.sql.exec("UPDATE app_grants SET grant_sealed = NULL, account = NULL, last_error = NULL, grant_generation = grant_generation + 1 WHERE app = ?", app);
    this.deps.sql.exec("DELETE FROM app_flows WHERE app = ?", app);
    if (grant) this.deps.waitUntil(revokeGoogleGrant(grant, this.deps.fetcher).catch(() => undefined));
    return true;
  }

  /**
   * Runs an app's tool with the account's grant. A 401 renews the grant once and the call is
   * sent again, since it did not run. A call to a tool that is not idempotent and got no answer
   * fails as may-have-run.
   */
  async call(app: AppName, toolName: string, input: unknown): Promise<unknown> {
    const definition = APP_DEFINITIONS[app];
    const tool = definition.tools.find((t) => t.name === toolName);
    if (!tool) throw new Error(`apps.${app} has no tool named ${toolName}`);
    const parsed = tool.input.safeParse(input ?? {});
    if (!parsed.success) throw new Error(`invalid input: ${z.prettifyError(parsed.error)}`.slice(0, 1024));
    if (!this.client(definition)) throw new Error(`${definition.title} is not set up on this Axo deployment`);
    for (let attempt = 0; ; attempt++) {
      const grant = await this.grant(app, attempt > 0);
      if (!grant) {
        // Errors reach the Session in at most 256 characters, so the link comes first.
        throw new Error(`needs sign-in: ${await this.signInLink(app)} (open in a browser signed in to Axo)`);
      }
      try {
        return await tool.run(this.api(definition, tool, grant.accessToken), parsed.data);
      } catch (error) {
        if (!(error instanceof Unauthorized)) throw error;
        if (attempt > 0) {
          this.dropGrant(app, this.row(app)?.grant_generation ?? 0, `${definition.title} refused the grant`);
          throw new Error(`needs sign-in: ${definition.title} refused the grant`);
        }
      }
    }
  }

  private api(definition: AppDefinition, tool: AppTool, accessToken: string): ProviderApi {
    const fetcher = this.deps.fetcher;
    return {
      async request(method, path, options = {}) {
        const url = new URL(path, definition.apiOrigin);
        for (const [key, value] of Object.entries(options.query ?? {})) {
          if (value === undefined) continue;
          for (const item of Array.isArray(value) ? value : [value]) url.searchParams.append(key, item);
        }
        // Only a write that is not safe to repeat can leave its outcome unknown; a failed read ran nothing that matters.
        const risky = method !== "GET" && !tool.idempotent;
        let response: Response;
        try {
          response = await fetcher(url, {
            method,
            headers: {
              Authorization: `Bearer ${accessToken}`,
              Accept: "application/json",
              ...(options.body === undefined ? {} : { "Content-Type": "application/json" }),
            },
            body: options.body === undefined ? undefined : JSON.stringify(options.body),
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
        const text = await response.text();
        if (!response.ok) throw new ProviderError(response.status, `${definition.title}: ${providerMessage(text) ?? `HTTP ${response.status}`}`);
        return text ? (JSON.parse(text) as unknown) : null;
      },
    };
  }

  /**
   * The current grant, renewed first if it is about to expire or `force`. One renewal runs per
   * app; it names the generation it renews, and lands only if that is still current.
   */
  private async grant(app: AppName, force: boolean): Promise<GoogleGrant | null> {
    const row = this.row(app);
    if (!row?.grant_sealed) return null;
    const grant = await this.unseal(row.grant_sealed);
    if (!grant) return null;
    const due = force || (grant.expiresAt !== null && grant.expiresAt - this.now() < EXPIRY_MARGIN_MS);
    if (!due) return grant;
    const client = this.client(APP_DEFINITIONS[app]);
    if (!grant.refreshToken || !client) {
      this.dropGrant(app, row.grant_generation, "the grant expired and cannot be renewed");
      return null;
    }
    const generation = row.grant_generation;
    const key = `${app}#${generation}`;
    const running = this.refreshing.get(key);
    if (running) return running;
    const attempt = (async () => {
      try {
        const renewed = await refreshGoogleGrant(client, grant, this.deps.fetcher, this.now());
        const landed = this.deps.sql.exec("UPDATE app_grants SET grant_sealed = ? WHERE app = ? AND grant_generation = ?",
          await this.seal(renewed), app, generation).rowsWritten > 0;
        return landed ? renewed : null;
      } catch (error) {
        // Google does not rotate refresh tokens, so a renewal that got no answer keeps the grant.
        if (error instanceof GrantRefused) this.dropGrant(app, generation, "Google refused to renew the grant");
        else throw new Error("renewing the grant got no answer; try again");
        return null;
      } finally {
        this.refreshing.delete(key);
      }
    })();
    this.refreshing.set(key, attempt);
    return attempt;
  }

  private dropGrant(app: AppName, generation: number, reason: string): void {
    this.deps.sql.exec("UPDATE app_grants SET grant_sealed = NULL, account = NULL, last_error = ? WHERE app = ? AND grant_generation = ?", reason, app, generation);
  }

  private setError(app: AppName, message: string): void {
    this.deps.sql.exec(`INSERT INTO app_grants (app, last_error) VALUES (?, ?)
      ON CONFLICT (app) DO UPDATE SET last_error = excluded.last_error`, app, message.slice(0, 512));
  }

  private client(definition: AppDefinition): GoogleClient | null {
    return definition.provider === "google" ? this.deps.google : null;
  }

  private row(app: string): Row | undefined {
    return this.deps.sql.exec<Row>("SELECT * FROM app_grants WHERE app = ?", app).toArray()[0];
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
