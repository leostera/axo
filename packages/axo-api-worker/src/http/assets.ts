import { ASSET_LIMITS, assetDeleteSchema, assetHexSchema, assetNameSchema, assetTypeOf, INLINE_ASSET_TYPES, uuid, hostIdSchema, type Asset, type AssetList } from "@axo/protocol";
import { json, requireAccount, type AuthExports } from "../auth/account-access";
import type { AuthEnvironment } from "../auth/config";
import type { Commit, Removal, Reservation, ReserveInput } from "../assets/assets-do";
import { assetKey, assetsDOName } from "../assets/keys";

/**
 * Assets over HTTPS (RFD0030, specs/assets/assets.ts). This is the gateway: it runs on every request,
 * authenticates the caller, and reads through the cached `AxoAssetCache` entrypoint with a
 * request that carries nothing of the caller's.
 *
 * A person uses `/api/v1/account/assets/<hash>`; a Mac uses
 * `/api/v1/accounts/<account>/hosts/<host>/assets/<hash>` with its host credential.
 */

type AssetsStub = {
  reserve(accountId: string, input: ReserveInput): Promise<Reservation>;
  commit(accountId: string, hash: string, stored: boolean): Promise<Commit>;
  head(accountId: string, hash: string): Promise<Asset | null>;
  list(accountId: string, before: number | null, limit?: number): Promise<AssetList>;
  remove(accountId: string, hash: string, version: number): Promise<Removal>;
};
type CacheFetcher = { fetch(request: Request): Promise<Response> };
type AssetsExports = {
  AxoAssetsDO: { getByName(name: string): AssetsStub };
  AxoAssetCache: (options: { props: { accountId: string } }) => CacheFetcher;
  AxoAccountDirectory: { getByName(name: string): unknown };
};
type HostAuthorizer = { authorizeHost(hostId: string, credentialId: string, credential: string): Promise<boolean> };
type AssetsEnvironment = AuthEnvironment & { AXO_ASSETS: R2Bucket };

/** Who an upload or read is for. */
type Caller = { accountId: string; by: string };

const privateNoStore = { "Cache-Control": "private, no-store" };

function exportsOf(ctx: ExecutionContext): AssetsExports {
  return ctx.exports as unknown as AssetsExports;
}

function stub(ctx: ExecutionContext, accountId: string): AssetsStub {
  return exportsOf(ctx).AxoAssetsDO.getByName(assetsDOName(accountId));
}

function log(event: string, fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ event, ...fields }));
}

export type AssetRoute = "list" | "asset" | "delete";

/** A person's routes: the list, one asset (PUT, HEAD, GET) and its delete. */
export async function serveAccountAssets(
  request: Request,
  env: AssetsEnvironment,
  exports: AuthExports,
  ctx: ExecutionContext,
  route: AssetRoute,
  rawHash?: string,
): Promise<Response> {
  const reads = route === "list" || (route === "asset" && (request.method === "GET" || request.method === "HEAD"));
  const caller = await requireAccount(request, env, exports, reads ? "read" : "change");
  if (caller instanceof Response) return caller;
  const who: Caller = { accountId: caller.accountId, by: `person:${caller.via}` };
  if (route === "list") {
    if (request.method !== "GET") return json({ error: "Method not allowed" }, 405, { Allow: "GET" });
    const before = new URL(request.url).searchParams.get("before");
    const cursor = before === null ? null : Number(before);
    if (cursor !== null && !Number.isSafeInteger(cursor)) return json({ error: "Invalid cursor" }, 400);
    return json(await stub(ctx, who.accountId).list(who.accountId, cursor));
  }
  const hash = assetHexSchema.safeParse(rawHash);
  if (!hash.success) return json({ error: "Invalid asset" }, 400);
  if (route === "delete") {
    if (request.method !== "POST") return json({ error: "Method not allowed" }, 405, { Allow: "POST" });
    const body = assetDeleteSchema.safeParse(await request.json().catch(() => null));
    if (!body.success) return json({ error: "Invalid delete" }, 400);
    const outcome = await stub(ctx, who.accountId).remove(who.accountId, hash.data, body.data.version);
    log("assets.delete", { accountId: who.accountId, hash: hash.data, by: who.by, outcome });
    if (outcome === "deleted") return json({ deleted: true });
    if (outcome === "notFound") return json({ error: "No such asset", code: "notFound" }, 404);
    return json({ error: outcome === "busy" ? "The asset is busy; try again" : "The asset changed since you saw it", code: outcome }, 409);
  }
  return serveAsset(request, env, ctx, who, hash.data);
}

