import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createFauxCore, fauxAssistantMessage, getCurrentTools } from "@earendil-works/pi-ai";
import {
  createAgentSession, createCodemodeExtension, DefaultResourceLoader,
  ModelRuntime, SessionManager, SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { installAxoSessionNaming } from "../src/title.js";
import type { AxoPiBridgeServer } from "../src/bridge-server.js";

test("real codemode calls the undeclared title tool with current naming guidance", { timeout: 20_000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), "axo-title-sdk-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const manager = SessionManager.create(root, join(root, "sessions"));
  const identity = {
    axoSessionId: "82cfd1e8-1cc6-4473-a16d-6f0e77476311",
    axoPaneId: "9b9e14e0-d1c6-46b8-b289-bab4fda8774f",
    piSessionId: manager.getSessionId(), sessionFile: manager.getSessionFile()!, cwd: root, processId: process.pid,
  };
  const published: Array<{ name: string; data: unknown }> = [];
  const bridge = { publish: async (name: string, data: unknown) => { published.push({ name, data }); } } as AxoPiBridgeServer;
  const faux = createFauxCore({ provider: "faux", models: [{ id: "faux-1" }] });
  faux.setResponses([
    context => {
      const tools = getCurrentTools(context.messages).map(tool => tool.name);
      assert.ok(tools.includes("codemode"));
      assert.ok(!tools.includes("axo_set_title"), "The title tool must not have a direct declaration");
      const input = JSON.stringify(context.messages);
      assert.match(input, /tools\.axo_set_title/);
      return fauxAssistantMessage([{
        type: "toolCall", id: "rename", name: "codemode",
        arguments: { code: 'text(await tools.axo_set_title({ title: "axo: test naming", emoji: "🧪" }));' },
      }], { stopReason: "toolUse" });
    },
    fauxAssistantMessage("Named through codemode."),
  ]);
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerProvider("faux", {
    api: faux.api as never, apiKey: "faux", baseUrl: "http://faux.invalid", streamSimple: faux.streamSimple as never,
    models: [{ id: "faux-1", name: "Faux", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100_000, maxTokens: 1_000 }],
  });
  const model = runtime.getModel("faux", "faux-1");
  assert.ok(model);
  const settings = SettingsManager.inMemory();
  const loader = new DefaultResourceLoader({
    cwd: root, agentDir: join(root, "agent"), settingsManager: settings,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    extensionFactories: [
      createCodemodeExtension({ models: false }),
      pi => {
        installAxoSessionNaming(pi, bridge, () => identity, () => identity);
      },
    ],
  });
  await loader.reload();
  assert.deepEqual(loader.getExtensions().errors, []);
  const { session } = await createAgentSession({
    cwd: root, agentDir: join(root, "agent"), model, modelRuntime: runtime,
    sessionManager: manager, settingsManager: settings, resourceLoader: loader, noTools: "builtin",
  });
  t.after(() => session.dispose());
  const errors: unknown[] = [];
  await session.bindExtensions({ onError: error => errors.push(error) });
  session.setActiveToolsByName(["codemode"]);
  await session.prompt("Test the naming tool.");
  await session.waitForIdle();
  assert.equal(manager.getSessionName(), "axo: test naming", JSON.stringify(manager.getEntries()));
  assert.equal(faux.state.callCount, 2);
  assert.ok(published.some(event => event.name === "axo.session.metadata"));
  assert.deepEqual(errors, []);
});
