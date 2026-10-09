import { AwsClient } from "aws4fetch";
import type { SharedFile } from "../../shared/files";
import { FileFault } from "../../shared/files";
interface UploadLease { file: SharedFile; key: string; expiresAt: number }

export interface FileSigningConfig {
  R2_ACCOUNT_ID: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  R2_BUCKET_NAME: string;
}

/** A bearer capability: return only to the authorized caller, never persist or log it. */
export async function signFileUpload(lease: UploadLease, principalExpiresAt: number, config: FileSigningConfig) {
  const expiresAt = Math.min(lease.expiresAt, principalExpiresAt);
  const seconds = Math.floor((expiresAt - Date.now()) / 1000);
  if (seconds < 1) throw new FileFault(403, "Upload authorization expired. Sign in again.");
  if (!/^[a-f0-9]{32}$/.test(config.R2_ACCOUNT_ID) || !config.R2_ACCESS_KEY_ID || !config.R2_SECRET_ACCESS_KEY) {
    throw new FileFault(503, "Direct file uploads are not configured.");
  }
  const headers = uploadHeaders(lease.file);
  const url = new URL(`https://${config.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${config.R2_BUCKET_NAME}/${lease.key}`);
  url.searchParams.set("X-Amz-Expires", String(seconds));
  const signer = new AwsClient({ accessKeyId: config.R2_ACCESS_KEY_ID, secretAccessKey: config.R2_SECRET_ACCESS_KEY, region: "auto", service: "s3" });
  const signed = await signer.sign(url, { method: "PUT", headers, aws: { signQuery: true, allHeaders: true } });
  return { file: lease.file, upload: { url: signed.url, headers, expiresAt } };
}

export function uploadHeaders(file: SharedFile): Record<string, string> {
  if (!/^[a-f0-9]{64}$/.test(file.sha256)) throw new FileFault(400, "Invalid file checksum.");
  const bytes = Array.from({ length: 32 }, (_, index) => Number.parseInt(file.sha256.slice(index * 2, index * 2 + 2), 16));
  return {
    "Content-Type": file.mediaType,
    "Content-Length": String(file.byteLength),
    "If-None-Match": "*",
    "x-amz-checksum-sha256": btoa(String.fromCharCode(...bytes)),
  };
}
