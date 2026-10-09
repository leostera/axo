import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { registerMacSessionState } from "../bridge/mac-session-state";

test("local state observes real lifecycle meanings, stable attention episodes, and detached generation fences", () => {
  const root = mkdtempSync(join(tmpdir(), "axo-mac-state-"));
  const keys = ["AXO_STATE_FILE", "AXO_WORK_SESSION_ID", "AXO_PANE_ID", "AXO_RUNTIME_GENERATION", "AXO_MANAGED_SESSION_FILE"];
  const before = keys.map(key => process.env[key]);
  const file = join(root, "state.json"), expected = join(root, "conversation.jsonl");
  process.env.AXO_STATE_FILE = file; process.env.AXO_MANAGED_SESSION_FILE = expected;
  for (const key of keys.slice(1, 4)) process.env[key] = crypto.randomUUID();
  const handlers = new Map<string, (event: any, ctx: ExtensionContext) => void>();
  const pi = { on: (event: string, handler: (event: any, ctx: ExtensionContext) => void) => handlers.set(event, handler) } as unknown as ExtensionAPI;
  let currentFile = expected;
  const ctx = { sessionManager: { getSessionFile: () => currentFile, getSessionId: () => "original-conversation" } } as unknown as ExtensionContext;
  const emit = (event: string, value: unknown = {}) => handlers.get(event)?.(value, ctx);
  const read = () => JSON.parse(readFileSync(file, "utf8"));
  try {
    const reporter = registerMacSessionState(pi);
    assert.equal(existsSync(file), false, "Discovery alone must not publish session state");
    emit("session_start"); assert.equal(read().state, "idle");
    emit("agent_start"); assert.equal(read().state, "working");
    const resume = reporter.waiting();
    const question = read(); assert.equal(question.state, "attention"); assert.equal(question.attentionReason, "question");
    assert.equal(reporter.waiting() instanceof Function, true);
    assert.equal(read().attentionID, question.attentionID);
    resume(); assert.equal(read().state, "working");
    emit("agent_settled", { aborted: false });
    const completed = read(); assert.equal(completed.attentionReason, "result");
    emit("agent_settled", { aborted: false }); assert.equal(read().attentionID, completed.attentionID);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    emit("agent_start"); emit("message_end", { message: { role: "assistant", stopReason: "error", content: [{ text: "private provider failure" }] } });
    emit("agent_settled", { aborted: false }); assert.equal(read().attentionReason, "failure");
    assert.ok(!readFileSync(file, "utf8").includes("private provider failure"));
    emit("agent_start"); emit("agent_settled", { aborted: true }); assert.equal(read().state, "idle");
    const staleResume = reporter.waiting();
    emit("session_before_switch"); currentFile = join(root, "different.jsonl"); emit("session_start");
    staleResume(); assert.equal(read().state, "detached"); assert.equal(read().conversationID, null);
    emit("agent_start"); emit("agent_settled", { aborted: false }); assert.equal(read().state, "detached");
    currentFile = expected; emit("session_start");
    const preTreeResume = reporter.waiting(); emit("session_before_tree");
    preTreeResume(); assert.equal(read().state, "detached");
    emit("session_shutdown");
    rmSync(root, { recursive: true });
    assert.doesNotThrow(() => reporter.waiting());
  } finally {
    emit("session_shutdown");
    keys.forEach((key, index) => { if (before[index] === undefined) delete process.env[key]; else process.env[key] = before[index]; });
    rmSync(root, { recursive: true, force: true });
  }
});
