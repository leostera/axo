import WebSocket from "ws";
import { z } from "zod";
import { MAX_FRAME_BYTES, parseFrame, relayToHostFrameSchema, type RelayToHostFrame, type HostFrame } from "../shared/protocol";
import type { BridgeConfig } from "./config";

const relayInputSchema = z.union([relayToHostFrameSchema, z.object({ type: z.literal("error"), id: z.string().optional(), sessionId: z.string().optional(), message: z.string().max(2_000) })]);

export function receiveRelayFrame(raw: string, onFrame: (frame: RelayToHostFrame) => void,
                                  reply: (frame: HostFrame) => void, status: (message: string) => void): void {
  let frame: z.infer<typeof relayInputSchema>;
  try { frame = parseFrame(raw, relayInputSchema); }
  catch {
    reply({ type: "error", message: "Protocol mismatch. Update the relay and phone app, then run /reload on the Mac." });
    return;
  }
  if (frame.type === "error") {
    // Relay control errors are not phone commands. Never reflect them back.
    status(frame.message);
    return;
  }
  try { onFrame(frame); }
  catch {
    reply({ type: "error", ...("id" in frame ? { id: frame.id } : {}),
      message: "The Mac bridge could not process the command. Run /reload, then reconnect; check Pi before retrying a prompt." });
  }
}

export class RelayConnection {
  private socket?: WebSocket;
  private retry?: ReturnType<typeof setTimeout>;
  private heartbeat?: ReturnType<typeof setInterval>;
  private stopped = false;
  private failures = 0;

  constructor(
    private config: BridgeConfig,
    private onFrame: (frame: RelayToHostFrame) => void,
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
      receiveRelayFrame(data.toString(), this.onFrame, frame => this.send(frame), this.onStatus);
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
