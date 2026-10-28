import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** What the Axo MCP server needs from Axod's launch environment (RFD0015). */
export interface AxoMcpConfig {
  /** The `axod` executable; its `mcp` subcommand is the server. */
  axod: string;
  /** Axod's local socket. */
  socket: string;
  /** The Axo Session this Pi runs in. */
  sessionId: string;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

function isAbsolutePath(value: string | undefined): value is string {
  return value !== undefined && value.startsWith("/") && !value.includes("\0") && Buffer.byteLength(value, "utf8") <= 4096;
}

/** `null` when Pi runs outside Axo, or under an Axod that predates the MCP server. */
export function parseAxoMcpConfig(environment: NodeJS.ProcessEnv): AxoMcpConfig | null {
  const { AXOD: axod, AXO_SOCKET: socket, AXO_SESSION_ID: sessionId } = environment;
  if (!isAbsolutePath(axod) || !isAbsolutePath(socket)) return null;
  if (sessionId === undefined || !UUID_PATTERN.test(sessionId)) return null;
  return { axod, socket, sessionId };
}

/**
 * Registers `axod mcp` for this Session as the `axo` MCP server. Its tools are reachable only
 * from codemode scripts (`tools.mcp__axo__session_catalog({})`), so they cost no tool
 * declarations; the server's instructions explain them.
 */
export function registerAxoMcpServer(pi: ExtensionAPI, config: AxoMcpConfig): void {
  pi.registerMcpServer("axo", {
    command: config.axod,
    args: ["mcp"],
    env: { AXO_SOCKET: config.socket, AXO_SESSION_ID: config.sessionId },
    exposure: "codemode",
    description:
      "Axo, the app this agent runs in: list Sessions and their transcript files, start and prompt Sessions (including this one), and type into and read terminal panes.",
  });
}
