import { chmod, lstat, mkdir, readFile, unlink } from "node:fs/promises";
import { lstatSync, readFileSync } from "node:fs";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import { basename, dirname, join } from "node:path";
import { z } from "zod";
import { MAX_FRAME_BYTES, catalogSchema, hostFrameSchema, parseFrame, type HostFrame, type PhoneFrame, type RelayToHostFrame } from "../shared/protocol";
import type { BridgeConfig } from "./config";
import { RelayConnection } from "./connection";

const runtimeRegistrationSchema = z.object({
  type: z.literal("runtime_register"),
  sessionId: z.uuid(),
  paneId: z.uuid(),
  runtimeGeneration: z.uuid(),
  capability: z.uuid(),
  conversationId: z.string().min(1).max(128),
});
const bindingFileSchema = runtimeRegistrationSchema.omit({ type: true, conversationId: true });
type RuntimeRegistration = z.infer<typeof runtimeRegistrationSchema>;
type Runtime = RuntimeRegistration & { socket: Socket };

export interface HostBrokerOptions {
  socketPath: string;
  registryPath: string;
  bindingDirectory: string;
  onMacCommand?: (frame: Extract<PhoneFrame, { type: "create_workspace" | "create_session" | "rename_workspace" | "rename_session" }>) => void;
  onStatus?: (message: string) => void;
}

/** One process owns the relay socket and multiplexes independent local Pi extensions. */
export class HostBroker {
  private server?: Server;
  private relay?: RelayConnection;
  private poll?: ReturnType<typeof setInterval>;
  private readonly runtimes = new Map<string, Runtime>();
  private readonly conversations = new Map<string, string>();
  private readonly clients = new Set<Socket>();
  private catalogRevision = 0;
  private remoteRevision = 0;
  private catalogFingerprint = "";
  private stopped = false;

  constructor(private readonly config: BridgeConfig, private readonly options: HostBrokerOptions) {}

  async start(): Promise<void> {
    await mkdir(dirname(this.options.socketPath), { recursive: true, mode: 0o700 });
    await mkdir(this.options.bindingDirectory, { recursive: true, mode: 0o700 });
    await chmod(dirname(this.options.socketPath), 0o700);
    await chmod(this.options.bindingDirectory, 0o700);
    try {
      const existing = await lstat(this.options.socketPath);
      if (!existing.isSocket()) throw new Error("Refusing to replace a non-socket bridge path");
      await assertSocketIsStale(this.options.socketPath);
      await unlink(this.options.socketPath);
    } catch (error) {
      if (!isMissing(error)) throw error;
    }

    this.server = createServer(socket => this.acceptRuntime(socket));
    await new Promise<void>((resolve, reject) => {
      this.server!.once("error", reject);
      this.server!.listen(this.options.socketPath, () => {
        this.server!.off("error", reject);
        resolve();
      });
    });
    await chmod(this.options.socketPath, 0o600);
    this.relay = new RelayConnection(this.config, frame => this.receiveRelay(frame), message => this.status(message), () => {
      this.remoteRevision = 0;
    });
    this.relay.connect();
    this.poll = setInterval(() => { void this.publishCatalog(); }, 1_000);
    this.poll.unref();
    this.status("host broker ready");
  }

  stop(): void {
    this.stopped = true;
    clearInterval(this.poll);
    this.relay?.stop();
    this.server?.close();
    for (const socket of this.clients) socket.destroy();
    this.clients.clear();
    this.runtimes.clear();
    this.conversations.clear();
    void unlink(this.options.socketPath).catch(() => {});
  }

  /** Mac UI replies to broker-forwarded create/rename requests over the owning host connection. */
  replyFromMac(frame: HostFrame): void { this.sendRelay(frame); }

