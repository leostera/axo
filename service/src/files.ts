import type { Relay } from "./index";
import type { Principal } from "./access";
import { signFileUpload, type FileSigningConfig } from "./file-signing";
import { FileFault, fileErrorResponse, sessionFileId, sharedFileIdSchema, uploadRequestSchema } from "../../shared/files";

const PRIVATE_HEADERS = { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" };
type FileRelay = DurableObjectStub<Relay>;
interface FileLocator { sessionId: string; fileId: string }
interface FilePolicy { writesEnabled: boolean }
type FileOperation =
  | { kind: "reserve"; sessionId: string }
  | { kind: "list"; sessionId: string; cursor?: string }
  | { kind: "authorize" | "complete" | "metadata" | "delete" | "download"; file: FileLocator };

/** Called only after public Access authorization. Keys never leave this server boundary. */
export async function handleFiles(request: Request, principal: Principal, relay: FileRelay, bucket: R2Bucket, policy: FilePolicy, signing: FileSigningConfig): Promise<Response> {
  try {
    const operation = parseFileOperation(request);
    await relay.admitFileRequest();
    requireWritableOperation(operation, policy);
    switch (operation.kind) {
      case "reserve": return json(await relay.reserveFile(operation.sessionId, uploadRequestSchema.parse(await boundedJSON(request)), principal.role));
      case "list": return json(await relay.listFiles(operation.sessionId, operation.cursor));
      case "metadata": return json(await relay.getFile(operation.file.sessionId, operation.file.fileId));
      case "delete": return json(await relay.deleteFile(operation.file.sessionId, operation.file.fileId));
      case "authorize": {
        const lease = await relay.beginSignedFileUpload(operation.file.sessionId, operation.file.fileId);
        return json("key" in lease ? await signFileUpload(lease, principal.expiresAt, signing) : lease);
      }
      case "complete": return json(await relay.completeSignedFileUpload(operation.file.sessionId, operation.file.fileId));
      case "download": return await downloadContent(operation.file, relay, bucket);
    }
  } catch (error) {
    if (error instanceof Error && error.name === "ZodError") return fileErrorResponse(new FileFault(400, "Invalid file metadata."));
    return fileErrorResponse(error);
  }
}

function parseFileOperation(request: Request): FileOperation {
  const url = new URL(request.url);
  const match = /^\/files\/sessions\/([^/]+)\/(uploads|files)(?:\/([^/]+))?(\/content|\/authorize|\/complete)?$/.exec(url.pathname);
  if (!match) throw new FileFault(404, "Unknown file operation.");
  const sessionId = sessionFileId.parse(decodeURIComponent(match[1]));
  const [, , collection, id, content] = match;
  if (!id && collection === "uploads" && request.method === "POST") return { kind: "reserve", sessionId };
  if (!id && collection === "files" && request.method === "GET") return { kind: "list", sessionId, cursor: url.searchParams.get("cursor") ?? undefined };
  if (id) {
    const file = { sessionId, fileId: sharedFileIdSchema.parse(id) };
    if (collection === "uploads" && content === "/authorize" && request.method === "POST") return { kind: "authorize", file };
    if (collection === "uploads" && content === "/complete" && request.method === "POST") return { kind: "complete", file };
    if (collection === "files" && content === "/content" && request.method === "GET") return { kind: "download", file };
    if (collection === "files" && !content && request.method === "GET") return { kind: "metadata", file };
    if (collection === "files" && !content && request.method === "DELETE") return { kind: "delete", file };
  }
  throw new FileFault(400, "Unsupported file operation.");
}

function requireWritableOperation(operation: FileOperation, policy: FilePolicy): void {
  if ((operation.kind === "reserve" || operation.kind === "authorize" || operation.kind === "complete") && !policy.writesEnabled) {
    throw new FileFault(503, "New file uploads are temporarily disabled; existing files remain readable and deletable.");
  }
}

/** Internal managed-writer fixture only. No production HTTP route accepts file bodies. */
export async function uploadContent(request: Request, principal: Principal, file: FileLocator, relay: FileRelay, bucket: R2Bucket): Promise<Response> {
  const lease = await relay.beginFileUpload(file.sessionId, file.fileId);
  if (!("key" in lease)) return json(lease.file);
  const fixed = new FixedLengthStream(lease.file.byteLength);
  const abort = new AbortController();
  const deadline = Math.min(lease.expiresAt, principal.expiresAt);
  const timeout = setTimeout(() => abort.abort(), Math.max(1, deadline - Date.now()));
  const body = request.body ?? new ReadableStream<Uint8Array>({ start(controller) { controller.close(); } });
  const pipeline = body.pipeTo(fixed.writable, { signal: abort.signal });
  const put = bucket.put(lease.key, fixed.readable, {
    sha256: lease.file.sha256, onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: lease.file.mediaType },
  });
  try {
    const [, object] = await Promise.all([pipeline, put]);
    if (!object || object.size !== lease.file.byteLength) throw new FileFault(422, "File size verification failed.");
    return json(await relay.commitFile(file.sessionId, file.fileId, lease.key));
  } catch (error) {
    if (error instanceof FileFault) throw error;
    throw new FileFault(422, "Upload did not complete or its length/checksum did not match. Check file status before retrying.");
  } finally {
    clearTimeout(timeout);
    abort.abort();
    // A rejected pipe is not proof that the R2 write has terminated.
    await Promise.allSettled([pipeline, put]);
    await relay.finishFileAttempt(file.sessionId, file.fileId, lease.key).catch(() => {});
  }
}

async function downloadContent(file: FileLocator, relay: FileRelay, bucket: R2Bucket): Promise<Response> {
  const { file: metadata, key } = await relay.fileContent(file.sessionId, file.fileId);
  const object = await bucket.get(key);
  if (!object) throw new FileFault(503, "File contents unavailable. Try again later.");
  return new Response(object.body, { headers: { ...PRIVATE_HEADERS,
    "Content-Type": metadata.mediaType, "Content-Length": String(metadata.byteLength),
    "Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(metadata.filename).replace(/'/g, "%27")}`,
  } });
}

function json(value: unknown): Response { return Response.json(value, { headers: PRIVATE_HEADERS }); }
async function boundedJSON(request: Request): Promise<unknown> {
  if (!request.body) throw new FileFault(400, "File metadata required.");
  const reader = request.body.getReader();
  let bytes = 0;
  const chunks: Uint8Array[] = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 4096) throw new FileFault(413, "File metadata is too large.");
      chunks.push(value);
    }
    const data = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.byteLength; }
    try { return JSON.parse(new TextDecoder().decode(data)); } catch { throw new FileFault(400, "Invalid file metadata."); }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
}
