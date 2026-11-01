import type { Connection, ToolDefinition } from "@axo/protocol";
import { seal, unseal } from "../auth/crypto";
import { callTool, initialize, listTools, McpAuthRequired, McpError, toolOutput, type McpSession } from "./mcp-client";

/** How a tool's "401" is recorded as the connection's last error; a working call clears it. */
const REFUSED_UPSTREAM = "its tools answered Unauthorized";
const SERVERS_PAGE = "https://axo.leostera.dev/app/settings/apps/mcp";
import { findSiteIcon } from "./site-icon";
import {
  authorizationUrl,
  discover,
  GrantRefused,
  pkce,
  redeemCode,
  refresh,
  register,
  type Client,
  type Discovery,
  type Grant,
} from "./oauth";

/**
 * The account's third-party connections (RFD0016): remote MCP servers it calls from the cloud
 * with grants that never leave this Durable Object.
 *
 * Grants carry a generation that goes up with every completed sign-in, and a refresh only lands
 * on the generation it renewed (specs/connection-sign-in.ts). Tool lists are cached; at most one
 * refresh per connection runs, and a change heard meanwhile queues exactly one more
 * (specs/tool-lists.ts). Searches never wait on a server.
 */

/** A tool list older than this is refreshed in the background when a search reads it. */
export const TOOLS_MAX_AGE_MS = 60 * 60 * 1000;
/** A sign-in link works for this long, once. */
export const FLOW_LIFETIME_MS = 10 * 60 * 1000;
/** An access token this close to expiring is renewed before use. */
const EXPIRY_MARGIN_MS = 60_000;

type Row = {
  name: string;
  url: string;
  created_at: number;
  discovery_json: string | null;
  client_sealed: string | null;
  grant_sealed: string | null;
  grant_generation: number;
  tools_json: string;
  synced_at: number | null;
  last_error: string | null;
  needs_sign_in: number;
  icon_url: string | null;
  title: string | null;
  icon_checked_at: number | null;
};

const ICON_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** Where to send a browser that opened a sign-in link, and for which connection. */
export type OpenedFlow = { authorizeUrl: string; name: string };

type StoredTool = { name: string; upstream: string; title: string; description: string; inputSchema: Record<string, unknown> };

export type ThirdPartyDeps = {
  sql: SqlStorage;
  secret: string;
  accountId: string;
  fetcher: typeof fetch;
  /** Keeps background work (tool-list refreshes) alive after the call that started it. */
  waitUntil(promise: Promise<unknown>): void;
  now?: () => number;
};

export class ThirdPartyConnections {
  /** Per connection: the refresh in flight, and whether a change was heard during it. */
  private readonly syncing = new Map<string, { running: Promise<void>; again: boolean }>();
  private readonly refreshing = new Map<string, Promise<Grant | null>>();
  private readonly sessions = new Map<string, McpSession>();

