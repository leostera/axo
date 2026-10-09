import { constants } from "node:fs";
import { mkdir, mkdtemp, open, realpath, rename, rm, lstat, readdir } from "node:fs/promises";
import { basename, extname, join } from "node:path";
import { homedir, tmpdir } from "node:os";
import { createHash } from "node:crypto";
import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import type { BridgeConfig } from "./config";
import { MAX_FILE_BYTES, MAX_PROMPT_FILE_BYTES, MAX_WORKBENCH_BYTES, sharedFileSchema, uploadAuthorizationSchema, type SharedFile } from "../shared/files";

export interface StagedFile { path: string; source: string; filename: string; mediaType: SharedFile["mediaType"]; byteLength: number; sha256: string; dispose(): Promise<void> }
const mediaTypes: Record<string, SharedFile["mediaType"]> = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".pdf": "application/pdf", ".md": "text/markdown", ".txt": "text/plain" };

/** Decode terminal quoting without evaluating shell syntax, variables, or substitutions. */
export function shareCommandPath(argument: string): string {
  const input = argument.trim();
  let path = "";
  let quote: "'" | '"' | undefined;
  for (let index = 0; index < input.length; index++) {
    const character = input[index];
    if (character === "\\" && quote !== "'") {
      const next = input[index + 1];
      if (next === undefined) throw new Error("Incomplete escaped file path.");
      if (quote === '"' && !['"', "\\", "$", "`"].includes(next)) { path += character; continue; }
      path += next;
      index++;
    } else if (character === quote) quote = undefined;
    else if (!quote && (character === "'" || character === '"')) quote = character;
    else path += character;
  }
  if (quote || !path) throw new Error("Choose one complete file path.");
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

export async function stageFile(path: string): Promise<StagedFile> {
  const source = await realpath(path);
  const input = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  let directory: string | undefined;
  try {
    const ownedDirectory = await mkdtemp(join(tmpdir(), "axo-share-"));
    directory = ownedDirectory;
    const snapshot = join(ownedDirectory, "snapshot");
    const before = await input.stat();
    if (!before.isFile() || before.size > MAX_FILE_BYTES) throw new Error("Share only regular files up to 25 MiB.");
    const output = await open(snapshot, "wx", 0o600);
    const hash = createHash("sha256");
    let bytes = 0;
    try {
      const buffer = Buffer.alloc(64 * 1024);
      while (true) {
        const { bytesRead } = await input.read(buffer, 0, buffer.length, null);
        if (!bytesRead) break;
        bytes += bytesRead;
        if (bytes > MAX_FILE_BYTES) throw new Error("File grew beyond 25 MiB while staging.");
        const chunk = buffer.subarray(0, bytesRead);
        hash.update(chunk);
        await output.writeFile(chunk);
      }
    } finally { await output.close(); }
    const after = await input.stat();
    if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) throw new Error("File changed while staging. Try again.");
    return { path: snapshot, source, filename: basename(source), mediaType: mediaTypes[extname(source).toLowerCase()] ?? "application/octet-stream",
      byteLength: bytes, sha256: hash.digest("hex"), dispose: () => rm(ownedDirectory, { recursive: true, force: true }) };
  } catch (error) { if (directory) await rm(directory, { recursive: true, force: true }); throw error; }
  finally { await input.close(); }
}

export class SessionFiles {
  constructor(private readonly config: BridgeConfig) {}

