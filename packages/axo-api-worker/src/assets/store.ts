import { ASSET_LIMITS, assetNameSchema, assetTypeOf, type Asset, type AssetList, type Attachment, type SavedFile } from "@axo/protocol";
import type { Commit, Reservation, ReserveInput } from "./assets-do";
import { assetKey, assetsDOName } from "./keys";

/**
 * One account's assets as the cloud itself writes and reads them (RFD0030, Assets from scripts):
 * a script's `codemode.assets` tools, and app tools that store a file they fetched (a Gmail
 * attachment) instead of handing its bytes to the script.
 *
 * A save is an upload the Worker makes: the bytes are hashed, reserved against the quota in the
 * account's AxoAssetsDO, put to R2 under their hash (which R2 checks), and committed. It is
 * refused, never partial, like a person's upload.
 */
export type AccountAssets = {
  /** Stores `bytes` as an asset of the account, or answers the one already there. */
  save(file: { name: string; mimeType: string; bytes: Uint8Array<ArrayBuffer> }, by: string): Promise<Asset>;
  head(hash: string): Promise<Asset | null>;
  list(before: number | null, limit?: number): Promise<AssetList>;
  /** `length` bytes from `offset`, or null if the asset is not in the account. */
  read(hash: string, offset: number, length: number): Promise<{ asset: Asset; bytes: Uint8Array } | null>;
};

/** Why a save was refused; the message says it in plain words. */
export class AssetRefused extends Error {}

type AssetsStub = {
  reserve(accountId: string, input: ReserveInput): Promise<Reservation>;
  commit(accountId: string, hash: string, stored: boolean): Promise<Commit>;
  head(accountId: string, hash: string): Promise<Asset | null>;
  list(accountId: string, before: number | null, limit?: number): Promise<AssetList>;
};
type AssetsNamespace = { getByName(name: string): unknown };

/** The address a person opens an asset at, signed in to its account. */
export function assetUrl(hash: string): string {
  return `https://axo.leostera.dev/api/v1/account/assets/${hash}`;
}

/** An asset as a file a script returns: what the Mac's `apps_run` fetches, and its link. */
export function savedFile(asset: Asset): SavedFile {
  const attachment: Attachment = { asset: asset.asset, name: asset.name, mimeType: asset.mimeType, size: asset.size };
  return { type: "file", attachment, url: assetUrl(asset.asset.slice("sha256:".length)) };
}

export function accountAssets(bucket: R2Bucket, namespace: AssetsNamespace, accountId: string): AccountAssets {
  const index = () => namespace.getByName(assetsDOName(accountId)) as AssetsStub;
  return {
    async save(file, by) {
      if (file.bytes.byteLength > ASSET_LIMITS.assetBytes) throw new AssetRefused("an asset is at most 100 MiB");
      if (!assetNameSchema.safeParse(file.name).success) throw new AssetRefused("a file name has no slashes or control characters and is at most 255 bytes");
      const hash = hex(await crypto.subtle.digest("SHA-256", file.bytes));
      const type = assetTypeOf(file.mimeType);
      const reservation = plain(await index().reserve(accountId, { hash, size: file.bytes.byteLength, type, name: file.name, createdBy: by }));
      if (reservation.answer === "exists") return reservation.asset;
      if (reservation.answer === "busy") throw new AssetRefused("the same file is being stored or deleted right now; try again");
      if (reservation.answer === "quota") throw new AssetRefused("the account's assets are full; the person deletes some under Settings");
      let stored = false;
      try {
        await bucket.put(assetKey(accountId, hash), file.bytes, { sha256: hash, httpMetadata: { contentType: type } });
        stored = true;
      } catch (error) {
        console.error(JSON.stringify({ event: "assets.store_failed", accountId, hash, by, error: String(error) }));
      }
      // Committed either way: a failed store releases its reservation now, not at the alarm.
      const commit = plain(await index().commit(accountId, hash, stored));
      console.log(JSON.stringify({ event: "assets.save", accountId, hash, bytes: file.bytes.byteLength, by, outcome: commit.ok ? "stored" : "failed" }));
      if (!commit.ok) throw new AssetRefused("the file could not be stored; try again");
      return commit.asset;
    },
    async head(hash) {
      return plain(await index().head(accountId, hash));
    },
    async list(before, limit) {
      return plain(await index().list(accountId, before, limit));
    },
    async read(hash, offset, length) {
      const asset = plain(await index().head(accountId, hash));
      if (!asset) return null;
      // An offset at or past the end reads nothing; R2 refuses such a range, so it is not asked.
      if (offset >= asset.size) return { asset, bytes: new Uint8Array() };
      const object = await bucket.get(assetKey(accountId, hash), { range: { offset, length: Math.min(length, asset.size - offset) } });
      if (!object) return null;
      return { asset, bytes: new Uint8Array(await object.arrayBuffer()) };
    },
  };
}

function hex(digest: ArrayBuffer): string {
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** RPC results arrive as proxies; this keeps the plain data. */
function plain<T>(value: T): T {
  return value === null || value === undefined ? value : (JSON.parse(JSON.stringify(value)) as T);
}
