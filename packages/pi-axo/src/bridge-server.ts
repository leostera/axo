import { chmod, lstat, unlink } from "node:fs/promises";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { connect, createServer, type Server, type Socket } from "node:net";
import {
  MAX_BRIDGE_RECORD_BYTES,
  parsePiControlCommand,
  type PiBridgeRecord,
  type PiCommandResult,
  type PiControlCommand,
  type PiSessionIdentity,
} from "./protocol.js";

const MAX_CACHED_COMMANDS = 256;

function traceBridge(message: string): void {
  if (process.env.AXO_PI_BRIDGE_DEBUG === "1") console.error(`Axo Pi bridge: ${message}`);
}

type CommandHandler = (command: PiControlCommand) => Promise<PiCommandResult>;

export class AxoPiBridgeServer {
  private server: Server | undefined;
  private socket: Socket | undefined;
  private identity: PiSessionIdentity | undefined;
  private readonly streamId = randomUUID();
  private nextSequence = 0;
  private ownsSocketPath = false;
  private commandQueue: Promise<void> = Promise.resolve();
  private readonly commandResults = new Map<string, { fingerprint: string; result: PiCommandResult }>();

  constructor(
    private readonly socketPath: string,
    private readonly axoSessionId: string,
    private readonly bridgeToken: string,
    private readonly handleCommand: CommandHandler,
  ) {}

  async start(): Promise<void> {
    if (this.server !== undefined) return;

    try {
      await this.listen();
    } catch (error) {
      // A Pi that was killed (not shut down) leaves its socket file behind, and Node will not
      // listen over it. Every later Pi for this Session would then fail the same way, so an
      // abandoned file is removed; a socket some process still answers on is never taken.
      if ((error as NodeJS.ErrnoException).code !== "EADDRINUSE" || !(await isAbandonedSocket(this.socketPath))) {
        throw error;
      }
      traceBridge("removing abandoned socket file");
      await this.removeSocketFile();
      await this.listen();
    }
    this.ownsSocketPath = true;
    try {
      await chmod(this.socketPath, 0o600);
    } catch (error) {
      await this.close();
      throw error;
    }
  }