  constructor(private readonly deps: ThirdPartyDeps) {
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS third_party_connections (
      name TEXT PRIMARY KEY, url TEXT NOT NULL, created_at REAL NOT NULL, discovery_json TEXT,
      client_sealed TEXT, grant_sealed TEXT, grant_generation INTEGER NOT NULL DEFAULT 0,
      tools_json TEXT NOT NULL DEFAULT '[]', synced_at REAL, last_error TEXT,
      needs_sign_in INTEGER NOT NULL DEFAULT 0)`);
    // A server's icon, for its tile: looked up once a week, when its tools are.
    // The name the person typed, as typed (`name` is its slug); null for connections from before.
    for (const column of ["icon_url TEXT", "icon_checked_at REAL", "title TEXT"]) {
      try {
        deps.sql.exec(`ALTER TABLE third_party_connections ADD COLUMN ${column}`);
      } catch {
        // Already there.
      }
    }
    deps.sql.exec(`CREATE TABLE IF NOT EXISTS connection_flows (
      nonce TEXT PRIMARY KEY, name TEXT NOT NULL, verifier TEXT NOT NULL, created_at REAL NOT NULL,
      opened INTEGER NOT NULL DEFAULT 0, redeemed INTEGER NOT NULL DEFAULT 0)`);
  }

  private now(): number {
    return this.deps.now?.() ?? Date.now();
  }

  private key(name: string): string {
    return `${this.deps.accountId}:${name}`;
  }

  names(): string[] {
    return this.deps.sql.exec<{ name: string }>("SELECT name FROM third_party_connections ORDER BY created_at, name").toArray().map((r) => r.name);
  }

  has(name: string): boolean {
    return this.row(name) !== undefined;
  }

  list(): Connection[] {
    return this.rows().map((row) => ({
      kind: "thirdParty",
      name: row.name,
      title: row.title ?? null,
      url: row.url,
      state: row.needs_sign_in ? "needsSignIn" : row.last_error && row.synced_at === null ? "error" : "ready",
      tools: this.storedTools(row).length,
      icon: row.icon_url ?? null,
      syncedAt: row.synced_at === null ? null : new Date(row.synced_at).toISOString(),
      lastError: row.last_error,
    }));
  }

  /** Every cached tool. A list older than an hour is refreshed behind the search, not before it. */
  tools(): ToolDefinition[] {
    const tools: ToolDefinition[] = [];
    for (const row of this.rows()) {
      if (!row.needs_sign_in && (row.synced_at === null || this.now() - row.synced_at > TOOLS_MAX_AGE_MS)) this.requestSync(row.name);
      for (const tool of this.storedTools(row))
        tools.push({ service: row.name, name: tool.name, title: tool.title, description: tool.description, inputSchema: tool.inputSchema, call: `codemode.${row.name}.${tool.name}` });
    }
    return tools;
  }

  /**
   * Adds a connection and tries it without a grant. A server that needs sign-in gets a client
   * (registered, or to be entered on the Connections page) and a sign-in link.
   */
  async add(name: string, url: string, title: string | null = null): Promise<{ signInUrl: string | null }> {
    this.deps.sql.exec("INSERT INTO third_party_connections (name, url, created_at, title) VALUES (?, ?, ?, ?)", name, url, this.now(), title);
    try {
      await this.sync(name);
      return { signInUrl: null };
    } catch (error) {
      if (!(error instanceof McpAuthRequired)) {
        this.setError(name, error);
        return { signInUrl: null };
      }
      return { signInUrl: await this.prepareSignIn(name, error.wwwAuthenticate) };
    }
  }

  remove(name: string): boolean {
    const removed = this.deps.sql.exec("DELETE FROM third_party_connections WHERE name = ?", name).rowsWritten > 0;
    this.deps.sql.exec("DELETE FROM connection_flows WHERE name = ?", name);
    this.sessions.delete(this.key(name));
    return removed;
  }

  /** A client the person registered with the provider themselves, entered on the Connections page. */
  async setClient(name: string, client: Client): Promise<{ signInUrl: string }> {
    if (!this.has(name)) throw new Error(`no connection named ${name}`);
    this.deps.sql.exec("UPDATE third_party_connections SET client_sealed = ? WHERE name = ?", await this.seal("client", client), name);
    return { signInUrl: await this.prepareSignIn(name, null) };
  }

  /** A fresh sign-in link for a connection, for example after its grant was dropped. */
  async signInLink(name: string): Promise<string> {
    if (!this.has(name)) throw new Error(`no connection named ${name}`);
    return this.prepareSignIn(name, null);
  }

  private async prepareSignIn(name: string, wwwAuthenticate: string | null): Promise<string> {
    const row = this.row(name)!;
    let discovery = row.discovery_json ? (JSON.parse(row.discovery_json) as Discovery) : null;
    if (!discovery) {
      discovery = await discover(row.url, wwwAuthenticate, this.deps.fetcher);
      this.deps.sql.exec("UPDATE third_party_connections SET discovery_json = ? WHERE name = ?", JSON.stringify(discovery), name);
    }
    if (!row.client_sealed && discovery.registrationEndpoint) {
      const client = await register(discovery, this.deps.fetcher);
      this.deps.sql.exec("UPDATE third_party_connections SET client_sealed = ? WHERE name = ?", await this.seal("client", client), name);
    }
    this.deps.sql.exec("UPDATE third_party_connections SET needs_sign_in = 1 WHERE name = ?", name);
    if (!this.row(name)!.client_sealed) {
      this.setError(name, new Error("the server does not register clients itself; enter a client ID on the Connections page"));
      return startUrl(null);
    }
    const nonce = crypto.randomUUID();
    const { verifier } = await pkce();
    this.deps.sql.exec("DELETE FROM connection_flows WHERE created_at < ?", this.now() - FLOW_LIFETIME_MS);
    this.deps.sql.exec("INSERT INTO connection_flows (nonce, name, verifier, created_at) VALUES (?, ?, ?, ?)", nonce, name, verifier, this.now());
    return startUrl(nonce);
  }

  /**
   * The browser opened a sign-in link: returns where to send it, once. The PKCE verifier stays
   * here; only its challenge leaves.
   */
  async openFlow(nonce: string): Promise<OpenedFlow | null> {
    const flow = this.flow(nonce);
    if (!flow || flow.opened) return null;
    this.deps.sql.exec("UPDATE connection_flows SET opened = 1 WHERE nonce = ?", nonce);
    const row = this.row(flow.name);
    const client = row?.client_sealed ? await this.unseal<Client>("client", row.client_sealed) : null;
    if (!row?.discovery_json || !client) return null;
    const challenge = await challengeOf(flow.verifier);
    const state = await seal(this.deps.secret, "connections-oauth-state", { accountId: this.deps.accountId, nonce });
    return { authorizeUrl: authorizationUrl(JSON.parse(row.discovery_json) as Discovery, client, challenge, state), name: flow.name };
  }

  /** The provider sent the browser back with a code: redeems it once and stores a new generation. */
  async completeFlow(nonce: string, code: string): Promise<{ name: string } | { error: string }> {
    const flow = this.flow(nonce);
    if (!flow || !flow.opened || flow.redeemed) return { error: "this sign-in link was already used or has expired" };
    this.deps.sql.exec("UPDATE connection_flows SET redeemed = 1 WHERE nonce = ?", nonce);
    const row = this.row(flow.name);
    const client = row?.client_sealed ? await this.unseal<Client>("client", row.client_sealed) : null;
    if (!row?.discovery_json || !client) return { error: "the connection was removed" };
    let grant: Grant;
    try {
      grant = await redeemCode(JSON.parse(row.discovery_json) as Discovery, client, code, flow.verifier, this.deps.fetcher, this.now());
    } catch (error) {
      this.setError(flow.name, error);
      return { error: "the provider did not accept the sign-in" };
    }
    this.deps.sql.exec(`UPDATE third_party_connections SET grant_sealed = ?, grant_generation = grant_generation + 1,
      needs_sign_in = 0, last_error = NULL WHERE name = ?`, await this.seal("grant", grant), flow.name);
    this.sessions.delete(this.key(flow.name));
    this.requestSync(flow.name);
    return { name: flow.name };
  }

  /** Calls a tool with the account's grant. A 401 renews the grant once; the call is then sent again, since it did not run. */
  async call(name: string, tool: string, input: unknown): Promise<unknown> {
    const row = this.row(name);
    if (!row) throw new Error(`no connection named ${name}`);
    if (row.needs_sign_in) throw new Error(`${name} needs sign-in; open the Connections page or ask for a new link with connections_add`);
    const stored = this.storedTools(row).find((t) => t.name === tool);
    if (!stored) throw new Error(`${name} has no tool named ${tool}`);
    for (let attempt = 0; ; attempt++) {
      try {
        const session = await this.session(name, attempt > 0);
        const result = await callTool(session, stored.upstream, input, this.deps.fetcher);
        try {
          const output = toolOutput(result);
          if (row.last_error?.startsWith(REFUSED_UPSTREAM)) this.deps.sql.exec("UPDATE third_party_connections SET last_error = NULL WHERE name = ? AND last_error = ?", name, row.last_error);
          return output;
        } catch (failed) {
          throw this.refusedUpstream(name, failed);
        }
      } catch (error) {
        const unauthorized = error instanceof McpAuthRequired;
        const sessionLost = error instanceof McpError && /HTTP 404/.test(error.message);
        if (attempt > 0 || !(unauthorized || sessionLost)) {
          if (unauthorized) this.dropGrant(name, row.grant_generation, "the server refused the grant");
          throw error;
        }
        if (unauthorized && !(await this.renew(name, true))) throw new Error(`${name} needs sign-in`);
      }
    }
  }

  /** Asks for a tool-list refresh: one runs at a time, and one more is queued if asked meanwhile. */
  requestSync(name: string): void {
    const key = this.key(name);
    const current = this.syncing.get(key);
    if (current) return void (current.again = true);
    const entry = { running: Promise.resolve(), again: false };
    entry.running = (async () => {
      do {
        entry.again = false;
        await this.sync(name).catch((error) => {
          if (error instanceof McpAuthRequired) this.dropGrant(name, this.row(name)?.grant_generation ?? 0, "the server asks for sign-in again");
          else this.setError(name, error);
        });
      } while (entry.again);
      this.syncing.delete(key);
    })();
    this.syncing.set(key, entry);
    this.deps.waitUntil(entry.running);
  }

  /** Waits for a refresh in flight, if any. For tests and the Connections page. */
  async settled(name: string): Promise<void> {
    await this.syncing.get(this.key(name))?.running;
  }

  private async sync(name: string): Promise<void> {
    const session = await this.session(name, true);
    const upstream = await listTools(session, this.deps.fetcher);
    const taken = new Set<string>();
    const tools: StoredTool[] = upstream.map((tool) => {
      const base = identifier(tool.name);
      let safe = base;
      for (let n = 2; taken.has(safe); n++) safe = `${base}_${n}`;
      taken.add(safe);
      return {
        name: safe,
        upstream: tool.name,
        title: (tool.title ?? tool.name).slice(0, 256),
        description: (tool.description ?? "").slice(0, 16_384),
        inputSchema: tool.inputSchema && typeof tool.inputSchema === "object" ? tool.inputSchema : { type: "object" },
      };
    });
    this.deps.sql.exec("UPDATE third_party_connections SET tools_json = ?, synced_at = ?, last_error = NULL WHERE name = ?", JSON.stringify(tools), this.now(), name);
    const row = this.row(name);
    if (row && (row.icon_checked_at === null || row.icon_checked_at === undefined || this.now() - row.icon_checked_at > ICON_TTL_MS)) {
      this.deps.sql.exec("UPDATE third_party_connections SET icon_checked_at = ? WHERE name = ?", this.now(), name);
      this.deps.waitUntil(findSiteIcon(row.url, session.icons ?? [], this.deps.fetcher)
        .then((icon) => { this.deps.sql.exec("UPDATE third_party_connections SET icon_url = ? WHERE name = ? AND url = ?", icon, name, row.url); })
        .catch(() => undefined));
    }
  }

  private async session(name: string, fresh: boolean): Promise<McpSession> {
    const key = this.key(name);
    const row = this.row(name)!;
    // Checked on every use: a cached session must not outlive its access token.
    const grant = await this.renew(name, false);
    const cached = this.sessions.get(key);
    if (cached && !fresh && cached.token === (grant?.accessToken ?? null)) return cached;
    const session = await initialize(row.url, grant?.accessToken ?? null, this.deps.fetcher);
    this.sessions.set(key, session);
    return session;
  }

  /**
   * The current grant, renewed first if it is about to expire or `force`. One renewal runs per
   * connection; it names the generation it renews, and lands only if that is still current.
   */
  private async renew(name: string, force: boolean): Promise<Grant | null> {
    const row = this.row(name);
    if (!row?.grant_sealed) return null;
    const grant = await this.unseal<Grant>("grant", row.grant_sealed);
    if (!grant) return null;
    const due = force || (grant.expiresAt !== null && grant.expiresAt - this.now() < EXPIRY_MARGIN_MS);
    if (!due) return grant;
    if (!grant.refreshToken || !row.discovery_json || !row.client_sealed) {
      this.dropGrant(name, row.grant_generation, "the grant expired and cannot be renewed");
      return null;
    }
    const key = `${this.key(name)}#${row.grant_generation}`;
    const running = this.refreshing.get(key);
    if (running) return running;
    const generation = row.grant_generation;
    const attempt = (async () => {
      const client = await this.unseal<Client>("client", row.client_sealed!);
      try {
        const renewed = await refresh(JSON.parse(row.discovery_json!) as Discovery, client!, grant.refreshToken!, this.deps.fetcher, this.now());
        const sealed = await this.seal("grant", renewed);
        const landed = this.deps.sql.exec("UPDATE third_party_connections SET grant_sealed = ? WHERE name = ? AND grant_generation = ?", sealed, name, generation).rowsWritten > 0;
        return landed ? renewed : null;
      } catch (error) {
        // Refused, or no answer: a rotated refresh token may already be spent, so the grant goes.
        this.dropGrant(name, generation, error instanceof GrantRefused ? "the provider refused to renew the grant" : "renewing the grant got no answer");
        return null;
      } finally {
        this.refreshing.delete(key);
      }
    })();
    this.refreshing.set(key, attempt);
    return attempt;
  }

