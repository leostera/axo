// Only Axo-owned questions are remotely actionable. Generic Pi UI waits are not approvals.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { randomUUID } from "node:crypto";
import { ControlFailure } from "./control-protocol.ts";
export interface Question { id: string; interactionId: string; title: string; options: { id: string; label: string }[] }
export function questions(pi: ExtensionAPI, changed: () => void, interaction: () => string | null) {
  let pending: { question: Question; finish: (value: string | undefined) => void } | undefined;
  pi.registerTool({ name: "axo_ask", label: "Ask on Mac or iPhone", description: "Ask the user a multiple-choice question. Wait for an offered answer; cancellation never grants approval.",
    parameters: Type.Object({ title: Type.String({ minLength: 1, maxLength: 2000 }), options: Type.Array(Type.String({ minLength: 1, maxLength: 500 }), { minItems: 2, maxItems: 8 }) }),
    async execute(_id, args, signal, _update, ctx) {
      const interactionId = interaction();
      if (!interactionId || pending || signal?.aborted || new Set(args.options).size !== args.options.length) throw new Error("Question unavailable or invalid");
      const question: Question = { id: randomUUID(), interactionId, title: args.title, options: args.options.map(label => ({ id: randomUUID(), label })) };
      const local = new AbortController();
      let finish!: (value: string | undefined) => void;
      const answer = new Promise<string | undefined>(resolve => {
        finish = value => { if (pending?.question.id !== question.id) return; pending = undefined; local.abort(); resolve(!signal?.aborted && question.options.some(option => option.label === value) ? value : undefined); changed(); };
      });
      pending = { question, finish }; const cancel = () => finish(undefined);
      signal?.addEventListener("abort", cancel, { once: true }); changed();
      if (signal?.aborted) cancel();
      else if (ctx.hasUI) void ctx.ui.select(args.title, args.options, { signal: local.signal }).then(finish, cancel);
      try { const value = await answer; return { content: [{ type: "text" as const, text: value === undefined ? "User cancelled. No approval granted." : `User chose: ${value}` }], details: { value: value ?? null } }; }
      finally { signal?.removeEventListener("abort", cancel); }
    },
  });
  return {
    current: () => pending?.question ?? null,
    answer(questionId: string, optionId: string, interactionId: string) {
      if (!pending || pending.question.id !== questionId || pending.question.interactionId !== interactionId) throw new ControlFailure("staleInteraction");
      const option = pending.question.options.find(option => option.id === optionId);
      if (!option) throw new ControlFailure("invalid");
      pending.finish(option.label);
    },
  };
}
