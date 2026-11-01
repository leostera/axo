import { z } from "zod";
import { APP_ACCOUNTS_MAX, APPS, type AppAccount, type AppMacSignIn, type AppName, type AppSignIn, type Connection, type ToolDefinition } from "@axo/protocol";
import {
  allowedUrl,
  APP_DEFINITIONS,
  authorizationUrl,
  DEVICE_CODE_LIFETIME_MS,
  DEVICE_VERIFICATION_URL,
  GrantRefused,
  OAUTH_PROVIDER_CONFIGS,
  OAUTH_PROVIDERS,
  pkceChallenge,
  pkceVerifier,
  pollDeviceCode,
  ProviderError,
  ProviderOutcomeUnknown,
  randomState,
  redeemCode,
  refreshGrant,
  refreshOpenAIGrant,
  requestDeviceCode,
  revokeOpenAIGrant,
  toolsOf,
  macCommand,
  Unauthorized,
  type AppDefinition,
  type AppTool,
  type Authorized,
  type DeviceApp,
  type MacApp,
  type MacShell,
  type OAuthApp,
  type OAuthClient,
  type OAuthGrant,
  type OAuthProviderName,
  type OpenAIGrant,
  type OutgoingRequest,
  type ProviderApi,
  type ProviderRequest,
  type TokenApp,
} from "@axo/apps";
import { seal, unseal } from "../../auth/crypto";
import { CALLBACK_URL } from "../oauth";
import { FLOW_LIFETIME_MS, startUrl } from "../third-party";

export { APP_DEFINITIONS, macCommand, toolsOf };

/**
 * The account's apps (RFD0016, Apps; what each app is lives in @axo/apps): services Axo provides
 * itself, such as Gmail, reached as `codemode.apps.<app>.<tool>({ account, ... })`. An OAuth app
 * signs in with a client the person registered with its provider and entered on the app's page,
 * kept sealed here with the grants; a token app takes a token the person pasted (Hetzner). Each
 * holds any number of provider accounts, each named by its email or by the person. Every call
 * names the account it acts as: nothing is read or sent from a guessed one.
 *
 * Grants and tokens are sealed with the account's key and never leave this Durable Object. Sign-in reuses
 * the connections callback and its checks: a flow is a one-time nonce that works for ten
 * minutes, only in a browser signed in to this account. Each provider account's grant carries a
 * generation, and a renewal lands only on the generation it renewed.
 */

/** Where a person adds an account to an app, or signs in to one again. */
export function appPage(app: AppName): string {
  return `https://axo.leostera.dev/app/settings/apps/${app}`;
}

/**
 * A token app's credential, as stored (sealed) for one account: the fields the person pasted, or
 * that a sign-in on their Mac got (TokenSignIn.mac), with when they stop working and what undoes
 * that sign-in at the service.
 */
type TokenCredential = { kind: "token"; fields: Record<string, string>; expiresAt?: number | null; revocation?: unknown };

/** How long a sign-in on a Mac waits for the person in their browser. */
export const MAC_SIGN_IN_TIMEOUT_MS = 5 * 60_000;
/** What axod's loopback sign-in answers (axo-relay's signin.rs). */
export type MacSignInCallback = { redirectUri: string; code?: string; error?: string; errorDescription?: string };
/** A signed-in account's grant: an OAuth provider's (Google's stored before grants had a provider) or OpenAI's. */
type Grant = OAuthGrant | OpenAIGrant;

/** A device sign-in in progress, as the web app polls it. */
export type DeviceSignIn =
  | { state: "pending"; userCode: string; verificationUrl: string; intervalSeconds: number; expiresAt: string }
  | { state: "done"; account: string }
  | { state: "failed"; error: string };

/** Adding an account was refused: the token was not accepted, or the input was wrong. Nothing was stored. */
export class AppAccountRefused extends Error {}

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
  /**
   * Google's client from the Worker's environment, from when Axo's clients were set there: used
   * while the account has none of its own stored. Goes once the account manager stops passing it.
   */
  legacyGoogle?: OAuthClient | null;
  fetcher: typeof fetch;
  waitUntil(promise: Promise<unknown>): void;
  now?: () => number;
  /** The account's Macs, by their names as connections: the accounts of a Mac app (1Password). */
  macs?: () => string[];
  /**
   * Runs a command on one of them, for a Mac app's tool; the call is logged as the app's.
   * Throws ProviderError when nothing was sent (the Mac is offline) and ProviderOutcomeUnknown
   * when it may have run.
   */
  runOnMac?: (mac: string, command: string, timeoutMs: number) => Promise<{ exitCode: number | null; stdout: string; stderr: string; timedOut: boolean }>;
  /**
   * Has a Mac open a sign-in page in the person's browser and wait on a localhost redirect port
   * (axod's loopback sign-in), for a token app's sign-in on a Mac. Throws ProviderError when the
   * Mac refused or could not finish it.
   */
  signInOnMac?: (mac: string, request: { authorizeUrl: string; ports: readonly number[]; path: string; state: string; timeoutMs: number }) => Promise<MacSignInCallback>;
};

const accountInput = z.string().min(3).max(320)
  .describe("The account to act as: one of this app's accounts, by its name in connections_list (an email, a username, an account number or a Mac, depending on the app).");

export class AppConnections {
  private readonly refreshing = new Map<string, Promise<Grant | null>>();

