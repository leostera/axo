import assert from "node:assert/strict";
import { mkdtemp, lstat } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect, type Socket } from "node:net";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { installAxoPiExtension } from "../src/extension.js";
import type { PiBridgeRecord } from "../src/protocol.js";

const axoSessionId = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
const axoPaneId = "9b9e14e0-d1c6-46b8-b289-bab4fda8774f";
const bridgeToken = "11cfda23-bc7c-4812-9613-4336f44b498e";

function recordReader(socket: Socket): () => Promise<PiBridgeRecord> {
  let buffer = Buffer.alloc(0);
  const records: PiBridgeRecord[] = [];
  const waiting: Array<(record: PiBridgeRecord) => void> = [];
  socket.on("data", data => {
    buffer = Buffer.concat([buffer, data]);
    let newline = buffer.indexOf(0x0a);
    while (newline >= 0) {
      const line = buffer.subarray(0, newline);
      buffer = buffer.subarray(newline + 1);
      const record = JSON.parse(line.toString("utf8")) as PiBridgeRecord;
      const next = waiting.shift();
      if (next) next(record);
      else records.push(record);
      newline = buffer.indexOf(0x0a);
    }
  });
  return () => {
    const record = records.shift();
    if (record) return Promise.resolve(record);
    return new Promise(resolve => waiting.push(resolve));
  };
}

