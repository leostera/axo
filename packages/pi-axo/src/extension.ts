import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext, ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";
import { AxoPiBridgeServer } from "./bridge-server.js";
import { parsePiSessionIdentity, type PiControlCommand, type PiSessionIdentity } from "./protocol.js";
import { installAxoSessionNaming } from "./title.js";
import { registerShareCommand } from "./share-command.js";
import { messageEvent, ProgressThrottle, toolEvent, turnEndEvent } from "./events.js";
import { QUEUED_ENTRY, RECEIPT_ENTRY, RemoteCommands, type ClientPrompt } from "./remote-commands.js";
import { commandList, modelList, piState } from "./pi-state.js";
import { promptContent, showAttachmentLines, type PromptContent } from "./attachments.js";
import type { ThinkingLevel } from "./pi-state.js";

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

/**
 * What an Axo client sends (the app's composer, the phone, the menu bar) is taken as if typed into
 * this Pi: `/axo-share` and other extension commands run, skills and prompt templates expand.
 * Without this, `pi.sendUserMessage` hands `/axo-share` to the model as plain text.
 */
const AS_TYPED = { expandPromptTemplates: true } as const;

/** Whether `content` names one of this Pi's extension commands, which run without a turn. */
function isExtensionCommand(pi: ExtensionAPI, content: PromptContent): boolean {
  if (typeof content !== "string" || !content.startsWith("/")) return false;
  const name = content.slice(1).split(/\s/, 1)[0];
  return pi.getCommands().some(command => command.source === "extension" && command.name === name);
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
  const remote = new RemoteCommands({
    isIdle: () => context?.isIdle() ?? true,
    entries: () => context?.sessionManager.getEntries() ?? [],
    appendReceipt: receipt => pi.appendEntry(RECEIPT_ENTRY, receipt),
    appendQueued: command => pi.appendEntry(QUEUED_ENTRY, command),
    prompt: (prompt: ClientPrompt, as) => {
      let content: PromptContent;
      try {
        content = promptContent(prompt.text, prompt.attachments);
      } catch {
        // A file gone since the prompt was accepted: nothing can be sent, and nothing waits on it.
        console.error("Axo Pi bridge: a held prompt's attachment is gone; it was not sent");
        return "command";
      }
      const runs = !isExtensionCommand(pi, content);
      pi.sendUserMessage(content, as === "steer" && runs ? { ...AS_TYPED, deliverAs: "steer" } : AS_TYPED);
      return runs ? "run" : "command";
    },
    abort: () => context?.abort(),
    now: () => Date.now(),
  });
  const handleCommand = async (command: PiControlCommand) => {
    const activeContext = context;
    if (activeContext === undefined || identity?.axoSessionId !== command.axoSessionId) {
      return { accepted: false as const, reason: "stale" as const };
    }

    if (command.action.kind === "shutdownIfIdle") {
      if (!activeContext.isIdle()) {
        return { accepted: false as const, reason: "busy" as const };
      }
      setImmediate(() => activeContext.shutdown());
      return { accepted: true as const };
    }

    if (command.action.kind === "shutdown") {
      if (!activeContext.isIdle()) activeContext.abort();
      setImmediate(() => activeContext.shutdown());
      return { accepted: true as const };
    }

    if (command.action.kind === "stop") {
      const { kind: _, ...request } = command.action;
      const outcome = remote.stop(request);
      // A client that asks to stop an idle Pi was shown it working: say again that it is not.
      if (outcome === "idle") void publish("activity.snapshot", { working: false });
      return outcome === "stopped"
        ? { accepted: true as const }
        : { accepted: false as const, reason: "idle" as const };
    }

    if (command.action.kind === "setModel") {
      return setModel(activeContext, command.action.model, command.action.thinkingLevel);
    }

    let content: PromptContent = "";
    if (command.action.kind === "send") {
      try {
        content = promptContent(command.action.text, command.action.attachments ?? []);
      } catch {
        // axod fetched the files a moment ago; one gone now fails the prompt, never half of it.
        return { accepted: false as const, reason: "unavailable" as const };
      }
    }

    // A client's prompt (RFD0024): taken at most once, with a receipt, queued in the log while Pi
    // works (RFD0033). Its files were read above, so one already gone is refused now.
    // An interrupt goes the same way even without one: a stop moves Pi's own queue into its editor.
    if (command.action.kind === "send" && (command.action.commandId !== undefined || command.action.delivery === "interrupt")) {
      const prompt = { text: command.action.text, attachments: command.action.attachments ?? [] };
      const commandId = command.action.commandId ?? randomUUID();
      return remote.prompt(commandId, prompt, command.action.delivery ?? "followUp") === "busy"
        ? { accepted: false as const, reason: "busy" as const }
        : { accepted: true as const };
    }

    if (command.action.kind === "cancel") {
      if (activeContext.isIdle()) return { accepted: false as const, reason: "idle" as const };
      activeContext.abort();
      return { accepted: true as const };
    }

    if (activeContext.isIdle()) {
      pi.sendUserMessage(content, AS_TYPED);
      return { accepted: true as const };
    }
    const deliverAs = command.action.delivery;
    if (deliverAs === undefined || deliverAs === "interrupt") {
      return { accepted: false as const, reason: "busy" as const };
    }

    pi.sendUserMessage(content, { ...AS_TYPED, deliverAs });
    return { accepted: true as const };
  };

  // Attachments (RFD0030) show as one short line each in the terminal; the model still reads them whole.
  if (typeof pi.registerMarkdownTransformer === "function") {
    pi.registerMarkdownTransformer((markdown, context) => context.messageType === "user" ? showAttachmentLines(markdown) : markdown);
  }

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
  const progress = new ProgressThrottle((name, data) => void publish(name, data));

  // What this Pi runs, for clients to show and change (RFD0033).
  // Each is also sent to an Axod that connects later, after its activity snapshot.
  const stateEvent = (sessionContext: ExtensionContext) => ({ name: "pi.state", data: piState(sessionContext.model, pi.getThinkingLevel()) });
  const catalogEvents = (sessionContext: ExtensionContext) => [
    { name: "pi.commands", data: { commands: commandList(pi.getCommands()) } },
    { name: "pi.models", data: { models: modelList(sessionContext.modelRegistry.getAvailable()) } },
  ];
  const publishState = (sessionContext: ExtensionContext) => {
    const { name, data } = stateEvent(sessionContext);
    return publish(name, data);
  };
  const setModel = async (
    activeContext: ExtensionContext,
    wanted: { provider: string; id: string } | undefined,
    thinkingLevel: ThinkingLevel | undefined,
  ) => {
    if (wanted !== undefined) {
      const model = activeContext.modelRegistry.find(wanted.provider, wanted.id);
      if (model === undefined) return { accepted: false as const, reason: "invalid" as const };
      // False when Pi has no credentials for the model's provider.
      if (!(await pi.setModel(model))) return { accepted: false as const, reason: "unavailable" as const };
    }
    // Pi clamps the level to what the model supports.
    if (thinkingLevel !== undefined) pi.setThinkingLevel(thinkingLevel);
    return { accepted: true as const };
  };

  pi.registerCommand("axo-import", {
    description: "Import a Pi JSONL transcript as a new Axo Session in this folder",
    handler: async (args, commandContext) => {
      const argument = args.trim();
      const quotedPath = argument.match(/^(?:\"([^\"]+)\"|'([^']+)')$/);
      const rawPath = quotedPath ? quotedPath[1] ?? quotedPath[2] ?? "" : argument;
      if (rawPath.length === 0 || rawPath.length > 4096 || rawPath.includes("\0")) {
        commandContext.ui.notify("Usage: /axo-import <path-to-session.jsonl>", "warning");
        return;
      }
      const sourcePath = resolve(commandContext.cwd, rawPath);
      if (!(await commandContext.ui.confirm(
        "Import Pi Session into Axo",
        `Create a new Session in this folder from ${sourcePath}? The current Session and source file will be left unchanged.`,
      ))) return;
      await publish("session.import.requested", { sourcePath });
      commandContext.ui.notify("Axo is importing the transcript as a new Session.", "info");
    },
  });

  registerShareCommand(pi);

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
    remote.restore();
    // Prompts queued in the log before this Pi started go now, once Pi is past session_start.
    setImmediate(() => remote.resume());

    if (!bridgeAvailable) {
      notifyBridgeFailure(sessionContext, "socket listener did not start");
      return;
    }

    bridge.bindIdentity(
      nextIdentity,
      () => ({ working: !sessionContext.isIdle() }),
      () => [stateEvent(sessionContext), ...catalogEvents(sessionContext)],
    );
    traceBridge(`session bound (${event.reason})`);
    await publish("session.started", { reason: event.reason });
    for (const { name, data } of [stateEvent(sessionContext), ...catalogEvents(sessionContext)]) await publish(name, data);
  });

  pi.on("session_shutdown", async event => {
    traceBridge(`shutdown (${event.reason})`);
    context = undefined;
    progress.finishAll();
    await bridge.close();
  });

  pi.on("session_before_switch", async (event, sessionContext) => {
    const targetSessionFile = event.targetSessionFile;
    if (
      event.reason === "resume" &&
      typeof targetSessionFile === "string" &&
      isAbsolute(targetSessionFile) &&
      Buffer.byteLength(targetSessionFile, "utf8") <= 4096
    ) {
      await publish("session.resume.requested", { targetSessionFile });
      if (sessionContext.hasUI) {
        sessionContext.ui.notify(
          "Axo is resuming the selected saved Session. If successful, Axo will archive this Session and switch to the resumed one.",
          "warning",
        );
      }
      return { cancel: true };
    }

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

  // Every payload is shaped to fit the wire (see events.ts); progress is throttled.
  pi.on("message_start", event => {
    if (event.message.role === "user") remote.userMessageWritten();
    return publish("message.start", messageEvent(event));
  });
  pi.on("message_update", event => progress.offer("message.update", "message", messageEvent(event)));
  pi.on("message_end", event => {
    progress.finish("message.update", "message");
    return publish("message.end", messageEvent(event));
  });
  pi.on("turn_start", event => publish("turn.start", event));
  // Pi reads its steering queue right after this: a held steer joins the run here (RFD0033).
  pi.on("turn_end", event => {
    const stopReason = (event.message as { stopReason?: string }).stopReason;
    remote.turnEnded(stopReason === "aborted" || stopReason === "error");
    return publish("turn.end", turnEndEvent(event));
  });
  pi.on("agent_start", () => {
    remote.runStarted();
    return publish("agent.start", {});
  });
  // The run's messages already went out one by one; repeating them could exceed the wire's limit.
  pi.on("agent_end", () => {
    progress.finishAll();
    return publish("agent.end", {});
  });
  pi.on("agent_settled", event => {
    remote.settled();
    return publish("agent.settled", event);
  });
  pi.on("tool_execution_start", event => publish("tool.start", toolEvent(event)));
  pi.on("tool_execution_update", event => progress.offer("tool.update", event.toolCallId, toolEvent(event)));
  pi.on("tool_execution_end", event => {
    progress.finish("tool.update", event.toolCallId);
    return publish("tool.end", toolEvent(event));
  });
  pi.on("session_info_changed", event => publish("session.info", event));
  pi.on("model_select", (_event, sessionContext) => publishState(sessionContext));
  pi.on("thinking_level_select", (_event, sessionContext) => publishState(sessionContext));
  pi.on("ui_prompt_start", event => publish("ui.prompt.start", { kind: event.kind, ...(event.title ? { title: event.title.slice(0, 500) } : {}) }));
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
