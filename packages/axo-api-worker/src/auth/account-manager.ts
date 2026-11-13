import { DurableObject } from "cloudflare:workers";
import { LIMITS, type ClientHost } from "@axo/protocol";
import { hostModelSchema, hostRegisterSchema, hostSnapshotSchema, type HostModel, type HostSnapshot } from "@axo/protocol/v1";
import { constantTimeEqual, hmac } from "./crypto";
import { hostDOName } from "../host-do";
import { AccountApps, type CallOutcome, type AppsCall } from "../apps/account";
import type { DeviceSignIn } from "../apps/builtin";
import { googleClient } from "../apps/builtin/google";
import type { AppLink, AppLinkRequest, AppMacSignIn, AppPhoneSignIn, AppPhoneSignInRequest, CallRecord, AccountApp } from "@axo/protocol";
import type { LinkedDevice } from "@axo/apps";
import type { ChainCheck } from "../apps/call-log";

import type { AccountProfile } from "./account-access";
type PairingRow = {
  pairing_id: string;
  code_verifier: string;
  expires_at: number;
  consumed_host_id: string | null;
  consumed_host_generation: string | null;
  consumed_credential_id: string | null;
  consumed_credential_verifier: string | null;
};
type AccountHostRow = {
  host_id: string;
  host_generation: string;
  credential_id: string;
  credential_verifier: string;
  /** What the Mac reports, on every connect. */
  label: string;
  /** What a person named it; shown instead of `label` when set. */
  name: string | null;
  host_kind: string;
  /** What kind of Mac it reports itself to be (`HostModel`), as JSON; null until it says. */
  model_json: string | null;
  capabilities_json: string | null;
  linked_at: number;
  last_seen_at: number;
  revoked_at: number | null;
};
const MAX_SESSIONS = 20;
const MAX_PENDING_LOGIN_CODES = 10;
type HostStub = {
  disconnect(): Promise<void>;
  renamed(label: string): Promise<void>;
  presenceOf(): Promise<{ online: boolean; hostGeneration: string | null }>;
  callHost(request: { method: string; params: unknown; deadlineMs: number }): Promise<CallOutcome>;
};
type ClientStub = { hostsChanged(): Promise<boolean> };

/** What kind of Mac it said it is, if it has said and it still reads as one. */
function modelOf(row: AccountHostRow): { model?: HostModel } {
  if (row.model_json === null) return {};
  const model = hostModelSchema.safeParse(JSON.parse(row.model_json));
  return model.success ? { model: model.data } : {};
}

/** A Mac is shown by the name a person gave it, or else by what it reports. */
function shownLabel(row: AccountHostRow): string {
  return row.name ?? row.label;
}

export type PairingCreationStatus = "created" | "collision" | "limited";
export type PairingRedemption =
  | { status: "invalid" }
  | { status: "linked"; hostId: string; hostGeneration: string; credentialId: string; linkedAt: number };
export type PairingRedemptionInput = {
  codeVerifier: string;
  pairingId: string;
  hostId: string;
  hostGeneration: string;
  credentialId: string;
  credentialVerifier: string;
  label: string;
  hostKind: string;
  now: number;
};

/**
 * One account's state: sign-ins, pairing and its hosts. Each host's socket, presence and
 * Sessions live in that host's HostDO (RFD0018), which reaches this object by RPC.
 */
