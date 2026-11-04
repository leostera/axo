import { ASSET_LIMITS, assetSchema, assetTypeOf, type Attachment } from "@axo/protocol";

/**
 * Uploading files to the account's assets (RFD0030), so a prompt can carry them. A file is named
 * by the SHA-256 of its bytes: the browser hashes it, then PUTs it; the account answers 200 if it
 * already had it. A prompt is sent only once each of its files has answered.
 */

export type UploadAsset = (file: Blob, name: string) => Promise<Attachment>;

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

/** Uploads one file with the browser's session cookie; what a prompt names it by. */
export function assetUploader(baseUrl: string): UploadAsset {
  return async (file, name) => {
    if (file.size > ASSET_LIMITS.assetBytes) throw new Error("Files can be at most 100 MB.");
    const bytes = await file.arrayBuffer();
    const hash = hex(await crypto.subtle.digest("SHA-256", bytes));
    const mimeType = assetTypeOf(file.type);
    const response = await fetch(new URL(`/api/v1/account/assets/${hash}`, baseUrl), {
      method: "PUT",
      credentials: "include",
      cache: "no-store",
      headers: { "Content-Type": mimeType, "X-Axo-Asset-Name": encodeURIComponent(name) },
      body: bytes,
    });
    const payload = (await response.json().catch(() => null)) as { error?: string } | null;
    if (!response.ok) throw new Error(payload?.error ?? `Upload failed (${response.status})`);
    const asset = assetSchema.parse(payload);
    return { asset: asset.asset, name: asset.name, mimeType: asset.mimeType, size: asset.size };
  };
}

/** A file name the account takes: no slashes or control characters, at most 255 bytes. */
export function safeFileName(name: string): string {
  const cleaned = name.replace(/[/\\\p{Cc}]/gu, "_").trim();
  const bounded = [...cleaned].reduce((kept, character) =>
    new TextEncoder().encode(kept + character).length <= ASSET_LIMITS.nameBytes ? kept + character : kept, "");
  return bounded === "" || bounded === "." || bounded === ".." ? "file" : bounded;
}