  /** Drops the grant of `generation`; a newer sign-in is left alone. */
  private dropGrant(name: string, generation: number, reason: string): void {
    this.deps.sql.exec(`UPDATE third_party_connections SET grant_sealed = NULL, needs_sign_in = 1, last_error = ?
      WHERE name = ? AND grant_generation = ?`, reason, name, generation);
    this.sessions.delete(this.key(name));
  }

  /**
   * A tool that answers "401 Unauthorized" as its own error: the server took the grant, but the
   * service behind it did not (PayPal's server, once its sign-in with PayPal lapsed). Axo cannot
   * renew that, so the connection says so on its page and in connections_list, and the agent is
   * told what the person can do; the next call that works clears it.
   */
  private refusedUpstream(name: string, failed: unknown): unknown {
    const message = failed instanceof Error ? failed.message : String(failed);
    if (!/\b401\b|\bunauthori[sz]ed\b|\binvalid[_ ]token\b|\btoken (has )?expired\b/i.test(message)) return failed;
    const note = `${REFUSED_UPSTREAM}: ${message.replace(/\s+/g, " ").slice(0, 200)}`;
    this.deps.sql.exec("UPDATE third_party_connections SET last_error = ? WHERE name = ?", note, name);
    return new Error(`${message.slice(0, 3000)}\n(${name} refused this account. If its other tools say the same, the person signs in to ${name} again: remove it at ${SERVERS_PAGE} and add it back, or connections_remove then connections_add.)`);
  }

