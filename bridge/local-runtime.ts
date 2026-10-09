import { createConnection, type Socket } from "node:net";
import { MAX_FRAME_BYTES, parseFrame, phoneFrameSchema, type HostFrame, type PhoneFrame } from "../shared/protocol";

export interface RuntimeBinding {
  sessionId: string;
  paneId: string;
  runtimeGeneration: string;
  capability: string;
  conversationId: string;
}

export class LocalRuntimeConnection {
  private socket?: Socket;
  private buffer = "";
  private stopped = false;
  private retry?: ReturnType<typeof setTimeout>;
  private failures = 0;

  constructor(
    private readonly socketPath: string,
    private readonly binding: RuntimeBinding,
    private readonly onFrame: (frame: PhoneFrame) => void,
    private readonly onStatus: (status: string) => void,
    private readonly onRegistered: () => void = () => {},
  ) {}

  connect(): void {
    if (this.stopped) return;
    const socket = createConnection(this.socketPath);
    this.socket = socket;
    socket.on("connect", () => {
      this.failures = 0;
      this.onStatus("local broker connected");
      this.send({ type: "runtime_register", ...this.binding });
    });
    socket.on("data", chunk => this.read(chunk.toString("utf8")));
    socket.on("error", () => this.onStatus("local broker unavailable; Pi remains local"));
    socket.on("close", () => {
      if (this.socket === socket) this.socket = undefined;
      if (this.stopped) return;
      this.onStatus("local broker disconnected; reconnecting");
      this.retry = setTimeout(() => this.connect(), Math.min(30_000, 1_000 * 2 ** this.failures++));
      this.retry.unref();
    });
  }

  send(frame: HostFrame | { type: "runtime_register" } & RuntimeBinding): void {
    const socket = this.socket;
    if (!socket || socket.destroyed || !socket.writable) return;
    const text = JSON.stringify(frame);
    if (Buffer.byteLength(text) > MAX_FRAME_BYTES) return;
    socket.write(text + "\n");
  }

  updateBinding(binding: RuntimeBinding): void {
    Object.assign(this.binding, binding);
    this.send({ type: "runtime_register", ...binding });
  }

  stop(): void {
    this.stopped = true;
    clearTimeout(this.retry);
    this.socket?.destroy();
    this.socket = undefined;
  }

  private read(chunk: string): void {
    this.buffer += chunk;
    if (Buffer.byteLength(this.buffer) > MAX_FRAME_BYTES && !this.buffer.includes("\n")) {
      this.socket?.destroy(new Error("Local bridge frame too large"));
      return;
    }
    while (true) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const text = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (!text) continue;
      if (Buffer.byteLength(text) > MAX_FRAME_BYTES) {
        this.socket?.destroy(new Error("Local bridge frame too large"));
        return;
      }
      try {
        const value = JSON.parse(text) as { type?: unknown };
        if (value.type === "runtime_registered") { this.onRegistered(); continue; }
        if (value.type === "error") {
          this.onStatus(typeof (value as { message?: unknown }).message === "string" ? String((value as { message: string }).message) : "Local broker rejected this runtime.");
          continue;
        }
        this.onFrame(parseFrame(text, phoneFrameSchema));
      } catch {
        this.socket?.destroy(new Error("Malformed local bridge frame"));
        return;
      }
    }
  }
}
