import { DurableObject } from "cloudflare:workers";
import { authorize, type Principal } from "./access";
import { catalogPageSchema, hostFrameSchema, phoneFrameSchema, parseFrame, type HostFrame, type PhoneFrame } from "../../shared/protocol";
import { CatalogStore } from "./catalog";
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

interface Attachment extends Principal {
  windowStart: number;
  count: number;
  selectedSessionId?: string;
  pendingIDs: string[];
}

/** One authenticated Mac broker owns all local Pi bindings; phone commands are always addressed. */
export class Relay extends DurableObject<Env> {
  private readonly files: FileIndex;
  private readonly catalog: CatalogStore;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.catalog = new CatalogStore(ctx.storage);
    this.files = new FileIndex(ctx.storage, env.FILES, (conversationId, revision) => {
      ctx.waitUntil(ctx.storage.sync().then(() => this.broadcastFileChange(conversationId, revision)));
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
    const existingHosts = this.peers("host");
    if (role === "host" && existingHosts.length) return new Response("A Mac broker is already connected", { status: 409 });
    if (role === "phone" && this.peers("phone").length >= 4) return new Response("Phone connection limit reached", { status: 429 });
    if (this.ctx.getWebSockets().length >= 5) return new Response("Connection limit reached", { status: 429 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({ role, expiresAt, windowStart: Date.now(), count: 0, pendingIDs: [] } satisfies Attachment);
    if (role === "phone") {
      const hostOnline = this.peers("host").length > 0;
      server.send(JSON.stringify({ type: "presence", online: hostOnline }));
      server.send(JSON.stringify(this.catalog.page(null, null, hostOnline)));
    } else {
      this.broadcast("phone", JSON.stringify({ type: "presence", online: true }));
      server.send(JSON.stringify({ type: "catalog_request", revision: this.catalog.read().revision }));
      for (const sessionId of this.subscribedSessions()) this.sendHost({ type: "session_sync", sessionId });
    }
    await this.scheduleExpiry();
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket: WebSocket, raw: string | ArrayBuffer): void {
    const identity = socket.deserializeAttachment() as Attachment;
    if (!identity || identity.expiresAt <= Date.now()) { socket.close(4001, "Access session expired"); return; }
    if (Date.now() - identity.windowStart >= 1_000) { identity.windowStart = Date.now(); identity.count = 0; }
    identity.count += 1;
    if (identity.count > 30) { socket.close(1008, "Rate limit"); return; }
    try {
      if (typeof raw !== "string") throw new Error("Text frames required");
      if (identity.role === "host") this.receiveHost(socket, identity, parseFrame(raw, hostFrameSchema));
      else this.receivePhone(socket, identity, parseFrame(raw, phoneFrameSchema));
    } catch {
      const message = identity.role === "host"
        ? "Mac broker protocol mismatch. Update Axo and reconnect."
        : "Phone protocol mismatch. Update the iOS app, then reconnect.";
      this.send(socket, { type: "error", message });
    }
  }

  private receiveHost(socket: WebSocket, identity: Attachment, frame: HostFrame): void {
    if (!this.peers("host").includes(socket)) return;
    if (frame.type === "catalog") {
      try {
        const catalog = this.catalog.replace(frame.catalog);
        this.broadcastCatalog(catalog.revision);
      } catch {
        this.send(socket, { type: "error", message: "Catalog revision is stale or conflicts with the saved catalog." });
      }
      return;
    }
    if (frame.type === "snapshot" && fileStorageEnabled(this.env)) {
      try { this.files.registerSession(frame.conversationId); }
      catch { console.warn(JSON.stringify({ operation: "file_session_registration", outcome: "rejected" })); }
    }
    if (frame.type === "snapshot") {
      this.sendToSubscribers(frame.sessionId, frame);
      return;
    }
    if ("id" in frame && frame.id) {
      const recipients = this.takePendingRecipients(frame.id);
      for (const recipient of recipients) this.send(recipient, frame);
      return;
    }
    if ("sessionId" in frame && frame.sessionId) this.sendToSubscribers(frame.sessionId, frame);
    void identity;
  }

  private receivePhone(socket: WebSocket, identity: Attachment, frame: PhoneFrame): void {
    if (frame.type === "sync") {
      this.send(socket, this.catalog.page(null, null, this.peers("host").length > 0));
      if (identity.selectedSessionId) this.sendHost({ type: "session_sync", sessionId: identity.selectedSessionId });
      return;
    }
    if (frame.type === "catalog_page") {
      const page = this.catalog.page(frame.revision, frame.cursor, this.peers("host").length > 0);
      this.send(socket, { ...page, type: "catalog_page", requestId: frame.id });
      return;
    }
    if (frame.type === "subscribe") {
      if (frame.sessionId && !this.catalog.read().sessions.some(session => session.id === frame.sessionId)) {
        this.replyError(socket, frame.id, frame.sessionId, "Session no longer exists in the Mac catalog.");
        return;
      }
      identity.selectedSessionId = frame.sessionId ?? undefined;
      this.persist(socket, identity);
      this.reply(socket, { type: "subscription", id: frame.id, sessionId: frame.sessionId, hostOnline: this.peers("host").length > 0 });
      if (frame.sessionId && this.peers("host").length) this.sendHost({ type: "sync", sessionId: frame.sessionId });
      return;
    }

    if (!this.peers("host").length) {
      this.replyError(socket, frame.id, "sessionId" in frame ? frame.sessionId : undefined, "Mac offline. Nothing was queued.");
      return;
    }
    if (frame.type === "create_workspace" || frame.type === "create_session"
      || frame.type === "rename_workspace" || frame.type === "rename_session") {
      this.forward(socket, identity, frame);
      return;
    }

    const selected = identity.selectedSessionId;
    if (frame.sessionId !== selected) {
      this.replyError(socket, frame.id, frame.sessionId, "Select this session before sending a command to it.");
      return;
    }
    const session = this.catalog.read().sessions.find(item => item.id === frame.sessionId);
    if (!session) {
      this.replyError(socket, frame.id, frame.sessionId, "Session is not in the current Mac catalog.");
      return;
    }
    if (frame.type === "prompt" && frame.attachmentIds?.length && !fileWritesEnabled(this.env)) {
      this.replyError(socket, frame.id, frame.sessionId, "Attachment submission is temporarily disabled. Prompt not sent; keep the draft.");
      return;
    }
    if (session.availability !== "running") {
      this.replyError(socket, frame.id, frame.sessionId, "This session is not running on the Mac. Nothing was sent.");
      return;
    }
    this.forward(socket, identity, frame);
  }

  private forward(socket: WebSocket, identity: Attachment, frame: Exclude<PhoneFrame, { type: "sync" | "catalog_page" | "subscribe" }>): void {
    const idInUse = this.peers("phone").some(peer => (peer.deserializeAttachment() as Attachment).pendingIDs.includes(frame.id));
    if (idInUse) {
      this.replyError(socket, frame.id, "sessionId" in frame ? frame.sessionId : undefined, "This command ID is already awaiting a result.");
      return;
    }
    if (identity.pendingIDs.length >= 32) {
      this.replyError(socket, frame.id, "sessionId" in frame ? frame.sessionId : undefined, "Too many outstanding commands. Wait for a reply before retrying.");
      return;
    }
    identity.pendingIDs.push(frame.id);
    this.persist(socket, identity);
    if (!this.sendHost(frame)) {
      identity.pendingIDs = identity.pendingIDs.filter(id => id !== frame.id);
      this.persist(socket, identity);
      this.replyError(socket, frame.id, "sessionId" in frame ? frame.sessionId : undefined, "Mac offline. Nothing was queued.");
    }
  }

  webSocketClose(socket: WebSocket): void {
    const identity = socket.deserializeAttachment() as Attachment;
    if (identity.role === "host" && !this.peers("host").length) {
      this.broadcast("phone", JSON.stringify({ type: "presence", online: false }));
      this.broadcastCatalog();
    }
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
    if (!this.peers("host").length) {
      this.broadcast("phone", JSON.stringify({ type: "presence", online: false }));
      this.broadcastCatalog();
    }
    await this.scheduleExpiry();
  }

  private peers(role: Principal["role"]): WebSocket[] {
    return this.ctx.getWebSockets(role).filter(socket => {
      const identity = socket.deserializeAttachment() as Attachment;
      return socket.readyState === WebSocket.OPEN && identity.expiresAt > Date.now();
    });
  }

  private sendHost(frame: unknown): boolean {
    const host = this.peers("host")[0];
    if (!host) return false;
    return this.send(host, frame);
  }

  private sendToSubscribers(sessionId: string, frame: unknown): void {
    for (const socket of this.peers("phone")) {
      const identity = socket.deserializeAttachment() as Attachment;
      if (identity.selectedSessionId === sessionId) this.send(socket, frame);
    }
  }

  private takePendingRecipients(id: string): WebSocket[] {
    const recipients: WebSocket[] = [];
    for (const socket of this.peers("phone")) {
      const identity = socket.deserializeAttachment() as Attachment;
      if (!identity.pendingIDs.includes(id)) continue;
      identity.pendingIDs = identity.pendingIDs.filter(candidate => candidate !== id);
      this.persist(socket, identity);
      recipients.push(socket);
    }
    return recipients;
  }

  private reply(socket: WebSocket, frame: unknown): void { this.send(socket, frame); }
  private replyError(socket: WebSocket, id: string, sessionId: string | undefined, message: string): void {
    this.reply(socket, { type: "error", id, ...(sessionId ? { sessionId } : {}), message });
  }
  private persist(socket: WebSocket, identity: Attachment): void { socket.serializeAttachment(identity); }
  private send(socket: WebSocket, frame: unknown): boolean {
    try { socket.send(JSON.stringify(frame)); return true; } catch { socket.close(1011, "Delivery failed"); return false; }
  }

  private broadcastCatalog(revision = this.catalog.read().revision): void {
    const page = this.catalog.page(revision, null, this.peers("host").length > 0);
    for (const socket of this.peers("phone")) this.send(socket, page);
  }

  private broadcastFileChange(conversationId: string, revision: number): void {
    const sessions = this.catalog.read().sessions.filter(session => session.conversationId === conversationId).map(session => session.id);
    for (const socket of this.peers("phone")) {
      const identity = socket.deserializeAttachment() as Attachment;
      if (identity.selectedSessionId && sessions.includes(identity.selectedSessionId)) {
        this.send(socket, { type: "files_changed", sessionId: conversationId, revision });
      }
    }
  }

  private subscribedSessions(): string[] {
    return [...new Set(this.peers("phone").map(socket => (socket.deserializeAttachment() as Attachment).selectedSessionId).filter((id): id is string => !!id))];
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
