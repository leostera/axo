import { DurableObject } from "cloudflare:workers";
import { authorize, type Principal } from "./access";
import { hostFrameSchema, phoneFrameSchema, parseFrame } from "../../shared/protocol";
import { FileIndex } from "./file-index";
import { handleFiles } from "./files";
import type { UploadRequest } from "../../shared/files";

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path.startsWith("/files/")) {
      let principal: Principal;
      try { principal = await authorize(request, "phone", env); }
      catch {
        try { principal = await authorize(request, "host", env); }
        catch { return new Response("Cloudflare Access authentication required", { status: 401 }); }
      }
      if (!fileStorageEnabled(env)) return Response.json({ message: "Shared files are not enabled on this relay." }, { status: 503, headers: { "Cache-Control": "private, no-store" } });
      return handleFiles(request, principal, ctx.exports.Relay.getByName("single-workbench"), env.FILES, { writesEnabled: fileWritesEnabled(env) }, env);
    }
    if (request.method !== "GET") return new Response("Method not allowed", { status: 405 });
    if (!["/login", "/connect/phone", "/connect/host"].includes(path)) return new Response("Not found", { status: 404 });
    const role = path === "/connect/host" ? "host" : "phone";
    let principal: Principal;
    try { principal = await authorize(request, role, env); }
    catch { return new Response("Cloudflare Access authentication required", { status: 401 }); }
    if (path === "/login") {
      return new Response("<!doctype html><title>Axo connected</title><p>You can return to Axo.</p>", {
        headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'" },
      });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket required", { status: 426 });
    return ctx.exports.Relay.getByName("single-workbench").fetch(new Request("https://relay.internal/", {
      headers: { Upgrade: "websocket", "X-Axo-Role": principal.role, "X-Axo-Expiry": String(principal.expiresAt) },
    }));
  },
} satisfies ExportedHandler<Env>;

function fileStorageEnabled(env: { FILE_STORAGE_ENABLED: string }): boolean { return env.FILE_STORAGE_ENABLED === "true"; }
function fileWritesEnabled(env: { FILE_STORAGE_ENABLED: string; FILE_STORAGE_WRITES_ENABLED: string }): boolean { return fileStorageEnabled(env) && env.FILE_STORAGE_WRITES_ENABLED === "true"; }

interface Attachment extends Principal { windowStart: number; count: number }

