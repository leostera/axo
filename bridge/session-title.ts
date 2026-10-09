import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const TOOL = "axo_set_title";
const NAMING_GUIDANCE = "After the user's first request, call axo_set_title once to give this untitled conversation a concise 3–7 word title. " +
  "Use the user's request as context, not a separate naming task. Do not wait for more input, start another agent, or change an existing title automatically. " +
  "Respect a user request not to name the conversation. Continue answering the user's request normally.";

interface TitleTarget { conversationID: string; file: string | undefined; generation: number }

export function cleanTitle(value: string): string | undefined {
  const title = value.trim().replace(/^[\"'“”]+|[\"'“”]+$/g, "").trim();
  if (!title || /[\r\n\p{Cc}]/u.test(title) || Buffer.byteLength(title) > 120) return;
  return title;
}

/** Main-turn metadata tool. Discovery/startup never sends a message or starts a model request. */
export function registerSessionTitles(pi: ExtensionAPI, waiting: () => () => void = () => () => {}): void {
  let generation = 0, active: TitleTarget | undefined;
  const calls = new Map<string, TitleTarget>();
  const target = (ctx: ExtensionContext): TitleTarget => ({ conversationID: ctx.sessionManager.getSessionId(), file: ctx.sessionManager.getSessionFile(), generation });
  const invalidate = () => { generation++; active = undefined; calls.clear(); };
  pi.on("session_start", (_event, ctx) => { invalidate(); active = target(ctx); });
  pi.on("session_shutdown", invalidate);
  pi.on("session_before_switch", invalidate);
  pi.on("session_before_fork", invalidate);
  pi.on("session_before_tree", invalidate);
  pi.on("before_agent_start", (event, ctx) => {
    active = target(ctx); // Also readmits a run after a cancelled navigation operation.
    delete event.systemPromptOptions.sections.axo_conversation_title;
    const alreadyNamed = pi.getSessionName() || ctx.sessionManager.getEntries().some(entry => entry.type === "custom" && entry.customType === "axo.title_set");
    if (process.env.AXO_AUTO_TITLE === "1" && !alreadyNamed && event.systemPromptOptions.selectedTools.includes(TOOL)) {
      event.systemPromptOptions.sections.axo_conversation_title = NAMING_GUIDANCE;
    }
  });
  pi.on("tool_call", (event, ctx) => {
    if (event.toolName !== TOOL) return;
    if (calls.size >= 32) calls.delete(calls.keys().next().value!);
    calls.set(event.toolCallId, target(ctx));
  });
  pi.registerTool({
    name: TOOL, label: "Set conversation title",
    description: "Set a concise title for the invoking Pi conversation. Naming an untitled conversation is immediate. Replacing an existing title requires replace=true and explicit user confirmation. Axo sidebar manual labels remain protected.",
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    parameters: Type.Object({
      title: Type.String({ minLength: 1, maxLength: 120, description: "A short, single-line title, at most 120 UTF-8 bytes." }),
      replace: Type.Optional(Type.Boolean({ description: "Ask the user to approve changing an existing title. Never set this for automatic naming." })),
    }),
    async execute(toolCallId, params, signal, _onUpdate, ctx) {
      const captured = calls.get(toolCallId); calls.delete(toolCallId);
      const assertCurrent = () => {
        if (!captured || signal?.aborted || active?.generation !== captured.generation || generation !== captured.generation ||
            active.conversationID !== captured.conversationID || active.file !== captured.file ||
            ctx.sessionManager.getSessionId() !== captured.conversationID || ctx.sessionManager.getSessionFile() !== captured.file) {
          throw new Error("The conversation changed or this title request was cancelled. No title was changed.");
        }
      };
      assertCurrent();
      const title = cleanTitle(params.title);
      if (!title) throw new Error("Use a nonempty, single-line title of at most 120 UTF-8 bytes, without control characters.");
      const previous = pi.getSessionName();
      if (previous && previous !== title) {
        if (!params.replace) throw new Error("This conversation already has a title. Automatic naming cannot overwrite it; request confirmation with replace=true.");
        if (!ctx.hasUI) throw new Error("Replacing an existing title requires user confirmation in an interactive session.");
        const resume = waiting();
        let approved = false;
        try { approved = await ctx.ui.confirm("Change conversation title?", `Change “${previous}” to “${title}”?`); }
        finally { resume(); }
        assertCurrent();
        if (approved !== true) throw new Error("Title change cancelled. The existing title was retained.");
        if (pi.getSessionName() !== previous) throw new Error("The title changed while approval was pending. The newer title was retained.");
      }
      if (previous !== title) {
        // No await between the final destination/name checks and the public Pi persistence API.
        pi.setSessionName(title);
        pi.appendEntry("axo.title_set", { toolCallId, conversationID: captured!.conversationID });
      }
      return { content: [{ type: "text", text: `Conversation title: ${title}` }], details: { title, conversationID: captured!.conversationID } };
    },
  });
}