  private async listen(): Promise<void> {
    const server = createServer(socket => this.accept(socket));
    server.on("error", () => this.socket?.destroy());
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => {
        server.off("listening", onListening);
        this.server = undefined;
        reject(error);
      };
      const onListening = () => {
        server.off("error", onError);
        resolve();
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen(this.socketPath);
    });
  }

  bindIdentity(identity: PiSessionIdentity): void {
    if (identity.axoSessionId !== this.axoSessionId) throw new Error("Pi bridge Session binding mismatch");
    this.identity = identity;
    void this.sendHello().catch(() => {});
  }

  async publish(name: string, data: unknown): Promise<void> {
    if (this.identity === undefined) return;
    this.nextSequence += 1;
    try {
      await this.send({ type: "event", streamId: this.streamId, sequence: this.nextSequence, name, data });
    } catch {
      // The Pi session file is the durable source used to reconcile after disconnect.
    }
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.socket = undefined;
    socket?.destroy();

    const server = this.server;
    this.server = undefined;
    if (server !== undefined) {
      await new Promise<void>(resolve => server.close(() => resolve()));
    }
    if (this.ownsSocketPath) {
      this.ownsSocketPath = false;
      await this.removeSocketFile();
    }
  }

  private accept(socket: Socket): void {
    traceBridge("accepted local connection");
    if (this.socket !== undefined) {
      socket.destroy();
      return;
    }

    this.socket = socket;
    socket.setNoDelay(true);
    socket.on("error", () => this.disconnect(socket));
    socket.on("close", () => this.disconnect(socket));
    socket.on("data", data => this.receive(socket, data));
    if (this.identity !== undefined) void this.sendHello(socket).catch(() => socket.destroy());
  }

  private receive(socket: Socket, data: Buffer): void {
    const state = (socket as SocketWithInput).axoInput ?? { buffer: Buffer.alloc(0) };
    state.buffer = Buffer.concat([state.buffer, data]);
    if (state.buffer.byteLength > MAX_BRIDGE_RECORD_BYTES && !state.buffer.includes(0x0a)) {
      this.protocolError(socket, "bridge record exceeds its size limit");
      return;
    }

    let newline = state.buffer.indexOf(0x0a);
    while (newline >= 0) {
      const line = state.buffer.subarray(0, newline);
      state.buffer = state.buffer.subarray(newline + 1);
      if (line.byteLength > MAX_BRIDGE_RECORD_BYTES) {
        this.protocolError(socket, "bridge record exceeds its size limit");
        return;
      }
      this.enqueueCommand(socket, line);
      newline = state.buffer.indexOf(0x0a);
    }

    if (state.buffer.byteLength > MAX_BRIDGE_RECORD_BYTES) {
      this.protocolError(socket, "bridge record exceeds its size limit");
      return;
    }
    (socket as SocketWithInput).axoInput = state;
  }

  private enqueueCommand(socket: Socket, line: Buffer): void {
    this.commandQueue = this.commandQueue.catch(() => {}).then(async () => {
      if (socket.destroyed) return;
      let value: unknown;
      try {
        value = JSON.parse(line.toString("utf8"));
      } catch {
        this.protocolError(socket, "bridge record is not valid JSON");
        return;
      }

      const peer = socket as SocketWithInput;
      if (peer.axoAuthenticated !== true) {
        if (!this.authenticate(value, peer)) this.protocolError(socket, "bridge authentication failed");
        return;
      }

      const parsed = parsePiControlCommand(value, this.axoSessionId);
      if (!parsed.ok) {
        const requestId = this.readRequestId(value);
        if (requestId !== null) {
          await this.send({ type: "commandResult", requestId, result: { accepted: false, reason: parsed.reason } }, socket);
        } else {
          this.protocolError(socket, "bridge command has an invalid envelope");
        }
        return;
      }

      const fingerprint = JSON.stringify(parsed.command.action);
      const cached = this.commandResults.get(parsed.command.requestId);
      if (cached !== undefined) {
        const result = cached.fingerprint === fingerprint
          ? cached.result
          : { accepted: false as const, reason: "invalid" as const };
        await this.send({ type: "commandResult", requestId: parsed.command.requestId, result }, socket);
        return;
      }

      let result: PiCommandResult;
      try {
        result = await this.handleCommand(parsed.command);
      } catch {
        result = { accepted: false, reason: "unavailable" };
      }
      this.rememberResult(parsed.command.requestId, fingerprint, result);
      await this.send({ type: "commandResult", requestId: parsed.command.requestId, result }, socket);
    });
    void this.commandQueue.catch(() => {
      this.protocolError(socket, "bridge command processing failed");
    });
  }

  private authenticate(value: unknown, socket: SocketWithInput): boolean {
    if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
    const record = value as Record<string, unknown>;
    if (Object.keys(record).some(key => !["type", "protocolVersion", "token"].includes(key))) return false;
    if (record.type !== "authenticate" || record.protocolVersion !== 1 || typeof record.token !== "string") return false;
    const expected = Buffer.from(this.bridgeToken, "utf8");
    const received = Buffer.from(record.token, "utf8");
    if (expected.byteLength !== received.byteLength || !timingSafeEqual(expected, received)) return false;
    socket.axoAuthenticated = true;
    void this.send({ type: "authenticated", protocolVersion: 1 }, socket)
      .then(() => this.sendHello(socket))
      .catch(() => socket.destroy());
    return true;
  }

  private readRequestId(value: unknown): string | null {
    if (typeof value !== "object" || value === null || !("requestId" in value)) return null;
    const requestId = value.requestId;
    return typeof requestId === "string" && /^[a-zA-Z0-9._:-]{1,128}$/u.test(requestId) ? requestId : null;
  }

  private rememberResult(requestId: string, fingerprint: string, result: PiCommandResult): void {
    this.commandResults.delete(requestId);
    this.commandResults.set(requestId, { fingerprint, result });
    while (this.commandResults.size > MAX_CACHED_COMMANDS) {
      const oldest = this.commandResults.keys().next().value;
      if (oldest === undefined) return;
      this.commandResults.delete(oldest);
    }
  }

  private async sendHello(socket = this.socket): Promise<void> {
    const identity = this.identity;
    if (identity === undefined || (socket as SocketWithInput | undefined)?.axoAuthenticated !== true) return;
    await this.send({ type: "hello", protocolVersion: 1, identity }, socket);
  }

  private async send(record: PiBridgeRecord, socket = this.socket): Promise<void> {
    if (socket === undefined || socket.destroyed) return;
    let line: string;
    try {
      line = `${JSON.stringify(record)}\n`;
    } catch {
      return;
    }
    if (Buffer.byteLength(line, "utf8") > MAX_BRIDGE_RECORD_BYTES) return;
    await new Promise<void>((resolve, reject) => {
      socket.write(line, "utf8", error => {
        if (error === null || error === undefined) {
          traceBridge(`sent ${record.type}`);
          resolve();
        } else {
          traceBridge(`write failed (${(error as NodeJS.ErrnoException).code ?? "unknown"})`);
          reject(error);
        }
      });
    });
  }

  private protocolError(socket: Socket, message: string): void {
    void this.send({ type: "protocolError", message }, socket)
      .catch(() => {})
      .finally(() => socket.destroy());
  }

  private disconnect(socket: Socket): void {
    if (this.socket === socket) this.socket = undefined;
  }

  private async removeSocketFile(): Promise<void> {
    try {
      const file = await lstat(this.socketPath);
      if (file.isSocket()) await unlink(this.socketPath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
}

interface SocketWithInput extends Socket {
  axoInput?: { buffer: Buffer };
  axoAuthenticated?: boolean;
}

/** True when nothing listens on `path`: connecting is refused, or the file has gone. */
function isAbandonedSocket(path: string): Promise<boolean> {
  return new Promise(resolve => {
    const probe = connect(path);
    probe.once("connect", () => {
      probe.destroy();
      resolve(false);
    });
    probe.once("error", error => {
      const code = (error as NodeJS.ErrnoException).code;
      resolve(code === "ECONNREFUSED" || code === "ENOENT");
    });
  });
}
