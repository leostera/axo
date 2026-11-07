import type { PiCommand, PiModel, PiRuntime, ThinkingLevel } from "@axo/protocol";
import type { WaitingPrompt } from "./workbench.ts";

/**
 * What the message box shows and offers of a Session's Pi (RFD0033): its model and thinking level,
 * the `/` list, and what a held Send can do.
 */

const levelNames: Record<ThinkingLevel, string> = {
  off: "Off", minimal: "Minimal", low: "Low", medium: "Medium", high: "High", xhigh: "Extra high", max: "Max",
};

export function levelName(level: ThinkingLevel): string {
  return levelNames[level];
}

/** "Opus 4.1 · High", as the box names what Pi runs; null until Pi has said. */
export function runtimeLabel(pi: PiRuntime | undefined): string | null {
  if (!pi?.model) return null;
  return pi.thinkingLevel === "off" ? pi.model.name : `${pi.model.name} · ${levelName(pi.thinkingLevel)}`;
}

/** The models by provider, in the order Pi lists them. */
export function modelsByProvider(models: readonly PiModel[]): Array<{ provider: string; models: PiModel[] }> {
  const groups = new Map<string, PiModel[]>();
  for (const model of models) groups.set(model.provider, [...(groups.get(model.provider) ?? []), model]);
  return [...groups].map(([provider, list]) => ({ provider, models: list }));
}

/** The thinking levels the model Pi runs supports, from what Pi listed of it. */
export function levelsOf(models: readonly PiModel[], pi: PiRuntime | undefined): ThinkingLevel[] {
  const current = pi?.model;
  return current ? models.find(model => model.provider === current.provider && model.id === current.id)?.thinkingLevels ?? [] : [];
}

/** What follows a `/` at the start of the box while the command is still being named, or null. */
export function slashQuery(draft: string): string | null {
  const match = /^\/(\S*)$/u.exec(draft);
  return match ? match[1]! : null;
}

export const MAX_SLASH_ROWS = 8;

/** The commands a query names: those it starts first, then those whose name has it, then by description. */
export function matchingCommands(commands: readonly PiCommand[], query: string): PiCommand[] {
  const q = query.toLowerCase();
  const rank = (command: PiCommand) => {
    const name = command.name.toLowerCase();
    if (name.startsWith(q)) return 0;
    if (name.includes(q)) return 1;
    if (command.description.toLowerCase().includes(q)) return 2;
    return 3;
  };
  return commands
    .map((command, index) => ({ command, index, rank: rank(command) }))
    .filter(entry => entry.rank < 3)
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .slice(0, MAX_SLASH_ROWS)
    .map(entry => entry.command);
}

/** The box once a command is chosen: the command, ready for its arguments. */
export function withCommand(command: PiCommand): string {
  return `/${command.name} `;
}

/** What a waiting message says of itself. A queued one is in the log: it waits for the reply, or steers it. */
export function pendingLabel(prompt: Pick<WaitingPrompt, "state" | "delivery">): string {
  switch (prompt.state) {
    case "sending": return "Sending…";
    case "sent": return "Sent";
    case "waking": return "Waiting for the agent to start…";
    case "uncertain": return "Not confirmed yet · trying again";
    case "queued": return prompt.delivery === "steer" ? "Steering · read at the agent's next step" : "Queued · answered after the current reply";
  }
}
