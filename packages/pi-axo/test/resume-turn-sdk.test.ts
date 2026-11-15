import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { connect } from "node:net";
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
} from "@earendil-works/pi-coding-agent";
import { installAxoPiExtension } from "../src/extension.js";

// Runs against both supported and older SDKs. An older SDK must explicitly refuse, not
// silently turn a recovery instruction into a user/custom message. Use the same test with
// the resumeTurn SDK build to exercise the real provider/extension/socket path.
test(
  "real SDK bridge resumes message-free or explicitly refuses an unsupported SDK",
  { timeout: 10_000 },
  async (t) => {
    const root = await mkdtemp(join(tmpdir(), "axo-resume-sdk-"));
    t.after(() => rm(root, { recursive: true, force: true }));
    const sessionId = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
    const paneId = "9b9e14e0-d1c6-46b8-b289-bab4fda8774f";
    const token = "329a2ee2-8cd9-47df-8575-a5090f5df231";
    const manager = SessionManager.create(root, join(root, "sessions"));
    manager.appendMessage({ role: "user", content: [{ type: "text", text: "original saved request" }], timestamp: 1 });
    const socketPath = join(root, "bridge.sock");
    const faux = createFauxCore({ provider: "faux", models: [{ id: "faux-1" }] });
    faux.setResponses([fauxAssistantMessage("resumed without another prompt")]);
    const runtime = await ModelRuntime.create({
      authPath: join(root, "auth.json"),
      modelsPath: null,
      refreshOnCreate: false,
    });
    runtime.registerProvider("faux", {
      api: faux.api as never,
      apiKey: "faux",
      baseUrl: "http://faux.invalid",
      streamSimple: faux.streamSimple as never,
      models: [
        {
          id: "faux-1",
          name: "Faux",
          reasoning: false,
          input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow: 100_000,
          maxTokens: 1_000,
        },
      ],
    });
    const model = runtime.getModel("faux", "faux-1");
    assert.ok(model);
    const settings = SettingsManager.inMemory();
    const loader = new DefaultResourceLoader({
      cwd: root,
      agentDir: join(root, "agent"),
      settingsManager: settings,
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
      extensionFactories: [
        (pi) =>
          installAxoPiExtension(pi, {
            socketPath,
            piSessionFile: manager.getSessionFile()!,
            axoSessionId: sessionId,
            axoPaneId: paneId,
            bridgeToken: token,
          }),
      ],
    });
    await loader.reload();
    const { session } = await createAgentSession({
      cwd: root,
      agentDir: join(root, "agent"),
      model,
      modelRuntime: runtime,
      sessionManager: manager,
      settingsManager: settings,
      resourceLoader: loader,
      noTools: "all",
    });
    t.after(async () => {
      await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
      session.dispose();
    });
    const errors: unknown[] = [];
    await session.bindExtensions({ onError: (error) => errors.push(error) });
    const supported = "resumeTurn" in session && typeof session.resumeTurn === "function";
    if (process.env.AXO_TEST_REQUIRE_RESUME_TURN === "1")
      assert.ok(supported, "this run requires the resumeTurn SDK, not the unsupported-SDK branch");
    t.diagnostic(`resumeTurn SDK capability: ${supported ? "supported" : "explicit refusal"}`);
    const socket = connect(socketPath);
    t.after(() => socket.destroy());
    let buffer = "";
    const ready: Record<string, unknown>[] = [];
    const waiting: Array<(record: Record<string, unknown>) => void> = [];
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let end: number;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const record = JSON.parse(buffer.slice(0, end)) as Record<string, unknown>;
        buffer = buffer.slice(end + 1);
        const consume = waiting.shift();
        if (consume) consume(record);
        else ready.push(record);
      }
    });
    const next = () =>
      ready.length
        ? Promise.resolve(ready.shift()!)
        : new Promise<Record<string, unknown>>((resolve) => waiting.push(resolve));
    await once(socket, "connect");
    socket.write(`${JSON.stringify({ type: "authenticate", protocolVersion: 1, token })}\n`);
    for (const requestId of ["resume-one", "resume-duplicate"]) {
      socket.write(
        `${JSON.stringify({ type: "command", requestId, axoSessionId: sessionId, action: { kind: "resumeTurn" } })}\n`,
      );
      for (;;) {
        const record = await next();
        if (record.type === "commandResult" && record.requestId === requestId) {
          assert.deepEqual(record.result, supported ? { accepted: true } : { accepted: false, reason: "unavailable" });
          break;
        }
      }
      await session.waitForIdle();
    }
    assert.equal(faux.state.callCount, supported ? 1 : 0, "duplicate recovery must not start a second turn");
    assert.equal(
      manager.getEntries().filter((entry) => entry.type === "message" && entry.message.role === "user").length,
      1,
    );
    assert.equal(manager.getEntries().filter((entry) => entry.type === "custom_message").length, 0);
    assert.deepEqual(errors, []);
  },
);