  private acceptRuntime(socket: Socket): void {
    this.clients.add(socket);
    let registered: Runtime | undefined;
    let buffer = "";
    socket.setNoDelay(true);
    socket.on("data", chunk => {
      buffer += chunk.toString("utf8");
      while (true) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) {
          if (Buffer.byteLength(buffer) > MAX_FRAME_BYTES) socket.destroy(new Error("Local frame too large"));
          return;
        }
        const raw = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (!raw) continue;
        try {
          if (Buffer.byteLength(raw) > MAX_FRAME_BYTES) throw new Error("Local frame too large");
          const parsed = JSON.parse(raw) as { type?: string };
          if (parsed.type === "runtime_register") {
            registered = this.register(socket, parsed);
            continue;
          }
          if (!registered) throw new Error("Register the managed Pi binding first");
          const frame = parseFrame(raw, hostFrameSchema);
          if (frame.type === "catalog" || !this.matchesRuntime(registered, frame)) throw new Error("Runtime frame is outside its admitted binding");
          this.sendRelay(frame);
        } catch {
          this.write(socket, { type: "error", message: "Local bridge rejected the frame; check the session binding and reload Pi." });
          socket.destroy();
          return;
        }
      }
    });
    socket.on("error", () => {});
    socket.on("close", () => {
      this.clients.delete(socket);
      if (registered) this.removeRuntime(registered);
    });
  }

  private register(socket: Socket, raw: unknown): Runtime {
    const registration = runtimeRegistrationSchema.parse(raw);
    const bindingPath = join(this.options.bindingDirectory, `${registration.paneId}.json`);
    const saved = bindingFileSchema.parse(JSON.parse(readFileSyncBounded(bindingPath)));
    if (saved.sessionId !== registration.sessionId || saved.paneId !== registration.paneId
      || saved.runtimeGeneration !== registration.runtimeGeneration || saved.capability !== registration.capability) {
      throw new Error("Binding capability mismatch");
    }
    this.assertRegistryBinding(registration);
    const existingForSession = this.runtimes.get(registration.sessionId);
    if (existingForSession && existingForSession.socket !== socket) throw new Error("A runtime is already bound to this Axo session");
    const owner = this.conversations.get(registration.conversationId);
    if (owner && owner !== registration.sessionId) throw new Error("Pi conversation already has an admitted writer");
    if (existingForSession && existingForSession.conversationId !== registration.conversationId) {
      this.conversations.delete(existingForSession.conversationId);
    }
    const runtime: Runtime = { ...registration, socket };
    this.runtimes.set(registration.sessionId, runtime);
    this.conversations.set(registration.conversationId, registration.sessionId);
    this.write(socket, { type: "runtime_registered", sessionId: registration.sessionId, conversationId: registration.conversationId });
    void this.publishCatalog();
    return runtime;
  }

  private assertRegistryBinding(registration: RuntimeRegistration): void {
    const registry = JSON.parse(readFileSyncBounded(this.options.registryPath)) as RegistryFile;
    const session = registry.sessions?.find(value => idValue(value.id) === registration.sessionId && value.isArchived !== true);
    if (!session || !session.panes?.some(pane => idValue(pane.id) === registration.paneId && pane.kind === "pi")) {
      throw new Error("Runtime is not a live Pi pane in the Mac registry");
    }
    if (session.conversationID && session.conversationID !== registration.conversationId) {
      throw new Error("Pi switched to an unpaired conversation; create or select its Axo session before reconnecting the phone");
    }
  }

  private matchesRuntime(runtime: Runtime, frame: HostFrame): boolean {
    if (!("sessionId" in frame) || frame.sessionId !== runtime.sessionId) return false;
    return !("conversationId" in frame) || frame.conversationId === runtime.conversationId;
  }

  private removeRuntime(runtime: Runtime): void {
    if (this.runtimes.get(runtime.sessionId)?.socket !== runtime.socket) return;
    this.runtimes.delete(runtime.sessionId);
    if (this.conversations.get(runtime.conversationId) === runtime.sessionId) this.conversations.delete(runtime.conversationId);
    void this.publishCatalog();
  }

  private receiveRelay(frame: RelayToHostFrame): void {
    if (frame.type === "catalog_request") {
      this.remoteRevision = frame.revision;
      this.catalogRevision = Math.max(this.catalogRevision, frame.revision);
      this.catalogFingerprint = "";
      void this.publishCatalog();
      return;
    }
    if (frame.type === "session_sync") {
      if (frame.sessionId) this.runtimes.get(frame.sessionId)?.socket.write(JSON.stringify({ type: "sync" }) + "\n");
      return;
    }
    if (frame.type === "create_workspace" || frame.type === "create_session"
      || frame.type === "rename_workspace" || frame.type === "rename_session") {
      if ((frame.type === "rename_workspace" || frame.type === "rename_session")
        && frame.expectedRevision !== this.catalogRevision) {
        this.sendRelay({ type: "error", id: frame.id, message: "Workspace catalog changed. Refresh before renaming." });
        return;
      }
      if (!this.options.onMacCommand) {
        this.sendRelay({ type: "error", id: frame.id, message: "Mac workspace control is unavailable. Nothing was changed." });
        return;
      }
      this.options.onMacCommand(frame);
      return;
    }
    if (frame.type === "sync" || frame.type === "catalog_page" || frame.type === "subscribe") return;
    const runtime = this.runtimes.get(frame.sessionId);
    if (!runtime || runtime.socket.destroyed) {
      this.sendRelay({ type: "error", id: frame.id, sessionId: frame.sessionId, message: "This session is no longer active on the Mac. Nothing was sent." });
      return;
    }
    this.write(runtime.socket, frame);
  }

  private async publishCatalog(): Promise<void> {
    if (this.stopped) return;
    try {
      const raw = JSON.parse(await readFile(this.options.registryPath, "utf8")) as RegistryFile;
      const workspaces = (raw.workspaces ?? []).filter(item => item.isArchived !== true).map(item => ({
        id: idValue(item.id), name: item.name, kind: catalogWorkspaceKind(item.kind),
      }));
      const sessions = (raw.sessions ?? []).filter(item => item.isArchived !== true).map(item => {
        const id = idValue(item.id);
        const runtime = this.runtimes.get(id);
        return {
          id,
          workspaceId: idValue(item.workspaceID),
          name: item.name,
          ...(runtime?.conversationId || item.conversationID ? { conversationId: runtime?.conversationId ?? item.conversationID } : {}),
          availability: runtime ? "running" as const : "stopped" as const,
        };
      });
      const data = { workspaces, sessions };
      const fingerprint = JSON.stringify(data);
      if (fingerprint === this.catalogFingerprint) return;
      const revision = Math.max(Date.now(), this.remoteRevision + 1, this.catalogRevision + 1);
      const catalog = catalogSchema.parse({ revision, storeRevision: raw.revision, ...data });
      const frame = { type: "catalog" as const, catalog };
      if (Buffer.byteLength(JSON.stringify(frame)) > MAX_FRAME_BYTES) {
        this.status("Catalog exceeds the relay frame limit; reduce catalog metadata before connecting phones.");
        return;
      }
      this.catalogFingerprint = fingerprint;
      this.catalogRevision = revision;
      this.sendRelay(frame);
    } catch (error) {
      this.status(error instanceof Error ? error.message : "Could not read the Mac workspace catalog.");
    }
  }

  private sendRelay(frame: HostFrame): void { this.relay?.send(frame); }
  private write(socket: Socket, frame: unknown): void {
    const text = JSON.stringify(frame);
    if (Buffer.byteLength(text) <= MAX_FRAME_BYTES && !socket.destroyed) socket.write(text + "\n");
  }
  private status(message: string): void { this.options.onStatus?.(message); }
}

