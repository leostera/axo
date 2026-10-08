import WebSocket from "ws";
import { MAX_FRAME_BYTES, parseFrame, phoneFrameSchema, type PhoneFrame, type HostFrame } from "../shared/protocol";
import type { BridgeConfig } from "./config";

export class RelayConnection {
  private socket?: WebSocket;
  private retry?: ReturnType<typeof setTimeout>;
  private heartbeat?: ReturnType<typeof setInterval>;
  private stopped = false;
  private failures = 0;

  constructor(
    private config: BridgeConfig,
    private onFrame: (frame: PhoneFrame) => void,
    private onStatus: (status: string) => void,
    private onOpen: () => void,
  ) {}

  connect(): void {
    if (this.stopped) return;
    const url = new URL("/connect/host", this.config.relayURL);
    url.protocol = "wss:";
    const socket = new WebSocket(url, {
      maxPayload: MAX_FRAME_BYTES,
      headers: { "CF-Access-Client-Id": this.config.accessClientId, "CF-Access-Client-Secret": this.config.accessClientSecret },
    });
    this.socket = socket;
    socket.on("open", () => {
      this.failures = 0;
      this.onStatus("phone relay connected");
      this.heartbeat = setInterval(() => socket.ping(), 20_000);
      this.onOpen();
    });
    socket.on("message", data => {
      try { this.onFrame(parseFrame(data.toString(), phoneFrameSchema)); }
      catch { this.send({ type: "error", message: "Invalid remote command" }); }
    });
    socket.on("error", () => this.onStatus("relay unavailable; local Pi still works"));
    socket.on("close", () => {
      clearInterval(this.heartbeat);
      if (this.stopped) return;
      this.onStatus("relay disconnected; reconnecting");
      this.retry = setTimeout(() => this.connect(), Math.min(30_000, 1000 * 2 ** this.failures++));
    });
  }

  send(frame: HostFrame): void {
    const text = JSON.stringify(frame);
    if (Buffer.byteLength(text) > MAX_FRAME_BYTES) return;
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.send(text);
  }

  stop(): void {
    this.stopped = true;
    clearTimeout(this.retry);
    clearInterval(this.heartbeat);
    this.socket?.close();
  }
}
