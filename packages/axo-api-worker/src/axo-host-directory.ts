import { DurableObject } from "cloudflare:workers";
import {
  LIMITS,
  uuid,
  registrationSchema,
  type Registration,
} from "@axo/protocol";
import {
  hostIdSchema,
  hostDataEventSchema,
  hostRegisterSchema,
  hostSessionsPublishSchema,
  hostSnapshotSchema,
  hostRefSchema,
  sessionSnapshotSchema,
  type HostSnapshot,
  type SessionSnapshot,
} from "@axo/protocol/v1";
import type { Principal } from "./access";

type MachineRow = {
  machine_id: string;
  principal: string;
  label: string;
  generation: string;
};

type HostRow = {
  host_id: string;
  principal: string;
  label: string;
  host_kind: string;
  host_generation: string;
  last_seen_at: number;
};

type StoredHostSessionRow = {
  host_id: string;
  session_id: number;
  snapshot_json: string;
};
export class AxoHostDirectory extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS machines (machine_id TEXT PRIMARY KEY, principal TEXT NOT NULL, label TEXT NOT NULL, generation TEXT NOT NULL)",
    );
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS hosts_v1 (
        host_id TEXT PRIMARY KEY,
        principal TEXT NOT NULL,
        label TEXT NOT NULL,
        host_kind TEXT NOT NULL,
        host_generation TEXT NOT NULL,
        last_seen_at INTEGER NOT NULL
      )
    `);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS host_sessions_v1 (
        host_id TEXT NOT NULL REFERENCES hosts_v1(host_id) ON DELETE CASCADE,
        session_id INTEGER NOT NULL,
        snapshot_json TEXT NOT NULL CHECK (json_valid(snapshot_json)),
        PRIMARY KEY (host_id, session_id)
      )
    `);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS host_reservations_v1 (
        host_id TEXT PRIMARY KEY,
        principal TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      )
    `);
    ctx.storage.sql.exec(
      "CREATE INDEX IF NOT EXISTS host_sessions_v1_by_host ON host_sessions_v1(host_id, session_id)",
    );
  }
  admit(
    machineId: string,
    principal: Principal,
  ): "admitted" | "capacity" | "conflict" | "unregistered" {
    uuid.parse(machineId);
    const sql = this.ctx.storage.sql;
    const old = sql
      .exec<MachineRow>(
        "SELECT * FROM machines WHERE machine_id = ?",
        machineId,
      )
      .toArray()[0];
    if (principal.role === "client")
      return old?.label ? "admitted" : "unregistered";
    if (old)
      return old.principal === principal.identity ? "admitted" : "conflict";
    if (
      sql
        .exec<{ count: number }>("SELECT COUNT(*) AS count FROM machines")
        .one().count >= LIMITS.machines
    )
      return "capacity";
    // Reserve before creating a relay object, but never publish an unregistered machine.
    sql.exec(
      "INSERT INTO machines VALUES (?, ?, '', '')",
      machineId,
      principal.identity,
    );
    return "admitted";
  }
  register(registration: Registration, principal: string): void {
    const input = registrationSchema.parse(registration);
    const sql = this.ctx.storage.sql;
    const old = sql
      .exec<MachineRow>(
        "SELECT * FROM machines WHERE machine_id = ?",
        input.machineId,
      )
      .toArray()[0];
    if (old && old.principal !== principal)
      throw new Error("Machine principal conflict");
    if (
      !old &&
      sql
        .exec<{ count: number }>("SELECT COUNT(*) AS count FROM machines")
        .one().count >= LIMITS.machines
    )
      throw new Error("Machine capacity");
    sql.exec(
      "INSERT INTO machines VALUES (?, ?, ?, ?) ON CONFLICT(machine_id) DO UPDATE SET label = excluded.label, generation = excluded.generation",
      input.machineId,
      principal,
      input.label,
      input.hostGeneration,
    );
  }
  async list() {
    const rows = this.ctx.storage.sql
      .exec<MachineRow>(
        "SELECT * FROM machines WHERE label <> '' ORDER BY machine_id LIMIT 16",
      )
      .toArray();
    return Promise.all(
      rows.map(async (row) => ({
        machineId: row.machine_id,
        label: row.label,
        ...(await this.ctx.exports.AxoHostRelay.getByName(
          row.machine_id,
        ).presence()),
      })),
    );
  }

  admitHost(
    hostId: string,
    principal: Principal,
  ): "admitted" | "capacity" | "conflict" | "unregistered" {
    const id = hostIdSchema.parse(hostId);
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    sql.exec("DELETE FROM host_reservations_v1 WHERE expires_at <= ?", now);

    const host = sql
      .exec<HostRow>("SELECT * FROM hosts_v1 WHERE host_id = ?", id)
      .toArray()[0];
    if (principal.role === "client") return host ? "admitted" : "unregistered";
    if (host) return host.principal === principal.identity ? "admitted" : "conflict";

    const reservation = sql
      .exec<{ principal: string }>(
        "SELECT principal FROM host_reservations_v1 WHERE host_id = ?",
        id,
      )
      .toArray()[0];
    if (reservation)
      return reservation.principal === principal.identity ? "admitted" : "conflict";

    const hostCount = sql
      .exec<{ count: number }>("SELECT COUNT(*) AS count FROM hosts_v1")
      .one().count;
    const reservationCount = sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM host_reservations_v1 WHERE expires_at > ?",
        now,
      )
      .one().count;
    if (hostCount + reservationCount >= LIMITS.machines) return "capacity";

    sql.exec(
      "INSERT INTO host_reservations_v1 (host_id, principal, expires_at) VALUES (?, ?, ?)",
      id,
      principal.identity,
      now + LIMITS.leaseMs,
    );
    return "admitted";
  }

  registerHost(registration: unknown, principal: string): HostSnapshot {
    const input = hostRegisterSchema.parse(registration);
    const sql = this.ctx.storage.sql;
    const old = sql
      .exec<HostRow>("SELECT * FROM hosts_v1 WHERE host_id = ?", input.hostId)
      .toArray()[0];
    if (old && old.principal !== principal)
      throw new Error("Host principal conflict");
    if (
      !old &&
      sql
        .exec<{ count: number }>("SELECT COUNT(*) AS count FROM hosts_v1")
        .one().count >= LIMITS.machines
    )
      throw new Error("Host capacity");

    const now = Date.now();
    const storedAt = new Date(now).toISOString();
    const sessions = input.sessions.map((session) =>
      sessionSnapshotSchema.parse({ ...session, updatedAt: storedAt }),
    );

    this.ctx.storage.transactionSync(() => {
      sql.exec(
        `INSERT INTO hosts_v1 (host_id, principal, label, host_kind, host_generation, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(host_id) DO UPDATE SET
           principal = excluded.principal,
           label = excluded.label,
           host_kind = excluded.host_kind,
           host_generation = excluded.host_generation,
           last_seen_at = excluded.last_seen_at`,
        input.hostId,
        principal,
        input.label,
        input.hostKind,
        input.hostGeneration,
        now,
      );
      sql.exec("DELETE FROM host_sessions_v1 WHERE host_id = ?", input.hostId);
      for (const session of sessions) {
        sql.exec(
          "INSERT INTO host_sessions_v1 (host_id, session_id, snapshot_json) VALUES (?, ?, ?)",
          input.hostId,
          session.sessionId,
          JSON.stringify(session),
        );
      }
      sql.exec("DELETE FROM host_reservations_v1 WHERE host_id = ?", input.hostId);
    });

    // The relay marks itself ready immediately after this RPC reply is sent.
    return hostSnapshotSchema.parse({
      hostId: input.hostId,
      hostGeneration: input.hostGeneration,
      label: input.label,
      hostKind: input.hostKind,
      status: "online",
      stale: false,
      lastSeenAt: storedAt,
      sessions,
    });
  }

  heartbeatHost(reference: unknown, principal: string): { acknowledged: true; lastSeenAt: string } {
    const hostRef = hostRefSchema.parse(reference);
    const row = this.ctx.storage.sql
      .exec<HostRow>("SELECT * FROM hosts_v1 WHERE host_id = ?", hostRef.hostId)
      .toArray()[0];
    if (!row) throw new Error("Host not found");
    if (row.principal !== principal) throw new Error("Host principal conflict");
    if (row.host_generation !== hostRef.hostGeneration)
      throw new Error("Host generation conflict");

    const now = Date.now();
    this.ctx.storage.sql.exec(
      "UPDATE hosts_v1 SET last_seen_at = ? WHERE host_id = ? AND host_generation = ?",
      now,
      hostRef.hostId,
      hostRef.hostGeneration,
    );
    return { acknowledged: true, lastSeenAt: new Date(now).toISOString() };
  }

  publishHostSessions(publication: unknown, principal: string): { storedAt: string } {
    const input = hostSessionsPublishSchema.parse(publication);
    const sql = this.ctx.storage.sql;
    const row = sql
      .exec<HostRow>("SELECT * FROM hosts_v1 WHERE host_id = ?", input.hostId)
      .toArray()[0];
    if (!row) throw new Error("Host not found");
    if (row.principal !== principal) throw new Error("Host principal conflict");
    if (row.host_generation !== input.hostGeneration)
      throw new Error("Host generation conflict");

    const now = Date.now();
    const storedAt = new Date(now).toISOString();
    const sessions = input.sessions.map((session) =>
      sessionSnapshotSchema.parse({ ...session, updatedAt: storedAt }),
    );
    this.ctx.storage.transactionSync(() => {
      sql.exec(
        "UPDATE hosts_v1 SET last_seen_at = ? WHERE host_id = ? AND host_generation = ?",
        now,
        input.hostId,
        input.hostGeneration,
      );
      sql.exec("DELETE FROM host_sessions_v1 WHERE host_id = ?", input.hostId);
      for (const session of sessions) {
        sql.exec(
          "INSERT INTO host_sessions_v1 (host_id, session_id, snapshot_json) VALUES (?, ?, ?)",
          input.hostId,
          session.sessionId,
          JSON.stringify(session),
        );
      }
    });
    return { storedAt };
  }

  applyHostEvent(event: unknown, principal: string): void {
    const parsed = hostDataEventSchema.parse(event);
    const sql = this.ctx.storage.sql;
    const host = sql
      .exec<HostRow>("SELECT * FROM hosts_v1 WHERE host_id = ?", parsed.hostId)
      .toArray()[0];
    if (!host) throw new Error("Host not found");
    if (host.principal !== principal) throw new Error("Host principal conflict");
    if (host.host_generation !== parsed.hostGeneration)
      throw new Error("Host generation conflict");

    const now = Date.now();
    switch (parsed.event.type) {
      case "session.snapshot": {
        const snapshot = sessionSnapshotSchema.parse({
          ...parsed.event.snapshot,
          updatedAt: new Date(now).toISOString(),
        });
        this.ctx.storage.transactionSync(() => {
          sql.exec(
            "UPDATE hosts_v1 SET last_seen_at = ? WHERE host_id = ? AND host_generation = ?",
            now,
            parsed.hostId,
            parsed.hostGeneration,
          );
          sql.exec(
            `INSERT INTO host_sessions_v1 (host_id, session_id, snapshot_json)
             VALUES (?, ?, ?)
             ON CONFLICT(host_id, session_id) DO UPDATE SET snapshot_json = excluded.snapshot_json`,
            parsed.hostId,
            snapshot.sessionId,
            JSON.stringify(snapshot),
          );
        });
        return;
      }
      case "session.removed": {
        const sessionId = parsed.event.sessionId;
        this.ctx.storage.transactionSync(() => {
          sql.exec(
            "UPDATE hosts_v1 SET last_seen_at = ? WHERE host_id = ? AND host_generation = ?",
            now,
            parsed.hostId,
            parsed.hostGeneration,
          );
          sql.exec(
            "DELETE FROM host_sessions_v1 WHERE host_id = ? AND session_id = ?",
            parsed.hostId,
            sessionId,
          );
        });
        return;
      }
      case "shell.activity":
      case "terminal.output":
      case "pi.event":
        // The unassigned legacy fleet has no Pi history store.
        return;
    }
  }

  async listHosts(): Promise<{ hosts: HostSnapshot[] }> {
    const rows = this.ctx.storage.sql
      .exec<HostRow>("SELECT * FROM hosts_v1 ORDER BY host_id LIMIT ?", LIMITS.machines)
      .toArray();
    return { hosts: await Promise.all(rows.map((row) => this.hostSnapshot(row))) };
  }

  async listHostSessions(reference: unknown): Promise<{
    host: HostSnapshot;
    sessions: SessionSnapshot[];
  } | null> {
    const hostRef = hostRefSchema.parse(reference);
    const row = this.ctx.storage.sql
      .exec<HostRow>("SELECT * FROM hosts_v1 WHERE host_id = ?", hostRef.hostId)
      .toArray()[0];
    if (!row) return null;
    if (row.host_generation !== hostRef.hostGeneration)
      throw new Error("Host generation conflict");
    const host = await this.hostSnapshot(row);
    return { host, sessions: host.sessions };
  }

  private async hostSnapshot(row: HostRow): Promise<HostSnapshot> {
    const presence = await this.ctx.exports.AxoHostRelay.getByName(row.host_id).presence();
    const online = presence.online && presence.hostGeneration === row.host_generation;
    const sessionRows = this.ctx.storage.sql
      .exec<StoredHostSessionRow>(
        "SELECT * FROM host_sessions_v1 WHERE host_id = ? ORDER BY session_id LIMIT 256",
        row.host_id,
      )
      .toArray();
    const sessions = sessionRows.map((sessionRow) =>
      sessionSnapshotSchema.parse(JSON.parse(sessionRow.snapshot_json)),
    );
    return hostSnapshotSchema.parse({
      hostId: row.host_id,
      hostGeneration: row.host_generation,
      label: row.label,
      hostKind: row.host_kind,
      status: online ? "online" : "offline",
      stale: !online,
      lastSeenAt: new Date(row.last_seen_at).toISOString(),
      sessions,
    });
  }
}