export class AxoAccountManager extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS account (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), account_id TEXT NOT NULL UNIQUE
    )`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS profile (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), email TEXT, name TEXT
    )`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS sessions (
      digest TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('web', 'native')),
      created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
    )`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS login_codes (
      digest TEXT PRIMARY KEY, challenge TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
    )`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS pairing_issuance (created_at INTEGER NOT NULL)`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS pairings (
      pairing_id TEXT PRIMARY KEY, code_verifier TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL, consumed_host_id TEXT, consumed_host_generation TEXT,
      consumed_credential_id TEXT, consumed_credential_verifier TEXT
    )`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS account_hosts (
      host_id TEXT PRIMARY KEY, host_generation TEXT NOT NULL, credential_id TEXT NOT NULL UNIQUE,
      credential_verifier TEXT NOT NULL, label TEXT NOT NULL, host_kind TEXT NOT NULL, capabilities_json TEXT,
      linked_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, revoked_at INTEGER
    )`);
    // The ClientDOs listing this account's hosts, told when a host is paired or revoked (RFD0031).
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS client_followers (client_do TEXT PRIMARY KEY)");
    const hostColumns = ctx.storage.sql.exec<{ name: string }>("PRAGMA table_info(account_hosts)").toArray();
    if (!hostColumns.some(column => column.name === "capabilities_json")) {
      ctx.storage.sql.exec("ALTER TABLE account_hosts ADD COLUMN capabilities_json TEXT");
    }
    if (!hostColumns.some(column => column.name === "name")) {
      ctx.storage.sql.exec("ALTER TABLE account_hosts ADD COLUMN name TEXT");
    }
    if (!hostColumns.some(column => column.name === "model_json")) {
      ctx.storage.sql.exec("ALTER TABLE account_hosts ADD COLUMN model_json TEXT");
    }
    // Each host's Session index moved to its HostDO (RFD0018), and the relay tables with it.
    for (const table of ["host_sessions_v1", "host_sessions_v2", "groups", "pending", "route", "fragments_in", "fragments_discarded", "outbox"])
      ctx.storage.sql.exec(`DROP TABLE IF EXISTS ${table}`);
  }

  /** Starts a sign-in: binds this object's account ID, keeps the profile current, and keeps at most 20. */
  establishSession(accountId: string, digest: string, kind: "web" | "native", now: number, expiresAt: number, profile: AccountProfile): void {
    this.ctx.storage.transactionSync(() => {
      this.bindAccount(accountId);
      this.saveProfile(profile);
      const sql = this.ctx.storage.sql;
      sql.exec("DELETE FROM sessions WHERE expires_at <= ?", now);
      sql.exec("INSERT INTO sessions (digest, kind, created_at, expires_at) VALUES (?, ?, ?, ?)", digest, kind, now, expiresAt);
      // The oldest sign-ins go first, so a forgotten phone never blocks a new one.
      sql.exec(`DELETE FROM sessions WHERE digest IN (
        SELECT digest FROM sessions ORDER BY created_at DESC, digest LIMIT -1 OFFSET ?)`, MAX_SESSIONS);
    });
  }

  /** The profile and end of a sign-in that is still good, or null. */
  verifySession(digest: string, now: number): { profile: AccountProfile; expiresAt: number } | null {
    if (!this.accountId()) return null;
    const row = this.ctx.storage.sql.exec<{ expires_at: number }>(
      "SELECT expires_at FROM sessions WHERE digest = ? AND expires_at > ?", digest, now).toArray()[0];
    if (!row) return null;
    const profile = this.ctx.storage.sql.exec<{ email: string | null; name: string | null }>(
      "SELECT email, name FROM profile WHERE singleton = 1").toArray()[0];
    return { profile: { email: profile?.email ?? null, name: profile?.name ?? null }, expiresAt: row.expires_at };
  }

  revokeSession(digest: string): void {
    this.ctx.storage.sql.exec("DELETE FROM sessions WHERE digest = ?", digest);
  }

  /** A one-time code the app trades, with its secret, for a session. At most 10 wait at once. */
  createLoginCode(accountId: string, digest: string, challenge: string, now: number, expiresAt: number, profile: AccountProfile): void {
    this.ctx.storage.transactionSync(() => {
      this.bindAccount(accountId);
      this.saveProfile(profile);
      const sql = this.ctx.storage.sql;
      sql.exec("DELETE FROM login_codes WHERE expires_at <= ?", now);
      sql.exec("INSERT INTO login_codes (digest, challenge, created_at, expires_at) VALUES (?, ?, ?, ?)", digest, challenge, now, expiresAt);
      sql.exec(`DELETE FROM login_codes WHERE digest IN (
        SELECT digest FROM login_codes ORDER BY created_at DESC, digest LIMIT -1 OFFSET ?)`, MAX_PENDING_LOGIN_CODES);
    });
  }

  /**
   * Uses up a login code. It is gone whatever the answer, so a wrong secret is one guess, not a
   * way to keep trying. The profile comes back only if the secret matches what the app started with.
   */
  redeemLoginCode(digest: string, challenge: string, now: number): AccountProfile | null {
    return this.ctx.storage.transactionSync(() => {
      const sql = this.ctx.storage.sql;
      const row = sql.exec<{ challenge: string; expires_at: number }>(
        "SELECT challenge, expires_at FROM login_codes WHERE digest = ?", digest).toArray()[0];
      sql.exec("DELETE FROM login_codes WHERE digest = ?", digest);
      if (!row || row.expires_at <= now || !constantTimeEqual(row.challenge, challenge)) return null;
      const profile = sql.exec<{ email: string | null; name: string | null }>(
        "SELECT email, name FROM profile WHERE singleton = 1").toArray()[0];
      return { email: profile?.email ?? null, name: profile?.name ?? null };
    });
  }

  private saveProfile(profile: AccountProfile): void {
    this.ctx.storage.sql.exec(`INSERT INTO profile (singleton, email, name) VALUES (1, ?, ?)
      ON CONFLICT(singleton) DO UPDATE SET email = excluded.email, name = excluded.name
      WHERE email IS NOT excluded.email OR name IS NOT excluded.name`, profile.email, profile.name);
  }

  createPairing(codeVerifier: string, pairingId: string, now: number, expiresAt: number): PairingCreationStatus {
    if (!Number.isSafeInteger(now) || !Number.isSafeInteger(expiresAt) || expiresAt <= now || expiresAt > now + 10 * 60 * 1000)
      throw new Error("Invalid pairing expiration");
    return this.ctx.storage.transactionSync(() => {
      const sql = this.ctx.storage.sql;
      sql.exec("DELETE FROM pairings WHERE expires_at <= ? AND (consumed_host_id IS NULL OR created_at <= ?)", now, now - 24 * 60 * 60 * 1000);
      sql.exec("DELETE FROM pairing_issuance WHERE created_at <= ?", now - 60 * 60 * 1000);
      if (sql.exec("SELECT pairing_id FROM pairings WHERE code_verifier = ?", codeVerifier).toArray().length)
        return "collision";
      const pending = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pairings WHERE consumed_host_id IS NULL AND expires_at > ?", now).one().count;
      const issued = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM pairing_issuance").one().count;
      if (pending >= 3 || issued >= 5) return "limited";
      sql.exec(`INSERT INTO pairings (pairing_id, code_verifier, created_at, expires_at,
        consumed_host_id, consumed_host_generation, consumed_credential_id, consumed_credential_verifier)
        VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL)`, pairingId, codeVerifier, now, expiresAt);
      sql.exec("INSERT INTO pairing_issuance (created_at) VALUES (?)", now);
      return "created";
    });
  }

  cancelPairing(codeVerifier: string, pairingId: string): void {
    this.ctx.storage.sql.exec("DELETE FROM pairings WHERE code_verifier = ? AND pairing_id = ? AND consumed_host_id IS NULL", codeVerifier, pairingId);
  }

  redeemPairing(input: PairingRedemptionInput): PairingRedemption {
    let credentialRotated = false;
    let hostAdded = false;
    const result = this.ctx.storage.transactionSync(() => {
      const sql = this.ctx.storage.sql;
      const pairing = sql.exec<PairingRow>(
        "SELECT * FROM pairings WHERE pairing_id = ? AND code_verifier = ?",
        input.pairingId,
        input.codeVerifier,
      ).toArray()[0];
      if (!pairing) return { status: "invalid" } as const;

      if (pairing.consumed_host_id !== null) {
        const sameRedemption = pairing.consumed_host_id === input.hostId &&
          pairing.consumed_host_generation === input.hostGeneration &&
          pairing.consumed_credential_id === input.credentialId &&
          pairing.consumed_credential_verifier === input.credentialVerifier;
        const host = sql.exec<AccountHostRow>(
          "SELECT * FROM account_hosts WHERE host_id = ?",
          input.hostId,
        ).toArray()[0];
        if (!sameRedemption || !host || host.credential_id !== input.credentialId ||
            host.credential_verifier !== input.credentialVerifier ||
            host.host_generation !== input.hostGeneration || host.revoked_at !== null)
          return { status: "invalid" } as const;
        return {
          status: "linked",
          hostId: host.host_id,
          hostGeneration: host.host_generation,
          credentialId: host.credential_id,
          linkedAt: host.linked_at,
        } as const;
      }

      if (pairing.expires_at <= input.now) return { status: "invalid" } as const;
      const sqlHost = sql.exec<AccountHostRow>(
        "SELECT * FROM account_hosts WHERE host_id = ?",
        input.hostId,
      ).toArray()[0];
      const credentialOwner = sql.exec<{ host_id: string }>(
        "SELECT host_id FROM account_hosts WHERE credential_id = ?",
        input.credentialId,
      ).toArray()[0];
      if (credentialOwner && credentialOwner.host_id !== input.hostId)
        return { status: "invalid" } as const;
      if (!sqlHost) {
        const activeHosts = sql.exec<{ count: number }>(
          "SELECT COUNT(*) AS count FROM account_hosts WHERE revoked_at IS NULL",
        ).one().count;
        if (activeHosts >= LIMITS.machines) return { status: "invalid" } as const;
      }

      hostAdded = !sqlHost || sqlHost.revoked_at !== null;
      credentialRotated = Boolean(sqlHost && (
        sqlHost.credential_id !== input.credentialId ||
        sqlHost.credential_verifier !== input.credentialVerifier ||
        sqlHost.host_generation !== input.hostGeneration ||
        sqlHost.revoked_at !== null
      ));
      const linkedAt = sqlHost?.linked_at ?? input.now;
      sql.exec(`INSERT INTO account_hosts (host_id, host_generation, credential_id, credential_verifier,
        label, host_kind, linked_at, last_seen_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
        ON CONFLICT(host_id) DO UPDATE SET host_generation = excluded.host_generation,
        credential_id = excluded.credential_id, credential_verifier = excluded.credential_verifier,
        label = excluded.label, host_kind = excluded.host_kind, last_seen_at = excluded.last_seen_at, revoked_at = NULL`,
        input.hostId, input.hostGeneration, input.credentialId, input.credentialVerifier,
        input.label, input.hostKind, linkedAt, input.now);
      sql.exec(`UPDATE pairings SET consumed_host_id = ?, consumed_host_generation = ?,
        consumed_credential_id = ?, consumed_credential_verifier = ?
        WHERE pairing_id = ? AND code_verifier = ? AND consumed_host_id IS NULL`,
        input.hostId, input.hostGeneration, input.credentialId, input.credentialVerifier,
        input.pairingId, input.codeVerifier);
      return {
        status: "linked",
        hostId: input.hostId,
        hostGeneration: input.hostGeneration,
        credentialId: input.credentialId,
        linkedAt,
      } as const;
    });

    if (result.status === "linked" && credentialRotated) this.disconnectHost(input.hostId);
    if (result.status === "linked" && hostAdded) this.hostsChanged();
    return result;
  }

  async listHosts(): Promise<{ hosts: HostSnapshot[] }> {
    const rows = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts ORDER BY host_id LIMIT ?", LIMITS.machines).toArray();
    return { hosts: await Promise.all(rows.map((row) => this.hostSnapshot(row))) };
  }

  /**
   * The hosts a client follows: every host the account still owns. Presence comes from each
   * HostDO. A ClientDO that names itself is told when that list changes, until it unfollows.
   */
  async clientHosts(clientDO?: string): Promise<Array<Omit<ClientHost, "online">>> {
    if (clientDO) this.ctx.storage.sql.exec("INSERT OR IGNORE INTO client_followers (client_do) VALUES (?)", clientDO);
    return this.ctx.storage.sql.exec<AccountHostRow>(
      "SELECT * FROM account_hosts WHERE revoked_at IS NULL ORDER BY host_id LIMIT ?", LIMITS.machines,
    ).toArray().map((row) => ({
      hostId: row.host_id, hostGeneration: row.host_generation, label: shownLabel(row), hostKind: row.host_kind,
      ...modelOf(row), lastSeenAt: new Date(row.last_seen_at).toISOString(),
    }));
  }

  async unfollow(clientDO: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM client_followers WHERE client_do = ?", clientDO);
  }

  /**
   * Names a Mac (RFD0022): it is shown by that name everywhere, and reconnecting never undoes it.
   * An empty name shows what the Mac reports again. Returns the name shown.
   */
  async renameHost(hostId: string, name: string): Promise<string | null> {
    const host = this.activeHost(hostId);
    if (!host) return null;
    const chosen = name.trim() || null;
    this.ctx.storage.sql.exec("UPDATE account_hosts SET name = ? WHERE host_id = ?", chosen, hostId);
    const label = chosen ?? host.label;
    await this.hostDO(hostId)?.renamed(label).catch(() => undefined);
    return label;
  }

  revokeHost(hostId: string, now = Date.now()): void {
    this.ctx.storage.sql.exec("UPDATE account_hosts SET revoked_at = ? WHERE host_id = ? AND revoked_at IS NULL", now, hostId);
    // Its clients see it go offline, its Sessions still listed; they stop listing it when they
    // next say hello or refresh.
    this.disconnectHost(hostId);
  }

  /** Whether `credential` is the current credential of a host this account still owns. */
  async authorizeHost(hostId: string, credentialId: string, credential: string): Promise<boolean> {
    const host = this.activeHost(hostId);
    const sessionSecret = (this.env as Env & { SESSION_SECRET?: string }).SESSION_SECRET;
    if (!host || !/^[A-Za-z0-9_-]{43}$/.test(credential) || credentialId !== host.credential_id || !sessionSecret)
      return false;
    const verifier = await hmac(sessionSecret, `host-credential\0${credential}`);
    return constantTimeEqual(verifier, host.credential_verifier);
  }

  /** A host registered on its socket: keeps its boot generation, label and capabilities. */
  async registerHost(registration: unknown, now: number): Promise<HostSnapshot> {
    const input = hostRegisterSchema.parse(registration);
    const host = this.activeHost(input.hostId);
    if (!host) throw new Error("Host is not linked to this account");
    // A Mac that does not say what it is (one too old to) keeps what it said before.
    const model = input.model === undefined ? host.model_json : JSON.stringify(input.model);
    this.ctx.storage.sql.exec(`UPDATE account_hosts SET host_generation = ?, label = ?, host_kind = ?, model_json = ?, capabilities_json = ?, last_seen_at = ?
      WHERE host_id = ? AND revoked_at IS NULL`, input.hostGeneration, input.label, input.hostKind, model,
      input.capabilities === undefined ? null : JSON.stringify(input.capabilities), now, input.hostId);
    // Clients list hosts as they were when they last said hello; one that changed what it is
    // shows as it is now.
    if (model !== host.model_json) this.hostsChanged();
    return hostSnapshotSchema.parse({ hostId: input.hostId, hostGeneration: input.hostGeneration, label: input.label,
      hostKind: input.hostKind, ...(input.model === undefined ? {} : { model: input.model }), ...(input.capabilities === undefined ? {} : { capabilities: input.capabilities }),
      status: "online", stale: false, lastSeenAt: new Date(now).toISOString(), sessions: [] });
  }

  async touchHost(hostId: string, hostGeneration: string, now: number): Promise<{ acknowledged: true; lastSeenAt: string }> {
    const row = this.activeHost(hostId);
    if (!row) throw new Error("Host is not linked to this account");
    if (row.host_generation !== hostGeneration) throw new Error("Host generation conflict");
    this.ctx.storage.sql.exec("UPDATE account_hosts SET last_seen_at = ? WHERE host_id = ?", now, hostId);
    return { acknowledged: true, lastSeenAt: new Date(now).toISOString() };
  }

  /**
   * An `axo.apps.*` call from one of the account's Macs, forwarded by its HostDO
   * (RFD0016). Apps state stays here; the HostDO only carries calls.
   */
  async appsCall(call: AppsCall): Promise<CallOutcome> {
    const apps = this.apps();
    if (!apps) return { error: { code: -32002, message: "Stale host" } };
    return apps.call(call);
  }

  // ─── Apps on the web (RFD0016, Apps page) ──────────────────────

  async listApps(): Promise<{ apps: AccountApp[] }> {
    return this.requireApps().list();
  }

  async addApp(name: string, url: string): Promise<CallOutcome> {
    return this.requireApps().add(name, url);
  }

  /** Removes a third-party connection, or signs `account` out of an app. */
  async removeApp(name: string, account?: string): Promise<CallOutcome> {
    return this.requireApps().remove(name, account);
  }

  /** A client the person registered with the provider, typed on the Apps page only. */
  async setConnectionClient(name: string, clientId: string, clientSecret: string | null): Promise<{ signInUrl: string }> {
    return this.requireApps().setClient(name, { clientId, clientSecret });
  }

  /** A token app's account, from what the person pasted on its page (RFD0016). */
  async addAppToken(name: string, account: string | null, fields: Record<string, string>): Promise<{ name: string; account: string } | { error: string }> {
    return this.requireApps().addAppToken(name, account, fields);
  }

  async startAppDevice(name: string): Promise<({ flow: string } & Extract<DeviceSignIn, { state: "pending" }>) | { error: string }> {
    return this.requireApps().startAppDevice(name);
  }

  async pollAppDevice(name: string, flow: string): Promise<DeviceSignIn> {
    return this.requireApps().pollAppDevice(name, flow);
  }

  async startAppMacSignIn(name: string, mac: string, preset: string, account: string | null): Promise<({ flow: string } & AppMacSignIn) | { error: string }> {
    return this.requireApps().startAppMacSignIn(name, mac, preset, account);
  }

  async pollAppMacSignIn(name: string, flow: string): Promise<AppMacSignIn> {
    return this.requireApps().pollAppMacSignIn(name, flow);
  }

  async appPhoneSignIn(name: string, request: AppPhoneSignInRequest): Promise<AppPhoneSignIn> {
    return this.requireApps().appPhoneSignIn(name, request);
  }

  async appLink(name: string, request: AppLinkRequest): Promise<AppLink> {
    return this.requireApps().appLink(name, request);
  }

  async appSignInLink(name: string): Promise<string> {
    return this.requireApps().signInLink(name);
  }

  async openConnectionFlow(nonce: string): Promise<{ authorizeUrl: string; name: string; nonce: string } | null> {
    return this.requireApps().openFlow(nonce);
  }

  async completeConnectionFlow(nonce: string, code: string): Promise<{ name: string } | { error: string }> {
    return this.requireApps().completeFlow(nonce, code);
  }

  async appsLog(limit?: number, before?: string, service?: string): Promise<{ records: CallRecord[] }> {
    return { records: await this.requireApps().readLog(limit, before, service) };
  }

  async appsLogIntegrity(): Promise<ChainCheck> {
    return this.requireApps().verifyLog();
  }

  private requireApps(): AccountApps {
    const apps = this.apps();
    if (!apps) throw new Error("This account has no apps yet");
    return apps;
  }

  private appsState: AccountApps | null = null;

  private apps(): AccountApps | null {
    if (this.appsState) return this.appsState;
    const accountId = this.accountId();
    const secret = (this.env as Env & { SESSION_SECRET?: string }).SESSION_SECRET;
    if (!accountId || !secret) return null;
    return this.appsState = new AccountApps({
      sql: this.ctx.storage.sql,
      secret,
      accountId,
      loader: this.env.LOADER,
      hosts: () => this.ctx.storage.sql.exec<AccountHostRow>(
        "SELECT * FROM account_hosts WHERE revoked_at IS NULL ORDER BY linked_at, host_id LIMIT ?", LIMITS.machines,
      ).toArray().map((row) => ({ hostId: row.host_id, hostGeneration: row.host_generation, label: shownLabel(row), linkedAt: row.linked_at })),
      presence: async (hostId) => plain(await this.hostDO(hostId)!.presenceOf()),
      callHost: async (hostId, request) => plain(await this.hostDO(hostId)!.callHost(request)),
      google: googleClient(this.env as Env & { GOOGLE_CLIENT_ID?: string; GOOGLE_CLIENT_SECRET?: string }),
      fetcher: (input, init) => fetch(input, init),
      waitUntil: (promise) => this.ctx.waitUntil(promise),
      // Each linked WhatsApp device is a Durable Object of its own, named by the account and the device.
      linked: (_app, device) => this.ctx.exports.AxoWhatsAppDO.getByName(`${accountId}:${device}`) as unknown as LinkedDevice,
    });
  }

  private activeHost(hostId: string): AccountHostRow | undefined {
    return this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts WHERE host_id = ? AND revoked_at IS NULL", hostId).toArray()[0];
  }

  private hostDO(hostId: string): HostStub | null {
    const accountId = this.accountId();
    return accountId ? this.ctx.exports.AxoHostDO.getByName(hostDOName(accountId, hostId)) as unknown as HostStub : null;
  }

  /** Tells every following ClientDO the account's hosts changed; one that is gone is dropped. */
  private hostsChanged(): void {
    const sql = this.ctx.storage.sql;
    const followers = sql.exec<{ client_do: string }>("SELECT client_do FROM client_followers").toArray();
    this.ctx.waitUntil(Promise.all(followers.map(async ({ client_do }) => {
      const client = this.ctx.exports.AxoClientDO.getByName(client_do) as unknown as ClientStub;
      const following = await client.hostsChanged().catch(() => client.hostsChanged()).catch(() => false);
      if (!following) sql.exec("DELETE FROM client_followers WHERE client_do = ?", client_do);
    })));
  }

  private disconnectHost(hostId: string): void {
    const host = this.hostDO(hostId);
    if (host) this.ctx.waitUntil(host.disconnect().catch(() => undefined));
  }

  private async hostSnapshot(row: AccountHostRow): Promise<HostSnapshot> {
    const presence = row.revoked_at === null ? await this.hostDO(row.host_id)?.presenceOf().catch(() => null) : null;
    const online = Boolean(presence?.online && presence.hostGeneration === row.host_generation);
    return hostSnapshotSchema.parse({
      hostId: row.host_id, hostGeneration: row.host_generation, label: shownLabel(row), hostKind: row.host_kind,
      ...modelOf(row), ...(row.capabilities_json === null ? {} : { capabilities: JSON.parse(row.capabilities_json) as unknown }),
      status: online ? "online" : "offline", stale: !online,
      lastSeenAt: new Date(row.last_seen_at).toISOString(), sessions: [],
    });
  }

  private bindAccount(accountId: string): void {
    const sql = this.ctx.storage.sql;
    const old = sql.exec<{ account_id: string }>("SELECT account_id FROM account WHERE singleton = 1").toArray()[0];
    if (old && old.account_id !== accountId) throw new Error("Account identity conflict");
    if (!old) sql.exec("INSERT INTO account (singleton, account_id) VALUES (1, ?)", accountId);
  }
  private accountId(): string | null {
    return this.ctx.storage.sql.exec<{ account_id: string }>("SELECT account_id FROM account WHERE singleton = 1").toArray()[0]?.account_id ?? null;
  }
}

/** RPC results arrive as proxies that hold resources; this keeps the plain value and lets them go. */
function plain<T>(value: T): T {
  const copy = JSON.parse(JSON.stringify(value)) as T;
  (value as Partial<Disposable>)[Symbol.dispose]?.();
  return copy;
}
