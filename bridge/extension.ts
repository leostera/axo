import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Text } from "@earendil-works/pi-tui";
import { resolve } from "node:path";
import { SessionFiles, stageFile, shareCommandPath } from "./files";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { loadConfig } from "./config";
import { RelayConnection } from "./connection";
import { promptDelivery } from "./delivery";
import { attachmentFiles, projectHistory, projectMessages, submittedCommandIds } from "./projection";
import { readToolOutput } from "./tool-output";
import { MAX_FRAME_BYTES, type AgentActivity, type AgentEvent, type PhoneFrame, type HostFrame, type Question } from "../shared/protocol";

interface PendingQuestion { question: Question; finish: (answer: string | undefined) => void }

export default function axoBridge(pi: ExtensionAPI): void {
  let context: ExtensionContext | undefined;
  let viewId = crypto.randomUUID();
  let connection: RelayConnection | undefined;
  let files: SessionFiles | undefined;
  const preparing = new Map<string, AbortController>();
  let pending: PendingQuestion | undefined;
  let submitted = new Set<string>();
  let activities: AgentActivity[] = [];
  let recentEvents: AgentEvent[] = [];
  let pendingEvents: AgentEvent[] = [];
  let eventSequence = 0;
  let droppedEvents = 0;
  let activeRunID: string | undefined;
  let activeRunMessageID: string | undefined;
  let liveText: string | undefined;
  let streamingMessage: AssistantMessage | undefined;
  let refresh: ReturnType<typeof setTimeout> | undefined;

  function snapshot(replayRecentEvents = false): void {
    if (!context) return;
    const events = replayRecentEvents ? recentEvents.slice(-50) : pendingEvents.splice(0, 50);
    const frame: Extract<HostFrame, { type: "snapshot" }> = {
      type: "snapshot", sessionId: context.sessionManager.getSessionId(), viewId,
      state: pending ? "waiting" : context.isIdle() ? "idle" : "running",
      ...projectHistory(context.sessionManager.getBranch(), streamingMessage), activities, events, droppedEvents,
      liveText, runId: activeRunID ?? null, question: pending?.question ?? null,
    };
    while (events.length > 0 && Buffer.byteLength(JSON.stringify(frame)) > MAX_FRAME_BYTES) {
      const deferred = events.pop()!;
      if (!replayRecentEvents) pendingEvents.unshift(deferred);
    }
    connection?.send(frame);
    if (!replayRecentEvents && pendingEvents.length > 0) scheduleSnapshot(context);
  }

  function recordEvent(
    ctx: ExtensionContext, category: AgentEvent["category"], name: string, summary: string,
    detail?: string, correlationId?: string,
  ): void {
    if (activeRunID && !activeRunMessageID) {
      activeRunMessageID = projectMessages(ctx.sessionManager.getBranch()).filter(message => message.role === "user").at(-1)?.id;
    }
    const event: AgentEvent = {
      id: crypto.randomUUID(), sequence: ++eventSequence, timestamp: Date.now(), category, name,
      ...(activeRunMessageID ? { anchorMessageId: activeRunMessageID } : {}),
      ...(correlationId ? { correlationId } : {}),
      summary: summary.slice(0, 200), ...(detail ? { detail: detail.slice(0, 500) } : {}),
    };
    recentEvents.push(event);
    if (recentEvents.length > 50) recentEvents.shift();
    pendingEvents.push(event);
    if (pendingEvents.length > 5_000) { pendingEvents.shift(); droppedEvents += 1; }
    scheduleSnapshot(ctx);
  }

  function scheduleSnapshot(ctx: ExtensionContext): void {
    context = ctx;
    if (refresh) return;
    // Flush in bounded batches even during continuous token/event traffic.
    refresh = setTimeout(() => {
      refresh = undefined;
      snapshot();
    }, 50);
  }

  function shortText(value: unknown, maxLength: number): string {
    let text: string;
    try { text = typeof value === "string" ? value : JSON.stringify(value) ?? String(value); }
    catch { text = String(value); }
    return text.replace(/\s+/g, " ").slice(0, maxLength);
  }

  function toolOutput(value: unknown): string | undefined {
    if (!value || typeof value !== "object" || !("content" in value) || !Array.isArray(value.content)) return undefined;
    const text = value.content
      .filter((block): block is { type: "text"; text: string } => !!block && typeof block === "object" && block.type === "text" && typeof block.text === "string")
      .map(block => block.text)
      .join("\n");
    return text ? shortText(text, 300) : undefined;
  }

  function updateActivity(activity: AgentActivity): void {
    const index = activities.findIndex(item => item.id === activity.id);
    if (index === -1) activities.push(activity);
    else activities[index] = activity;
    // Keep the live snapshot comfortably below the relay's 256 KiB frame limit.
    if (activities.length > 10) activities.shift();
  }

  function receive(frame: PhoneFrame): void {
    if (!context) return;
    if (frame.type === "sync") { snapshot(true); return; }
    const fail = (message: string) => connection?.send({ type: "error", id: frame.id, message });
    if (frame.sessionId !== context.sessionManager.getSessionId()) { fail("The desktop conversation changed. Refresh before sending."); return; }
    if (frame.type === "history") {
      if (frame.viewId !== viewId) { fail("The conversation branch changed. Refresh before loading history."); return; }
      try {
        connection?.send({ type: "history", id: frame.id, sessionId: frame.sessionId, viewId, beforeId: frame.beforeId,
          ...(frame.direction ? { direction: frame.direction } : {}),
          ...projectHistory(context.sessionManager.getBranch(), streamingMessage, frame.beforeId, frame.direction) });
      } catch (error) { fail(error instanceof Error ? error.message : "Could not load history."); }
      return;
    }
    if (frame.type === "tool_output") {
      void readToolOutput(context.sessionManager.getBranch(), frame.toolCallId, frame.offset).then(page => {
        connection?.send({ type: "tool_output", id: frame.id, sessionId: frame.sessionId,
          toolCallId: frame.toolCallId, offset: frame.offset, ...page });
      }).catch(error => fail(error instanceof Error ? error.message : "Could not load tool output."));
      return;
    }
    if (submitted.has(frame.id) || preparing.has(frame.id)) { fail("Already submitted or preparing; not replayed. Check the conversation."); return; }
    if (frame.type === "answer") {
      if (!pending || pending.question.id !== frame.questionId) { fail("That question is no longer pending."); return; }
      if (!pending.question.options.includes(frame.value)) { fail("Choose one of the offered answers."); return; }
      submitted.add(frame.id);
      pending.finish(frame.value);
    } else if (frame.type === "cancel") {
      if (context.isIdle() || frame.runId !== activeRunID) { fail("That Pi run is no longer active."); return; }
      submitted.add(frame.id);
      context.abort();
      connection?.send({ type: "ack", id: frame.id, disposition: "cancelled" });
      return;
    } else {
      if (pending) { fail("Answer the pending question before sending another prompt."); return; }
      if (frame.attachmentIds?.length) {
        void submitAttachments(frame, context, viewId).catch(error => fail(error instanceof Error ? error.message : "Could not prepare attachments. Prompt not submitted."));
        return;
      }
      // Record before dispatch: ambiguous crashes must never blindly replay side effects.
      pi.appendEntry("axo.submitted", { id: frame.id });
      submitted.add(frame.id);
      const isIdle = context.isIdle();
      if (isIdle) activities = [];
      const delivery = isIdle ? "submitted" : "steering";
      pi.sendMessage({ customType: "axo.prompt", display: true, content: frame.text,
        details: { commandId: frame.id, text: frame.text, delivery },
      }, { triggerTurn: true, ...promptDelivery(isIdle) });
      connection?.send({ type: "ack", id: frame.id, disposition: "submitted", delivery });
      return;
    }
    // The extension API is fire-and-forget; submitted is NOT proof of execution.
    connection?.send({ type: "ack", id: frame.id, disposition: "submitted" });
  }

  async function submitAttachments(frame: Extract<PhoneFrame, { type: "prompt" }>, ctx: ExtensionContext, generation: string): Promise<void> {
    if (!files) throw new Error("Shared files require a configured relay.");
    const controller = new AbortController();
    preparing.set(frame.id, controller);
    try {
      const prepared = await files.prepare(frame.sessionId, frame.attachmentIds ?? [], ctx.model?.input.includes("image") ?? false, controller.signal);
      if (viewId !== generation || context?.sessionManager.getSessionId() !== frame.sessionId || pending) throw new Error("Conversation changed or is waiting for an answer. Prompt not submitted.");
      pi.appendEntry("axo.submitted", { id: frame.id });
      submitted.add(frame.id);
      // Custom message content and details persist together: no guessed user-message anchor.
      const delivery = ctx.isIdle() ? "submitted" : "steering";
      pi.sendMessage({ customType: "axo.attachments", display: true,
        content: [...(frame.text ? [{ type: "text" as const, text: frame.text }] : []), ...prepared.content],
        details: { commandId: frame.id, text: frame.text, files: prepared.files, delivery },
      }, { triggerTurn: true, ...promptDelivery(ctx.isIdle()) });
      connection?.send({ type: "ack", id: frame.id, disposition: "submitted", delivery });
    } finally { preparing.delete(frame.id); }
  }

  pi.on("session_start", (event, ctx) => {
    for (const controller of preparing.values()) controller.abort();
    preparing.clear();
    files = undefined;
    connection?.stop();
    pending?.finish(undefined);
    context = ctx;
    viewId = crypto.randomUUID();
    activities = [];
    recentEvents = [];
    pendingEvents = [];
    eventSequence = 0;
    droppedEvents = 0;
    activeRunID = undefined;
    activeRunMessageID = undefined;
    liveText = undefined;
    streamingMessage = undefined;
    submitted = submittedCommandIds(ctx.sessionManager.getEntries());
    const configPath = process.env.AXO_CONFIG;
    if (!configPath) { ctx.ui.setStatus("axo", "Axo: local only (AXO_CONFIG not set)"); return; }
    try {
      const config = loadConfig(configPath);
      files = new SessionFiles(config);
      connection = new RelayConnection(config, receive,
        status => context?.ui.setStatus("axo", `Axo: ${status} · transcript blocks · paged history`), () => snapshot(true));
      connection.connect();
    } catch {
      ctx.ui.notify("Axo could not load its relay credentials. Check AXO_CONFIG and file permissions (0600).", "error");
    }
    recordEvent(ctx, "session", event.type, `Pi session ${event.reason}`);
  });
  pi.on("resources_discover", (event, ctx) => recordEvent(ctx, "session", event.type, `Resources discovered during ${event.reason}`));
  pi.on("mcp_servers_change", (event, ctx) => recordEvent(ctx, "session", event.type, `${event.servers.length} MCP servers configured`));
  pi.on("session_info_changed", (event, ctx) => recordEvent(ctx, "session", event.type, event.name ? `Session named ${event.name}` : "Session name cleared"));
  pi.on("session_before_switch", (event, ctx) => recordEvent(ctx, "session", event.type, `Session ${event.reason} requested`));
  pi.on("session_before_fork", (event, ctx) => recordEvent(ctx, "session", event.type, `Session fork requested (${event.position})`));
  pi.on("session_before_compact", (event, ctx) => recordEvent(ctx, "session", event.type, `Context compaction starting (${event.reason})`));
  pi.on("session_compact", (event, ctx) => recordEvent(ctx, "session", event.type, `Context compacted (${event.reason})`));
  pi.on("session_compact_failed", (event, ctx) => recordEvent(ctx, "session", event.type, `Context compaction ${event.aborted ? "aborted" : "failed"}`,
    event.errorMessage ? shortText(event.errorMessage, 500) : undefined));
  pi.on("session_before_tree", (event, ctx) => recordEvent(ctx, "session", event.type, "Session tree navigation requested"));
  pi.on("session_tree", (event, ctx) => {
    for (const controller of preparing.values()) controller.abort();
    viewId = crypto.randomUUID();
    recordEvent(ctx, "session", event.type, "Session tree navigation completed");
  });
  pi.on("context", (event, ctx) => recordEvent(ctx, "provider", event.type, `${event.messages.length} context messages prepared`));
  pi.on("context_with_system", (event, ctx) => recordEvent(ctx, "provider", event.type, `${event.messages.length} model-context messages prepared; prompt content withheld`));
  pi.on("cache_warming_decision", (_event, ctx) => recordEvent(ctx, "provider", "cache_warming_decision", "Prompt cache decision made"));
  pi.on("before_provider_request", (_event, ctx) => recordEvent(ctx, "provider", "before_provider_request", "Provider request prepared; prompt payload withheld"));
  pi.on("before_provider_headers", (event, ctx) => recordEvent(ctx, "provider", event.type, "Provider request headers prepared", `Header names: ${Object.keys(event.headers).join(", ")}`));
  pi.on("after_provider_response", (event, ctx) => recordEvent(ctx, "provider", event.type, `Provider responded with HTTP ${event.status}`));
  pi.on("provider_stream_event", (event, ctx) => {
    const dataType = event.data && typeof event.data === "object" && "type" in event.data ? String(event.data.type) : "provider data";
    recordEvent(ctx, "provider", event.type, `${event.provider}/${event.model} stream event`, dataType);
  });
  pi.on("before_agent_start", (event, ctx) => recordEvent(ctx, "lifecycle", event.type,
    `Agent input prepared (${event.prompt.length} characters, ${event.images?.length ?? 0} images); prompt text in conversation`));
  pi.on("agent_start", (_event, ctx) => {
    activeRunID ??= crypto.randomUUID();
    activeRunMessageID = projectMessages(ctx.sessionManager.getBranch()).filter(message => message.role === "user").at(-1)?.id;
    recordEvent(ctx, "lifecycle", "agent_start", "Pi run started");
  });
  pi.on("agent_end", (event, ctx) => recordEvent(ctx, "lifecycle", event.type, `Pi run produced ${event.messages.length} messages`));
  pi.on("agent_before_settle", (event, ctx) => recordEvent(ctx, "lifecycle", event.type,
    `Pi is settling (${event.outcome}${event.continue ? ", continuing" : ""})`));
  pi.on("agent_settled", (event, ctx) => {
    recordEvent(ctx, "lifecycle", event.type, event.aborted ? "Pi run aborted" : "Pi run settled");
    activeRunID = undefined;
    activeRunMessageID = undefined;
    liveText = undefined;
    streamingMessage = undefined;
  });
  pi.on("ui_prompt_start", (event, ctx) => recordEvent(ctx, "input", event.type, `${event.kind} prompt opened`, event.title));
  pi.on("ui_prompt_end", (event, ctx) => recordEvent(ctx, "input", event.type, `${event.kind} prompt closed`, event.title));
  pi.on("turn_start", (event, ctx) => recordEvent(ctx, "turn", event.type, `Turn ${event.turnIndex} started`));
  pi.on("turn_end", (event, ctx) => recordEvent(ctx, "turn", event.type, `Turn ${event.turnIndex} ended (${event.toolResults.length} tool results)`));
  pi.on("message_start", (event, ctx) => {
    if (event.message.role === "user" && ctx.isIdle()) {
      activities = [];
      liveText = undefined;
    }
    if (event.message.role === "assistant") { liveText = undefined; streamingMessage = event.message; }
    recordEvent(ctx, "assistant", event.type, `${event.message.role} message started`);
  });
  pi.on("message_update", (event, ctx) => {
    if (event.message.role === "assistant") streamingMessage = event.message;
    const update = event.assistantMessageEvent;
    switch (update.type) {
      case "text_delta":
        liveText = `${liveText ?? ""}${update.delta}`.slice(-4_000);
        recordEvent(ctx, "assistant", "assistant.text_delta", "Assistant text streamed", update.delta);
        break;
      case "thinking_start":
        recordEvent(ctx, "assistant", "assistant.thinking_start", "Private reasoning block started; content withheld");
        break;
      case "thinking_delta":
        recordEvent(ctx, "assistant", "assistant.thinking_delta", `Private reasoning updated (${update.delta.length} characters; content withheld)`);
        break;
      case "thinking_end":
        recordEvent(ctx, "assistant", "assistant.thinking_end", `Private reasoning block ended (${update.content.length} characters; content withheld)`);
        break;
      case "toolcall_start":
      case "toolcall_delta":
        recordEvent(ctx, "assistant", `assistant.${update.type}`, "Assistant is composing a tool call; argument content omitted");
        break;
      case "toolcall_end":
        recordEvent(ctx, "assistant", update.type, `Assistant requested tool ${update.toolCall.name}`);
        break;
      case "done":
        recordEvent(ctx, "assistant", update.type, `Assistant response finished (${update.reason})`);
        break;
      case "error":
        recordEvent(ctx, "assistant", update.type, `Assistant response ended (${update.reason})`);
        break;
      default:
        recordEvent(ctx, "assistant", update.type, `Assistant message event: ${update.type}`);
    }
  });
  pi.on("message_end", (event, ctx) => {
    if (event.message.role === "assistant") { liveText = undefined; streamingMessage = undefined; }
    recordEvent(ctx, "assistant", event.type, `${event.message.role} message ended`);
  });
  pi.on("tool_execution_start", (event, ctx) => {
    const summary = shortText(event.args, 250);
    updateActivity({ id: event.toolCallId, toolName: event.toolName, summary, status: "running" });
    recordEvent(ctx, "tool", event.type, `${event.toolName} started`, summary, event.toolCallId);
  });
  pi.on("tool_execution_update", (event, ctx) => {
    const summary = shortText(event.args, 250);
    const output = toolOutput(event.partialResult);
    updateActivity({ id: event.toolCallId, toolName: event.toolName, summary, status: "running", output });
    recordEvent(ctx, "tool", event.type, `${event.toolName} updated`, output, event.toolCallId);
  });
  pi.on("tool_execution_end", (event, ctx) => {
    const summary = activities.find(activity => activity.id === event.toolCallId)?.summary ?? "";
    const output = toolOutput(event.result);
    updateActivity({ id: event.toolCallId, toolName: event.toolName, summary,
      status: event.isError ? "failed" : "completed", output });
    recordEvent(ctx, "tool", event.type, `${event.toolName} ${event.isError ? "failed" : "finished"}`,
      output ?? (event.durationMs === undefined ? undefined : `Duration: ${event.durationMs} ms`), event.toolCallId);
  });
  pi.on("model_select", (event, ctx) => recordEvent(ctx, "model", event.type,
    `Model selected: ${event.model.provider}/${event.model.id} (${event.source})`));
  pi.on("thinking_level_select", (event, ctx) => recordEvent(ctx, "model", event.type, `Thinking level set to ${event.level}`));
  pi.on("input", (event, ctx) => recordEvent(ctx, "input", event.type,
    `Input received from ${event.source}${event.streamingBehavior ? ` (${event.streamingBehavior})` : ""}`,
    `${event.text.length} characters`));
  pi.on("user_bash", (event, ctx) => recordEvent(ctx, "input", event.type, "User shell command", shortText(event.command, 300)));
  pi.on("tool_call", (event, ctx) => recordEvent(ctx, "tool", event.type,
    `${event.toolName} call prepared`, shortText(event.input, 300), event.toolCallId));
  pi.on("tool_result", (event, ctx) => recordEvent(ctx, "tool", event.type,
    `${event.toolName} result ${event.isError ? "failed" : "returned"}`, toolOutput({ content: event.content }), event.toolCallId));
  pi.on("session_shutdown", (event, ctx) => {
    recordEvent(ctx, "session", event.type, `Pi session shutting down (${event.reason})`);
    clearTimeout(refresh);
    snapshot();
    pending?.finish(undefined);
    connection?.stop();
    for (const controller of preparing.values()) controller.abort();
    preparing.clear();
    files = undefined;
    activeRunID = undefined;
    activeRunMessageID = undefined;
    liveText = undefined;
    streamingMessage = undefined;
    context = undefined;
  });

  pi.registerMessageRenderer("axo.prompt", (message, _options, theme) => {
    const details = message.details;
    const text = details && typeof details === "object" && "text" in details && typeof details.text === "string" ? details.text : "";
    const steering = details && typeof details === "object" && "delivery" in details && details.delivery === "steering";
    return new Text(`${theme.fg("accent", steering ? "Phone steering" : "Phone prompt")}\n${text}`, 0, 0);
  });
  pi.registerMessageRenderer("axo.attachments", (message, _options, theme) => {
    const details: unknown = message.details;
    const text = details && typeof details === "object" && "text" in details && typeof details.text === "string" ? details.text : "";
    const names = attachmentFiles(details).map(file => file.filename).join(", ");
    return new Text(`${theme.fg("accent", "Phone attachments")} · ${names}${text ? `\n${text}` : ""}`, 0, 0);
  });
  pi.registerEntryRenderer<{ files: { filename: string }[] }>("axo.shared_file", entry => new Text(`Shared: ${entry.data?.files.map(file => file.filename).join(", ") ?? "file"}`, 0, 0));

  pi.registerCommand("axo-share", {
    description: "Publish an immutable snapshot to this conversation's private cloud file storage (25 MiB maximum).",
    async handler(path, ctx) {
      if (!files || !path.trim()) { ctx.ui.notify("Usage: /axo-share <path> (requires the relay)", "error"); return; }
      const generation = viewId;
      const sessionId = ctx.sessionManager.getSessionId();
      const staged = await stageFile(resolve(ctx.cwd, shareCommandPath(path)));
      try {
        const requestId = crypto.randomUUID();
        pi.appendEntry("axo.upload", { requestId, sessionId, filename: staged.filename, sha256: staged.sha256 });
        const file = await files.publish(sessionId, staged, undefined, requestId);
        if (viewId !== generation || context?.sessionManager.getSessionId() !== sessionId) throw new Error("File uploaded to the original session; no reference added to the new conversation.");
        pi.appendEntry("axo.shared_file", { files: [file] });
        snapshot();
        ctx.ui.notify(`Shared ${file.filename}`, "info");
      } finally { await staged.dispose(); }
    },
  });

  pi.registerTool({
    name: "axo_share_file", label: "Share file with iPhone",
    description: "Publish an immutable snapshot of one regular Mac file to the session's private cloud storage. Always asks for publication consent. Does not share files merely because they were read/written.",
    parameters: Type.Object({ path: Type.String({ minLength: 1 }) }),
    async execute(_id, args, signal, _onUpdate, ctx) {
      if (!files) throw new Error("Shared files require a configured relay.");
      const generation = viewId;
      const sessionId = ctx.sessionManager.getSessionId();
      const staged = await stageFile(resolve(ctx.cwd, args.path));
      try {
        const consent = await ctx.executeTool("axo_ask", {
          title: `Upload ${staged.source} (${staged.byteLength} bytes) to private Cloudflare R2? The relay can read this file.`, options: ["Publish file", "Cancel"],
        }, { signal });
        const details: unknown = consent.result.details;
        if (consent.isError || !details || typeof details !== "object" || !("value" in details) || details.value !== "Publish file") throw new Error("Publication cancelled. Nothing uploaded.");
        if (viewId !== generation || signal?.aborted) throw new Error("Publication interrupted. Nothing uploaded.");
        const requestId = crypto.randomUUID();
        pi.appendEntry("axo.upload", { requestId, sessionId, toolCallId: _id, filename: staged.filename, sha256: staged.sha256 });
        const file = await files.publish(sessionId, staged, signal, requestId);
        if (viewId !== generation) throw new Error("File uploaded to the original session; no reference added to the new branch.");
        return { content: [{ type: "text" as const, text: `Shared ${file.filename} (${file.byteLength} bytes). File ID: ${file.id}.` }], details: { files: [file] } };
      } finally { await staged.dispose(); }
    },
  });

  pi.registerTool({
    name: "axo_ask", label: "Ask on Mac or iPhone",
    description: "Ask the user a multiple-choice question and wait for their answer on the Mac or iPhone. Use for clarification and confirmation. Never interpret cancellation as approval.",
    parameters: Type.Object({
      title: Type.String({ minLength: 1, maxLength: 2000 }),
      options: Type.Array(Type.String({ minLength: 1, maxLength: 500 }), { minItems: 2, maxItems: 8 }),
    }),
    async execute(_toolCallId, args, signal, _onUpdate, ctx) {
      if (pending) throw new Error("Another question is already pending");
      if (new Set(args.options).size !== args.options.length) throw new Error("Options must be distinct");
      if (signal?.aborted) throw new Error("Question cancelled");
      context = ctx;
      const question = { id: crypto.randomUUID(), title: args.title, options: args.options };
      const localDialog = new AbortController();
      let finish!: (answer: string | undefined) => void;
      const answer = new Promise<string | undefined>(resolve => {
        finish = value => {
          if (pending?.question.id !== question.id) return;
          pending = undefined;
          localDialog.abort();
          resolve(value);
          snapshot();
        };
      });
      pending = { question, finish };
      const cancel = () => finish(undefined);
      signal?.addEventListener("abort", cancel, { once: true });
      snapshot();
      if (ctx.hasUI) void ctx.ui.select(args.title, args.options, { signal: localDialog.signal }).then(finish, cancel);
      try {
        const value = await answer;
        return { content: [{ type: "text" as const, text: value === undefined ? "User cancelled. No approval granted." : `User chose: ${value}` }], details: { value: value ?? null } };
      } finally { signal?.removeEventListener("abort", cancel); }
    },
  });
}
