import type { ExtensionAPI, ExtensionContext, ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";
import { AxoPiBridgeServer } from "./bridge-server.js";
import { parsePiSessionIdentity, type PiControlCommand, type PiSessionIdentity } from "./protocol.js";
import { installAxoSessionNaming } from "./title.js";

export interface AxoPiExtensionConfig {
  socketPath: string;
  piSessionFile: string;
  axoSessionId: string;
  axoPaneId: string;
  bridgeToken: string;
}

function currentIdentity(context: ExtensionContext, config: AxoPiExtensionConfig): PiSessionIdentity | null {
  const piSessionId = context.sessionManager.getSessionId();
  const sessionFile = context.sessionManager.getSessionFile() ?? null;
  if (sessionFile === null || !isAbsolute(sessionFile)) return null;
  if (resolve(sessionFile) !== resolve(config.piSessionFile)) return null;

  return parsePiSessionIdentity({
    axoSessionId: config.axoSessionId,
    axoPaneId: config.axoPaneId,
    piSessionId,
    sessionFile,
    cwd: context.cwd,
    processId: process.pid,
  });
}

function notifyBridgeFailure(context: ExtensionContext, detail: string): void {
  console.error(`Axo Pi bridge unavailable: ${detail}`);
  if (context.hasUI) context.ui.notify("Axo's local Pi bridge is unavailable; this agent cannot be controlled remotely.", "warning");
}

function traceBridge(message: string): void {
  if (process.env.AXO_PI_BRIDGE_DEBUG === "1") console.error(`Axo Pi bridge: ${message}`);
}

function errorCode(error: unknown): string {
  if (typeof error !== "object" || error === null || !("code" in error) || typeof error.code !== "string") {
    return "unknown";
  }
  return error.code;
}

export async function installAxoPiExtension(pi: ExtensionAPI, config: AxoPiExtensionConfig): Promise<void> {
  let context: ExtensionContext | undefined;
  let identity: PiSessionIdentity | undefined;
  const handleCommand = async (command: PiControlCommand) => {
    const activeContext = context;
    if (activeContext === undefined || identity?.axoSessionId !== command.axoSessionId) {
      return { accepted: false as const, reason: "stale" as const };
    }

    if (command.action.kind === "cancel") {
      if (activeContext.isIdle()) return { accepted: false as const, reason: "idle" as const };
      activeContext.abort();
      return { accepted: true as const };
    }

    if (activeContext.isIdle()) {
      pi.sendUserMessage(command.action.text);
      return { accepted: true as const };
    }
    if (command.action.delivery === undefined) {
      return { accepted: false as const, reason: "busy" as const };
    }

    pi.sendUserMessage(command.action.text, { deliverAs: command.action.delivery });
    return { accepted: true as const };
  };

  const bridge = new AxoPiBridgeServer(config.socketPath, config.axoSessionId, config.bridgeToken, handleCommand);
  let bridgeAvailable = false;
  traceBridge("factory initialization started");
  const bridgeStarted = bridge.start().then(() => {
    bridgeAvailable = true;
    traceBridge("socket listener ready");
  }).catch(error => {
    console.error(`Axo Pi bridge unavailable: socket setup failed (${errorCode(error)})`);
  });

  const publish = (name: string, data: unknown) => bridge.publish(name, data);

  pi.on("session_start", async (event, sessionContext) => {
    traceBridge("session_start received");
    await bridgeStarted;
    context = sessionContext;
    const nextIdentity = currentIdentity(sessionContext, config);
    if (nextIdentity === null) {
      notifyBridgeFailure(sessionContext, "Pi session identity did not validate");
      bridgeAvailable = false;
      await bridge.close();
      return;
    }
    identity = nextIdentity;

    if (!bridgeAvailable) {
      notifyBridgeFailure(sessionContext, "socket listener did not start");
      return;
    }

    bridge.bindIdentity(nextIdentity);
    traceBridge(`session bound (${event.reason})`);
    await publish("session.started", { reason: event.reason });
  });

  pi.on("session_shutdown", async event => {
    traceBridge(`shutdown (${event.reason})`);
    context = undefined;
    await bridge.close();
  });

  pi.on("session_before_switch", async (_event, sessionContext) => {
    if (sessionContext.hasUI) {
      sessionContext.ui.notify("This Pi session is owned by Axo. Create or select Sessions in Axo instead.", "warning");
    }
    return { cancel: true };
  });

  pi.on("session_before_fork", async (_event, sessionContext) => {
    if (sessionContext.hasUI) {
      sessionContext.ui.notify("This Pi session is owned by Axo. Forking is not available from the Pi TUI.", "warning");
    }
    return { cancel: true };
  });

  pi.on("message_start", event => publish("message.start", event));
  pi.on("message_update", event => publish("message.update", event));
  pi.on("message_end", event => publish("message.end", event));
  pi.on("turn_start", event => publish("turn.start", event));
  pi.on("turn_end", event => publish("turn.end", {
    turnIndex: event.turnIndex,
    message: event.message,
    toolResults: event.toolResults,
    messageEntryId: event.messageEntryId,
    toolResultEntryIds: event.toolResultEntryIds,
    outcome: event.outcome,
  }));
  pi.on("agent_start", event => publish("agent.start", event));
  pi.on("agent_end", event => publish("agent.end", event));
  pi.on("agent_settled", event => publish("agent.settled", event));
  pi.on("tool_execution_start", event => publish("tool.start", event));
  pi.on("tool_execution_update", event => publish("tool.update", event));
  pi.on("tool_execution_end", event => publish("tool.end", event));
  pi.on("session_info_changed", event => publish("session.info", event));
  pi.on("ui_prompt_start", event => publish("ui.prompt.start", { kind: event.kind }));
  pi.on("ui_prompt_end", event => publish("ui.prompt.end", { kind: event.kind }));

  installAxoSessionNaming(
    pi,
    bridge,
    () => identity,
    sessionContext => currentIdentity(sessionContext, config),
  );

  await bridgeStarted;
  traceBridge("factory initialization complete");
}

export function createAxoPiExtension(config: AxoPiExtensionConfig): ExtensionFactory {
  return pi => installAxoPiExtension(pi, config);
}
