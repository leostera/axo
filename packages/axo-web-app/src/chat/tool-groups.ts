import type { ToolActivity } from "./transcript.ts";

/**
 * Where a tool's row sits among the tools the agent used one after another, with nothing said in
 * between: they show as one block, headed by what they did together.
 */
export interface ToolGroupPlace {
  readonly first: boolean;
  readonly last: boolean;
  /** On the first row of a block of two or more: what the block did, as "Read 3 files, ran a command". */
  readonly title: string | null;
}

/** One tool's row, in the order the transcript lists them, and whether it is a tool's. */
export interface Grouped<T> {
  readonly row: T;
  readonly tool: ToolActivity | null;
}

/** Each tool row's place in its block; null for every row that is not a tool's. */
export function toolGroups<T>(rows: readonly Grouped<T>[]): (ToolGroupPlace | null)[] {
  const places: (ToolGroupPlace | null)[] = rows.map(() => null);
  let start = 0;
  while (start < rows.length) {
    if (!rows[start]!.tool) {
      start += 1;
      continue;
    }
    let end = start;
    while (end + 1 < rows.length && rows[end + 1]!.tool) end += 1;
    const tools = rows.slice(start, end + 1).map(row => row.tool!);
    const title = tools.length > 1 ? toolGroupTitle(tools) : null;
    for (let index = start; index <= end; index++) {
      places[index] = { first: index === start, last: index === end, title: index === start ? title : null };
    }
    start = end + 1;
  }
  return places;
}

/** What a block of tools did, in the order it first did each thing: "Read 3 files, edited 2 files, ran 4 commands". */
export function toolGroupTitle(tools: readonly ToolActivity[]): string {
  const actions = new Map<string, { verb: string; one: string; many: string; things: Set<string>; count: number }>();
  for (const tool of tools) {
    const [verb, one, many] = action(tool);
    const key = `${verb} ${one} ${many}`;
    const entry = actions.get(key) ?? { verb, one, many, things: new Set<string>(), count: 0 };
    entry.count += 1;
    // A file edited twice is one file edited.
    if (tool.subtitle && many === "files") entry.things.add(tool.subtitle.split(" · ")[0]!);
    actions.set(key, entry);
  }
  const phrases = [...actions.values()].map(({ verb, one, many, things, count }) => {
    const n = things.size || count;
    if (n === 1) return `${verb} ${one}`;
    // "used mcp 3 times": a tool with no better words is counted after its name.
    return many === "" ? `${verb} ${one} ${n} times` : `${verb} ${n} ${many}`;
  });
  const sentence = phrases.join(", ");
  return sentence.charAt(0).toUpperCase() + sentence.slice(1);
}

/** How a tool's work reads: its verb, and what it acts on, one and many. */
function action(tool: ToolActivity): [string, string, string] {
  switch (tool.name) {
    case "bash": return ["ran", "a command", "commands"];
    case "edit": return ["edited", "a file", "files"];
    case "write": return ["wrote", "a file", "files"];
    case "read": return ["read", "a file", "files"];
    case "codemode": case "mcpScript": return ["ran", "a script", "scripts"];
    case "grep": case "find": case "ls": case "search": return ["searched", "once", "times"];
    default: return ["used", tool.name, ""];
  }
}

/** The tool's input in a line, for its row: the path it works on, or the first line it was given. */
export function toolPreview(tool: ToolActivity): string {
  if (tool.subtitle) return tool.subtitle;
  const text = tool.command ?? (tool.input?.kind === "args" ? null : tool.input?.text) ?? "";
  return text.split("\n").map(line => line.trim()).find(line => line && !line.startsWith("//")) ?? "";
}
