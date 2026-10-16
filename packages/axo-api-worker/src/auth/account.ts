import { DurableObject } from "cloudflare:workers";

/** Maps a verified issuer-qualified identity to one immutable Axo account ID. */
export class AxoIdentityIndex extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS identity (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        account_id TEXT NOT NULL
      )
    `);
  }

  resolveAccount(): string {
    const sql = this.ctx.storage.sql;
    const existing = sql.exec<{ account_id: string }>(
      "SELECT account_id FROM identity WHERE singleton = 1",
    ).toArray()[0];
    if (existing) return existing.account_id;

    const accountId = crypto.randomUUID();
    sql.exec("INSERT INTO identity (singleton, account_id) VALUES (1, ?)", accountId);
    return accountId;
  }
}
