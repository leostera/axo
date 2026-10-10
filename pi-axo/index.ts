// Installed into ambient Pi's interactive TUI. Only an explicit inherited fd-3
// launch activates this internal seam; no listener, credentials or Pi RPC mode.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { z } from "zod";
const runtimeSchema = z.object({ host_generation: z.string().uuid(), runtime_generation: z.string().uuid(),
  target: z.object({ session_id: z.string().uuid(), pane_id: z.string().uuid() }).strict() }).strict();
const targetSchema = z.object({ runtime: runtimeSchema, chatId: z.string().min(1).max(128), interactionId: z.string().uuid().optional() }).strict();
const requestSchema = z.object({ id: z.string().max(128), method: z.enum(["bind", "get", "history", "send", "steer", "cancel", "shutdown"]),
  target: targetSchema.optional(), runtime: runtimeSchema.optional(), text: z.string().min(1).refine(value => value.trim().length > 0 && [...value].every(character => { const code = character.codePointAt(0)!; return code < 0xd800 || code > 0xdfff; })).optional() }).strict();

export default function managed(pi: ExtensionAPI) {
  pi.registerFlag("axo-managed-control", { description: "Use the daemon-owned inherited control endpoint", type: "boolean", default: false });
  let ctx: ExtensionContext | undefined;
  let socket: Socket | undefined;
  let bound: z.infer<typeof runtimeSchema> | undefined;
  let chatId: string | undefined;
  let sessionFile: string | undefined;
  let cwd: string | undefined;
  let interactionId: string | null = null;
  let uiWaits = 0;
  const activeTools = new Set<string>();
  let submissionPending = false;
  let pendingTimer: NodeJS.Timeout | undefined;
  let cancelling = false;
  let recovery = false;
  let buffer = Buffer.alloc(0);
  function write(value: unknown) {
    if (!socket || socket.destroyed) return;
    const raw = JSON.stringify(value) + "\n";
    if (Buffer.byteLength(raw) > 4*1024*1024 || socket.writableLength + Buffer.byteLength(raw) > 4*1024*1024) { recovery = true; socket.destroy(); return; }
    socket.write(raw, error => { if (error) recovery = true; });
  }
  function snapshot() {
    if (!ctx) throw new Error("notReady");
    return { chatId: ctx.sessionManager.getSessionId(), file: ctx.sessionManager.getSessionFile() ?? null,
      leafId: ctx.sessionManager.getLeafId(), cwd: ctx.cwd, mode: ctx.mode, stdinTTY: !!process.stdin.isTTY, stdoutTTY: !!process.stdout.isTTY, stderrTTY: !!process.stderr.isTTY,
      rows: process.stdout.rows, columns: process.stdout.columns, pid: process.pid,
      busy: !ctx.isIdle() || submissionPending, interactionId, uiWaits, tools: [...activeTools], pending: ctx.hasPendingMessages(), recovery,
      model: ctx.model ? { id: ctx.model.id, provider: ctx.model.provider } : null };
  }
  function changed() { if (bound && ctx) write({ kind: "status", state: snapshot() }); }
  function dispatch(raw: unknown) {
    const parsed = requestSchema.safeParse(raw);
    if (!parsed.success) { write({ id: typeof (raw as any)?.id === "string" ? (raw as any).id : null, error: "invalid" }); return; }
    const request = parsed.data;
    try {
      if (!ctx || ctx.mode !== "tui" || !process.stdin.isTTY || !process.stdout.isTTY) throw new Error("notInteractive");
      if (request.method === "bind") {
        if (bound || !request.runtime) throw new Error("rejected");
        bound = request.runtime; chatId = ctx.sessionManager.getSessionId(); sessionFile = ctx.sessionManager.getSessionFile(); cwd = ctx.cwd;
        write({ id: request.id, result: snapshot() }); return;
      }
      const target = request.target;
      if (!bound || !target || JSON.stringify(target.runtime) !== JSON.stringify(bound) || target.chatId !== chatId || ctx.sessionManager.getSessionId() !== chatId || ctx.sessionManager.getSessionFile() !== sessionFile || ctx.cwd !== cwd) throw new Error("stale");
      if (request.method === "get") { write({ id: request.id, result: snapshot() }); return; }
      if (request.method === "history") { write({ id: request.id, result: { leafId: ctx.sessionManager.getLeafId(), entries: ctx.sessionManager.getEntries(), branch: ctx.sessionManager.getBranch() } }); return; }
      if (recovery || (!interactionId && ctx.hasPendingMessages())) throw new Error("recovery");
      if (request.method === "shutdown") { write({ id: request.id, result: { disposition: "dispatched" } }); ctx.shutdown(); return; }
      if (request.method === "send") {
        if (!request.text || request.text.startsWith("/")) throw new Error("invalid");
        if (!ctx.isIdle() || submissionPending || interactionId || uiWaits || cancelling) throw new Error("busy");
        submissionPending = true;
        // Public void dispatch may be swallowed/blocked by an input hook. A deadline
        // is only uncertainty fencing, not execution/rejection proof or replay permission.
        pendingTimer = setTimeout(() => { if (submissionPending) { submissionPending = false; recovery = true; changed(); } }, 5000);
        pendingTimer.unref();
        pi.sendUserMessage(request.text);
      } else {
        if (!interactionId || target.interactionId !== interactionId || ctx.isIdle() || cancelling) throw new Error("staleInteraction");
        if (request.method === "steer") {
          if (!request.text || request.text.startsWith("/")) throw new Error("invalid");
          if (uiWaits) throw new Error("blocked");
          pi.sendUserMessage(request.text, { deliverAs: "steer" });
        } else if (request.method === "cancel") { cancelling = true; ctx.abort(); }
      }
      write({ id: request.id, result: { disposition: "dispatched" } }); // Public API void is not an execution/delivery receipt.
    } catch (error) {
      const code = error instanceof Error && ["notReady","notInteractive","rejected","stale","recovery","invalid","busy","staleInteraction","blocked"].includes(error.message) ? error.message : "unknown";
      if (code === "unknown") recovery = true;
      write({ id: request.id, error: code });
    }
  }
  pi.on("session_start", (_event, context) => {
    ctx = context;
    if (!pi.getFlag("axo-managed-control")) return;
    if (socket) { recovery = true; changed(); return; }
    if (ctx.mode !== "tui" || !process.stdin.isTTY || !process.stdout.isTTY) return;
    socket = new Socket({ fd: 3, readable: true, writable: true });
    socket.on("error", () => { recovery = true; });
    socket.on("end", () => { recovery = true; }); // Losing control never aborts accepted work.
    socket.on("data", bytes => {
      buffer = Buffer.concat([buffer, bytes]);
      for (;;) {
        const newline = buffer.indexOf(10);
        if (newline === -1) { if (buffer.length > 65536) { recovery = true; socket?.destroy(); } return; }
        const line = buffer.subarray(0, newline); buffer = buffer.subarray(newline + 1);
        if (line.length > 65536) { recovery = true; socket?.destroy(); return; }
        try { dispatch(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(line))); }
        catch { recovery = true; socket?.destroy(); return; }
      }
    });
    write({ kind: "ready", state: snapshot() });
  });
  pi.on("agent_start", (_event, context) => { ctx = context; submissionPending = false; clearTimeout(pendingTimer); interactionId ??= randomUUID(); changed(); });
  pi.on("agent_settled", (_event, context) => { ctx = context; interactionId = null; cancelling = false; changed(); });
  pi.on("tool_execution_start", (event, context) => { ctx = context; activeTools.add(event.toolCallId); changed(); });
  pi.on("tool_execution_end", (event, context) => { ctx = context; activeTools.delete(event.toolCallId); changed(); });
  pi.on("ui_prompt_start", (_event, context) => { ctx = context; uiWaits++; changed(); });
  pi.on("ui_prompt_end", (_event, context) => { ctx = context; uiWaits = Math.max(0, uiWaits - 1); changed(); });
  pi.on("session_shutdown", () => { clearTimeout(pendingTimer); socket?.end(); socket = undefined; });
}