/** One private workbench. Files are durable; transcripts and offline prompts are not. */
export class Relay extends DurableObject<Env> {
  private readonly files: FileIndex;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.files = new FileIndex(ctx.storage, env.FILES, (sessionId, revision) => {
      ctx.waitUntil(ctx.storage.sync().then(() => this.broadcast("phone", JSON.stringify({ type: "files_changed", sessionId, revision }))));
    });
  }

  admitFileRequest() { this.files.admitRequest(); }
  getFile(sessionId: string, id: string) { return this.files.get(sessionId, id); }
  listFiles(sessionId: string, cursor?: string) { return this.files.list(sessionId, cursor); }
  async reserveFile(sessionId: string, input: UploadRequest, role: Principal["role"]) {
    const file = this.files.reserve(sessionId, input, role);
    await this.scheduleExpiry();
    return file;
  }
  async beginFileUpload(sessionId: string, id: string) {
    const lease = this.files.beginUpload(sessionId, id);
    await this.scheduleExpiry();
    return lease;
  }
  async beginSignedFileUpload(sessionId: string, id: string) {
    const lease = this.files.beginUpload(sessionId, id, true);
    await this.scheduleExpiry();
    return lease;
  }
  completeSignedFileUpload(sessionId: string, id: string) { return this.files.completeSignedUpload(sessionId, id); }
  commitFile(sessionId: string, id: string, key: string) { return this.files.commit(sessionId, id, key); }
  finishFileAttempt(sessionId: string, id: string, key: string) {
    this.files.finishAttempt(sessionId, id, key);
    this.ctx.waitUntil(this.files.maintain().then(() => this.scheduleExpiry()));
  }
  async deleteFile(sessionId: string, id: string) {
    const file = await this.files.remove(sessionId, id);
    await this.scheduleExpiry();
    return file;
  }
  fileContent(sessionId: string, id: string) { return { file: this.files.get(sessionId, id), key: this.files.contentKey(sessionId, id) }; }

  async fetch(request: Request): Promise<Response> {
    // Only the authenticated entrypoint constructs this internal request.
    const role = request.headers.get("X-Axo-Role");
    const expiresAt = Number(request.headers.get("X-Axo-Expiry"));
    if ((role !== "host" && role !== "phone") || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
      return new Response("Invalid connection identity", { status: 403 });
    }
    const principal: Principal = { role, expiresAt };
    const existing = this.peers(principal.role);
    if (principal.role === "host" && existing.length) return new Response("A Mac is already connected", { status: 409 });
    if (this.ctx.getWebSockets().length >= 5) return new Response("Connection limit reached", { status: 429 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [principal.role]);
    server.serializeAttachment({ ...principal, windowStart: Date.now(), count: 0 } satisfies Attachment);
    if (principal.role === "phone") {
      server.send(JSON.stringify({ type: "presence", online: this.peers("host").length > 0 }));
      this.broadcast("host", JSON.stringify({ type: "sync" }));
    } else {
      this.broadcast("phone", JSON.stringify({ type: "presence", online: true }));
      server.send(JSON.stringify({ type: "sync" }));
    }
    await this.scheduleExpiry();
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket: WebSocket, raw: string | ArrayBuffer): void {
    const identity = socket.deserializeAttachment() as Attachment;
    if (identity.expiresAt <= Date.now()) { socket.close(4001, "Access session expired"); return; }
    if (Date.now() - identity.windowStart >= 1000) { identity.windowStart = Date.now(); identity.count = 0; }
    identity.count += 1;
    socket.serializeAttachment(identity);
    if (identity.count > 30) { socket.close(1008, "Rate limit"); return; }
    try {
      if (typeof raw !== "string") throw new Error("Text frames required");
      if (identity.role === "host") {
        const frame = parseFrame(raw, hostFrameSchema);
        if (frame.type === "snapshot" && fileStorageEnabled(this.env)) {
          try { this.files.registerSession(frame.sessionId); }
          catch { console.warn(JSON.stringify({ operation: "file_session_registration", outcome: "rejected" })); }
        }
        this.broadcast("phone", JSON.stringify(frame));
      } else {
        const frame = parseFrame(raw, phoneFrameSchema);
        if (frame.type === "prompt" && frame.attachmentIds?.length && !fileWritesEnabled(this.env)) {
          socket.send(JSON.stringify({ type: "error", id: frame.id, message: "Attachment submission is temporarily disabled. Prompt not sent; keep the draft." }));
          return;
        }
        if (!this.peers("host").length) {
          socket.send(JSON.stringify({ type: "error", ...("id" in frame ? { id: frame.id } : {}), message: "Mac offline. Nothing was queued." }));
          return;
        }
        this.broadcast("host", JSON.stringify(frame));
      }
    } catch {
      const message = identity.role === "host"
        ? "Mac bridge protocol mismatch. Run /reload in Pi, then reconnect the phone."
        : "Phone protocol mismatch. Update the iOS app, then reconnect.";
      const frame = JSON.stringify({ type: "error", message });
      socket.send(frame);
      if (identity.role === "host") this.broadcast("phone", frame);
    }
  }

  webSocketClose(socket: WebSocket): void {
    const identity = socket.deserializeAttachment() as Attachment;
    if (identity.role === "host" && !this.peers("host").length) this.broadcast("phone", JSON.stringify({ type: "presence", online: false }));
  }

  webSocketError(socket: WebSocket): void {
    socket.close(1011, "Connection failed");
    this.webSocketClose(socket);
  }

  async alarm(): Promise<void> {
    if (fileStorageEnabled(this.env)) await this.files.maintain();
    for (const socket of this.ctx.getWebSockets()) {
      const identity = socket.deserializeAttachment() as Attachment;
      if (identity.expiresAt <= Date.now()) socket.close(4001, "Access session expired");
    }
    if (!this.peers("host").length) this.broadcast("phone", JSON.stringify({ type: "presence", online: false }));
    await this.scheduleExpiry();
  }

  private peers(role: Principal["role"]): WebSocket[] {
    return this.ctx.getWebSockets(role).filter(socket => {
      const identity = socket.deserializeAttachment() as Attachment;
      return socket.readyState === WebSocket.OPEN && identity.expiresAt > Date.now();
    });
  }

  private broadcast(role: Principal["role"], text: string): void {
    for (const socket of this.peers(role)) {
      try { socket.send(text); } catch { socket.close(1011, "Delivery failed"); }
    }
  }

  private async scheduleExpiry(): Promise<void> {
    const expiries = this.ctx.getWebSockets().map(socket => (socket.deserializeAttachment() as Attachment).expiresAt).filter(time => time > Date.now());
    const maintenance = this.files.nextMaintenance();
    if (maintenance !== undefined) expiries.push(maintenance);
    if (expiries.length) await this.ctx.storage.setAlarm(Math.min(...expiries));
    else await this.ctx.storage.deleteAlarm();
  }
}
