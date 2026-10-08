import { DurableObject } from "cloudflare:workers";
import { authorize, type Principal } from "./access";
import { hostFrameSchema, phoneFrameSchema, parseFrame } from "../../shared/protocol";

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const path = new URL(request.url).pathname;
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

interface Attachment extends Principal { windowStart: number; count: number }

/** One private workbench, no transcript or offline-prompt storage. */
export class Relay extends DurableObject<Env> {
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
        this.broadcast("phone", JSON.stringify(frame));
      } else {
        const frame = parseFrame(raw, phoneFrameSchema);
        if (!this.peers("host").length) {
          socket.send(JSON.stringify({ type: "error", ...("id" in frame ? { id: frame.id } : {}), message: "Mac offline. Nothing was queued." }));
          return;
        }
        this.broadcast("host", JSON.stringify(frame));
      }
    } catch {
      socket.send(JSON.stringify({ type: "error", message: "Invalid or oversized message" }));
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
    if (expiries.length) await this.ctx.storage.setAlarm(Math.min(...expiries));
    else await this.ctx.storage.deleteAlarm();
  }
}
