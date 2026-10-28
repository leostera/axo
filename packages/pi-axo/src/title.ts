import { basename } from "node:path";
import { homedir } from "node:os";
import { Type } from "typebox";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { AxoPiBridgeServer } from "./bridge-server.js";
import type { PiSessionIdentity } from "./protocol.js";

const AXO_APPEARANCE_ENTRY = "axo_session_appearance";
const TITLE_TOOL = "axo_set_title";
/**
 * How titles read: a project keyword first, then a few words, so the sidebar sorts by eye and
 * typing the keyword finds every Session about that project.
 */
const TITLE_STYLE = [
  "Titles are very short (2 to 5 words, about 30 characters at most) and start with one keyword naming the project, product or ticket they are about, so searching that keyword finds every Session about it.",
  "Write it as `<keyword>: <focus>`, lowercase except for names and ticket IDs, with no filler words, or just the keyword and a word or two when that says it all.",
  "Good: \"r2facts: optimize push flow\", \"iphone app\", \"evalkit: prepare release\", \"mu: pi parity\", \"workers-sdk PR-16888\", \"JIRA-1234: testing\".",
  "Bad: \"find townlake and sentry data for debugging\", \"Address review feedback on PR 16186\".",
].join(" ");

const titleParameters = Type.Object({
  title: Type.String({
    minLength: 1,
    maxLength: 80,
    description: "A very short title: a project keyword, then the focus, e.g. \"evalkit: prepare release\". No emoji.",
  }),
  emoji: Type.String({ minLength: 1, maxLength: 16, description: "One emoji that represents the session's current focus." }),
});

/** The project keyword the working directory suggests; none in the home directory. */
function projectHint(cwd: string): string {
  const name = basename(cwd);
  if (name.length === 0 || cwd === homedir()) return "";
  return ` This Session works in \`${cwd}\`, so the keyword is probably \`${name}\` unless the request is about something more specific.`;
}

function firstMessageNamingGuidance(cwd: string): string {
  return [
    "Name this Axo Session from the intent of the user's first request in this conversation.",
    "Before answering the first request, call axo_set_title with a title and one representative emoji in the separate emoji field.",
    TITLE_STYLE + projectHint(cwd),
    "Do not include the emoji in the title, ask the user to name the session, or make a separate model request just for naming.",
  ].join(" ");
}

function existingTitleGuidance(cwd: string): string {
  return [
    "Keep this Axo Session's title and emoji representative of its current focus.",
    "If the conversation's focus changes materially or the current title becomes inaccurate, call axo_set_title again to update the title and emoji.",
    TITLE_STYLE + projectHint(cwd),
    "Do not rename on routine turns.",
  ].join(" ");
}

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
  pi.registerTool({
    name: TITLE_TOOL,
    label: "Set Axo Session Title",
    description: `Set or update this Axo Session's title and representative emoji. ${TITLE_STYLE} Update it when the conversation's focus materially changes; do not rename on routine turns.`,
    promptSnippet: "Set or update the Axo Session title and emoji to reflect the conversation's current focus.",
    parameters: titleParameters,
    async execute(_toolCallId, parameters, _signal, _onUpdate, context) {
      const identity = currentIdentity();
      if (!sameIdentity(identity, identityForContext(context))) {
        throw new Error("This Pi conversation is no longer bound to the active Axo Session.");
      }
      const hadTitle = context.sessionManager.getSessionName() !== undefined;
      const title = validTitle(parameters.title);
      const emoji = validEmoji(parameters.emoji);
      if (title === undefined || emoji === undefined) {
        throw new Error("Provide a nonempty title and exactly one representative emoji.");
      }

      pi.setSessionName(title);
      pi.appendEntry(AXO_APPEARANCE_ENTRY, { emoji });
      // setSessionName also emits session_info_changed, but forwarding that callback is
      // asynchronous. Publish the canonical title event directly so the sidebar updates now.
      await bridge.publish("session.info", { name: title });
      await bridge.publish("axo.session.metadata", { title: null, emoji });
      return {
        content: [{ type: "text", text: `${hadTitle ? "Session title updated to" : "Session named"} ${emoji} ${title}.` }],
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
    publishCurrentMetadata(context);
  });

  pi.on("agent_settled", (_event, context) => {
    publishCurrentMetadata(context);
  });

  pi.on("before_agent_start", (event, context) => {
    const title = publishCurrentMetadata(context);
    if (event.messageType !== "user") return;
    if (!event.systemPromptOptions.selectedTools.includes(TITLE_TOOL)) return;
    event.systemPromptOptions.sections.axo_session_title = title === undefined
      ? firstMessageNamingGuidance(context.cwd)
      : existingTitleGuidance(context.cwd);
  });
}
