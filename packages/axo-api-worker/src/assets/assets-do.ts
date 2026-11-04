import { DurableObject } from "cloudflare:workers";
import { ASSET_LIMITS, assetListSchema, type Asset, type AssetList, type AssetType } from "@axo/protocol";
import { assetCacheTag, assetKey } from "./keys";

/**
 * One account's assets (RFD0030, specs/assets.ts, specs/asset-quota.ts): the index and the quota.
 * The bytes are in R2 under the account's prefix; the gateway streams uploads there itself.
 *
 * An asset is `reserved` while its bytes go to R2, `ready` once committed, `deleting` while R2
 * deletes it and `deleted` after. Rows are kept when deleted so versions only grow.
 */

type State = "reserved" | "ready" | "deleting" | "deleted";
type Row = {
  hash: string;
  size: number;
  type: AssetType;
  name: string;
  created_at: number;
  created_by: string;
  state: State;
  version: number;
  reserved_until: number | null;
};

export type Reservation =
  | { answer: "reserved"; version: number }
  | { answer: "exists"; asset: Asset }
  | { answer: "busy" }
  | { answer: "quota" };

export type Commit = { ok: true; asset: Asset } | { ok: false };
export type Removal = "deleted" | "notFound" | "conflict" | "busy";

export type ReserveInput = { hash: string; size: number; type: AssetType; name: string; createdBy: string };

/** What AxoAssetsDO needs from the Worker: R2, and the cached entrypoint to purge. */
type AssetsEnv = { AXO_ASSETS: R2Bucket };
type CachePurger = { purge(hash: string): Promise<boolean> };
type Loopback = { AxoAssetCache?: (options: { props: { accountId: string } }) => CachePurger };

