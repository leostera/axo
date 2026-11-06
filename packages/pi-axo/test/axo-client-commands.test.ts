/**
 * A real Pi session loading pi-axo through its entry point, prompted the way Axo clients prompt
 * (the app's composer, the phone, the menu bar): through the bridge socket, not Pi's editor.
 *
 * Regression: `/axo-share` sent from the Axo app reached the model as plain text, because client
 * prompts were handed to `pi.sendUserMessage` without command dispatch.
 */
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createFauxCore, fauxAssistantMessage } from "@earendil-works/pi-ai";
import {
  createAgentSession,
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  type ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";
import axoPiExtension from "../src/index.js";

const axoSessionId = "5d0c6a52-2a39-4c55-9d43-0e8f6f4f2b11";
const axoPaneId = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d";
const bridgeToken = "0f1e2d3c-4b5a-4968-8776-655443322110";
const AXO_ENVIRONMENT = ["AXO_PI_BRIDGE_SOCKET", "AXO_PI_SESSION_FILE", "AXO_SESSION_ID", "AXO_PANE_ID", "AXO_PI_BRIDGE_TOKEN", "AXOD", "AXO_SOCKET", "AXO_REMOTE_VIEW"];

function lines(socket: Socket): () => Promise<Record<string, unknown>> {
  let buffer = "";
  const ready: Record<string, unknown>[] = [];
  const waiting: Array<(record: Record<string, unknown>) => void> = [];
  socket.on("data", chunk => {
    buffer += chunk.toString("utf8");
    for (let newline = buffer.indexOf("\n"); newline >= 0; newline = buffer.indexOf("\n")) {
      const record = JSON.parse(buffer.slice(0, newline)) as Record<string, unknown>;
      buffer = buffer.slice(newline + 1);
      const next = waiting.shift();
      if (next) next(record);
      else ready.push(record);
    }
  });
  return () => ready.length > 0 ? Promise.resolve(ready.shift()!) : new Promise(resolve => waiting.push(resolve));
}

async function eventually(what: string, check: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

test("/axo-share sent from an Axo client runs the command instead of reaching the model", async t => {
  const directory = await mkdtemp(join(tmpdir(), "pi-axo-client-commands-"));
  const saved = Object.fromEntries(AXO_ENVIRONMENT.map(name => [name, process.env[name]]));
  t.after(async () => {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await rm(directory, { recursive: true, force: true });
  });

  const sessionManager = SessionManager.create(directory, join(directory, "sessions"));
  const sessionFile = sessionManager.getSessionFile();
  assert.ok(sessionFile);
  for (const name of AXO_ENVIRONMENT) delete process.env[name];
  Object.assign(process.env, {
    AXO_PI_BRIDGE_SOCKET: join(directory, "bridge.sock"),
    AXO_PI_SESSION_FILE: sessionFile,
    AXO_SESSION_ID: axoSessionId,
    AXO_PANE_ID: axoPaneId,
    AXO_PI_BRIDGE_TOKEN: bridgeToken,
  });

  const faux = createFauxCore({ provider: "faux", models: [{ id: "faux-1" }] });
  faux.setResponses([fauxAssistantMessage("hello back")]);
  const modelRuntime = await ModelRuntime.create({ authPath: join(directory, "auth.json"), modelsPath: null, refreshOnCreate: false });
  modelRuntime.registerProvider("faux", {
    api: faux.api as never,
    apiKey: "faux",
    baseUrl: "http://faux.invalid",
    streamSimple: faux.streamSimple as never,
    models: [{ id: "faux-1", name: "Faux", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100_000, maxTokens: 1_000 }],
  });
  const model = modelRuntime.getModel("faux", "faux-1");
  assert.ok(model);

  const settingsManager = SettingsManager.inMemory();
  const resourceLoader = new DefaultResourceLoader({
    cwd: directory,
    agentDir: join(directory, "agent"),
    settingsManager,
    noExtensions: true,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
    extensionFactories: [axoPiExtension],
  });
  await resourceLoader.reload();
  const { session } = await createAgentSession({ cwd: directory, agentDir: join(directory, "agent"), model, modelRuntime, sessionManager, settingsManager, resourceLoader, noTools: "all" });
  t.after(async () => {
    // What Pi does on quit: pi-axo closes its bridge socket.
    await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
    session.dispose();
  });

  const notices: string[] = [];
  const ui = new Proxy({ notify: (message: string) => { notices.push(message); } }, {
    get: (target, key) => key in target ? target[key as "notify"] : key === "then" ? undefined : () => undefined,
  }) as unknown as ExtensionUIContext;
  const errors: unknown[] = [];
  await session.bindExtensions({ uiContext: ui, mode: "tui", onError: error => { errors.push(error); } });
  t.after(() => assert.deepEqual(errors, [], "no extension errors"));

  // The command must exist in this Pi at all.
  assert.ok(session.extensionRunner.getCommand("axo-share"), "pi-axo registers /axo-share");

  const socket = connect({ path: process.env.AXO_PI_BRIDGE_SOCKET! });
  t.after(() => socket.destroy());
  const next = lines(socket);
  await once(socket, "connect");
  socket.write(`${JSON.stringify({ type: "authenticate", protocolVersion: 1, token: bridgeToken })}\n`);
  assert.equal((await next()).type, "authenticated");
  assert.equal((await next()).type, "hello");

  const send = async (requestId: string, commandId: string, text: string) => {
    socket.write(`${JSON.stringify({ type: "command", requestId, axoSessionId, action: { kind: "send", text, commandId } })}\n`);
    for (;;) {
      const record = await next();
      if (record.type === "commandResult" && record.requestId === requestId) return record.result;
    }
  };
  const userTexts = () => session.sessionManager.getEntries().flatMap(entry =>
    entry.type === "message" && entry.message.role === "user"
      ? [typeof entry.message.content === "string" ? entry.message.content : entry.message.content.map(part => part.type === "text" ? part.text : "").join("")]
      : []);

  assert.deepEqual(await send("share", "11111111-2222-4333-8444-555555555555", "/axo-share"), { accepted: true });
  await eventually("the /axo-share command to run", () => notices.some(notice => notice.includes("Sharing works in Pi sessions that Axo runs")));
  assert.equal(faux.state.callCount, 0, "the model never saw /axo-share");
  assert.deepEqual(userTexts(), [], "/axo-share is not a user message");

  // An ordinary client prompt still becomes a turn, so the check above can fail.
  assert.deepEqual(await send("hello", "66666666-7777-4888-8999-aaaaaaaaaaaa", "hello"), { accepted: true });
  await eventually("the prompt's turn", () => faux.state.callCount === 1);
  await session.waitForIdle();
  assert.deepEqual(userTexts(), ["hello"]);
});