test("bridges Pi events and remote commands without owning the Pi process", async () => {
  const directory = await mkdtemp(join(tmpdir(), "axo-pi-extension-"));
  const socketPath = join(directory, "bridge.sock");
  const registered = new Map<string, (event: never, context: never) => unknown>();
  const commands = new Map<string, (args: string, context: ExtensionContext) => Promise<void>>();
  const sentMessages: Array<{ text: string; options?: unknown }> = [];
  let aborted = 0;
  let shutdowns = 0;
  let idle = true;
  const entries: Array<{ type: string; customType?: string; data?: unknown }> = [];
  const opus = { provider: "anthropic", id: "claude-opus-4-1", name: "Opus 4.1", reasoning: true, thinkingLevelMap: { xhigh: "max" } };
  const haiku = { provider: "anthropic", id: "claude-haiku-4-5", name: "Haiku 4.5", reasoning: false };
  let model: typeof opus | typeof haiku = opus;
  let thinkingLevel = "high";

  const pi = {
    on(name: string, handler: (event: never, context: never) => unknown) {
      const previous = registered.get(name);
      registered.set(name, previous === undefined
        ? handler
        : async (event, context) => {
          await previous(event, context);
          return handler(event, context);
        });
      return () => registered.delete(name);
    },
    registerTool() {},
    registerCommand(name: string, command: { handler: (args: string, context: ExtensionContext) => Promise<void> }) {
      commands.set(name, command.handler);
    },
    getCommands: () => [...commands.keys()].map(name => ({ name, source: "extension" })),
    sendUserMessage(text: string, options?: unknown) {
      sentMessages.push({ text, options });
    },
    appendEntry(customType: string, data: unknown) {
      entries.push({ type: "custom", customType, data });
    },
    getThinkingLevel: () => thinkingLevel,
    setThinkingLevel(level: string) {
      thinkingLevel = level;
    },
    async setModel(next: typeof opus) {
      model = next;
      return true;
    },
  } as unknown as ExtensionAPI;
  const context = {
    cwd: "/projects/axo",
    hasUI: false,
    isIdle: () => idle,
    get model() {
      return model;
    },
    modelRegistry: {
      getAvailable: () => [opus, haiku],
      find: (provider: string, id: string) => [opus, haiku].find(candidate => candidate.provider === provider && candidate.id === id),
    },
    abort: () => { aborted += 1; },
    shutdown: () => { shutdowns += 1; },
    sessionManager: {
      getSessionId: () => "pi-session-1",
      getSessionFile: () => "/private/axo/pi-session-1.jsonl",
      getSessionName: () => undefined,
      getBranch: () => [],
      getEntries: () => entries,
    },
  } as unknown as ExtensionContext;

  await installAxoPiExtension(pi, {
    socketPath,
    piSessionFile: "/private/axo/pi-session-1.jsonl",
    axoSessionId,
    axoPaneId,
    bridgeToken,
  });
  try {
    const start = registered.get("session_start");
    assert.ok(start);
    await start({ reason: "startup" } as never, context as never);

    const socket = connect({ path: socketPath });
    const next = recordReader(socket);
    await once(socket, "connect");
    socket.write(`${JSON.stringify({ type: "authenticate", protocolVersion: 1, token: bridgeToken })}\n`);
    assert.deepEqual(await next(), { type: "authenticated", protocolVersion: 1 });
    const hello = await next();
    assert.equal(hello.type, "hello");
    if (hello.type !== "hello") throw new Error("expected Pi bridge identity");
    assert.equal(hello.identity.axoSessionId, axoSessionId);
    assert.equal(hello.identity.axoPaneId, axoPaneId);
    assert.equal(hello.identity.piSessionId, "pi-session-1");
    assert.equal(hello.identity.sessionFile, "/private/axo/pi-session-1.jsonl");
    const activitySnapshot = await next();
    assert.equal(activitySnapshot.type, "event");
    if (activitySnapshot.type !== "event") throw new Error("expected initial activity snapshot");
    assert.equal(activitySnapshot.name, "activity.snapshot");
    assert.deepEqual(activitySnapshot.data, { working: false });
    // What Pi runs reaches an Axod that connected after session_start (RFD0033).
    const state = await next();
    assert.deepEqual(state.type === "event" && [state.name, state.data], ["pi.state", {
      model: { provider: "anthropic", id: "claude-opus-4-1", name: "Opus 4.1" },
      thinkingLevel: "high",
    }]);
    const listedCommands = await next();
    assert.deepEqual(listedCommands.type === "event" && [listedCommands.name, listedCommands.data], ["pi.commands", {
      commands: [
        { name: "axo-import", description: "", source: "extension" },
        { name: "axo-share", description: "", source: "extension" },
      ],
    }]);
    const listedModels = await next();
    assert.deepEqual(listedModels.type === "event" && [listedModels.name, listedModels.data], ["pi.models", {
      models: [
        { provider: "anthropic", id: "claude-haiku-4-5", name: "Haiku 4.5", thinkingLevels: ["off"] },
        { provider: "anthropic", id: "claude-opus-4-1", name: "Opus 4.1", thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh"] },
      ],
    }]);

    const importSession = commands.get("axo-import");
    assert.ok(importSession);
    await importSession('"/tmp/imported session.jsonl"', {
      ...context,
      ui: {
        confirm: async () => true,
        notify: () => {},
      },
    } as unknown as ExtensionContext);
    const importRequest = await next();
    assert.equal(importRequest.type, "event");
    if (importRequest.type !== "event") throw new Error("expected import request event");
    assert.equal(importRequest.name, "session.import.requested");
    assert.deepEqual(importRequest.data, { sourcePath: "/tmp/imported session.jsonl" });

    const messageEnd = registered.get("message_end");
    assert.ok(messageEnd);
    messageEnd({ type: "message_end", message: { role: "assistant", content: "hello" } } as never, context as never);
    const event = await next();
    assert.equal(event.type, "event");
    if (event.type !== "event") throw new Error("expected a Pi event");
    assert.equal(event.name, "message.end");
    assert.deepEqual(event.data, { type: "message_end", message: { role: "assistant", content: "hello" } });

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "ask-1",
      axoSessionId,
      action: { kind: "send", text: "Check the build" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "ask-1", result: { accepted: true } });
    assert.deepEqual(sentMessages, [{ text: "Check the build", options: { expandPromptTemplates: true } }]);

    idle = false;
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "steer-1",
      axoSessionId,
      action: { kind: "send", text: "Take this alternate path", delivery: "steer" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "steer-1", result: { accepted: true } });
    assert.deepEqual(sentMessages[1], { text: "Take this alternate path", options: { expandPromptTemplates: true, deliverAs: "steer" } });

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "ask-2",
      axoSessionId,
      action: { kind: "send", text: "Interrupt with new direction" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "ask-2", result: { accepted: false, reason: "busy" } });

    // A client's steer is in the log before it is accepted, and joins the run at the turn's end.
    const commandId = "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b";
    registered.get("agent_start")!({} as never, context as never);
    await next();
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "client-steer",
      axoSessionId,
      action: { kind: "send", text: "Use the other API", delivery: "steer", commandId },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "client-steer", result: { accepted: true } });
    assert.deepEqual(entries.at(-1), {
      type: "custom",
      customType: "axo.command.queued",
      data: { commandId, delivery: "steer", text: "Use the other API", attachments: [] },
    });
    assert.equal(sentMessages.length, 2, "nothing reaches Pi's queue before the turn ends");
    registered.get("turn_end")!({ type: "turn_end", turnIndex: 0, message: { role: "assistant", content: [], stopReason: "toolUse" }, toolResults: [] } as never, context as never);
    await next();
    assert.deepEqual(entries.at(-1), { type: "custom", customType: "axo.command", data: { commandId } });
    assert.deepEqual(sentMessages[2], { text: "Use the other API", options: { expandPromptTemplates: true, deliverAs: "steer" } });

    // A client picks the model and thinking level; Pi announces the change itself.
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "model-1",
      axoSessionId,
      action: { kind: "setModel", model: { provider: "anthropic", id: "claude-haiku-4-5" }, thinkingLevel: "low" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "model-1", result: { accepted: true } });
    assert.equal(model, haiku);
    assert.equal(thinkingLevel, "low");
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "model-2",
      axoSessionId,
      action: { kind: "setModel", model: { provider: "openai", id: "gpt-unknown" } },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "model-2", result: { accepted: false, reason: "invalid" } });
    registered.get("model_select")!({ type: "model_select", model: haiku, source: "set" } as never, context as never);
    const changed = await next();
    assert.deepEqual(changed.type === "event" && [changed.name, changed.data], ["pi.state", {
      model: { provider: "anthropic", id: "claude-haiku-4-5", name: "Haiku 4.5" },
      thinkingLevel: "low",
    }]);

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "cancel-1",
      axoSessionId,
      action: { kind: "cancel" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "cancel-1", result: { accepted: true } });
    assert.equal(aborted, 1);

    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "automatic-takeover-busy",
      axoSessionId,
      action: { kind: "shutdownIfIdle" },
    })}\n`);
    assert.deepEqual(await next(), {
      type: "commandResult",
      requestId: "automatic-takeover-busy",
      result: { accepted: false, reason: "busy" },
    });
    assert.equal(aborted, 1);
    assert.equal(shutdowns, 0);

    idle = true;
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "automatic-takeover-idle",
      axoSessionId,
      action: { kind: "shutdownIfIdle" },
    })}\n`);
    assert.deepEqual(await next(), {
      type: "commandResult",
      requestId: "automatic-takeover-idle",
      result: { accepted: true },
    });
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal(aborted, 1);
    assert.equal(shutdowns, 1);

    idle = false;
    socket.write(`${JSON.stringify({
      type: "command",
      requestId: "takeover-1",
      axoSessionId,
      action: { kind: "shutdown" },
    })}\n`);
    assert.deepEqual(await next(), { type: "commandResult", requestId: "takeover-1", result: { accepted: true } });
    await new Promise<void>(resolve => setImmediate(resolve));
    assert.equal(aborted, 2);
    assert.equal(shutdowns, 2);

    const beforeSwitch = registered.get("session_before_switch");
    assert.ok(beforeSwitch);
    assert.deepEqual(
      await beforeSwitch(
        { reason: "resume", targetSessionFile: "/private/axo/archived-session.jsonl" } as never,
        context as never,
      ),
      { cancel: true },
    );
    const resumeRequest = await next();
    assert.equal(resumeRequest.type, "event");
    if (resumeRequest.type !== "event") throw new Error("expected a resume request");
    assert.equal(resumeRequest.name, "session.resume.requested");
    assert.deepEqual(resumeRequest.data, {
      targetSessionFile: "/private/axo/archived-session.jsonl",
    });
    assert.deepEqual(await beforeSwitch({ reason: "new" } as never, context as never), { cancel: true });
    socket.destroy();

    const shutdown = registered.get("session_shutdown");
    assert.ok(shutdown);
    await shutdown({ reason: "quit" } as never, context as never);
    await assert.rejects(lstat(socketPath), { code: "ENOENT" });
  } finally {
    const shutdown = registered.get("session_shutdown");
    if (shutdown) await shutdown({ reason: "quit" } as never, context as never);
  }
});
