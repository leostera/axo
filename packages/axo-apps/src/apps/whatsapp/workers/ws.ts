import { EventEmitter } from "node:events";

/**
 * The `ws` package as Baileys uses it, over the Workers WebSocket: a fetch with `Upgrade`, so the
 * Origin header WhatsApp checks goes along. Bundled in place of `ws` for Baileys only (bundling.mjs).
 */
export default class WebSocket extends EventEmitter {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  readyState = WebSocket.CONNECTING;
  private socket: globalThis.WebSocket | null = null;

  constructor(url: string | URL, options: { origin?: string; headers?: Record<string, string> } = {}) {
    super();
    const headers: Record<string, string> = { Upgrade: "websocket", ...(options.headers ?? {}) };
    if (options.origin) headers.Origin = options.origin;
    fetch(String(url).replace(/^ws/, "http"), { headers }).then((response) => {
      const socket = (response as Response & { webSocket?: globalThis.WebSocket & { accept(): void } }).webSocket;
      if (!socket) throw new Error(`WhatsApp did not upgrade the connection: HTTP ${response.status}`);
      socket.accept();
      socket.binaryType = "arraybuffer";
      this.socket = socket;
      this.readyState = WebSocket.OPEN;
      socket.addEventListener("message", (event) => this.emit("message", typeof event.data === "string" ? event.data : Buffer.from(event.data as ArrayBuffer)));
      socket.addEventListener("close", (event) => {
        this.readyState = WebSocket.CLOSED;
        this.emit("close", event.code, Buffer.from(event.reason ?? ""));
      });
      socket.addEventListener("error", (event) => this.emit("error", (event as ErrorEvent).error ?? new Error("WhatsApp's connection failed")));
      this.emit("open");
    }).catch((error: unknown) => {
      this.readyState = WebSocket.CLOSED;
      this.emit("error", error);
      this.emit("close", 1006, Buffer.alloc(0));
    });
  }

  send(data: string | Uint8Array, callback?: (error?: Error) => void): void {
    try {
      this.socket!.send(data as Parameters<globalThis.WebSocket["send"]>[0]);
      callback?.();
    } catch (error) {
      callback?.(error as Error);
    }
  }

  close(code?: number, reason?: string): void {
    if (this.readyState >= WebSocket.CLOSING) return;
    this.readyState = WebSocket.CLOSING;
    if (!this.socket) {
      this.readyState = WebSocket.CLOSED;
      this.emit("close", code ?? 1000, Buffer.alloc(0));
      return;
    }
    try {
      this.socket.close(code ?? 1000, reason);
    } catch {
      // Already closed.
    }
  }

  terminate(): void {
    this.close();
  }

  ping(): void {}
}

export { WebSocket };
