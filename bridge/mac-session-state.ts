import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { writeFileSync, renameSync, unlinkSync } from "node:fs";
import { resolve } from "node:path";

export type MacAgentState = "idle" | "working" | "attention" | "detached";

/** Read-only local observation channel; not a command broker or transcript replica. */
export function registerMacSessionState(pi: ExtensionAPI): { waiting: () => () => void } {
  const path = process.env.AXO_STATE_FILE, sessionID = process.env.AXO_WORK_SESSION_ID;
  const paneID = process.env.AXO_PANE_ID, runtimeGeneration = process.env.AXO_RUNTIME_GENERATION;
  const expectedFile = process.env.AXO_MANAGED_SESSION_FILE;
  let context: ExtensionContext | undefined;
  let state: MacAgentState = "idle", attentionID: string | undefined;
  let attentionReason: "question" | "result" | "failure" | undefined;
  let generation = 0, failed = false;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  const validUUID = (value: string | undefined) => !!value && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(value);
  const enabled = !!path && !!expectedFile && validUUID(sessionID) && validUUID(paneID) && validUUID(runtimeGeneration);

  function publish(next: MacAgentState, reason?: "question" | "result" | "failure"): void {
    if (!enabled || !context) return;
    const currentFile = context.sessionManager.getSessionFile();
    const bound = currentFile && resolve(currentFile) === resolve(expectedFile!);
    next = bound ? next : "detached";
    if (next === "attention" && (state !== "attention" || attentionReason !== reason)) attentionID = crypto.randomUUID();
    if (next !== "attention") attentionID = undefined;
    state = next; attentionReason = next === "attention" ? reason : undefined;
    const temporary = path + "." + crypto.randomUUID();
    try {
      writeFileSync(temporary, JSON.stringify({ version: 1, sessionID, paneID, runtimeGeneration, updatedAt: Date.now(),
        conversationID: bound ? context.sessionManager.getSessionId() : null,
        state, attentionID: attentionID ?? null, attentionReason: attentionReason ?? null }), { mode: 0o600, flag: "wx" });
      renameSync(temporary, path!);
    } catch { try { unlinkSync(temporary); } catch {} /* Observation failure must never interrupt Pi. */ }
  }

  pi.on("session_start", (_event, ctx) => {
    clearInterval(heartbeat);
    context = ctx; generation++; failed = false; publish("idle");
    if (enabled) {
      heartbeat = setInterval(() => publish(state, attentionReason), 2_500);
      heartbeat.unref();
    }
  });
  pi.on("agent_start", () => { failed = false; publish("working"); });
  pi.on("message_end", event => {
    if (event.message.role === "assistant" && event.message.stopReason === "error") failed = true;
  });
  pi.on("agent_settled", (event, ctx) => { context = ctx; publish(event.aborted && !failed ? "idle" : "attention", failed ? "failure" : "result"); });
  pi.on("session_shutdown", () => { clearInterval(heartbeat); heartbeat = undefined; publish("detached"); generation++; context = undefined; });
  // Invalidate before the switch, so an old asynchronous callback cannot publish to a new binding.
  pi.on("session_before_switch", () => { generation++; publish("detached"); });
  pi.on("session_before_fork", () => { generation++; publish("detached"); });
  pi.on("session_before_tree", () => { generation++; publish("detached"); });

  // Only Axo-owned questions are observable here. Pi has no public global UI-wait observer.
  // A future public hook must cover other extensions' permission/dialog waits; do not parse terminal text.
  return { waiting: () => {
    const capturedGeneration = generation;
    publish("attention", "question");
    return () => { if (capturedGeneration === generation) publish("working"); };
  } };
}
