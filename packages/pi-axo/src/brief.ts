import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { callAxod } from "./axod-client.js";
import type { AxoMcpConfig } from "./mcp.js";

/**
 * The system prompt section (`<axo>`) that tells the agent what it can do through Axo: its
 * Sessions, asking the person, computer use, and the account's Macs and apps by name.
 *
 * Pi shows the model only the first line of an MCP server's description, so without this an
 * agent learns of Axo's tools only by calling `describeNamespace("axo")`. axod writes the text
 * (`axo.session.brief`, from `axo_mcp::brief`); this keeps it in the prompt.
 */
export const BRIEF_SECTION = "axo";

/** axod lists the account's apps for at most 3 seconds; this is that, plus a margin. */
const BRIEF_TIMEOUT_MS = 5_000;
/** A brief is a few lines. Anything longer is not one, and stays out of the prompt. */
const MAX_BRIEF_CHARS = 8_000;

/** Asks axod for this Session's brief: its answer, as is. */
export type FetchBrief = () => Promise<unknown>;

/** `axo.session.brief`'s answer; `null` when it is not one. */
export function parseBrief(answer: unknown): string | null {
  if (typeof answer !== "object" || answer === null) return null;
  const brief = (answer as { brief?: unknown }).brief;
  if (typeof brief !== "string") return null;
  const trimmed = brief.trim();
  return trimmed.length > 0 && trimmed.length <= MAX_BRIEF_CHARS ? trimmed : null;
}

export function fetchBriefFromAxod(config: AxoMcpConfig): FetchBrief {
  return () => callAxod(config.socket, "axo.session.brief", { sessionId: config.sessionId }, BRIEF_TIMEOUT_MS);
}

/**
 * Keeps the brief in the system prompt. It is asked for when the Session starts and again after
 * each turn, so a newly signed-in account shows up in the next one; the first turn waits for the
 * first answer, no longer than axod takes to give one. The section is set on every run with
 * the last brief axod gave, so the prompt changes only when the brief does.
 */
export function installAxoBrief(pi: ExtensionAPI, fetchBrief: FetchBrief): void {
  let current: string | null = null;
  let asking: Promise<void> | null = null;
  let reportedFailure = false;

  const refresh = (): Promise<void> => {
    asking ??= fetchBrief()
      .then(answer => {
        const brief = parseBrief(answer);
        if (brief === null) throw new Error("axod's answer is not a brief");
        current = brief;
        reportedFailure = false;
      })
      .catch((error: unknown) => {
        // The last brief stays; one failure in a row is reported, not each.
        if (!reportedFailure) console.error(`Axo brief unavailable: ${error instanceof Error ? error.message : String(error)}`);
        reportedFailure = true;
      })
      .finally(() => {
        asking = null;
      });
    return asking;
  };

  pi.on("session_start", () => {
    void refresh();
  });

  pi.on("agent_settled", () => {
    void refresh();
  });

  pi.on("before_agent_start", async event => {
    if (current === null) await (asking ?? refresh());
    if (current !== null) event.systemPromptOptions.sections[BRIEF_SECTION] = current;
  });
}
