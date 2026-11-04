import { WorkerEntrypoint } from "cloudflare:workers";
import type { Asset } from "@axo/protocol";
import { accountCacheTag, assetCacheTag, assetKey, assetsDOName } from "./keys";

/**
 * The cached read of one account's assets (RFD0030). Workers Cache sits in front of this
 * entrypoint: a hit is answered from the tiered cache without running it. Its props carry the
 * account and are part of the cache key, so one account's entry never answers another.
 *
 * Only the gateway calls it, after authenticating, with a request that carries nothing of the
 * caller's: no cookie, no token. What it answers is the same for everyone in the account.
 */
type Props = { accountId: string };
type AssetsReader = { head(accountId: string, hash: string): Promise<Asset | null> };
type CacheEnv = { AXO_ASSETS: R2Bucket };
type Namespace = { getByName(name: string): AssetsReader };

const IMMUTABLE = "public, max-age=31536000, immutable";

export class AxoAssetCache extends WorkerEntrypoint<CacheEnv, Props> {
  /** `GET /<hash>`: the bytes, cacheable for a year since they never change under their name. */
  override async fetch(request: Request): Promise<Response> {
    const { accountId } = this.ctx.props;
    const hash = new URL(request.url).pathname.slice(1);
    if (!/^[0-9a-f]{64}$/.test(hash) || request.method !== "GET") return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
    const assets = (this.ctx.exports as unknown as { AxoAssetsDO: Namespace }).AxoAssetsDO.getByName(assetsDOName(accountId));
    // The index says whether it is ready; R2 serves the bytes, so a read never queues in the DO.
    const asset = await assets.head(accountId, hash);
    const object = asset ? await this.env.AXO_ASSETS.get(assetKey(accountId, hash)) : null;
    // A miss is never stored: an upload a moment later must be readable at once.
    if (!asset || !object) return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
    const headers = new Headers({
      "Content-Type": asset.mimeType,
      "Content-Length": String(object.size),
      ETag: `"${hash}"`,
      "X-Axo-Asset-Name": encodeURIComponent(asset.name),
    });
    headers.set("Cache-Control", IMMUTABLE);
    headers.set("Cache-Tag", `${assetCacheTag(accountId, hash)},${accountCacheTag(accountId)}`);
    return new Response(object.body, { status: 200, headers });
  }

  /** Purges one asset's cached reads, everywhere; an RPC call, so it never hits the cache itself. */
  async purge(hash: string): Promise<boolean> {
    const cache = this.ctx.cache;
    if (!cache) return true;
    const result = await cache.purge({ tags: [assetCacheTag(this.ctx.props.accountId, hash)] });
    if (!result.success) console.error(JSON.stringify({ event: "assets.purge_failed", errors: result.errors }));
    return result.success;
  }
}