type RegistryWorkspaceKind = "project" | "playground" | "standalone";
interface RegistryFile {
  revision?: number;
  workspaces?: Array<{ id: unknown; name: string; kind?: RegistryWorkspaceKind; isArchived?: boolean }>;
  sessions?: Array<{ id: unknown; workspaceID: unknown; name: string; conversationID?: string; isArchived?: boolean; panes?: Array<{ id: unknown; kind: string }> }>;
}
function catalogWorkspaceKind(value: RegistryWorkspaceKind | undefined): "project" | "standalone" {
  if (value === undefined || value === "project") return "project";
  if (value === "playground" || value === "standalone") return "standalone";
  throw new Error("Unsupported workspace kind in the Mac registry");
}
function idValue(value: unknown): string {
  if (typeof value === "string") return value;
  if (value && typeof value === "object" && "rawValue" in value) return String((value as { rawValue: unknown }).rawValue);
  throw new Error("Malformed registry identifier");
}
function readFileSyncBounded(path: string): string {
  const info = lstatSync(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size < 2 || info.size > 4 * 1024 * 1024 || (info.mode & 0o077) !== 0) {
    throw new Error(`Unsafe local state file: ${basename(path)}`);
  }
  return readFileSync(path, "utf8");
}
function isMissing(error: unknown): boolean { return !!error && typeof error === "object" && "code" in error && error.code === "ENOENT"; }
async function assertSocketIsStale(path: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const probe = createConnection(path);
    probe.once("connect", () => { probe.destroy(); reject(new Error("A local Axo host broker is already running")); });
    probe.once("error", (error: NodeJS.ErrnoException) => {
      probe.destroy();
      if ("code" in error && (error.code === "ECONNREFUSED" || error.code === "ENOENT")) resolve();
      else reject(error);
    });
  });
}
