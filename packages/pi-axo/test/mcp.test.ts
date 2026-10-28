import assert from "node:assert/strict";
import test from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { parseAxoMcpConfig, registerAxoMcpServer } from "../src/index.js";

const environment = {
  AXOD: "/Applications/Axo.app/Contents/Helpers/axod",
  AXO_SOCKET: "/Users/me/Library/Application Support/Axo/run/axod.sock",
  AXO_SESSION_ID: "82cfd1e8-1cc6-4473-a16d-6f0e77476311",
};

test("reads where axod and its socket are, and nothing outside Axo", () => {
  assert.deepEqual(parseAxoMcpConfig(environment), {
    axod: environment.AXOD,
    socket: environment.AXO_SOCKET,
    sessionId: environment.AXO_SESSION_ID,
  });
  assert.equal(parseAxoMcpConfig({}), null);
  assert.equal(parseAxoMcpConfig({ ...environment, AXOD: undefined }), null);
  assert.equal(parseAxoMcpConfig({ ...environment, AXO_SOCKET: "relative.sock" }), null);
  assert.equal(parseAxoMcpConfig({ ...environment, AXO_SESSION_ID: "nope" }), null);
});

test("registers axod mcp for this Session, reachable from codemode", () => {
  const registered: Array<[string, unknown]> = [];
  const pi = { registerMcpServer: (name: string, config: unknown) => registered.push([name, config]) } as unknown as ExtensionAPI;
  registerAxoMcpServer(pi, parseAxoMcpConfig(environment)!);
  assert.equal(registered.length, 1);
  const [name, config] = registered[0]!;
  assert.equal(name, "axo");
  assert.deepEqual({ ...(config as Record<string, unknown>), description: undefined }, {
    command: environment.AXOD,
    args: ["mcp"],
    env: { AXO_SOCKET: environment.AXO_SOCKET, AXO_SESSION_ID: environment.AXO_SESSION_ID },
    exposure: "codemode",
    description: undefined,
  });
});
