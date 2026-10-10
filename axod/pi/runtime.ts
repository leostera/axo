// Managed headless Pi seam. Not yet a daemon/client RPC surface or native ownership cutover.
import { lstat, mkdir, open, realpath, rm } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { PiFailure, PiProcess, type PiRecord } from "./process.ts";
import { AmbientPi } from "./ambient.ts";

export type PiProfile = {
  pi: AmbientPi;
  args: readonly string[];
  cwd: string;
  sessionDirectory: string;
  env: NodeJS.ProcessEnv;
};
export type Persistence = { kind: "fresh" } | { kind: "resume"; chatId: string; file: string };
export type ChatTarget = { runtimeGeneration: string; chatId: string };
export type InteractionTarget = ChatTarget & { interactionId: string };
const stateSchema = z.object({
  sessionId: z.string().min(1).max(128), sessionFile: z.string(),
  model: z.object({ provider: z.string().min(1), id: z.string().min(1) }),
  isStreaming: z.boolean(), isCompacting: z.boolean(), pendingMessageCount: z.number().int().nonnegative(),
});
const dispositionSchema = z.object({ disposition: z.enum(["started", "handled", "queued"]) });
function data(record: PiRecord): unknown { return record.data; }

export class ManagedPi {
  readonly runtimeGeneration = randomUUID();
  private chatId = "";
  private file = "";
  private interactionId: string | null = null;
  private generation = 0;
  private recovery = false;
  private closing = false;
  private stopping: Promise<void> | undefined;
  private operation = false;
  private pendingQuestion: PiRecord | null = null;
  private readonly process: PiProcess;
  private leaseIdentity: { ino: number; dev: number };
  private constructor(private readonly profile: PiProfile, private readonly lease: string, leaseIdentity: { ino: number; dev: number }, persistence: Persistence) {
    this.leaseIdentity = leaseIdentity;
    const sessionArgs = persistence.kind === "fresh" ? [] : ["--session", persistence.file];
    this.process = new PiProcess(profile.pi.executable, [...profile.args, "--mode", "rpc", "--session-dir", profile.sessionDirectory, ...sessionArgs], profile.cwd, profile.env);
    this.process.events.on("gap", () => { this.recovery = true; });
    this.process.events.on("record", (event: PiRecord) => {
      if (event.type === "agent_start" && this.interactionId === null) this.interactionId = randomUUID();
      if (event.type === "agent_settled") { this.interactionId = null; this.pendingQuestion = null; }
      if (event.type === "extension_ui_request" && typeof event.method === "string" && ["select", "confirm", "input", "editor"].includes(event.method)) {
        if (typeof event.id !== "string") { this.recovery = true; return; }
        if (this.pendingQuestion !== null) this.recovery = true; // General multi-dialog semantics are not admitted.
        else this.pendingQuestion = event;
      }
      this.generation++;
    });
  }
  static async start(input: PiProfile, intent: Persistence): Promise<ManagedPi> {
    const profile: PiProfile = Object.freeze({ ...input, args: Object.freeze([...input.args]), env: Object.freeze({ ...input.env }) });
    const persistence = Object.freeze({ ...intent });
    if (!(profile.pi instanceof AmbientPi)) throw new PiFailure("rejected", "Validated ambient Pi dependency required");
    if (![profile.cwd, profile.sessionDirectory].every(isAbsolute)) throw new PiFailure("rejected", "Absolute approved Pi paths required");
    const directory = await lstat(profile.sessionDirectory);
    if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== process.getuid?.() || (directory.mode & 0o077) !== 0) {
      throw new PiFailure("rejected", "Owned private Pi directory required");
    }
    validateArguments(profile.args);
    const lease = join(profile.sessionDirectory, ".writer");
    try { await mkdir(lease, { mode: 0o700 }); }
    catch { throw new PiFailure("recovery", "Pi writer already owned or recovery required"); }
    const identity = await lstat(lease);
    let runtime: ManagedPi | undefined;
    try {
      if (persistence.kind === "resume") await validateResume(profile, persistence);
      runtime = new ManagedPi(profile, lease, identity, persistence);
      const state = stateSchema.parse(data(await runtime.process.request("get_state")));
      const entries = await runtime.process.request("get_entries");
      if (!z.object({ entries: z.array(z.unknown()), leafId: z.string().nullable() }).safeParse(data(entries)).success) throw new PiFailure("recovery", "Ambient Pi canonical-entry RPC unsupported");
      if (await realpath(dirname(state.sessionFile)) !== await realpath(profile.sessionDirectory)) throw new PiFailure("recovery", "Pi persistence outside approved binding");
      if (persistence.kind === "resume" && (state.sessionId !== persistence.chatId || resolve(state.sessionFile) !== resolve(persistence.file))) throw new PiFailure("recovery", "Pi exact-resume binding mismatch");
      if (state.isStreaming || state.isCompacting || state.pendingMessageCount !== 0) throw new PiFailure("recovery", "Pi started with unexpected active work");
      runtime.chatId = state.sessionId;
      runtime.file = state.sessionFile;
      return runtime;
    } catch {
      if (runtime) await runtime.stop();
      else await releaseLease(lease, identity);
      throw new PiFailure("recovery", "Pi admission failed; no ready binding");
    }
  }
  get target(): ChatTarget { return { runtimeGeneration: this.runtimeGeneration, chatId: this.chatId }; }
  get persistence(): { chatId: string; file: string } { return { chatId: this.chatId, file: this.file }; }
  private validate(target: ChatTarget) {
    if (target.chatId !== this.chatId || target.runtimeGeneration !== this.runtimeGeneration) throw new PiFailure("rejected", "Stale Pi destination");
    if (this.closing || this.recovery) throw new PiFailure("recovery", "Pi observation recovery required");
  }
  private async observed(target: ChatTarget) {
    this.validate(target);
    const state = stateSchema.safeParse(data(await this.process.request("get_state")));
    this.validate(target); // The runtime/transport may have failed while awaiting preparation.
    if (!state.success || state.data.sessionId !== this.chatId || state.data.sessionFile !== this.file) {
      this.recovery = true; throw new PiFailure("recovery", "Pi binding changed");
    }
    if (this.interactionId === null && state.data.pendingMessageCount > 0) {
      // A steering/settlement race must never leak latent input into a later normal interaction.
      this.recovery = true; throw new PiFailure("recovery", "Pi has unscoped pending input");
    }
    return state.data;
  }
  async snapshot(target: ChatTarget) {
    const state = await this.observed(target);
    return { target: this.target, interactionId: this.interactionId, busy: state.isStreaming || state.isCompacting,
      pendingMessageCount: state.pendingMessageCount, question: this.pendingQuestion ? {
        id: this.pendingQuestion.id, kind: this.pendingQuestion.method, options: this.pendingQuestion.options,
      } : null, revision: this.generation };
  }
  async history(target: ChatTarget, since?: string) {
    await this.observed(target);
    const result = await this.process.request("get_entries", since === undefined ? {} : { since });
    this.validate(target);
    const parsed = z.object({ entries: z.array(z.unknown()), leafId: z.string().nullable() }).safeParse(data(result));
    if (!parsed.success) { this.recovery = true; throw new PiFailure("unknown", "Invalid Pi history projection"); }
    return parsed.data;
  }
  private async control<T, Target extends ChatTarget>(target: Target, action: (captured: Readonly<Target>) => Promise<T>): Promise<T> {
    const captured = Object.freeze({ ...target });
    this.validate(captured);
    if (this.operation) throw new PiFailure("rejected", "Pi control admission busy");
    this.operation = true;
    try { return await action(captured); } finally { this.operation = false; }
  }
  async send(target: ChatTarget, message: string) {
    return this.control(target, async target => {
      const state = await this.observed(target);
      if (state.isStreaming || state.isCompacting || this.interactionId !== null || this.pendingQuestion) throw new PiFailure("rejected", "Normal input requires idle Pi");
      const response = await this.process.request("prompt", { message }); // Never adds streamingBehavior.
      const parsed = dispositionSchema.safeParse(data(response));
      if (!parsed.success || parsed.data.disposition === "queued") { this.recovery = true; throw new PiFailure("unknown", "Unexpected normal-input disposition"); }
      return parsed.data.disposition;
    });
  }
  async steer(target: InteractionTarget, message: string) {
    return this.control(target, async target => {
      const state = await this.observed(target);
      if (!state.isStreaming || this.interactionId !== target.interactionId || this.pendingQuestion) throw new PiFailure("rejected", "Steering requires captured active interaction");
      const response = await this.process.request("steer", { message });
      const parsed = dispositionSchema.safeParse(data(response));
      if (!parsed.success || parsed.data.disposition === "started") { this.recovery = true; throw new PiFailure("unknown", "Unexpected steering disposition"); }
      // Acceptance is not delivery. Idle with leftover queue is quarantined by observed(), not replayed.
      await this.observed(target);
      return parsed.data.disposition;
    });
  }
  async cancel(target: InteractionTarget) {
    return this.control(target, async target => {
      await this.observed(target);
      if (this.interactionId !== target.interactionId) throw new PiFailure("rejected", "Cancel requires captured active interaction");
      if (this.pendingQuestion) this.process.notify({ type: "extension_ui_response", id: this.pendingQuestion.id, cancelled: true });
      // Pi abort alone can continue queued input. Clear this interaction's queues before abort.
      await this.process.request("clear_queue");
      if (this.interactionId !== target.interactionId) throw new PiFailure("unknown", "Interaction settled during cancellation");
      await this.process.request("abort");
      const state = await this.observed(target);
      if (state.isStreaming || this.interactionId !== null || state.pendingMessageCount !== 0) { this.recovery = true; throw new PiFailure("unknown", "Pi cancellation not settled"); }
      return "settled" as const;
    });
  }
  async answer(target: InteractionTarget, questionId: string, choice: string) {
    return this.control(target, async target => {
      await this.observed(target);
      const question = this.pendingQuestion;
      if (this.interactionId !== target.interactionId || !question || question.id !== questionId || question.method !== "select" || !Array.isArray(question.options) || !question.options.includes(choice)) throw new PiFailure("rejected", "Stale question or invalid offered choice");
      this.process.notify({ type: "extension_ui_response", id: questionId, value: choice });
      this.pendingQuestion = null;
      return "dispatched" as const; // Public UI has no acceptance receipt; completion remains observed separately.
    });
  }
  async stop() {
    if (this.stopping) return this.stopping;
    this.closing = true;
    this.stopping = (async () => {
      await this.process.stop();
      await releaseLease(this.lease, this.leaseIdentity);
    })();
    return this.stopping;
  }
}
function validateArguments(args: readonly string[]) {
  const flags = new Set(["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-approve", "--offline", "--no-mcp"]);
  const values = new Set(["--extension", "--provider", "--model", "--thinking", "--tools", "--exclude-tools", "--system-prompt", "--append-system-prompt"]);
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (flags.has(arg)) continue;
    if (values.has(arg) && args[index + 1] !== undefined && !args[index + 1].startsWith("-")) { index++; continue; }
    throw new PiFailure("rejected", "Approved Pi profile cannot supply prompts, credentials, persistence or mode");
  }
}
async function releaseLease(path: string, identity: { ino: number; dev: number }) {
  const current = await lstat(path).catch(() => undefined);
  if (current?.ino === identity.ino && current.dev === identity.dev) await rm(path, { recursive: true });
}
async function validateResume(profile: PiProfile, persistence: Extract<Persistence, { kind: "resume" }>) {
  if (!isAbsolute(persistence.file) || await realpath(dirname(persistence.file)) !== await realpath(profile.sessionDirectory)) throw new PiFailure("rejected", "Resume requires owned exact persistence");
  const handle = await open(persistence.file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    const link = await lstat(persistence.file);
    if (!stat.isFile() || link.isSymbolicLink() || stat.nlink !== 1 || stat.uid !== process.getuid?.() || stat.size > 4 * 1024 * 1024) throw new PiFailure("rejected", "Invalid Pi resume file");
    const buffer = Buffer.alloc(4 * 1024 * 1024 + 1);
    let length = 0;
    while (length < buffer.length) {
      const result = await handle.read(buffer, length, buffer.length - length, null);
      if (result.bytesRead === 0) break;
      length += result.bytesRead;
    }
    if (length === buffer.length) throw new PiFailure("rejected", "Pi resume byte limit");
    const bytes = buffer.subarray(0, length);
    const newline = bytes.indexOf(10);
    if (newline < 0 || newline > 4096) throw new PiFailure("rejected", "Invalid Pi session header");
    if (bytes.at(-1) !== 10) throw new PiFailure("rejected", "Truncated Pi persistence");
    const records = new TextDecoder("utf-8", { fatal: true }).decode(bytes).trimEnd().split("\n").map(line => JSON.parse(line));
    const header = records[0];
    const ids = new Set<string>();
    for (const entry of records.slice(1)) {
      if (!entry || typeof entry.type !== "string" || typeof entry.id !== "string" || ids.has(entry.id) ||
          !(entry.parentId === null || ids.has(entry.parentId)) || typeof entry.timestamp !== "string") {
        throw new PiFailure("rejected", "Invalid Pi entry tree");
      }
      ids.add(entry.id);
    }
    if (header.type !== "session" || header.version !== 3 || header.id !== persistence.chatId || typeof header.cwd !== "string" || await realpath(header.cwd) !== await realpath(profile.cwd)) throw new PiFailure("rejected", "Resume identity/context mismatch");
    // Refuse legacy migration here; preserve original bytes for its separate import gate.
  } finally { await handle.close(); }
}
