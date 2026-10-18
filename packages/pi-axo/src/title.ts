import { Type } from "typebox";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { AxoPiBridgeServer } from "./bridge-server.js";
import type { PiSessionIdentity } from "./protocol.js";

const AXO_APPEARANCE_ENTRY = "axo_session_appearance";
const TITLE_TOOL = "axo_set_title";
const titleParameters = Type.Object({
  title: Type.String({ minLength: 1, maxLength: 80, description: "A concise title for this session, without the emoji." }),
  emoji: Type.String({ minLength: 1, maxLength: 16, description: "One emoji that represents the first user request." }),
});

const FIRST_MESSAGE_NAMING_GUIDANCE = [
  "Name this Axo Session from the intent of the user's first request in this conversation.",
  "Before answering the first request, call axo_set_title with a concise title (at most 80 characters) and one representative emoji in the separate emoji field.",
  "Do not include the emoji in the title, ask the user to name the session, or make a separate model request just for naming.",
].join(" ");

function validTitle(value: string): string | undefined {
  const title = value.trim();
  if (title.length === 0 || title.length > 80 || /\p{Cc}/u.test(title)) return undefined;
  return title;
}

function validEmoji(value: string): string | undefined {
  const emoji = value.trim();
  if (emoji.length === 0 || emoji.length > 16 || /[\s\p{Cc}]/u.test(emoji)) return undefined;
  const pictograph = /\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(emoji)
    || /[#*0-9]\uFE0F?\u20E3/u.test(emoji);
  if (!pictograph) return undefined;
  const graphemes = Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(emoji));
  return graphemes.length === 1 ? emoji : undefined;
}

function latestSessionEmoji(context: ExtensionContext): string | undefined {
  const entries = context.sessionManager.getBranch();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry?.type !== "custom" || entry.customType !== AXO_APPEARANCE_ENTRY) continue;
    if (typeof entry.data !== "object" || entry.data === null || !("emoji" in entry.data)) return undefined;
    const emoji = (entry.data as { emoji?: unknown }).emoji;
    return typeof emoji === "string" ? validEmoji(emoji) : undefined;
  }
  return undefined;
}

function sameIdentity(left: PiSessionIdentity | undefined, right: PiSessionIdentity | null): boolean {
  return left !== undefined && right !== null
    && left.axoSessionId === right.axoSessionId
    && left.axoPaneId === right.axoPaneId
    && left.piSessionId === right.piSessionId
    && left.sessionFile === right.sessionFile
    && left.processId === right.processId;
}

export function installAxoSessionNaming(
  pi: ExtensionAPI,
  bridge: AxoPiBridgeServer,
  currentIdentity: () => PiSessionIdentity | undefined,
  identityForContext: (context: ExtensionContext) => PiSessionIdentity | null,
): void {
  let needsTitle = false;

  pi.registerTool({
    name: TITLE_TOOL,
    label: "Name Axo Session",
    description: "Set this Axo Session's concise title and representative emoji. Use once, based on the first user request.",
    promptSnippet: "Set a concise Axo Session title and one representative emoji from the first user request.",
    parameters: titleParameters,
    async execute(_toolCallId, parameters, _signal, _onUpdate, context) {
      const identity = currentIdentity();
      if (!sameIdentity(identity, identityForContext(context))) {
        throw new Error("This Pi conversation is no longer bound to the active Axo Session.");
      }
      if (context.sessionManager.getSessionName() !== undefined) {
        throw new Error("This Pi conversation already has a session title.");
      }

      const title = validTitle(parameters.title);
      const emoji = validEmoji(parameters.emoji);
      if (title === undefined || emoji === undefined) {
        throw new Error("Provide a nonempty title and exactly one representative emoji.");
      }

      pi.setSessionName(title);
      pi.appendEntry(AXO_APPEARANCE_ENTRY, { emoji });
      needsTitle = false;
      await bridge.publish("axo.session.metadata", { title, emoji });
      return {
        content: [{ type: "text", text: `Session named ${emoji} ${title}.` }],
        details: { title, emoji },
      };
    },
  });

  const publishCurrentMetadata = (context: ExtensionContext) => {
    const title = context.sessionManager.getSessionName();
    const emoji = latestSessionEmoji(context);
    if (title !== undefined || emoji !== undefined) {
      void bridge.publish("axo.session.metadata", { title: title ?? null, emoji: emoji ?? null });
    }
    return title;
  };

  pi.on("session_start", (_event, context) => {
    needsTitle = publishCurrentMetadata(context) === undefined;
  });

  pi.on("session_info_changed", event => {
    needsTitle = event.name === undefined;
  });

  pi.on("agent_settled", (_event, context) => {
    publishCurrentMetadata(context);
  });

  pi.on("before_agent_start", (event, context) => {
    const title = publishCurrentMetadata(context);
    if (title !== undefined) needsTitle = false;
    if (!needsTitle || event.messageType !== "user") return;
    if (!event.systemPromptOptions.selectedTools.includes(TITLE_TOOL)) return;
    event.systemPromptOptions.sections.axo_session_title = FIRST_MESSAGE_NAMING_GUIDANCE;
  });
}
