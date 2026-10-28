import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { installAxoPiExtension, type AxoPiExtensionConfig } from "./extension.js";
import { parseAxoMcpConfig, registerAxoMcpServer } from "./mcp.js";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
// Keep aligned with MAX_PI_BRIDGE_SOCKET_PATH_BYTES in Axod's session manager.
const MAX_PI_BRIDGE_SOCKET_PATH_BYTES = 100;

export function parseAxoPiExtensionConfig(environment: NodeJS.ProcessEnv): AxoPiExtensionConfig | null {
  const socketPath = environment.AXO_PI_BRIDGE_SOCKET;
  const piSessionFile = environment.AXO_PI_SESSION_FILE;
  const axoSessionId = environment.AXO_SESSION_ID;
  const axoPaneId = environment.AXO_PANE_ID;
  const bridgeToken = environment.AXO_PI_BRIDGE_TOKEN;
  if (socketPath === undefined || piSessionFile === undefined || axoSessionId === undefined || axoPaneId === undefined || bridgeToken === undefined) return null;
  if (!socketPath.startsWith("/") || socketPath.includes("\0") || Buffer.byteLength(socketPath, "utf8") > MAX_PI_BRIDGE_SOCKET_PATH_BYTES) return null;
  if (!piSessionFile.startsWith("/") || piSessionFile.includes("\0") || Buffer.byteLength(piSessionFile, "utf8") > 4096) return null;
  if (!UUID_PATTERN.test(axoSessionId) || !UUID_PATTERN.test(axoPaneId) || !UUID_PATTERN.test(bridgeToken)) return null;
  return { socketPath, piSessionFile, axoSessionId, axoPaneId, bridgeToken };
}

export { createAxoPiExtension, installAxoPiExtension, type AxoPiExtensionConfig } from "./extension.js";
export {
  AXO_PI_PROTOCOL_VERSION,
  parsePiControlCommand,
  parsePiSessionIdentity,
  type PiBridgeEvent,
  type PiBridgeHello,
  type PiBridgeRecord,
  type PiCommandResult,
  type PiControlAction,
  type PiControlCommand,
  type PiSessionIdentity,
} from "./protocol.js";

export { parseAxoMcpConfig, registerAxoMcpServer, type AxoMcpConfig } from "./mcp.js";

export default function axoPiExtension(pi: ExtensionAPI): void {
  const mcp = parseAxoMcpConfig(process.env);
  if (mcp !== null) {
    try {
      registerAxoMcpServer(pi, mcp);
    } catch (error) {
      console.error(`Axo MCP server unavailable: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  const config = parseAxoPiExtensionConfig(process.env);
  if (config === null) {
    console.error("Axo Pi bridge unavailable: missing or invalid Axod environment");
    return;
  }
  installAxoPiExtension(pi, config);
}
