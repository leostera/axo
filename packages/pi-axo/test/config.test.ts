import assert from "node:assert/strict";
import test from "node:test";
import { parseAxoPiExtensionConfig } from "../src/index.js";

const environment = {
  AXO_PI_BRIDGE_SOCKET: "/private/axo/run/pi.sock",
  AXO_PI_SESSION_FILE: "/private/axo/sessions/pi-session-1.jsonl",
  AXO_SESSION_ID: "82cfd1e8-1cc6-4473-a16d-6f0e77476311",
  AXO_PANE_ID: "9b9e14e0-d1c6-46b8-b289-bab4fda8774f",
};

test("requires Axod's complete, absolute, session-scoped launch binding", () => {
  assert.deepEqual(parseAxoPiExtensionConfig(environment), {
    socketPath: environment.AXO_PI_BRIDGE_SOCKET,
    piSessionFile: environment.AXO_PI_SESSION_FILE,
    axoSessionId: environment.AXO_SESSION_ID,
    axoPaneId: environment.AXO_PANE_ID,
  });
  assert.equal(parseAxoPiExtensionConfig({ ...environment, AXO_PI_SESSION_FILE: "relative/session.jsonl" }), null);
  assert.equal(parseAxoPiExtensionConfig({ ...environment, AXO_SESSION_ID: "not-a-session" }), null);
  assert.equal(parseAxoPiExtensionConfig({ ...environment, AXO_PI_BRIDGE_SOCKET: "/" + "x".repeat(120) }), null);
});
