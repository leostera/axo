import { DurableObject } from "cloudflare:workers";
import {
  LIMITS,
  uuid,
  registrationSchema,
  type Registration,
} from "@axo/protocol";
import type { Principal } from "./access";

type MachineRow = {
  machine_id: string;
  principal: string;
  label: string;
  generation: string;
};
export class AxoHostDirectory extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS machines (machine_id TEXT PRIMARY KEY, principal TEXT NOT NULL, label TEXT NOT NULL, generation TEXT NOT NULL)",
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
}
