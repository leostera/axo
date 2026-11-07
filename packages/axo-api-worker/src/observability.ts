import type { RemoteMethod } from "@axo/protocol";

// Deliberately excludes identity, URLs, credentials, payloads, paths and arbitrary error text.
type ApiEvent =
  | { event: "host_registered" }
  | { event: "share_published"; messages: number }
  | { event: "sign_in"; client: "web" | "native"; outcome: "started" | "completed" | "refused" | "failed"; stage?: string }
  | { event: "connection_closed"; role: "client" | "daemon"; code: number }
  | { event: "relay_send_failed"; reason: "too_large" }
  | { event: "host_sync"; sessions: number; unknown: number }
  | { event: "session_append"; outcome: "committed" | "gap" | "conflict" | "epoch" | "invalid"; records: number }
  | { event: "session_truncate"; outcome: "truncated" | "mismatch" }
  | { event: "notice_batch"; subscribers: number; notices: number }
  | { event: "client_open"; records: number }
  | { event: "client_stalled" }
  | { event: "client_follow_failed" }
  /** What a Mac asked its person, and how it ended (RFD0029); never the words. */
  | { event: "elicitation_requested"; kind: "confirm" | "input" }
  | { event: "elicitation_resolved"; outcome: "accept" | "decline" | "cancel" }
  | { event: "host_apps_call"; outcome: "result" | "error" | "unknown" | "refused" }
  | { event: "host_call"; outcome: "result" | "error" | "offline" | "disconnected" | "timeout" }
  /** One `axo.apps.*` call the account answered; `outcome` is "result" or the error code. */
  | { event: "apps_call"; method: string; outcome: string; durationMs: number }
  | {
      event: "relay_reply";
      method: RemoteMethod;
      outcome: "reply" | "unknown";
    };

export function recordApiEvent(event: ApiEvent): void {
  console.info(JSON.stringify(event));
}
