// Private subprocess transport for vanilla Pi's documented RPC mode, not an Axo listener.
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";

export class PiFailure extends Error {
  constructor(readonly kind: "rejected" | "unknown" | "capacity" | "recovery", message: string) {
    super(message);
  }
}
export type PiRecord = Record<string, unknown>;
type Pending = {
  command: string;
  resolve: (value: PiRecord) => void;
  reject: (error: PiFailure) => void;
  timer: ReturnType<typeof setTimeout>;
};
const MAX_RECORD = 4 * 1024 * 1024;
const MAX_PENDING = 16;
const DEADLINE = 10000;

export class PiProcess {
  readonly events = new EventEmitter();
  private readonly pending = new Map<string, Pending>();
  private readonly child: ChildProcessWithoutNullStreams;
  private partial = Buffer.alloc(0);
  private discarding = false;
  private failed = false;
  private closing = false;
  private stopping: Promise<void> | undefined;
  private queuedBytes = 0;

  constructor(executable: string, args: readonly string[], cwd: string, env: NodeJS.ProcessEnv) {
    this.child = spawn(executable, [...args], { cwd, env, stdio: "pipe" });
    this.child.stdout.on("data", (chunk: Buffer) => this.read(chunk));
    this.child.stderr.resume(); // Payload/credential-bearing Pi diagnostics never become Axo diagnostics.
    this.child.on("error", () => this.fail("Pi process unavailable"));
    this.child.on("exit", () => this.fail("Pi process exited"));
    this.child.stdin.on("error", () => this.fail("Pi control write failed"));
  }
  private fail(message: string) {
    if (this.failed) return;
    this.failed = true;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new PiFailure("unknown", message));
    }
    this.pending.clear();
    this.events.emit("gap");
  }
  private read(chunk: Buffer) {
    // Split bytes on LF only. U+2028/U+2029 inside JSON strings are not framing.
    let start = 0;
    for (let index = 0; index <= chunk.length; index++) {
      if (index !== chunk.length && chunk[index] !== 10) continue;
      const part = chunk.subarray(start, index);
      if (!this.discarding) {
        if (this.partial.length + part.length > MAX_RECORD) {
          this.partial = Buffer.alloc(0);
          this.discarding = true;
          this.fail("Pi record limit; observation recovery required");
        } else this.partial = Buffer.concat([this.partial, part]);
      }
      if (index < chunk.length) {
        if (!this.discarding) this.record(this.partial);
        this.partial = Buffer.alloc(0);
        this.discarding = false;
      }
      start = index + 1;
    }
    // Keep draining even after a gap: an accepted Pi run must not stall on stdout backpressure.
  }
  private record(bytes: Buffer) {
    if (this.failed) return;
    let value: PiRecord;
    try {
      const parsed: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
      value = parsed as PiRecord;
      if (typeof value.type !== "string" || value.type.length > 64) throw new Error();
    } catch { this.fail("Invalid Pi record; observation recovery required"); return; }
    if (value.type !== "response") { this.events.emit("record", value); return; }
    if (typeof value.id !== "string") { this.fail("Uncorrelated Pi response"); return; }
    const pending = this.pending.get(value.id);
    if (!pending) { this.fail("Unexpected Pi response"); return; }
    this.pending.delete(value.id);
    clearTimeout(pending.timer);
    if (value.command !== pending.command || typeof value.success !== "boolean") {
      pending.reject(new PiFailure("unknown", "Invalid Pi response"));
      this.fail("Pi response mismatch");
    } else if (!value.success) {
      // Never propagate Pi's payload-bearing error text.
      pending.reject(new PiFailure("rejected", "Pi rejected command"));
    } else pending.resolve(value);
  }
  request(command: string, params: PiRecord = {}): Promise<PiRecord> {
    if (this.failed || this.closing) return Promise.reject(new PiFailure("recovery", "Pi channel not ready"));
    if (this.pending.size >= MAX_PENDING) return Promise.reject(new PiFailure("capacity", "Pi pending limit"));
    const id = randomUUID();
    const raw = JSON.stringify({ ...params, id, type: command }) + "\n";
    if (Buffer.byteLength(raw) > 65536) return Promise.reject(new PiFailure("rejected", "Pi command byte limit"));
    if (this.queuedBytes + Buffer.byteLength(raw) > 131072) return Promise.reject(new PiFailure("capacity", "Pi write budget"));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        // A timeout after dispatch is not rejection or permission to replay.
        this.fail("Pi command outcome unknown");
      }, DEADLINE);
      this.pending.set(id, { command, resolve, reject, timer });
      this.write(raw);
    });
  }
  notify(params: PiRecord) {
    if (this.failed || this.closing) throw new PiFailure("recovery", "Pi channel not ready");
    const raw = JSON.stringify(params) + "\n";
    if (Buffer.byteLength(raw) > 65536) throw new PiFailure("rejected", "Pi notification byte limit");
    if (this.queuedBytes + Buffer.byteLength(raw) > 131072) throw new PiFailure("capacity", "Pi write budget");
    this.write(raw);
  }
  private write(raw: string) {
    const bytes = Buffer.byteLength(raw);
    this.queuedBytes += bytes;
    this.child.stdin.write(raw, error => {
      this.queuedBytes -= bytes;
      if (error) this.fail("Pi command write outcome unknown");
    });
  }
  async stop(): Promise<void> {
    if (this.stopping) return this.stopping;
    this.closing = true;
    this.stopping = this.finishStop();
    return this.stopping;
  }
  private async finishStop(): Promise<void> {
    if (this.child.exitCode === null && this.child.signalCode === null) {
      const exited = once(this.child, "exit");
      this.child.stdin.end();
      const terminate = setTimeout(() => this.child.kill("SIGTERM"), 2000);
      const kill = setTimeout(() => this.child.kill("SIGKILL"), 5000);
      try { await exited; } finally { clearTimeout(terminate); clearTimeout(kill); }
    }
    this.fail("Pi stopped");
    this.events.removeAllListeners();
  }
}
