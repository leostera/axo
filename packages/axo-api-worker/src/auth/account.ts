import { DurableObject } from "cloudflare:workers";

type AccountProfile = {
  email: string | null;
  name: string | null;
};

type SessionRow = {
  session_digest: string;
  expires_at: number;
  revoked_at: number | null;
};

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

export class AxoAccountDirectory extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS profile (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        email TEXT,
        name TEXT
      )
    `);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS web_sessions (
        session_digest TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        revoked_at INTEGER
      )
    `);
  }

  establishSession(
    sessionDigest: string,
    expiresAt: number,
    profile: AccountProfile,
  ): void {
    const now = Date.now();
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec(
        `INSERT INTO profile (singleton, email, name) VALUES (1, ?, ?)
         ON CONFLICT(singleton) DO UPDATE SET email = excluded.email, name = excluded.name`,
        profile.email,
        profile.name,
      );
      this.ctx.storage.sql.exec(
        "DELETE FROM web_sessions WHERE expires_at <= ? OR revoked_at IS NOT NULL",
        now,
      );
      this.ctx.storage.sql.exec(
        "INSERT INTO web_sessions (session_digest, created_at, expires_at, revoked_at) VALUES (?, ?, ?, NULL)",
        sessionDigest,
        now,
        expiresAt,
      );
    });
  }

  async sessionProfile(
    sessionDigest: string,
    now: number,
  ): Promise<AccountProfile | null> {
    const session = this.ctx.storage.sql.exec<SessionRow>(
      "SELECT * FROM web_sessions WHERE session_digest = ?",
      sessionDigest,
    ).toArray()[0];
    if (!session || session.revoked_at !== null || session.expires_at <= now)
      return null;

    const profile = this.ctx.storage.sql.exec<{ email: string | null; name: string | null }>(
      "SELECT email, name FROM profile WHERE singleton = 1",
    ).toArray()[0];
    if (!profile) return null;
    return { email: profile.email, name: profile.name };
  }

  revokeSession(sessionDigest: string, now: number): void {
    this.ctx.storage.sql.exec(
      "UPDATE web_sessions SET revoked_at = ? WHERE session_digest = ? AND revoked_at IS NULL",
      now,
      sessionDigest,
    );
  }
}