/** A Mac's routes: one asset, with its host credential. */
export async function serveHostAssets(
  request: Request,
  env: AssetsEnvironment,
  ctx: ExecutionContext,
  rawAccountId: string,
  rawHostId: string,
  rawHash: string,
): Promise<Response> {
  if (request.headers.has("Origin")) return json({ error: "Origin not allowed" }, 403);
  const accountId = uuid.safeParse(rawAccountId);
  const hostId = hostIdSchema.safeParse(rawHostId);
  const hash = assetHexSchema.safeParse(rawHash);
  if (!accountId.success || !hostId.success || !hash.success) return json({ error: "Invalid asset" }, 400);
  const credential = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "")?.[1];
  const credentialId = request.headers.get("X-Axo-Credential-Id") ?? "";
  if (!credential || !uuid.safeParse(credentialId).success) return json({ error: "Host authentication required" }, 401);
  const account = exportsOf(ctx).AxoAccountDirectory.getByName(accountId.data) as HostAuthorizer;
  if (!(await account.authorizeHost(hostId.data, credentialId, credential))) return json({ error: "Host authentication required" }, 401);
  return serveAsset(request, env, ctx, { accountId: accountId.data, by: `host:${hostId.data}` }, hash.data);
}

async function serveAsset(request: Request, env: AssetsEnvironment, ctx: ExecutionContext, who: Caller, hash: string): Promise<Response> {
  switch (request.method) {
    case "PUT":
      return upload(request, env, ctx, who, hash);
    case "HEAD": {
      const asset = await stub(ctx, who.accountId).head(who.accountId, hash);
      return new Response(null, { status: asset ? 200 : 404, headers: asset ? { ...privateNoStore, "X-Axo-Asset-Version": String(asset.version) } : privateNoStore });
    }
    case "GET":
      return read(ctx, who, hash);
    default:
      return json({ error: "Method not allowed" }, 405, { Allow: "GET, HEAD, PUT" });
  }
}

/** Reserve, stream to R2 (which checks the hash), commit; `200` only once the commit is acked. */
async function upload(request: Request, env: AssetsEnvironment, ctx: ExecutionContext, who: Caller, hash: string): Promise<Response> {
  const size = Number(request.headers.get("Content-Length") ?? "");
  if (!Number.isSafeInteger(size) || size < 0) return json({ error: "Content-Length is required", code: "invalid" }, 411);
  if (size > ASSET_LIMITS.assetBytes) return json({ error: "An asset is at most 100 MiB", code: "tooLarge" }, 413);
  let rawName = "";
  try {
    rawName = decodeURIComponent(request.headers.get("X-Axo-Asset-Name") ?? "");
  } catch {
    return json({ error: "Invalid file name", code: "invalid" }, 400);
  }
  const name = assetNameSchema.safeParse(rawName);
  if (!name.success) return json({ error: "Invalid file name", code: "invalid" }, 400);
  const type = assetTypeOf(request.headers.get("Content-Type"));
  const assets = stub(ctx, who.accountId);
  const reservation = await assets.reserve(who.accountId, { hash, size, type, name: name.data, createdBy: who.by });
  const fields = { accountId: who.accountId, hash, bytes: size, by: who.by };
  if (reservation.answer === "exists") {
    log("assets.upload", { ...fields, outcome: "exists" });
    return json(reservation.asset);
  }
  if (reservation.answer === "busy") return json({ error: "The asset is busy; try again", code: "busy" }, 409);
  if (reservation.answer === "quota") {
    log("assets.upload", { ...fields, outcome: "quota" });
    return json({ error: "The account's assets are full", code: "quota" }, 413);
  }
  let stored = false;
  let mismatch = false;
  try {
    await env.AXO_ASSETS.put(assetKey(who.accountId, hash), request.body, {
      sha256: hash,
      httpMetadata: { contentType: type },
    });
    stored = true;
  } catch (error) {
    // R2 refuses bytes whose SHA-256 isn't the name; a short body fails too.
    mismatch = /sha|checksum|digest/i.test(String(error));
    log("assets.store_failed", { ...fields, error: String(error) });
  }
  const commit = await assets.commit(who.accountId, hash, stored);
  if (!commit.ok) {
    log("assets.upload", { ...fields, outcome: stored ? "late" : mismatch ? "mismatch" : "failed" });
    if (mismatch) return json({ error: "The bytes don't match the asset's name", code: "mismatch" }, 400);
    return json({ error: "The upload did not complete; try again", code: "invalid" }, stored ? 409 : 400);
  }
  log("assets.upload", { ...fields, outcome: "stored" });
  return json(commit.asset, 201);
}

/** Reads through Workers Cache, then hands the client a private copy it may keep. */
async function read(ctx: ExecutionContext, who: Caller, hash: string): Promise<Response> {
  const cached = await exportsOf(ctx).AxoAssetCache({ props: { accountId: who.accountId } })
    .fetch(new Request(`https://assets.internal/${hash}`));
  if (!cached.ok) return json({ error: "No such asset", code: "notFound" }, 404);
  const type = cached.headers.get("Content-Type") ?? "application/octet-stream";
  const name = cached.headers.get("X-Axo-Asset-Name") ?? hash;
  const headers = new Headers({
    "Content-Type": type,
    "Cache-Control": "private, max-age=31536000, immutable",
    ETag: `"${hash}"`,
    // Only images that can't run script are shown inline; everything else downloads.
    "Content-Disposition": `${INLINE_ASSET_TYPES.has(type) ? "inline" : "attachment"}; filename*=UTF-8''${name}`,
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; sandbox",
    "X-Axo-Asset-Name": name,
  });
  const length = cached.headers.get("Content-Length");
  if (length) headers.set("Content-Length", length);
  return new Response(cached.body, { status: 200, headers });
}
