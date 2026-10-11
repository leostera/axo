// Installed into ambient Pi's interactive TUI. Only an explicit inherited fd-3
// launch activates this internal seam; no listener, credentials or Pi RPC mode.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { questions } from "./questions.ts";
import { sessionTitles } from "./title.ts";
import { ControlFailure, type Record as ControlRecord, type Response } from "./control-protocol.ts";
const runtimeSchema = z.object({ host_generation: z.string().uuid(), runtime_generation: z.string().uuid(),
  target: z.object({ session_id: z.string().uuid(), pane_id: z.string().uuid() }).strict() }).strict();
const targetSchema = z.object({ runtime: runtimeSchema, chatId: z.string().uuid() }).strict();
const interactionTargetSchema = targetSchema.extend({ interactionId: z.string().uuid() }).strict();
const idSchema = z.string().min(1).max(128);
const textSchema = z.string().min(1).refine(value => /[^\p{White_Space}]/u.test(value) && !/^\p{White_Space}*\//u.test(value) && [...value].every(character => { const code = character.codePointAt(0)!; return code < 0xd800 || code > 0xdfff; }));
const requestSchema = z.discriminatedUnion("method", [
  z.object({ id: idSchema, method: z.literal("bind"), runtime: runtimeSchema }).strict(),
  z.object({ id: idSchema, method: z.literal("get"), target: targetSchema }).strict(),
  z.object({ id: idSchema, method: z.literal("history"), target: targetSchema }).strict(),
  z.object({ id: idSchema, method: z.literal("send"), target: targetSchema, text: textSchema }).strict(),
  z.object({ id: idSchema, method: z.literal("steer"), target: interactionTargetSchema, text: textSchema }).strict(),
  z.object({ id: idSchema, method: z.literal("cancel"), target: interactionTargetSchema }).strict(),
  z.object({ id: idSchema, method: z.literal("answer"), target: interactionTargetSchema, questionId: z.string().uuid(), optionId: z.string().uuid() }).strict(),
  z.object({ id: idSchema, method: z.literal("shutdown"), target: targetSchema }).strict(),
]);

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
  const ownedQuestions = questions(pi, changed, () => interactionId);
  sessionTitles(pi, changed);
  function write(value: ControlRecord<ReturnType<typeof snapshot>>) {
    if (!socket || socket.destroyed) return;
    const raw = JSON.stringify(value) + "\n";
    if (Buffer.byteLength(raw) > 4*1024*1024 || socket.writableLength + Buffer.byteLength(raw) > 4*1024*1024) { recovery = true; socket.destroy(); return; }
    socket.write(raw, error => { if (error) recovery = true; });
  }
  function snapshot() {
    if (!ctx) throw new ControlFailure("notReady");
    const title = pi.getSessionName();
    return { chatId: ctx.sessionManager.getSessionId(), file: ctx.sessionManager.getSessionFile() ?? null,
      title: title && title === title.trim() && title.length <= 80 && !/[\u0000-\u001f\u007f]/u.test(title) ? title : null,
      leafId: ctx.sessionManager.getLeafId(), cwd: ctx.cwd, mode: ctx.mode, stdinTTY: !!process.stdin.isTTY, stdoutTTY: !!process.stdout.isTTY, stderrTTY: !!process.stderr.isTTY,
      rows: process.stdout.rows, columns: process.stdout.columns, pid: process.pid,
      busy: !ctx.isIdle() || submissionPending, interactionId, uiWaits, question: ownedQuestions.current(), tools: [...activeTools], pending: ctx.hasPendingMessages(), recovery,
      model: ctx.model ? { id: ctx.model.id, provider: ctx.model.provider } : null };
  }
  function respond(id: string | null, response: Response<ReturnType<typeof snapshot>>) { write({ reply: { id, response } }); }
  function changed() { if (bound && ctx) write({ status: snapshot() }); }
  function dispatch(raw: unknown) {
    const parsed = requestSchema.safeParse(raw);
    if (!parsed.success) { const id = z.object({ id: idSchema }).safeParse(raw); respond(id.success ? id.data.id : null, { rejected: "invalid" }); return; }
    const request = parsed.data;
    try {
      if (!ctx || ctx.mode !== "tui" || !process.stdin.isTTY || !process.stdout.isTTY) throw new ControlFailure("notInteractive");
      if (request.method === "bind") {
        if (bound) throw new ControlFailure("rejected");
        bound = request.runtime; chatId = ctx.sessionManager.getSessionId(); sessionFile = ctx.sessionManager.getSessionFile(); cwd = ctx.cwd;
        respond(request.id, { snapshot: snapshot() }); return;
      }
      const target = request.target;
      if (!bound || JSON.stringify(target.runtime) !== JSON.stringify(bound) || target.chatId !== chatId || ctx.sessionManager.getSessionId() !== chatId || ctx.sessionManager.getSessionFile() !== sessionFile || ctx.cwd !== cwd) throw new ControlFailure("stale");
      if (request.method === "get") { respond(request.id, { snapshot: snapshot() }); return; }
      if (request.method === "history") { respond(request.id, { history: { leafId: ctx.sessionManager.getLeafId(), entries: ctx.sessionManager.getEntries(), branch: ctx.sessionManager.getBranch() } }); return; }
      if (recovery || (!interactionId && ctx.hasPendingMessages())) throw new ControlFailure("recovery");
      if (request.method === "answer") {
        if (cancelling || request.target.interactionId !== interactionId) throw new ControlFailure("staleInteraction");
        ownedQuestions.answer(request.questionId, request.optionId, request.target.interactionId); respond(request.id, "dispatched"); return;
      }
      if (request.method === "shutdown") { respond(request.id, "dispatched"); ctx.shutdown(); return; }
      if (request.method === "send") {
        if (!ctx.isIdle() || submissionPending || interactionId || uiWaits || ownedQuestions.current() || cancelling) throw new ControlFailure("busy");
        submissionPending = true;
        // Public void dispatch may be swallowed/blocked by an input hook. A deadline
        // is only uncertainty fencing, not execution/rejection proof or replay permission.
        pendingTimer = setTimeout(() => { if (submissionPending) { submissionPending = false; recovery = true; changed(); } }, 5000);
        pendingTimer.unref();
        pi.sendUserMessage(request.text);
      } else {
        if (!interactionId || request.target.interactionId !== interactionId || ctx.isIdle() || cancelling) throw new ControlFailure("staleInteraction");
        if (request.method === "steer") {
          if (uiWaits || ownedQuestions.current()) throw new ControlFailure("blocked");
          pi.sendUserMessage(request.text, { deliverAs: "steer" });
        } else if (request.method === "cancel") { cancelling = true; ctx.abort(); }
      }
      respond(request.id, "dispatched"); // Public API void is not an execution/delivery receipt.
    } catch (error) {
      const code = error instanceof ControlFailure ? error.code : "unknown";
      if (code === "unknown") recovery = true;
      respond(request.id, { rejected: code });
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
    write({ ready: snapshot() });
  });
  pi.on("agent_start", (_event, context) => { ctx = context; submissionPending = false; clearTimeout(pendingTimer); interactionId ??= randomUUID(); changed(); });
  pi.on("agent_settled", (_event, context) => { ctx = context; interactionId = null; cancelling = false; changed(); });
  pi.on("tool_execution_start", (event, context) => { ctx = context; activeTools.add(event.toolCallId); changed(); });
  pi.on("tool_execution_end", (event, context) => { ctx = context; activeTools.delete(event.toolCallId); changed(); });
  pi.on("ui_prompt_start", (_event, context) => { ctx = context; uiWaits++; changed(); });
  pi.on("ui_prompt_end", (_event, context) => { ctx = context; uiWaits = Math.max(0, uiWaits - 1); changed(); });
  pi.on("session_shutdown", () => { clearTimeout(pendingTimer); socket?.end(); socket = undefined; });
}
