/**
 * What this Pi runs, as Axo clients see and change it (RFD0033): its model and thinking level
 * (`pi.state`), the slash commands a client may send (`pi.commands`) and the models it could
 * switch to (`pi.models`). pi-axo publishes each on the bridge when it changes; axod keeps the
 * latest for clients.
 */

/** Pi's thinking levels, lowest first, as `getSupportedThinkingLevels` in pi-ai orders them. */
export const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
export type ThinkingLevel = (typeof THINKING_LEVELS)[number];

/** More than any Pi has; a list past these is cut, never refused. */
export const MAX_COMMANDS = 500;
export const MAX_MODELS = 300;
const MAX_NAME_LENGTH = 128;
const MAX_DESCRIPTION_LENGTH = 200;

/** The parts of a Pi model this module reads. */
export interface ModelLike {
  provider: string;
  id: string;
  name?: string;
  reasoning?: boolean;
  thinkingLevelMap?: Partial<Record<string, unknown>>;
}

/** The parts of a Pi slash command this module reads. */
export interface CommandLike {
  name: string;
  description?: string;
  source: string;
}

export interface ModelRef {
  provider: string;
  id: string;
  name: string;
}

export interface PiState {
  model: ModelRef | null;
  thinkingLevel: ThinkingLevel;
}

export interface CommandInfo {
  name: string;
  description: string;
  source: "extension" | "prompt" | "skill";
}

export interface ModelInfo extends ModelRef {
  thinkingLevels: ThinkingLevel[];
}

export function isThinkingLevel(value: unknown): value is ThinkingLevel {
  return typeof value === "string" && (THINKING_LEVELS as readonly string[]).includes(value);
}

/** The levels `model` supports, as Pi's own picker offers them. */
export function supportedThinkingLevels(model: ModelLike): ThinkingLevel[] {
  if (!model.reasoning) return ["off"];
  return THINKING_LEVELS.filter(level => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    // The two highest exist only where a model maps them.
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
}

function clip(text: string, length: number): string {
  return text.length <= length ? text : `${text.slice(0, length - 1)}…`;
}

export function modelRef(model: ModelLike): ModelRef {
  return { provider: clip(model.provider, MAX_NAME_LENGTH), id: clip(model.id, MAX_NAME_LENGTH), name: clip(model.name || model.id, MAX_NAME_LENGTH) };
}

export function piState(model: ModelLike | undefined, thinkingLevel: string): PiState {
  return { model: model === undefined ? null : modelRef(model), thinkingLevel: isThinkingLevel(thinkingLevel) ? thinkingLevel : "off" };
}

/** The commands a client's prompt can run: Pi's terminal-only built-ins are not among them. */
export function commandList(commands: readonly CommandLike[]): CommandInfo[] {
  const listed: CommandInfo[] = [];
  for (const command of commands) {
    if (command.source !== "extension" && command.source !== "prompt" && command.source !== "skill") continue;
    if (command.name.length === 0 || command.name.length > MAX_NAME_LENGTH || /\s/u.test(command.name)) continue;
    listed.push({ name: command.name, description: clip((command.description ?? "").trim(), MAX_DESCRIPTION_LENGTH), source: command.source });
    if (listed.length === MAX_COMMANDS) break;
  }
  return listed;
}

/** The models Pi could switch to, by provider then name, each with the levels it supports. */
export function modelList(models: readonly ModelLike[]): ModelInfo[] {
  return models
    .map(model => ({ ...modelRef(model), thinkingLevels: supportedThinkingLevels(model) }))
    .sort((left, right) => left.provider.localeCompare(right.provider) || left.name.localeCompare(right.name))
    .slice(0, MAX_MODELS);
}
