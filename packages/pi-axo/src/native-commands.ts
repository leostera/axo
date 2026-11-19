import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { commandList, isThinkingLevel, modelList, type CommandInfo, type CommandLike } from "./pi-state.js";

const BRIDGE_COMMAND = "axo-native";
const nativeCommands = [
  { name: "reload", description: "Reload extensions, skills, prompts, themes and context files" },
  { name: "compact", description: "Compact this session's context; optional instructions" },
  { name: "name", description: "Rename this session: /name <name>" },
  { name: "model", description: "Choose this session's model: /model [provider/id]" },
  { name: "thinking", description: "Set reasoning effort: /thinking <level>" },
] as const;

/** Only Pi installs this adapter. Other agents must publish their own command catalogs. */
export function nativeCommandCatalog(commands: readonly CommandLike[]): CommandInfo[] {
  const extensions = commands.filter(command => command.name !== BRIDGE_COMMAND);
  const names = new Set(extensions.map(command => command.name));
  return commandList([
    ...nativeCommands.filter(command => !names.has(command.name)).map(command => ({ ...command, source: "extension" })),
    ...extensions,
  ]);
}

/** Built-in TUI commands aren't dispatched by sendUserMessage. Invoke reviewed SDK actions instead. */
export function nativeCommandText(text: string, commands: readonly CommandLike[]): string {
  const match = /^\/([^\s]+)([\s\S]*)$/u.exec(text);
  if (!match || !nativeCommands.some(command => command.name === match[1])
    || commands.some(command => command.name === match[1])) return text;
  return `/${BRIDGE_COMMAND} ${match[1]}${match[2]}`;
}

export function registerNativeCommands(pi: ExtensionAPI): void {
  pi.registerCommand(BRIDGE_COMMAND, {
    description: "Axo's remote adapter for native Pi controls",
    handler: async (text, ctx) => {
      const match = /^(\S+)(?:\s+([\s\S]*))?$/u.exec(text.trim());
      const name = match?.[1];
      const args = match?.[2]?.trim() ?? "";
      switch (name) {
        case "reload":
          if (args) { ctx.ui.notify("Usage: /reload", "warning"); return; }
          await ctx.reload();
          return;
        case "compact":
          ctx.compact({
            ...(args ? { customInstructions: args } : {}),
            onError: () => ctx.ui.notify("Compaction failed. The conversation is preserved.", "error"),
          });
          return;
        case "name":
          if (!args) { ctx.ui.notify("Usage: /name <name>", "warning"); return; }
          pi.setSessionName(args);
          return;
        case "thinking":
          if (!isThinkingLevel(args)) { ctx.ui.notify("Usage: /thinking off|minimal|low|medium|high|xhigh|max", "warning"); return; }
          pi.setThinkingLevel(args);
          return;
        case "model": {
          const available = ctx.modelRegistry.getAvailable();
          const choices = modelList(available);
          const selected = args || await ctx.ui.select("Choose model", choices.map(model => `${model.provider}/${model.id}`));
          if (!selected) return;
          const model = available.find(model => `${model.provider}/${model.id}` === selected);
          if (!model || !await pi.setModel(model)) ctx.ui.notify("That model is not available. The current model is unchanged.", "warning");
          return;
        }
        default:
          ctx.ui.notify("This native command is not available through Axo.", "warning");
      }
    },
  });
}
