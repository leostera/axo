import type { ConversationMessage } from "../shared/protocol";

/** Native presentation mirrors Pi's built-in renderers without transferring raw arguments. */
export function presentTool(name: string, args: Record<string, unknown>): Pick<ConversationMessage, "text" | "toolPresentation"> {
  const tool = name.split(".").at(-1);
  const path = string(args.path ?? args.file_path);
  switch (tool) {
    case "bash":
    case "powershell":
      return { text: string(args.command).slice(0, 1_000), toolPresentation: {
        kind: "shell", title: tool === "bash" ? "Bash" : "PowerShell",
        ...(typeof args.timeout === "number" ? { subtitle: `Timeout: ${args.timeout}s` } : {}),
      } };
    case "edit": {
      const edits = Array.isArray(args.edits) ? args.edits : [{ oldText: args.oldText, newText: args.newText }];
      const diff = edits.filter(edit => edit && typeof edit === "object").map(edit => {
        const change = edit as Record<string, unknown>;
        return string(change.oldText).split("\n").map(line => `- ${line}`).join("\n")
          + "\n" + string(change.newText).split("\n").map(line => `+ ${line}`).join("\n");
      }).join("\n\n");
      return { text: diff.slice(0, 1_000), toolPresentation: { kind: "edit", title: "Edit", subtitle: path.slice(0, 500) } };
    }
    case "read":
      return { text: [typeof args.offset === "number" ? `From line ${args.offset}` : "",
        typeof args.limit === "number" ? `${args.limit} lines` : ""].filter(Boolean).join(" · "),
        toolPresentation: { kind: "file", title: "Read", subtitle: path.slice(0, 500) } };
    case "write":
      return { text: string(args.content).slice(0, 1_000),
        toolPresentation: { kind: "file", title: "Write", subtitle: path.slice(0, 500) } };
    case "ls":
    case "find":
    case "grep":
      return { text: string(args.pattern ?? args.query).slice(0, 1_000),
        toolPresentation: { kind: "search", title: tool === "ls" ? "List files" : tool === "find" ? "Find files" : "Search",
          subtitle: (path || ".").slice(0, 500) } };
    default:
      return { text: Object.entries(args).map(([key, value]) => `${key}: ${typeof value === "string" ? value : JSON.stringify(value)}`).join("\n").slice(0, 1_000),
        toolPresentation: { kind: "generic", title: name.slice(0, 128) } };
  }
}
function string(value: unknown): string { return typeof value === "string" ? value : ""; }