  private setError(name: string, error: unknown): void {
    const message = (error instanceof Error ? error.message : String(error)).slice(0, 512);
    this.deps.sql.exec("UPDATE third_party_connections SET last_error = ? WHERE name = ?", message, name);
  }

  private storedTools(row: Row): StoredTool[] {
    try {
      return JSON.parse(row.tools_json) as StoredTool[];
    } catch {
      return [];
    }
  }

  private rows(): Row[] {
    return this.deps.sql.exec<Row>("SELECT * FROM third_party_connections ORDER BY created_at, name").toArray();
  }

  private row(name: string): Row | undefined {
    return this.deps.sql.exec<Row>("SELECT * FROM third_party_connections WHERE name = ?", name).toArray()[0];
  }

  private flow(nonce: string) {
    return this.deps.sql.exec<{ name: string; verifier: string; created_at: number; opened: number; redeemed: number }>(
      "SELECT * FROM connection_flows WHERE nonce = ? AND created_at >= ?", nonce, this.now() - FLOW_LIFETIME_MS,
    ).toArray()[0];
  }

  private seal(kind: "client" | "grant", value: unknown): Promise<string> {
    return seal(this.deps.secret, `connections-${kind}\0${this.deps.accountId}`, value);
  }

  private async unseal<T>(kind: "client" | "grant", sealed: string): Promise<T | null> {
    return (await unseal(this.deps.secret, `connections-${kind}\0${this.deps.accountId}`, sealed, 65_536)) as T | null;
  }
}

/** Where a person starts signing in: Axo's own page, which checks they are signed in to the account. */
export function startUrl(nonce: string | null): string {
  return nonce ? `https://axo.leostera.dev/api/v1/connections/oauth/start?flow=${nonce}` : "https://axo.leostera.dev/app/settings/apps/mcp";
}

/** An upstream tool name as a JavaScript-safe identifier. */
export function identifier(name: string): string {
  const safe = name.replace(/[^A-Za-z0-9_]/g, "_").slice(0, 64) || "tool";
  return /^[0-9]/.test(safe) ? `_${safe}`.slice(0, 64) : safe;
}

async function challengeOf(verifier: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  let text = "";
  for (const byte of digest) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
