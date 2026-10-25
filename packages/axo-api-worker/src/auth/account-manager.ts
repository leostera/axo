import { AxoHostRelay } from "../axo-host-relay";
import { z } from "zod";
import { uuid } from "@axo/protocol";
import { LIMITS } from "@axo/protocol";
import {
  hostDataEventSchema,
  hostRegisterSchema,
  hostRefSchema,
  hostSessionsPublishSchema,
  sessionIdSchema,
  hostSnapshotSchema,
  sessionSnapshotSchema,
  type HostSnapshot,
  type SessionSnapshot,
} from "@axo/protocol/v1";
import { constantTimeEqual, hmac } from "./crypto";
import type { Peer } from "../relay/peer";
import { sessionDOName, sessionEventBindingSchema, sessionEventPageRequestSchema, sessionEventPageResultSchema } from "../session-history";

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
  label: string;
  host_kind: string;
  capabilities_json: string | null;
  linked_at: number;
  last_seen_at: number;
  revoked_at: number | null;
};
type StoredHostSessionRow = { host_id: string; session_id: number; snapshot_json: string };

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

/** All account-owned state and live host relays share this per-account Durable Object. */
export class AxoAccountManager extends AxoHostRelay {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS account (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), account_id TEXT NOT NULL UNIQUE
    )`);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS profile (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1), email TEXT, name TEXT
    )`);
    // Axo's own web sessions were replaced by Cloudflare Access identity.
    ctx.storage.sql.exec("DROP TABLE IF EXISTS web_sessions");
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
    const hostColumns = ctx.storage.sql.exec<{ name: string }>("PRAGMA table_info(account_hosts)").toArray();
    if (!hostColumns.some(column => column.name === "capabilities_json")) {
      ctx.storage.sql.exec("ALTER TABLE account_hosts ADD COLUMN capabilities_json TEXT");
    }
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS host_sessions_v1 (
      host_id TEXT NOT NULL REFERENCES account_hosts(host_id) ON DELETE CASCADE,
      session_id INTEGER NOT NULL, snapshot_json TEXT NOT NULL CHECK (json_valid(snapshot_json)),
      PRIMARY KEY (host_id, session_id)
    )`);
    ctx.storage.sql.exec("CREATE INDEX IF NOT EXISTS host_sessions_v1_by_host ON host_sessions_v1(host_id, session_id)");
  }

  /** Called for every request Access verified: binds this object's account ID and keeps the profile current. */
  recordSignIn(accountId: string, profile: AccountProfile): void {
    this.ctx.storage.transactionSync(() => {
      this.bindAccount(accountId);
      this.ctx.storage.sql.exec(`INSERT INTO profile (singleton, email, name) VALUES (1, ?, ?)
        ON CONFLICT(singleton) DO UPDATE SET email = excluded.email, name = excluded.name
        WHERE email IS NOT excluded.email OR name IS NOT excluded.name`, profile.email, profile.name);
    });
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

    if (result.status === "linked" && credentialRotated) this.closeHostRelay(input.hostId);
    return result;
  }

  async listHosts(): Promise<{ hosts: HostSnapshot[] }> {
    const rows = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts ORDER BY host_id LIMIT ?", LIMITS.machines).toArray();
    return { hosts: await Promise.all(rows.map((row) => this.hostSnapshot(row))) };
  }

  async listHostSessions(reference: unknown): Promise<{ host: HostSnapshot; sessions: SessionSnapshot[] } | null> {
    const hostRef = hostRefSchema.parse(reference);
    const row = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts WHERE host_id = ? AND revoked_at IS NULL", hostRef.hostId).toArray()[0];
    if (!row) return null;
    if (row.host_generation !== hostRef.hostGeneration) throw new Error("Host generation conflict");
    const host = await this.hostSnapshot(row);
    return { host, sessions: host.sessions };
  }

  async listPiEvents(request: unknown): Promise<{ events: unknown[]; next: number | null }> {
    const accountId = this.accountId();
    if (!accountId) throw new Error("Account identity is unavailable");
    const query = z.object({
      hostId: uuid,
      sessionId: sessionIdSchema,
      after: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER).default(0),
      limit: z.number().int().min(1).max(50).default(20),
    }).strict().parse(request);
    const input = sessionEventPageRequestSchema.parse({ ...query, accountId });
    const host = this.ctx.storage.sql.exec<AccountHostRow>(
      "SELECT * FROM account_hosts WHERE host_id = ?",
      input.hostId,
    ).toArray()[0];
    if (!host) throw new Error("Host not found");
    const page = await this.ctx.exports.AxoSessionDO.getByName(
      sessionDOName(accountId, input.hostId, input.sessionId),
    ).list(input) as unknown as { ok: boolean; events?: unknown; next?: unknown };
    if (!page.ok) throw new Error("Session history ownership conflict");
    return sessionEventPageResultSchema.parse({ events: page.events, next: page.next });
  }

  revokeHost(hostId: string, now = Date.now()): void {
    this.ctx.storage.sql.exec("UPDATE account_hosts SET revoked_at = ? WHERE host_id = ? AND revoked_at IS NULL", now, hostId);
    this.closeHostRelay(hostId);
  }

  protected override supportsLegacyMachineMethods(): boolean { return false; }

  protected override async authorizeRelayPeer(request: Request, peer: Peer): Promise<boolean> {
    const accountId = this.accountId();
    if (!accountId || peer.identity !== accountId) return false;
    const host = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts WHERE host_id = ? AND revoked_at IS NULL", peer.machineId).toArray()[0];
    if (!host) return false;
    // A client was verified by Access for this account in the Worker; it may reach any host the account still owns.
    if (peer.role === "client") return true;

    const credentialId = request.headers.get("X-Axo-Credential-Id") ?? "";
    const credential = request.headers.get("X-Axo-Credential") ?? "";
    const sessionSecret = (this.env as Env & { SESSION_SECRET?: string }).SESSION_SECRET;
    if (!/^[A-Za-z0-9_-]{43}$/.test(credential) || credentialId !== host.credential_id || !sessionSecret)
      return false;
    const verifier = await hmac(sessionSecret, `host-credential\0${credential}`);
    return constantTimeEqual(verifier, host.credential_verifier);
  }

  protected override async storeHostRegistration(registration: unknown, principal: string): Promise<HostSnapshot> {
    const input = hostRegisterSchema.parse(registration);
    this.requireAccount(principal);
    const old = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts WHERE host_id = ? AND revoked_at IS NULL", input.hostId).toArray()[0];
    if (!old) throw new Error("Host is not linked to this account");
    const storedAt = Date.now();
    const sessions = input.sessions.map((session) => sessionSnapshotSchema.parse({ ...session, updatedAt: new Date(storedAt).toISOString() }));
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec(`UPDATE account_hosts SET host_generation = ?, label = ?, host_kind = ?, capabilities_json = ?, last_seen_at = ?
        WHERE host_id = ? AND revoked_at IS NULL`, input.hostGeneration, input.label, input.hostKind,
        input.capabilities === undefined ? null : JSON.stringify(input.capabilities), storedAt, input.hostId);
      this.replaceHostSessions(input.hostId, sessions);
    });
    return hostSnapshotSchema.parse({ hostId: input.hostId, hostGeneration: input.hostGeneration, label: input.label,
      hostKind: input.hostKind, ...(input.capabilities === undefined ? {} : { capabilities: input.capabilities }),
      status: "online", stale: false, lastSeenAt: new Date(storedAt).toISOString(), sessions });
  }

  protected override async storeHostHeartbeat(reference: unknown, principal: string): Promise<{ acknowledged: true; lastSeenAt: string }> {
    const input = hostRefSchema.parse(reference);
    this.requireAccount(principal);
    const row = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts WHERE host_id = ? AND revoked_at IS NULL", input.hostId).toArray()[0];
    if (!row) throw new Error("Host is not linked to this account");
    if (row.host_generation !== input.hostGeneration) throw new Error("Host generation conflict");
    const now = Date.now();
    this.ctx.storage.sql.exec("UPDATE account_hosts SET last_seen_at = ? WHERE host_id = ?", now, input.hostId);
    return { acknowledged: true, lastSeenAt: new Date(now).toISOString() };
  }

  protected override async storeHostSessions(publication: unknown, principal: string): Promise<{ storedAt: string }> {
    const input = hostSessionsPublishSchema.parse(publication);
    this.requireAccount(principal);
    const row = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts WHERE host_id = ? AND revoked_at IS NULL", input.hostId).toArray()[0];
    if (!row) throw new Error("Host is not linked to this account");
    if (row.host_generation !== input.hostGeneration) throw new Error("Host generation conflict");
    const now = Date.now();
    const sessions = input.sessions.map((session) => sessionSnapshotSchema.parse({ ...session, updatedAt: new Date(now).toISOString() }));
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec("UPDATE account_hosts SET last_seen_at = ? WHERE host_id = ?", now, input.hostId);
      this.replaceHostSessions(input.hostId, sessions);
    });
    return { storedAt: new Date(now).toISOString() };
  }

  protected override async storeHostEvent(event: unknown, principal: string): Promise<void> {
    const input = hostDataEventSchema.parse(event);
    this.requireAccount(principal);
    const host = this.ctx.storage.sql.exec<AccountHostRow>("SELECT * FROM account_hosts WHERE host_id = ? AND revoked_at IS NULL", input.hostId).toArray()[0];
    if (!host || host.host_generation !== input.hostGeneration) throw new Error("Host generation conflict");
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    const hostEvent = input.event;
    switch (hostEvent.type) {
      case "session.snapshot": {
        const snapshot = sessionSnapshotSchema.parse({ ...hostEvent.snapshot, updatedAt: new Date(now).toISOString() });
        this.ctx.storage.transactionSync(() => {
          sql.exec("UPDATE account_hosts SET last_seen_at = ? WHERE host_id = ?", now, input.hostId);
          sql.exec(`INSERT INTO host_sessions_v1 (host_id, session_id, snapshot_json) VALUES (?, ?, ?)
            ON CONFLICT(host_id, session_id) DO UPDATE SET snapshot_json = excluded.snapshot_json`, input.hostId, snapshot.sessionId, JSON.stringify(snapshot));
        });
        return;
      }
      case "session.removed": {
        this.ctx.storage.transactionSync(() => {
          sql.exec("UPDATE account_hosts SET last_seen_at = ? WHERE host_id = ?", now, input.hostId);
          sql.exec("DELETE FROM host_sessions_v1 WHERE host_id = ? AND session_id = ?", input.hostId, hostEvent.sessionId);
        });
        return;
      }
      case "shell.activity":
      case "terminal.output":
        return;
      case "pi.event": {
        const session = sql.exec<StoredHostSessionRow>(
          "SELECT * FROM host_sessions_v1 WHERE host_id = ? AND session_id = ?",
          input.hostId,
          hostEvent.sessionId,
        ).toArray()[0];
        if (!session) throw new Error("Pi event references an unknown Session");
        const accountId = this.accountId();
        if (!accountId) throw new Error("Account identity is unavailable");
        const binding = sessionEventBindingSchema.parse({
          accountId,
          hostId: input.hostId,
          hostGeneration: input.hostGeneration,
          sessionId: hostEvent.sessionId,
          piSessionId: hostEvent.piSessionId,
          streamId: hostEvent.streamId,
          sequence: hostEvent.sequence,
          name: hostEvent.name,
          data: hostEvent.data,
        });
        const appended = await this.ctx.exports.AxoSessionDO.getByName(
          sessionDOName(accountId, input.hostId, hostEvent.sessionId),
        ).append(binding) as unknown as { ok: boolean };
        if (!appended.ok) throw new Error("Session history binding conflict");
        sql.exec("UPDATE account_hosts SET last_seen_at = ? WHERE host_id = ?", now, input.hostId);
        return;
      }
    }
  }

  private replaceHostSessions(hostId: string, sessions: SessionSnapshot[]): void {
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM host_sessions_v1 WHERE host_id = ?", hostId);
    for (const session of sessions) {
      sql.exec("INSERT INTO host_sessions_v1 (host_id, session_id, snapshot_json) VALUES (?, ?, ?)", hostId, session.sessionId, JSON.stringify(session));
    }
  }

  private async hostSnapshot(row: AccountHostRow): Promise<HostSnapshot> {
    const presence = this.presence(row.host_id);
    const online = row.revoked_at === null && presence.online && presence.hostGeneration === row.host_generation;
    const sessions = this.ctx.storage.sql.exec<StoredHostSessionRow>(
      "SELECT * FROM host_sessions_v1 WHERE host_id = ? ORDER BY session_id LIMIT 256", row.host_id,
    ).toArray().map((session) => sessionSnapshotSchema.parse(JSON.parse(session.snapshot_json)));
    return hostSnapshotSchema.parse({
      hostId: row.host_id, hostGeneration: row.host_generation, label: row.label, hostKind: row.host_kind,
      ...(row.capabilities_json === null ? {} : { capabilities: JSON.parse(row.capabilities_json) as unknown }),
      status: online ? "online" : "offline", stale: !online,
      lastSeenAt: new Date(row.last_seen_at).toISOString(), sessions,
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
  private requireAccount(accountId: string): void {
    if (!this.accountId() || this.accountId() !== accountId) throw new Error("Account identity conflict");
  }
}
