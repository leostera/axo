import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export function sessionTitles(pi: ExtensionAPI, changed: () => void) {
  pi.registerTool({
    name: "axo_set_title", label: "Set session title",
    description: "Name this conversation once its purpose is clear. Use a short, descriptive title; update it when the purpose materially changes.",
    parameters: Type.Object({ title: Type.String({ minLength: 1, maxLength: 80 }) }),
    async execute(_id, { title }) {
      if (title !== title.trim() || !title || title.length > 80 || /[\u0000-\u001f\u007f]/u.test(title)) {
        throw new Error("Use a nonempty, trimmed title of at most 80 characters without control characters.");
      }
      pi.setSessionName(title); // Pi alone persists canonical session metadata.
      changed();
      return { content: [{ type: "text", text: "Session title updated." }], details: { title } };
    },
  });
  pi.on("before_agent_start", event => {
    if (event.systemPromptOptions.selectedTools.includes("axo_set_title")) {
      event.systemPromptOptions.sections.axo_session_title = "Use axo_set_title during the main turn once you understand the user's request. Do not ask for a session name, invent a user message, or run a separate title-generation model call.";
    } else {
      delete event.systemPromptOptions.sections.axo_session_title;
    }
  });
}
