import type { AppName } from "@axo/protocol";
import type { AppDefinition, AppTool } from "./app";
import { calendar } from "./apps/calendar";
import { chatgpt } from "./apps/chatgpt";
import { cloud } from "./apps/cloud";
import { contacts } from "./apps/contacts";
import { discord } from "./apps/discord";
import { docs } from "./apps/docs";
import { drive } from "./apps/drive";
import { github } from "./apps/github";
import { gmail } from "./apps/gmail";
import { hetzner } from "./apps/hetzner";
import { kraken } from "./apps/kraken";
import { meet } from "./apps/meet";
import { octopus } from "./apps/octopus";
import { onepassword } from "./apps/onepassword";
import { sheets } from "./apps/sheets";
import { slides } from "./apps/slides";
import { tasks } from "./apps/tasks";
import { telegram } from "./apps/telegram";
import { unifi } from "./apps/unifi";
import { wise } from "./apps/wise";
import { requestTool } from "./request";

/** Every app Axo provides, by name (RFD0016, Apps). */
export const APP_DEFINITIONS: Record<AppName, AppDefinition> = { gmail, calendar, drive, docs, sheets, slides, contacts, tasks, meet, cloud, hetzner, chatgpt, onepassword, octopus, wise, telegram, kraken, github, discord, unifi };

/** An app's tools: its named ones, then, for an app with an HTTP API, `request`, for any endpoint of it. */
const TOOLS = new Map<AppName, readonly AppTool<any, any>[]>();
export function toolsOf(app: AppName): readonly AppTool<any, any>[] {
  let tools = TOOLS.get(app);
  if (!tools) {
    const definition = APP_DEFINITIONS[app];
    tools = definition.signIn === "mac" ? [...definition.tools] : [...definition.tools, requestTool(definition)];
    TOOLS.set(app, tools);
  }
  return tools;
}

/** A command a Mac app runs: its arguments quoted for the shell, and its input fed from a builtin, never on the command line. */
export function macCommand(args: readonly string[], stdin?: string): string {
  const quote = (arg: string) => `'${arg.replace(/'/g, "'\\''")}'`;
  const command = args.map(quote).join(" ");
  if (stdin === undefined) return command;
  const bytes = new TextEncoder().encode(stdin);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return `printf '%s' '${btoa(binary)}' | base64 -d | ${command}`;
}
