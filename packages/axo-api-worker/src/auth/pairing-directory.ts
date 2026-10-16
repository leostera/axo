import { DurableObject } from "cloudflare:workers";

export type PairingIndexEntry = {
  accountId: string;
  pairingId: string;
  expiresAt: number;
};

export class AxoPairingIndex extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS pairing_index (
        code_verifier TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        pairing_id TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      )
    `);
  }

  reserve(
    verifier: string,
    accountId: string,
    pairingId: string,
    expiresAt: number,
    now: number,
  ): boolean {
    return this.ctx.storage.transactionSync(() => {
      const existing = this.ctx.storage.sql.exec<{ expires_at: number }>(
        "SELECT expires_at FROM pairing_index WHERE code_verifier = ?",
        verifier,
      ).toArray()[0];
      if (existing && existing.expires_at > now) return false;
      if (existing) {
        this.ctx.storage.sql.exec(
          "DELETE FROM pairing_index WHERE code_verifier = ?",
          verifier,
        );
      }
      this.ctx.storage.sql.exec(
        "INSERT INTO pairing_index (code_verifier, account_id, pairing_id, expires_at) VALUES (?, ?, ?, ?)",
        verifier,
        accountId,
        pairingId,
        expiresAt,
      );
      return true;
    });
  }

  lookup(verifier: string, now: number): PairingIndexEntry | null {
    return this.ctx.storage.transactionSync(() => {
      const row = this.ctx.storage.sql.exec<{
        account_id: string;
        pairing_id: string;
        expires_at: number;
      }>(
        "SELECT account_id, pairing_id, expires_at FROM pairing_index WHERE code_verifier = ?",
        verifier,
      ).toArray()[0];
      if (!row) return null;
      if (row.expires_at <= now) {
        this.ctx.storage.sql.exec(
          "DELETE FROM pairing_index WHERE code_verifier = ?",
          verifier,
        );
        return null;
      }
      return {
        accountId: row.account_id,
        pairingId: row.pairing_id,
        expiresAt: row.expires_at,
      };
    });
  }

  remove(verifier: string, pairingId: string): void {
    this.ctx.storage.sql.exec(
      "DELETE FROM pairing_index WHERE code_verifier = ? AND pairing_id = ?",
      verifier,
      pairingId,
    );
  }
}

export class AxoPairingRateLimit extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS attempts (
        attempted_at INTEGER NOT NULL
      )
    `);
    ctx.storage.sql.exec(
      "CREATE INDEX IF NOT EXISTS attempts_by_time ON attempts (attempted_at)",
    );
  }

  consume(now: number, windowMs: number, maximum: number): boolean {
    if (!Number.isSafeInteger(now) || !Number.isSafeInteger(windowMs) ||
        !Number.isSafeInteger(maximum) || windowMs <= 0 || maximum <= 0) {
      throw new Error("Invalid rate-limit parameters");
    }

    return this.ctx.storage.transactionSync(() => {
      const cutoff = now - windowMs;
      this.ctx.storage.sql.exec(
        "DELETE FROM attempts WHERE attempted_at <= ?",
        cutoff,
      );
      const count = this.ctx.storage.sql.exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM attempts",
      ).one().count;
      if (count >= maximum) return false;
      this.ctx.storage.sql.exec(
        "INSERT INTO attempts (attempted_at) VALUES (?)",
        now,
      );
      return true;
    });
  }
}