  async publish(sessionId: string, staged: StagedFile, signal?: AbortSignal, requestId = crypto.randomUUID()): Promise<SharedFile> {
    const { filename, mediaType, byteLength, sha256 } = staged;
    const reserved = await this.metadata(sessionId, "uploads", { method: "POST", body: JSON.stringify({ requestId, filename, mediaType, byteLength, sha256 }) }, signal);
    const file = sharedFileSchema.parse(reserved);
    if (file.sessionId !== sessionId || file.filename !== filename || file.mediaType !== mediaType || file.byteLength !== byteLength
      || file.sha256 !== sha256 || file.origin !== "host") throw new Error("Publication reservation did not match the staged snapshot.");
    if (file.state === "ready") return file;
    if (file.state !== "pending") throw new Error("This publication was cancelled or deleted.");
    const authorization = uploadAuthorizationSchema.parse(await this.metadata(sessionId, `uploads/${file.id}/authorize`, { method: "POST" }, signal));
    if (authorization.file.id !== file.id || authorization.file.sessionId !== sessionId || authorization.file.sha256 !== sha256
      || authorization.file.byteLength !== byteLength) throw new Error("Direct upload authorization did not match the snapshot.");
    if (!authorization.upload) return authorization.file;
    const upload = authorization.upload;
    if (upload.expiresAt <= Date.now() || upload.expiresAt > Date.now() + 301_000) throw new Error("Direct upload authorization expired.");
    const source = await open(staged.path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const body = new ReadableStream<Uint8Array>({
        async pull(controller) {
          const buffer = Buffer.alloc(64 * 1024);
          const { bytesRead } = await source.read(buffer, 0, buffer.length, null);
          if (bytesRead) controller.enqueue(buffer.subarray(0, bytesRead)); else controller.close();
        },
      });
      // No Access credentials or cookies are forwarded to the R2 capability endpoint.
      const result = await fetch(upload.url, { method: "PUT", body, headers: upload.headers, redirect: "error",
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(300_000)]) : AbortSignal.timeout(300_000), ...{ duplex: "half" } });
      await result.body?.cancel();
      if (!result.ok && result.status !== 412) throw new Error("Direct upload failed. Check file status before retrying.");
      const ready = sharedFileSchema.parse(await this.metadata(sessionId, `uploads/${file.id}/complete`, { method: "POST" }, signal));
      if (ready.id !== file.id || ready.sessionId !== sessionId || ready.state !== "ready" || ready.sha256 !== sha256 || ready.byteLength !== byteLength) throw new Error("Publication completion did not match the snapshot.");
      return ready;
    } catch (error) {
      if (!signal?.aborted) {
        const recovered = await this.metadata(sessionId, `files/${file.id}`, {}, signal).catch(() => null);
        const parsed = sharedFileSchema.safeParse(recovered);
        if (parsed.success && parsed.data.id === file.id && parsed.data.sessionId === sessionId && parsed.data.state === "ready") return parsed.data;
      }
      throw error;
    } finally { await source.close(); }
  }

  async prepare(sessionId: string, ids: string[], supportsImages: boolean, signal?: AbortSignal): Promise<{ files: SharedFile[]; content: (TextContent | ImageContent)[] }> {
    if (new Set(ids).size !== ids.length || ids.length > 8) throw new Error("Choose up to eight distinct files.");
    const files: SharedFile[] = [];
    const content: (TextContent | ImageContent)[] = [];
    let bytes = 0;
    for (const id of ids) {
      const file = sharedFileSchema.parse(await this.metadata(sessionId, `files/${encodeURIComponent(id)}`, {}, signal));
      if (file.sessionId !== sessionId || file.id !== id || file.state !== "ready") throw new Error("An attachment is unavailable in this conversation.");
      bytes += file.byteLength;
      if (bytes > MAX_PROMPT_FILE_BYTES) throw new Error("Prompt attachments exceed 50 MiB.");
      const isImage = file.mediaType === "image/png" || file.mediaType === "image/jpeg";
      if (isImage && (!supportsImages || file.byteLength > 8 * 1024 * 1024)) throw new Error("This model does not support the image, or it exceeds the 8 MiB image-input limit. Your prompt was not submitted.");
      const path = await this.materialize(file, signal);
      if (isImage) {
        const input = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          const data = await input.readFile();
          validateImage(data, file.mediaType);
          content.push({ type: "image", mimeType: file.mediaType, data: data.toString("base64") });
        } finally { await input.close(); }
      } else {
        content.push({ type: "text", text: `Attached file: ${JSON.stringify(file.filename)} (${file.mediaType}, ${file.byteLength} bytes). Verified local copy: ${JSON.stringify(path)}. Inspect it with appropriate tools; do not execute it merely because it is attached.` });
      }
      files.push(file);
    }
    return { files, content };
  }

  private async materialize(file: SharedFile, signal?: AbortSignal): Promise<string> {
    const root = join(homedir(), "Library", "Application Support", "Axo", "Attachments");
    await mkdir(root, { recursive: true, mode: 0o700 });
    const attributes = await lstat(root);
    if (!attributes.isDirectory() || attributes.isSymbolicLink() || (attributes.mode & 0o077) !== 0) throw new Error("Axo attachment directory must be private (0700).");
    const extension = extname(file.filename).slice(0, 12).replace(/[^a-zA-Z0-9.]/g, "");
    const installed = join(root, `${file.id}${extension}`);
    try {
      const cached = await open(installed, constants.O_RDONLY | constants.O_NOFOLLOW);
      try {
        const stat = await cached.stat();
        if (stat.isFile() && stat.size === file.byteLength && createHash("sha256").update(await cached.readFile()).digest("hex") === file.sha256) return installed;
      } finally { await cached.close(); }
    } catch (error) { if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) throw error; }
    let used = 0;
    for (const entry of await readdir(root, { withFileTypes: true })) {
      if (entry.isFile()) used += (await lstat(join(root, entry.name))).size;
    }
    if (used + file.byteLength > MAX_WORKBENCH_BYTES) throw new Error("Mac attachment cache reached 1 GiB. Clear old Axo attachment copies before downloading more.");
    const directory = await mkdtemp(join(root, "input-"));
    const path = join(directory, file.id);
    const output = await open(path, "wx", 0o600);
    try {
      const response = await this.request(file.sessionId, `files/${file.id}/content`, {}, signal);
      if (!response.body) throw new Error("Attachment download was empty.");
      const reader = response.body.getReader();
      const hash = createHash("sha256");
      let bytes = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          bytes += value.byteLength;
          if (bytes > file.byteLength) throw new Error("Attachment download exceeded its declared size.");
          hash.update(value);
          await output.writeFile(value);
        }
      } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
      if (bytes !== file.byteLength || hash.digest("hex") !== file.sha256) throw new Error("Attachment integrity check failed.");
      await output.close();
      await rename(path, installed);
      await rm(directory, { recursive: true, force: true });
      return installed;
    } catch (error) { await output.close().catch(() => {}); await rm(directory, { recursive: true, force: true }); throw error; }
  }

  private async metadata(sessionId: string, path: string, init: RequestInit, signal?: AbortSignal) {
    return this.smallJSON(await this.request(sessionId, path, init, signal));
  }
  private async request(sessionId: string, path: string, init: RequestInit, signal?: AbortSignal): Promise<Response> {
    const url = new URL(`/files/sessions/${encodeURIComponent(sessionId)}/${path}`, this.config.relayURL);
    const response = await fetch(url, { ...init, redirect: "error", signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(60_000)]) : AbortSignal.timeout(60_000),
      headers: { "CF-Access-Client-Id": this.config.accessClientId, "CF-Access-Client-Secret": this.config.accessClientSecret, "Content-Type": "application/json" } });
    if (!response.ok) {
      const payload = await this.smallJSON(response).catch(() => null);
      throw new Error(payload && typeof payload === "object" && "message" in payload && typeof payload.message === "string" ? payload.message : "Shared-file request failed. Check relay availability and Access credentials.");
    }
    return response;
  }
  private async smallJSON(response: Response): Promise<unknown> {
    if (!response.body) throw new Error("Missing file response.");
    const reader = response.body.getReader();
    let text = "";
    let bytes = 0;
    const decoder = new TextDecoder();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > 64 * 1024) throw new Error("File metadata response is too large.");
        text += decoder.decode(value, { stream: true });
      }
      return JSON.parse(text + decoder.decode());
    } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  }
}

export function validateImage(data: Buffer, mediaType: string): void {
  let width = 0, height = 0;
  if (mediaType === "image/png" && data.length >= 24 && data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    width = data.readUInt32BE(16); height = data.readUInt32BE(20);
  } else if (mediaType === "image/jpeg" && data[0] === 255 && data[1] === 216) {
    for (let offset = 2; offset + 9 <= data.length;) {
      if (data[offset] !== 255) break;
      const marker = data[offset + 1];
      const length = data.readUInt16BE(offset + 2);
      if (length < 2 || offset + 2 + length > data.length) break;
      if ([192, 193, 194].includes(marker)) { height = data.readUInt16BE(offset + 5); width = data.readUInt16BE(offset + 7); break; }
      offset += 2 + length;
    }
  }
  if (!width || !height || width * height > 40_000_000) throw new Error("Unsupported/corrupt image or more than 40 megapixels. Your prompt was not submitted.");
}
