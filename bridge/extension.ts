import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { loadConfig } from "./config";
import { RelayConnection } from "./connection";
import { projectMessages, submittedCommandIds } from "./projection";
import type { PhoneFrame, Question } from "../shared/protocol";

interface PendingQuestion { question: Question; finish: (answer: string | undefined) => void }

export default function axoBridge(pi: ExtensionAPI): void {
  let context: ExtensionContext | undefined;
  let connection: RelayConnection | undefined;
  let pending: PendingQuestion | undefined;
  let submitted = new Set<string>();
  let refresh: ReturnType<typeof setTimeout> | undefined;

  function snapshot(): void {
    if (!context) return;
    connection?.send({
      type: "snapshot", sessionId: context.sessionManager.getSessionId(),
      state: pending ? "waiting" : context.isIdle() ? "idle" : "running",
      messages: projectMessages(context.sessionManager.getBranch()), question: pending?.question ?? null,
    });
  }

  function scheduleSnapshot(ctx: ExtensionContext): void {
    context = ctx;
    clearTimeout(refresh);
    // message_end can arrive before the session manager persists the message.
    refresh = setTimeout(snapshot, 50);
  }

  function receive(frame: PhoneFrame): void {
    if (!context) return;
    if (frame.type === "sync") { snapshot(); return; }
    const fail = (message: string) => connection?.send({ type: "error", id: frame.id, message });
    if (frame.sessionId !== context.sessionManager.getSessionId()) { fail("The desktop conversation changed. Refresh before sending."); return; }
    if (submitted.has(frame.id)) { fail("Already submitted; not replayed. Check the conversation."); return; }
    if (frame.type === "answer") {
      if (!pending || pending.question.id !== frame.questionId) { fail("That question is no longer pending."); return; }
      if (!pending.question.options.includes(frame.value)) { fail("Choose one of the offered answers."); return; }
      submitted.add(frame.id);
      pending.finish(frame.value);
    } else {
      if (pending) { fail("Answer the pending question before sending another prompt."); return; }
      // Record before dispatch: ambiguous crashes must never blindly replay side effects.
      pi.appendEntry("axo.submitted", { id: frame.id });
      submitted.add(frame.id);
      pi.sendUserMessage(frame.text, { deliverAs: "followUp" });
    }
    // The extension API is fire-and-forget; submitted is NOT proof of execution.
    connection?.send({ type: "ack", id: frame.id, disposition: "submitted" });
  }

  pi.on("session_start", (_event, ctx) => {
    connection?.stop();
    pending?.finish(undefined);
    context = ctx;
    submitted = submittedCommandIds(ctx.sessionManager.getEntries());
    const configPath = process.env.AXO_CONFIG;
    if (!configPath) { ctx.ui.setStatus("axo", "Axo: local only (AXO_CONFIG not set)"); return; }
    try {
      connection = new RelayConnection(loadConfig(configPath), receive,
        status => context?.ui.setStatus("axo", `Axo: ${status}`), snapshot);
      connection.connect();
    } catch {
      ctx.ui.notify("Axo could not load its relay credentials. Check AXO_CONFIG and file permissions (0600).", "error");
    }
  });
  pi.on("message_end", (_event, ctx) => scheduleSnapshot(ctx));
  pi.on("agent_start", (_event, ctx) => scheduleSnapshot(ctx));
  pi.on("agent_settled", (_event, ctx) => scheduleSnapshot(ctx));
  pi.on("session_shutdown", () => {
    clearTimeout(refresh);
    pending?.finish(undefined);
    connection?.stop();
    context = undefined;
  });

  pi.registerTool({
    name: "axo_ask", label: "Ask on Mac or iPhone",
    description: "Ask the user a multiple-choice question and wait for their answer on the Mac or iPhone. Use for clarification and confirmation. Never interpret cancellation as approval.",
    parameters: Type.Object({
      title: Type.String({ minLength: 1, maxLength: 2000 }),
      options: Type.Array(Type.String({ minLength: 1, maxLength: 500 }), { minItems: 2, maxItems: 8 }),
    }),
    async execute(_toolCallId, args, signal, _onUpdate, ctx) {
      if (pending) throw new Error("Another question is already pending");
      if (new Set(args.options).size !== args.options.length) throw new Error("Options must be distinct");
      if (signal?.aborted) throw new Error("Question cancelled");
      context = ctx;
      const question = { id: crypto.randomUUID(), title: args.title, options: args.options };
      const localDialog = new AbortController();
      let finish!: (answer: string | undefined) => void;
      const answer = new Promise<string | undefined>(resolve => {
        finish = value => {
          if (pending?.question.id !== question.id) return;
          pending = undefined;
          localDialog.abort();
          resolve(value);
          snapshot();
        };
      });
      pending = { question, finish };
      const cancel = () => finish(undefined);
      signal?.addEventListener("abort", cancel, { once: true });
      snapshot();
      if (ctx.hasUI) void ctx.ui.select(args.title, args.options, { signal: localDialog.signal }).then(finish, cancel);
      try {
        const value = await answer;
        return { content: [{ type: "text" as const, text: value === undefined ? "User cancelled. No approval granted." : `User chose: ${value}` }], details: { value: value ?? null } };
      } finally { signal?.removeEventListener("abort", cancel); }
    },
  });
}