export class AxoAssetsDO extends DurableObject<AssetsEnv> {
  private readonly sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: AssetsEnv) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS assets (
      hash TEXT PRIMARY KEY, size INTEGER NOT NULL, type TEXT NOT NULL, name TEXT NOT NULL,
      created_at INTEGER NOT NULL, created_by TEXT NOT NULL, state TEXT NOT NULL,
      version INTEGER NOT NULL, reserved_until INTEGER)`);
    this.sql.exec("CREATE INDEX IF NOT EXISTS assets_by_time ON assets (state, created_at)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS late_purges (hash TEXT PRIMARY KEY, at INTEGER NOT NULL)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
  }

  /** Reserves an upload against the quota, or answers that it is already here, busy or over quota. */
  async reserve(accountId: string, input: ReserveInput, now = Date.now()): Promise<Reservation> {
    this.bind(accountId);
    this.releaseExpired(now);
    const row = this.row(input.hash);
    if (row?.state === "ready") {
      // Every upload that succeeds raises the version, so an older delete can't remove it.
      this.sql.exec("UPDATE assets SET version = version + 1 WHERE hash = ?", input.hash);
      return { answer: "exists", asset: toAsset({ ...row, version: row.version + 1 }) };
    }
    if (row?.state === "reserved" || row?.state === "deleting") return { answer: "busy" };
    const usage = this.usage();
    if (usage.assets + 1 > ASSET_LIMITS.accountAssets || usage.bytes + input.size > ASSET_LIMITS.accountBytes)
      return { answer: "quota" };
    const version = (row?.version ?? 0) + 1;
    this.sql.exec(`INSERT INTO assets (hash, size, type, name, created_at, created_by, state, version, reserved_until)
      VALUES (?, ?, ?, ?, ?, ?, 'reserved', ?, ?)
      ON CONFLICT (hash) DO UPDATE SET size = excluded.size, type = excluded.type, name = excluded.name,
        created_at = excluded.created_at, created_by = excluded.created_by, state = 'reserved',
        version = excluded.version, reserved_until = excluded.reserved_until`,
      input.hash, input.size, input.type, input.name, now, input.createdBy, version, now + ASSET_LIMITS.reservationMs);
    await this.schedule();
    return { answer: "reserved", version };
  }

  /**
   * Marks a reserved upload ready once its bytes are in R2, or releases it. A reservation the
   * alarm already released can't be committed: the upload fails rather than vanish later.
   */
  async commit(accountId: string, hash: string, stored: boolean, now = Date.now()): Promise<Commit> {
    this.bind(accountId);
    const row = this.row(hash);
    if (row?.state !== "reserved" || (row.reserved_until ?? 0) <= now) {
      if (row?.state === "reserved") this.sql.exec("UPDATE assets SET state = 'deleted', reserved_until = NULL WHERE hash = ?", hash);
      return { ok: false };
    }
    if (!stored) {
      this.sql.exec("UPDATE assets SET state = 'deleted', reserved_until = NULL WHERE hash = ?", hash);
      return { ok: false };
    }
    this.sql.exec("UPDATE assets SET state = 'ready', reserved_until = NULL WHERE hash = ?", hash);
    return { ok: true, asset: toAsset({ ...row, state: "ready" }) };
  }

  /** A ready asset, or null. */
  async head(accountId: string, hash: string): Promise<Asset | null> {
    this.bind(accountId);
    const row = this.row(hash);
    return row?.state === "ready" ? toAsset(row) : null;
  }

  /** The account's ready assets, newest first. */
  async list(accountId: string, before: number | null, limit: number = ASSET_LIMITS.pageSize): Promise<AssetList> {
    this.bind(accountId);
    const size = Math.max(1, Math.min(limit, ASSET_LIMITS.pageSize));
    const rows = this.sql.exec<Row>(
      `SELECT * FROM assets WHERE state = 'ready' AND created_at < ? ORDER BY created_at DESC, hash LIMIT ?`,
      before ?? Number.MAX_SAFE_INTEGER, size + 1,
    ).toArray();
    const page = rows.slice(0, size);
    const next = rows.length > size ? String(page.at(-1)!.created_at) : null;
    return assetListSchema.parse({ assets: page.map(toAsset), next, usage: this.usage() });
  }

  /**
   * Deletes the version the person saw. The asset is `deleting` until R2 has deleted its bytes,
   * so a re-upload can't commit bytes that the delete then removes. Then its cache tag is purged,
   * now and again later, for a read that stored it after the first purge.
   */
  async remove(accountId: string, hash: string, version: number, now = Date.now()): Promise<Removal> {
    this.bind(accountId);
    const row = this.row(hash);
    if (row?.state === "deleting" || row?.state === "reserved") return "busy";
    if (row?.state !== "ready") return "notFound";
    if (row.version !== version) return "conflict";
    this.sql.exec("UPDATE assets SET state = 'deleting' WHERE hash = ?", hash);
    try {
      await this.env.AXO_ASSETS.delete(assetKey(accountId, hash));
    } catch (error) {
      this.sql.exec("UPDATE assets SET state = 'ready' WHERE hash = ? AND state = 'deleting'", hash);
      throw error;
    }
    this.sql.exec("UPDATE assets SET state = 'deleted' WHERE hash = ? AND state = 'deleting'", hash);
    this.sql.exec("INSERT INTO late_purges (hash, at) VALUES (?, ?) ON CONFLICT (hash) DO UPDATE SET at = excluded.at",
      hash, now + ASSET_LIMITS.latePurgeMs);
    await this.schedule();
    await this.purge(accountId, hash);
    return "deleted";
  }

  /** Releases reservations past their time, and runs the purges that are due. */
  override async alarm(): Promise<void> {
    const now = Date.now();
    this.releaseExpired(now);
    const accountId = this.account();
    const due = this.sql.exec<{ hash: string }>("SELECT hash FROM late_purges WHERE at <= ?", now).toArray();
    for (const { hash } of due) {
      if (accountId && !(await this.purge(accountId, hash))) continue;
      this.sql.exec("DELETE FROM late_purges WHERE hash = ? AND at <= ?", hash, now);
    }
    await this.schedule();
  }

  private releaseExpired(now: number): void {
    this.sql.exec("UPDATE assets SET state = 'deleted', reserved_until = NULL WHERE state = 'reserved' AND reserved_until <= ?", now);
  }

  /** Sets the alarm for the next reservation to expire or purge to run. */
  private async schedule(): Promise<void> {
    const next = this.sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM (
      SELECT reserved_until AS at FROM assets WHERE state = 'reserved'
      UNION ALL SELECT at FROM late_purges)`).one().at;
    if (next === null) return;
    const current = await this.ctx.storage.getAlarm();
    // A failed purge leaves its row due: try again in a minute rather than spin.
    const at = Math.max(next, Date.now() + 1_000);
    if (current === null || current > at) await this.ctx.storage.setAlarm(at);
  }

  private async purge(accountId: string, hash: string): Promise<boolean> {
    const exports = this.ctx.exports as unknown as Loopback;
    if (!exports.AxoAssetCache) return true;
    try {
      return await exports.AxoAssetCache({ props: { accountId } }).purge(hash);
    } catch (error) {
      console.error(JSON.stringify({ event: "assets.purge_failed", accountId, tag: assetCacheTag(accountId, hash), error: String(error) }));
      return false;
    }
  }

  private usage(): { bytes: number; assets: number } {
    const row = this.sql.exec<{ bytes: number | null; assets: number }>(
      "SELECT SUM(size) AS bytes, COUNT(*) AS assets FROM assets WHERE state IN ('reserved', 'ready', 'deleting')",
    ).one();
    return { bytes: row.bytes ?? 0, assets: row.assets };
  }

  private row(hash: string): Row | null {
    return this.sql.exec<Row>("SELECT * FROM assets WHERE hash = ?", hash).toArray()[0] ?? null;
  }

  /** This object belongs to one account: the first call records it, and any other is refused. */
  private bind(accountId: string): void {
    if (!/^[0-9a-f-]{36}$/.test(accountId)) throw new Error("invalid account");
    const known = this.account();
    if (known === null) this.sql.exec("INSERT INTO meta (key, value) VALUES ('account', ?)", accountId);
    else if (known !== accountId) throw new Error("this AxoAssetsDO belongs to another account");
  }

  private account(): string | null {
    return this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'account'").toArray()[0]?.value ?? null;
  }
}

function toAsset(row: Row): Asset {
  return {
    asset: `sha256:${row.hash}`,
    name: row.name,
    mimeType: row.type,
    size: row.size,
    createdAt: new Date(row.created_at).toISOString(),
    version: row.version,
  };
}
