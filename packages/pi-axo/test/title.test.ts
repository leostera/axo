import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { installAxoSessionNaming } from "../src/title.js";
import type { PiSessionIdentity } from "../src/protocol.js";

const identity: PiSessionIdentity = {
  axoSessionId: "session-1",
  axoPaneId: "pane-1",
  piSessionId: "pi-session-1",
  sessionFile: "/tmp/axo-title-test/session.jsonl",
  cwd: "/tmp/axo-title-test",
  processId: 1234,
};

test("axo_set_title can update an existing session title repeatedly", async () => {
  let sessionName: string | undefined;
  const branch: Array<{ type: string; customType: string; data: unknown }> = [];
  const published: Array<{ name: string; data: unknown }> = [];
  const listeners = new Map<string, (...args: any[]) => unknown>();
  let registeredTool: unknown;

  const pi = {
    registerTool(tool: unknown) {
      registeredTool = tool;
    },
    on(event: string, handler: (...args: any[]) => unknown) {
      listeners.set(event, handler);
      return () => listeners.delete(event);
    },
    setSessionName(name: string) {
      sessionName = name;
    },
    appendEntry(customType: string, data: unknown) {
      branch.push({ type: "custom", customType, data });
    },
  } as unknown as ExtensionAPI;

  const context = {
    sessionManager: {
      getSessionName: () => sessionName,
      getBranch: () => branch,
    },
    cwd: identity.cwd,
  } as unknown as ExtensionContext;
  const bridge = {
    publish: async (name: string, data: unknown) => {
      published.push({ name, data });
    },
  } as any;

  installAxoSessionNaming(pi, bridge, () => identity, () => identity);

  const tool = registeredTool as {
    description: string;
    execute: (...args: any[]) => Promise<{ content: Array<{ type: string; text: string }>; details: unknown }>;
  };

  assert.match(tool.description, /Set or update/u);

  const firstResult = await tool.execute("call-1", { title: "Explore Axo", emoji: "🌱" }, undefined, undefined, context);
  const secondResult = await tool.execute("call-2", { title: "Ship Axo", emoji: "🚀" }, undefined, undefined, context);

  assert.equal(sessionName, "Ship Axo");
  assert.deepEqual(branch.map(entry => entry.data), [{ emoji: "🌱" }, { emoji: "🚀" }]);
  assert.deepEqual(published, [
    { name: "session.info", data: { name: "Explore Axo" } },
    { name: "axo.session.metadata", data: { title: null, emoji: "🌱" } },
    { name: "session.info", data: { name: "Ship Axo" } },
    { name: "axo.session.metadata", data: { title: null, emoji: "🚀" } },
  ]);
  assert.equal(firstResult.content[0]?.text, "Session named 🌱 Explore Axo.");
  assert.equal(secondResult.content[0]?.text, "Session title updated to 🚀 Ship Axo.");

  const beforeAgentStart = listeners.get("before_agent_start");
  assert.ok(beforeAgentStart);
  const event = {
    messageType: "user",
    systemPromptOptions: { selectedTools: ["axo_set_title"], sections: {} as Record<string, string> },
  };
  beforeAgentStart(event, context);
  const guidance = event.systemPromptOptions.sections.axo_session_title ?? "";
  assert.match(guidance, /changes materially/u);
  // Titles lead with a project keyword; the working directory suggests one.
  assert.match(guidance, /<keyword>: <focus>/u);
  assert.match(guidance, /evalkit: prepare release/u);
  assert.match(guidance, /keyword is probably `axo-title-test`/u);
});