  constructor(private readonly deps: AppsDeps) {
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_accounts (
      app TEXT NOT NULL, account TEXT NOT NULL, grant_sealed TEXT, grant_generation INTEGER NOT NULL DEFAULT 1,
      last_error TEXT, created_at REAL NOT NULL, PRIMARY KEY (app, account))`);
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_device_flows (
      id TEXT PRIMARY KEY, app TEXT NOT NULL, device_sealed TEXT NOT NULL, interval_s INTEGER NOT NULL, created_at REAL NOT NULL,
      polled_at REAL NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0)`);
    // Sign-ins on a Mac in progress: the work runs in the background, and the web app polls this.
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_mac_sign_ins (
      id TEXT PRIMARY KEY, app TEXT NOT NULL, mac TEXT NOT NULL, state TEXT NOT NULL, account TEXT, error TEXT,
      expires_at REAL, created_at REAL NOT NULL)`);
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_flows (
      nonce TEXT PRIMARY KEY, app TEXT NOT NULL, verifier TEXT NOT NULL, created_at REAL NOT NULL,
      opened INTEGER NOT NULL DEFAULT 0, redeemed INTEGER NOT NULL DEFAULT 0)`);
    // The OAuth clients the person set up, one per provider: the ID as entered, the secret sealed.
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS app_clients (
      provider TEXT PRIMARY KEY, client_id TEXT NOT NULL, secret_sealed TEXT NOT NULL, updated_at REAL NOT NULL)`);
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

  /**
   * Every app, with its accounts; an OAuth app whose provider has no client yet is listed too, so
   * the person can set one up on its page. A Mac app is listed where Macs can be reached.
   */
  list(): Connection[] {
    return APPS.filter((app) => this.isListed(APP_DEFINITIONS[app])).map((app): Connection => {
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
        signIn: this.signInOf(definition),
        state: accounts.some((a) => a.state === "ready") ? "ready" : "needsSignIn",
        accounts,
        tools: toolsOf(app).map((t) => t.name),
        lastError: null,
      };
    });
  }

  /** The signed-in accounts of one app, oldest first. A Mac app's are the account's Macs. */
  accounts(app: AppName): AppAccount[] {
    if (APP_DEFINITIONS[app].signIn === "mac") return this.macs().map((mac) => ({ account: mac, state: "ready", lastError: null }));
    return this.rows(app).map((row) => ({ account: row.account, state: row.grant_sealed ? "ready" : "needsSignIn", lastError: row.last_error }));
  }

  /** The tools of every app that is set up, signed in or not: a call explains how to sign in. */
  tools(): ToolDefinition[] {
    return this.available().flatMap((app) => {
      const definition = APP_DEFINITIONS[app];
      const accounts = definition.signIn === "mac" ? this.macs() : this.rows(app).filter((r) => r.grant_sealed).map((r) => r.account);
      const signedIn = definition.signIn === "mac"
        ? ` The account is the Mac to run it on: ${accounts.join(", ") || "none is paired yet"}.`
        : accounts.length
        ? ` Signed-in accounts: ${accounts.join(", ")}.`
        : definition.signIn === "oauth"
          ? " No account is signed in yet: a call returns a sign-in link to give the person."
          : ` No account is added yet: the person adds one at ${appPage(app)}.`;
      return toolsOf(app).map((tool) => {
        const inputSchema = z.toJSONSchema(inputOf(tool), { io: "input" }) as { properties?: Record<string, { description?: string }> };
        // The schema names the accounts there are, so an agent passes one without looking them up.
        const account = inputSchema.properties?.account;
        if (account && accounts.length) account.description = `The account to act as: one of ${accounts.map((a) => JSON.stringify(a)).join(", ")}.`;
        return {
          service: `apps.${app}`,
          name: tool.name,
          title: tool.name,
          description: `${tool.description} Every call names its account.${signedIn}`,
          inputSchema: inputSchema as Record<string, unknown>,
          call: `codemode.apps.${app}.${tool.name}`,
        };
      });
    });
  }

  /** A sign-in link that adds an account to an app, or signs in to one again: Axo's own start page, once, in this account's browser. */
  async signInLink(app: AppName): Promise<string> {
    const definition = APP_DEFINITIONS[app];
    // A token app has no provider page to send the browser to: the person pastes a token on the app's page.
    if (definition.signIn !== "oauth") return appPage(app);
    if (!this.hasClient(definition.provider)) throw new Error(notSetUp(definition));
    const nonce = crypto.randomUUID();
    const verifier = pkceVerifier();
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
    const client = definition?.signIn === "oauth" ? await this.client(definition.provider) : null;
    if (!client || definition?.signIn !== "oauth") return null;
    const state = await seal(this.deps.secret, "connections-oauth-state", { accountId: this.deps.accountId, nonce });
    const provider = OAUTH_PROVIDER_CONFIGS[definition.provider];
    return { authorizeUrl: authorizationUrl(provider, client, definition.scopes, await pkceChallenge(flow.verifier), state, CALLBACK_URL), name: `apps.${flow.app}` };
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
    const client = definition?.signIn === "oauth" ? await this.client(definition.provider) : null;
    if (!client || definition?.signIn !== "oauth") return { error: "this app's OAuth client was removed; set it up again on the app's page" };
    const provider = OAUTH_PROVIDER_CONFIGS[definition.provider];
    let grant: OAuthGrant;
    try {
      grant = await redeemCode(provider, client, code, live.verifier, CALLBACK_URL, this.deps.fetcher, this.now());
    } catch {
      return { error: `${definition.title} did not accept the sign-in` };
    }
    const refuse = (error: string) => {
      this.revoke(grant);
      return { error };
    };
    if (definition.requiredScopes.some((scope) => !grant.scopes.includes(scope)))
      return refuse(`The sign-in did not grant ${definition.title} access. Sign in again and allow every permission asked for.`);
    let identified: string | null;
    try {
      identified = await unwrapped(provider.identify(grant, this.api(definition, CHECK_TOOL, () => ({ headers: authorization(grant) }), "")));
    } catch {
      identified = null;
    }
    const account = identified?.toLowerCase();
    if (!account || account.length < 3) return refuse(`${provider.title} did not say which account signed in; try again.`);
    const known = this.rows(app).some((r) => r.account === account);
    if (!known && this.rows(app).length >= APP_ACCOUNTS_MAX) return refuse(`${definition.title} holds at most ${APP_ACCOUNTS_MAX} accounts; sign one out first.`);
    this.deps.sql.exec(`INSERT INTO app_accounts (app, account, grant_sealed, grant_generation, last_error, created_at) VALUES (?, ?, ?, 1, NULL, ?)
      ON CONFLICT (app, account) DO UPDATE SET grant_sealed = excluded.grant_sealed, grant_generation = app_accounts.grant_generation + 1, last_error = NULL`,
    app, account, await this.seal(grant), this.now());
    return { name: `apps.${app}` };
  }

  /** Signs one provider account out of an app: its grant is deleted here and revoked at the provider. */
  async disconnect(app: AppName, account: string): Promise<boolean> {
    // A Mac app's accounts are the Macs: unpairing one removes it.
    if (APP_DEFINITIONS[app].signIn === "mac") return false;
    const row = this.row(app, account.toLowerCase());
    if (!row) return false;
    this.deps.sql.exec("DELETE FROM app_accounts WHERE app = ? AND account = ?", app, row.account);
    // A pasted token stays valid at the service: Axo can only forget it, and the person deletes
    // it there. One a sign-in on a Mac made is deleted at the service too.
    const definition = APP_DEFINITIONS[app];
    if (definition.signIn === "token") {
      if (row.grant_sealed) this.revokeToken(definition, row.grant_sealed);
      return true;
    }
    const grant = row.grant_sealed ? await this.unsealGrant(row.grant_sealed) : null;
    if (grant) this.revoke(grant);
    return true;
  }

  /** Tells the grant's provider to forget it, in the background, when the provider has a way to. */
  private revoke(grant: Grant): void {
    if (isOpenAI(grant)) {
      this.deps.waitUntil(revokeOpenAIGrant(grant, this.deps.fetcher).catch(() => undefined));
      return;
    }
    const provider = OAUTH_PROVIDER_CONFIGS[providerOf(grant)];
    if (!provider.revoke) return;
    this.deps.waitUntil((async () => {
      const client = await this.client(provider.name);
      if (client) await provider.revoke!(grant, client, this.deps.fetcher);
    })().catch(() => undefined));
  }

  /**
   * Sets up the OAuth client an app signs in with, or replaces it (a rotated secret, another
   * client): one per provider, so it serves every app of that provider. The person registered it
   * with the provider, with CALLBACK_URL as its redirect URI. The secret is sealed, and never
   * shown again. Accounts signed in with an older client keep working while the provider honours
   * their grants; a renewal the provider refuses asks for sign-in again.
   */
  async setClient(app: AppName, clientId: string, clientSecret: string): Promise<{ provider: OAuthProviderName }> {
    const definition = APP_DEFINITIONS[app];
    if (definition.signIn !== "oauth") throw new AppAccountRefused(`${definition.title} does not sign in with an OAuth client`);
    const id = clientId.trim();
    const secret = clientSecret.trim();
    if (!id || id.length > 512 || /\s/.test(id)) throw new AppAccountRefused("Enter the client ID, without spaces");
    if (!secret || secret.length > 2048 || /\s/.test(secret)) throw new AppAccountRefused("Enter the client secret, without spaces");
    const sealed = await seal(this.deps.secret, `apps-client\0${this.deps.accountId}`, { clientId: id, clientSecret: secret } satisfies OAuthClient);
    this.deps.sql.exec(`INSERT INTO app_clients (provider, client_id, secret_sealed, updated_at) VALUES (?, ?, ?, ?)
      ON CONFLICT (provider) DO UPDATE SET client_id = excluded.client_id, secret_sealed = excluded.secret_sealed, updated_at = excluded.updated_at`,
    definition.provider, id, sealed, this.now());
    return { provider: definition.provider };
  }

  /** Forgets the OAuth client of an app's provider. Signed-in accounts stay, but cannot sign in or renew until one is set up again. */
  removeClient(app: AppName): boolean {
    const definition = APP_DEFINITIONS[app];
    if (definition.signIn !== "oauth") return false;
    return this.deps.sql.exec("DELETE FROM app_clients WHERE provider = ?", definition.provider).rowsWritten > 0;
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
      identified = await unwrapped(definition.token.identify(this.api(definition, CHECK_TOOL, (request) => definition.token.authorize(credential.fields, request), named ?? ""), credential.fields));
    } catch (error) {
      if (error instanceof Unauthorized) throw new AppAccountRefused(`${definition.title} did not accept this token`);
      if (error instanceof ProviderError) throw new AppAccountRefused(`${definition.title} did not accept this token: ${error.message}`.slice(0, 300));
      throw error;
    }
    const account = (definition.token.named ? named : identified ?? named)?.toLowerCase();
    return this.storeToken(definition, account, credential);
  }

  /** Keeps a checked credential as the account's, replacing the one it had. */
  private async storeToken(definition: TokenApp, account: string | undefined, credential: TokenCredential): Promise<{ name: string; account: string }> {
    const app = definition.name;
    if (!account || account.length < 3) throw new AppAccountRefused("Name this account, such as \"personal\"");
    const known = this.rows(app).some((r) => r.account === account);
    if (!known && this.rows(app).length >= APP_ACCOUNTS_MAX) throw new AppAccountRefused(`${definition.title} holds at most ${APP_ACCOUNTS_MAX} accounts; remove one first.`);
    const replaced = known ? this.row(app, account) : null;
    this.deps.sql.exec(`INSERT INTO app_accounts (app, account, grant_sealed, grant_generation, last_error, created_at) VALUES (?, ?, ?, 1, NULL, ?)
      ON CONFLICT (app, account) DO UPDATE SET grant_sealed = excluded.grant_sealed, grant_generation = app_accounts.grant_generation + 1, last_error = NULL`,
    app, account, await this.seal(credential), this.now());
    // A credential a Mac sign-in made is undone at the service once it is replaced.
    if (replaced?.grant_sealed) this.revokeToken(definition, replaced.grant_sealed);
    return { name: `apps.${app}`, account };
  }

  /**
   * Starts a token app's sign-in on one of the account's Macs (TokenSignIn.mac): the Mac opens
   * the service's sign-in page and waits on its localhost redirect, and this Durable Object, which
   * keeps the PKCE verifier, redeems the code and checks the credential as a pasted one is. It
   * runs in the background; the web app polls `pollMacSignIn` with the returned flow.
   */
  async startMacSignIn(app: AppName, mac: string, preset: string, named: string | null): Promise<{ flow: string } & AppMacSignIn> {
    const definition = APP_DEFINITIONS[app];
    const signIn = definition.signIn === "token" ? definition.token.mac : undefined;
    if (definition.signIn !== "token" || !signIn) throw new AppAccountRefused(`${definition.title} does not sign in on a Mac`);
    if (!this.deps.signInOnMac || !this.macs().includes(mac)) throw new AppAccountRefused(`No Mac named ${mac} is paired with this account`);
    if (!signIn.presets.some((p) => p.id === preset)) throw new AppAccountRefused(`${definition.title} has no choice named ${preset}`);
    if (definition.token.named && !named) throw new AppAccountRefused("Name this account, such as \"personal\"");
    const running = this.deps.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM app_mac_sign_ins WHERE mac = ? AND state = 'pending' AND created_at >= ?",
      mac, this.now() - MAC_SIGN_IN_TIMEOUT_MS - 60_000).one().n;
    if (running > 0) throw new AppAccountRefused(`A sign-in is already waiting on ${mac}; finish it in the browser there, or wait for it to end.`);
    const id = crypto.randomUUID();
    this.deps.sql.exec("DELETE FROM app_mac_sign_ins WHERE created_at < ?", this.now() - 24 * 3600_000);
    this.deps.sql.exec("INSERT INTO app_mac_sign_ins (id, app, mac, state, created_at) VALUES (?, ?, ?, 'pending', ?)", id, app, mac, this.now());
    this.deps.waitUntil(this.runMacSignIn(id, definition, mac, preset, named));
    return { flow: id, state: "pending", mac, expiresAt: new Date(this.now() + MAC_SIGN_IN_TIMEOUT_MS).toISOString() };
  }

  /** A sign-in on a Mac, as the web app polls it. */
  pollMacSignIn(app: AppName, flowId: string): AppMacSignIn {
    const row = this.deps.sql.exec<{ mac: string; state: string; account: string | null; error: string | null; expires_at: number | null; created_at: number }>(
      "SELECT mac, state, account, error, expires_at, created_at FROM app_mac_sign_ins WHERE id = ? AND app = ?", flowId, app).toArray()[0];
    if (!row) return { state: "failed", error: "This sign-in has ended. Start again." };
    if (row.state === "done" && row.account) return { state: "done", account: row.account, expiresAt: row.expires_at ? new Date(row.expires_at).toISOString() : null };
    if (row.state === "failed") return { state: "failed", error: (row.error ?? "The sign-in failed.").slice(0, 512) };
    // A sign-in whose background work was lost (the Durable Object restarted) ends with its timeout.
    if (this.now() > row.created_at + MAC_SIGN_IN_TIMEOUT_MS + 60_000) return { state: "failed", error: "The sign-in was not finished in time. Start again." };
    return { state: "pending", mac: row.mac, expiresAt: new Date(row.created_at + MAC_SIGN_IN_TIMEOUT_MS).toISOString() };
  }

  private async runMacSignIn(id: string, definition: TokenApp, mac: string, preset: string, named: string | null): Promise<void> {
    const signIn = definition.token.mac!;
    const fail = (error: string) => {
      this.deps.sql.exec("UPDATE app_mac_sign_ins SET state = 'failed', error = ? WHERE id = ?", error.slice(0, 512), id);
    };
    try {
      const verifier = pkceVerifier();
      const state = randomState();
      const callback = await this.deps.signInOnMac!(mac, {
        authorizeUrl: signIn.authorizeUrl(preset, state, await pkceChallenge(verifier)),
        ports: signIn.ports,
        path: signIn.path,
        state,
        timeoutMs: MAC_SIGN_IN_TIMEOUT_MS,
      });
      if (!callback.code) {
        const declined = callback.error === "access_denied";
        return fail(declined ? `The sign-in was declined at ${definition.providerTitle}.` : `${definition.providerTitle} did not finish the sign-in: ${callback.errorDescription ?? callback.error ?? "no code came back"}`);
      }
      const done = await signIn.complete({ code: callback.code, state, redirectUri: callback.redirectUri, verifier, preset }, this.deps.fetcher, this.now());
      const credential: TokenCredential = { kind: "token", fields: done.fields, expiresAt: done.expiresAt, revocation: done.revocation };
      // Checked as a pasted credential is, with one read call.
      let identified: string | null;
      try {
        identified = await unwrapped(definition.token.identify(this.api(definition, CHECK_TOOL, (request) => definition.token.authorize(credential.fields, request), named ?? ""), credential.fields));
      } catch (error) {
        if (signIn.revoke) await signIn.revoke(done.revocation, done.fields, this.deps.fetcher, this.now()).catch(() => undefined);
        throw error instanceof Unauthorized ? new ProviderError(401, `${definition.providerTitle} did not accept the new key`) : error;
      }
      const account = (definition.token.named ? named : identified ?? named)?.toLowerCase();
      await this.storeToken(definition, account, credential);
      this.deps.sql.exec("UPDATE app_mac_sign_ins SET state = 'done', account = ?, expires_at = ? WHERE id = ?", account!, done.expiresAt, id);
    } catch (error) {
      fail(error instanceof Error ? error.message : String(error));
    }
  }

  /** Undoes a credential a Mac sign-in made, in the background; a pasted one only the person can delete. */
  private revokeToken(definition: TokenApp, sealed: string): void {
    const revoke = definition.token.mac?.revoke;
    if (!revoke) return;
    this.deps.waitUntil((async () => {
      const credential = await this.unsealToken(sealed);
      if (credential?.revocation !== undefined) await revoke(credential.revocation, credential.fields, this.deps.fetcher, this.now());
    })().catch(() => undefined));
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
    if (!this.isAvailable(definition)) throw new Error(definition.signIn === "oauth" ? notSetUp(definition) : `${definition.title} is not set up on this Axo deployment`);
    const parsed = inputOf(tool).safeParse(input ?? {});
    if (!parsed.success) throw new Error(invalidInput(inputOf(tool), parsed.error));
    const { account: named, ...rest } = parsed.data as { account: string } & Record<string, unknown>;
    if (definition.signIn === "mac") return this.callOnMac(definition, tool as AppTool<any, MacShell>, named, rest);
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
        return await runTool(definition, tool, this.api(definition, tool, () => ({ headers: authorization(grant) }), account), rest);
      } catch (error) {
        if (!(error instanceof Unauthorized)) throw error;
        if (attempt > 0) {
          this.dropGrant(app, account, this.row(app, account)?.grant_generation ?? 0, `${definition.title} refused the grant`);
          throw new Error(`${account} needs sign-in: ${definition.title} refused the grant`);
        }
      }
    }
  }

  /** A Mac app's call: the tool's commands run on the Mac its account names, and nowhere else. */
  private async callOnMac(definition: MacApp, tool: AppTool<any, MacShell>, mac: string, input: Record<string, unknown>): Promise<unknown> {
    const macs = this.macs();
    if (!macs.includes(mac)) throw new Error(`no Mac named ${mac.slice(0, 64)}; the account's Macs: ${macs.join(", ") || "none is paired"}`);
    const run = this.deps.runOnMac!;
    const shell: MacShell = {
      mac,
      run: (args, options = {}) => run(mac, macCommand(args, options.stdin), Math.min(options.timeoutMs ?? 60_000, MAX_REQUEST_TIMEOUT_MS)).catch((error: unknown) => {
        // A command that is safe to repeat and may have run is only a failed call.
        if (error instanceof ProviderOutcomeUnknown && tool.idempotent) throw new ProviderError(0, error.message);
        throw error;
      }),
    };
    return tool.run(shell, input);
  }

  /** A token app's call: a refused token is dropped, since only the person can issue a new one. */
  private async callWithToken(definition: TokenApp, tool: AppTool, account: string, input: Record<string, unknown>): Promise<unknown> {
    const row = this.row(definition.name, account);
    const credential = row?.grant_sealed ? await this.unsealToken(row.grant_sealed) : null;
    if (!row || !credential) throw new Error(`${account}'s token needs adding again at ${appPage(definition.name)}`);
    if (credential.expiresAt && credential.expiresAt <= this.now()) {
      throw new Error(`${account}'s ${definition.providerTitle} key expired on ${new Date(credential.expiresAt).toISOString().slice(0, 10)}; sign in again at ${appPage(definition.name)}`);
    }
    try {
      return await runTool(definition, tool, this.api(definition, tool, (request) => definition.token.authorize(credential.fields, request), account), input);
    } catch (error) {
      if (!(error instanceof Unauthorized)) throw error;
      this.dropGrant(definition.name, account, row.grant_generation, `${definition.title} refused the token`);
      throw new Error(`${account}: ${definition.title} refused the token; add a new one at ${appPage(definition.name)}`);
    }
  }

  /** The provider's API, with `authorize` putting the credential on every request. */
  private api(definition: OAuthApp | TokenApp | DeviceApp, tool: AppTool, authorize: (request: OutgoingRequest) => Authorized | Promise<Authorized>, account: string): ProviderApi {
    const fetcher = this.deps.fetcher;
    const refused = () => new ProviderError(0, `${definition.title} calls only reach ${definition.hosts.join(", ")}`);
    /**
     * One request with the credential on: only to the app's own hosts, never redirected, within
     * the timeout. A 401 is Unauthorized; a write that is not safe to repeat and got no answer
     * or a server error may have run. Any other answer is returned as it came.
     */
    const transmit = async (method: string, url: URL, headers: Record<string, string>, body: { contentType: string; data: string | Uint8Array<ArrayBuffer> } | undefined, timeout: number | AbortSignal | undefined): Promise<Response> => {
      // The grant goes only to the app's own API.
      if (!allowedUrl(definition, url)) throw refused();
      // Only a write that is not safe to repeat can leave its outcome unknown; a failed read ran nothing that matters.
      const risky = method !== "GET" && method !== "HEAD" && !tool.idempotent;
      const auth = await authorize({ method, url, body: body?.data, contentType: body?.contentType ?? null });
      // The credential's URL must still be the app's own; no header of a call's own may stand in for the credential's.
      const target = auth.url ?? url;
      if (!allowedUrl(definition, target)) throw refused();
      const authNames = new Set(Object.keys(auth.headers).map((name) => name.toLowerCase()));
      let response: Response;
      try {
        // Some APIs (GitHub's) refuse a request without a User-Agent, and Workers send none of their own.
        const sent = new Headers({ "User-Agent": "Axo (https://axo.leostera.dev)" });
        for (const [name, value] of Object.entries(headers)) {
          if (!authNames.has(name.toLowerCase()) && name.toLowerCase() !== "authorization") sent.set(name, value);
        }
        if (body) sent.set("Content-Type", body.contentType);
        for (const [name, value] of Object.entries(auth.headers)) sent.set(name, value);
        response = await fetcher(target, {
          method,
          headers: sent,
          body: auth.body ?? body?.data,
          redirect: "manual",
          // An SDK's own signal (grammY's long poll) is followed, never past the longest a call may take.
          signal: timeout instanceof AbortSignal
            ? AbortSignal.any([timeout, AbortSignal.timeout(MAX_REQUEST_TIMEOUT_MS)])
            : AbortSignal.timeout(Math.min(timeout ?? REQUEST_TIMEOUT_MS, MAX_REQUEST_TIMEOUT_MS)),
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
      return response;
    };
    const send = async (method: string, path: string, options: ProviderRequest = {}): Promise<Response> => {
      let url: URL;
      try {
        url = new URL(path, definition.apiOrigin);
      } catch {
        throw new ProviderError(0, `not a URL: ${path.slice(0, 100)}`);
      }
      for (const [key, value] of Object.entries(options.query ?? {})) {
        if (value === undefined) continue;
        for (const item of Array.isArray(value) ? value : [value]) url.searchParams.append(key, item);
      }
      const body = options.raw ?? (options.body === undefined ? undefined : { contentType: "application/json", data: JSON.stringify(options.body) });
      const response = await transmit(method, url, { ...options.headers, Accept: options.accept ?? "application/json" }, body, options.timeoutMs);
      if (!response.ok) {
        const text = await response.text();
        throw new ProviderError(response.status, `${definition.title}: ${providerMessage(text) ?? `HTTP ${response.status}`}`);
      }
      return definition.answerError ? checkAnswer(definition, response) : response;
    };
    const sdkFetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      const headers = Object.fromEntries([...request.headers].filter(([name]) => name !== "content-type" && name !== "content-length"));
      const contentType = request.headers.get("Content-Type");
      const bytes = request.body ? new Uint8Array(await request.arrayBuffer()) : null;
      // A text body stays text, so a credential that signs it (Kraken's) reads what is sent.
      const textual = contentType !== null && /json|text|x-www-form-urlencoded/i.test(contentType);
      const body = bytes ? { contentType: contentType ?? "application/octet-stream", data: textual ? new TextDecoder().decode(bytes) : bytes } : undefined;
      return transmit(request.method.toUpperCase(), new URL(request.url), headers, body, init?.signal ?? undefined);
    }) as typeof fetch;
    return {
      account,
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
      fetch: sdkFetch,
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
    const client = isOpenAI(grant) ? null : await this.client(providerOf(grant));
    if (!grant.refreshToken || (!client && !isOpenAI(grant))) {
      this.dropGrant(app, account, row.grant_generation, "the grant expired and cannot be renewed");
      return null;
    }
    const generation = row.grant_generation;
    const key = `${app}\0${account}#${generation}`;
    const running = this.refreshing.get(key);
    if (running) return running;
    const provider = isOpenAI(grant) ? null : OAUTH_PROVIDER_CONFIGS[providerOf(grant)];
    const title = provider?.title ?? "OpenAI";
    // OpenAI rotates refresh tokens, as do some providers: a renewal that got no answer may have
    // spent the only one, so the grant is dropped and the person signs in again. One that does
    // not rotate them keeps the grant.
    const rotates = provider?.rotatesRefreshTokens ?? true;
    const attempt = (async () => {
      try {
        const renewed = isOpenAI(grant)
          ? await refreshOpenAIGrant(grant, this.deps.fetcher, this.now())
          : await refreshGrant(provider!, client!, grant, this.deps.fetcher, this.now());
        const landed = this.deps.sql.exec("UPDATE app_accounts SET grant_sealed = ? WHERE app = ? AND account = ? AND grant_generation = ?",
          await this.seal(renewed), app, account, generation).rowsWritten > 0;
        return landed ? renewed : null;
      } catch (error) {
        if (error instanceof GrantRefused) this.dropGrant(app, account, generation, provider ? `${title} refused to renew the grant` : "OpenAI refused to renew the sign-in");
        else if (rotates) this.dropGrant(app, account, generation, "renewing the sign-in got no answer");
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
    return APPS.filter((app) => this.isAvailable(APP_DEFINITIONS[app]));
  }

  /** A Mac app needs a way to reach the Macs; every other app is listed. */
  private isListed(definition: AppDefinition): boolean {
    return definition.signIn !== "mac" || Boolean(this.deps.runOnMac && this.deps.macs);
  }

  /** Whether an app can be used: listed, and for an OAuth app, its provider's client set up. */
  private isAvailable(definition: AppDefinition): boolean {
    return this.isListed(definition) && (definition.signIn !== "oauth" || this.hasClient(definition.provider));
  }

  /** Whether a provider has a client: one the person set up, or Google's from the Worker's environment. */
  private hasClient(provider: OAuthProviderName): boolean {
    if (provider === "google" && this.deps.legacyGoogle) return true;
    return this.deps.sql.exec("SELECT 1 FROM app_clients WHERE provider = ?", provider).toArray().length > 0;
  }

  private macs(): string[] {
    return this.deps.macs?.() ?? [];
  }

  /** A provider's client, unsealed; the person's own comes before Google's from the environment. */
  private async client(provider: OAuthProviderName): Promise<OAuthClient | null> {
    const row = this.deps.sql.exec<{ secret_sealed: string }>("SELECT secret_sealed FROM app_clients WHERE provider = ?", provider).toArray()[0];
    if (row) return (await unseal(this.deps.secret, `apps-client\0${this.deps.accountId}`, row.secret_sealed)) as OAuthClient | null;
    return provider === "google" ? this.deps.legacyGoogle ?? null : null;
  }

  /** How the web app's Add account works for an app; an OAuth app's says whether its client is set up, and how to register one. */
  private signInOf(definition: AppDefinition): AppSignIn {
    if (definition.signIn !== "oauth") return signInOf(definition);
    const provider = OAUTH_PROVIDER_CONFIGS[definition.provider];
    return { kind: "oauth", client: { provider: provider.name, ready: this.hasClient(provider.name), consoleUrl: provider.consoleUrl, redirectUri: CALLBACK_URL } };
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
    const value = (await unseal(this.deps.secret, `apps-grant\0${this.deps.accountId}`, sealed, 65_536)) as (OAuthGrant & { kind?: undefined }) | OpenAIGrant | TokenCredential | null;
    return value && value.kind !== "token" ? value : null;
  }

  private async unsealToken(sealed: string): Promise<TokenCredential | null> {
    const value = (await unseal(this.deps.secret, `apps-grant\0${this.deps.accountId}`, sealed, 65_536)) as TokenCredential | { kind?: undefined } | null;
    return value?.kind === "token" ? value : null;
  }
}

/** The call that checks a token before it is stored: a read, so a lost answer ran nothing. */
/**
 * Runs a tool. An SDK wraps what its fetch threw in its own error (Octokit's `cause`, grammY's
 * `error`), so the gateway's own (Unauthorized, may-have-run, refused) is found inside it again;
 * an SDK's error for an HTTP answer becomes a ProviderError naming the app.
 */
async function runTool(definition: AppDefinition, tool: AppTool, api: ProviderApi, input: Record<string, unknown>): Promise<unknown> {
  try {
    return await tool.run(api, input);
  } catch (error) {
    const own = ownError(error);
    if (own) throw own;
    // An SDK's error for an answer it read (Octokit's RequestError) says what the service said.
    // Octokit's `status`, grammY's `error_code`.
    const status = (error as { status?: unknown } | null)?.status ?? (error as { error_code?: unknown } | null)?.error_code;
    if (error instanceof Error && typeof status === "number" && status >= 400) {
      throw new ProviderError(status, `${definition.title}: ${error.message.replace(/ - https:\/\/docs\.github\.com\S*$/, "").slice(0, 300)}`);
    }
    throw error;
  }
}

/** An account check's outcome, with the gateway's own error found inside an SDK's (see runTool). */
async function unwrapped<T>(promise: Promise<T>): Promise<T> {
  try {
    return await promise;
  } catch (error) {
    throw ownError(error) ?? error;
  }
}

function ownError(error: unknown): Error | null {
  let current: unknown = error;
  for (let depth = 0; depth < 5 && current && typeof current === "object"; depth++) {
    if (current instanceof Unauthorized || current instanceof ProviderOutcomeUnknown || current instanceof ProviderError) return current;
    const next = (current as { cause?: unknown; error?: unknown }).cause ?? (current as { error?: unknown }).error;
    if (next === current) break;
    current = next;
  }
  return null;
}

const CHECK_TOOL: AppTool = { name: "add_account", description: "", input: z.object({}), idempotent: true, run: async () => null };

function isOpenAI(grant: Grant): grant is OpenAIGrant {
  return (grant as { kind?: string }).kind === "openai";
}

/** An OAuth grant's provider; one sealed before there were others is Google's. */
function providerOf(grant: OAuthGrant): OAuthProviderName {
  return grant.provider ?? "google";
}

/** Whether a grant is one this app can use: its provider's, holding every scope the app needs. */
function grantFits(definition: OAuthApp | DeviceApp, grant: Grant): boolean {
  if (definition.signIn === "device") return isOpenAI(grant);
  return !isOpenAI(grant) && providerOf(grant) === definition.provider && definition.requiredScopes.every((scope) => grant.scopes.includes(scope));
}

/** The headers that carry a grant. ChatGPT also needs the ChatGPT account (workspace) it acts in. */
function authorization(grant: Grant): Record<string, string> {
  if (!isOpenAI(grant)) return { Authorization: `Bearer ${grant.accessToken}` };
  return { Authorization: `Bearer ${grant.accessToken}`, "chatgpt-account-id": grant.chatgptAccountId ?? "", originator: "axo" };
}

/**
 * An answer of a service that reports errors with HTTP 200 (HttpApp.answerError): read once and
 * checked, then handed on as it came.
 */
async function checkAnswer(definition: OAuthApp | TokenApp | DeviceApp, response: Response): Promise<Response> {
  if (!/[/+]json\b/i.test(response.headers.get("Content-Type") ?? "")) return response;
  const text = await response.text();
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  const error = json === undefined ? null : definition.answerError!(json);
  if (error?.unauthorized) throw new Unauthorized();
  if (error) throw new ProviderError(error.status, `${definition.title}: ${error.message}`.slice(0, 300));
  return new Response(text, { status: response.status, headers: response.headers });
}

/** What a call to an OAuth app whose provider has no client yet says. */
function notSetUp(definition: OAuthApp): string {
  return `${definition.title} is not set up yet: the person enters ${OAUTH_PROVIDER_CONFIGS[definition.provider].title}'s OAuth client at ${appPage(definition.name)}`;
}

/** How the web app's Add account works for a token, device or Mac app. */
function signInOf(definition: Exclude<AppDefinition, OAuthApp>): AppSignIn {
  if (definition.signIn === "device") return { kind: "device" };
  if (definition.signIn === "mac") return { kind: "mac", setup: definition.setup, helpUrl: definition.reference };
  const { helpUrl, named, fields, mac } = definition.token;
  return {
    kind: "token", helpUrl, named, fields: fields.map((f) => ({ ...f })),
    ...(mac ? { mac: { title: mac.title, presets: mac.presets.map((p) => ({ ...p })) } } : {}),
  };
}

/** A tool's input as scripts see it: `account` first, then the tool's own fields. */
/**
 * Why a tool refused its input, put so an agent can fix the call without looking the tool up:
 * the closest input to a name it does not take, and every input it takes (`?` when optional).
 */
function invalidInput(schema: z.ZodObject, error: z.ZodError): string {
  const inputs = Object.entries(schema.shape).map(([name, field]) => ((field as z.ZodType).safeParse(undefined).success ? `${name}?` : name));
  const names = Object.keys(schema.shape);
  const unknown = error.issues.flatMap((issue) => (issue.code === "unrecognized_keys" ? issue.keys : []));
  const hints = unknown.map((key) => {
    const near = closestName(key, names);
    return near ? `${JSON.stringify(key)} is not an input: did you mean ${JSON.stringify(near)}?` : `${JSON.stringify(key)} is not an input.`;
  });
  return [`invalid input: ${hints.join(" ")}`.trimEnd(), `It takes { ${inputs.join(", ")} }.`, z.prettifyError(error)].join(" ").replace(/: It takes/, ": it takes").slice(0, 1024);
}

/** The name `key` most likely meant: one that contains it or that it contains, else one a couple of edits away. */
function closestName(key: string, names: string[]): string | null {
  const plain = (name: string) => name.toLowerCase().replace(/[_-]/g, "");
  const k = plain(key);
  const containing = names.filter((name) => plain(name).includes(k) || (k.length > 2 && k.includes(plain(name))));
  if (containing.length === 1) return containing[0]!;
  const near = names.map((name) => ({ name, d: editDistance(k, plain(name)) })).filter((x) => x.d <= Math.max(1, Math.floor(k.length / 3))).sort((a, b) => a.d - b.d);
  return near[0]?.name ?? (containing[0] ?? null);
}

function editDistance(a: string, b: string): number {
  const row = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let diagonal = row[0]!;
    row[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const above = row[j]!;
      row[j] = Math.min(row[j]! + 1, row[j - 1]! + 1, diagonal + (a[i - 1] === b[j - 1] ? 0 : 1));
      diagonal = above;
    }
  }
  return row[b.length]!;
}

function inputOf(tool: AppTool): z.ZodObject {
  return z.object({ account: accountInput }).extend(tool.input.shape).strict();
}

/**
 * A service's error answer as one short line: Google's `{ error: { message } }`, and the common
 * others (`{ message }`, `{ description }` as Telegram's, `{ error: "..." }`, `{ detail }`).
 */
/** What an API said when it refused a call: its JSON error's message, or the start of its text. */
function providerMessage(text: string): string | null {
  const plain = () => {
    const words = text.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
    return words ? words.slice(0, 300) : null;
  };
  try {
    const answer = JSON.parse(text) as { error?: unknown; message?: unknown; description?: unknown; detail?: unknown; errors?: unknown };
    const nested = typeof answer.error === "object" && answer.error ? (answer.error as { message?: unknown }).message : undefined;
    const first = Array.isArray(answer.errors) ? (answer.errors[0] as { message?: unknown } | string | undefined) : undefined;
    const message = [nested, answer.message, answer.description, typeof answer.error === "string" ? answer.error : undefined, answer.detail, typeof first === "string" ? first : first?.message]
      .find((m): m is string => typeof m === "string" && m.length > 0);
    return message ? message.replace(/\s+/g, " ").slice(0, 300) : plain();
  } catch {
    return plain();
  }
}

