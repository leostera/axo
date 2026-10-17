import assert from "node:assert/strict";
import test from "node:test";
import { parsePiControlCommand, parsePiSessionIdentity } from "../src/protocol.js";

const sessionId = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
const paneId = "9b9e14e0-d1c6-46b8-b289-bab4fda8774f";

test("parses a scoped send command into a trusted value", () => {
  assert.deepEqual(parsePiControlCommand({
    type: "command",
    requestId: "request-1",
    axoSessionId: sessionId,
    action: { kind: "send", text: "Inspect the failing test" },
  }, sessionId), {
    ok: true,
    command: {
      requestId: "request-1",
      axoSessionId: sessionId,
      action: { kind: "send", text: "Inspect the failing test" },
    },
  });
});

test("rejects commands for a different Session and unknown fields", () => {
  const otherSessionId = "e1cd03bd-5fcc-4b5a-a1fa-47653e5fa822";
  assert.deepEqual(parsePiControlCommand({
    type: "command",
    requestId: "request-2",
    axoSessionId: otherSessionId,
    action: { kind: "cancel" },
  }, sessionId), { ok: false, reason: "stale" });

  assert.deepEqual(parsePiControlCommand({
    type: "command",
    requestId: "request-3",
    axoSessionId: sessionId,
    action: { kind: "cancel" },
    token: "not-accepted-here",
  }, sessionId), { ok: false, reason: "invalid" });
});

test("bounds prompt size and rejects unsupported delivery modes", () => {
  assert.deepEqual(parsePiControlCommand({
    type: "command",
    requestId: "request-4",
    axoSessionId: sessionId,
    action: { kind: "send", text: "x".repeat(65 * 1024) },
  }, sessionId), { ok: false, reason: "invalid" });

  assert.deepEqual(parsePiControlCommand({
    type: "command",
    requestId: "request-5",
    axoSessionId: sessionId,
    action: { kind: "send", text: "hello", delivery: "immediate" },
  }, sessionId), { ok: false, reason: "invalid" });
});

test("accepts a complete local Pi binding and rejects malformed identity fields", () => {
  const identity = {
    axoSessionId: sessionId,
    axoPaneId: paneId,
    piSessionId: "pi-session-1",
    sessionFile: "/tmp/axo/sessions/pi-session-1.jsonl",
    cwd: "/projects/axo",
    processId: 1234,
  };
  assert.deepEqual(parsePiSessionIdentity(identity), identity);
  assert.equal(parsePiSessionIdentity({ ...identity, axoPaneId: "not-a-uuid" }), null);
  assert.equal(parsePiSessionIdentity({ ...identity, processId: 0 }), null);
  assert.equal(parsePiSessionIdentity({ ...identity, sessionFile: "relative/session.jsonl" }), null);
  assert.equal(parsePiSessionIdentity({ ...identity, cwd: "/projects/axo\0private" }), null);
});
