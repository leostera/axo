/** A Mac following its peers (`host-…`), the iPhone app (`ios-…`), or a browser tab. */
export type ClientKind = "peer" | "phone" | "web";

/** The kind of client a client id names; the id itself is never logged. */
export function clientKind(clientId: string): ClientKind {
  return clientId.startsWith("host-") ? "peer" : clientId.startsWith("ios-") ? "phone" : "web";
}

// Deliberately excludes identity, URLs, credentials, payloads, paths and arbitrary error text.
type ApiEvent =
  | { event: "host_registered" }
  | { event: "share_published"; messages: number }
  | { event: "sign_in"; client: "web" | "native"; outcome: "started" | "completed" | "refused" | "failed"; stage?: string }
  /** `unowned`: a socket another release accepted, closed when the object woke (RFD0032, Release P). */
  | { event: "connection_closed"; role: "daemon" | "unowned"; code: number }
  | { event: "relay_send_failed"; reason: "too_large" }
  /** `read`: the Sessions the index could not answer, each one SessionDO call (RFD0032). */
  | { event: "host_sync"; sessions: number; read: number; unknown: number }
  | { event: "session_append"; outcome: "committed" | "gap" | "conflict" | "epoch" | "invalid" | "fenced"; records: number }
  | { event: "session_truncate"; outcome: "truncated" | "mismatch" | "fenced" }
  | { event: "notice_batch"; subscribers: number; notices: number }
  /** `read`: whether the open read the SessionDO; a protocol 3 open at the head reads nothing (RFD0032). */
  | { event: "client_open"; records: number; read?: boolean }
  /** A client said hello on its account socket: which protocol, and what kind of client (never which). */
  | { event: "client_hello"; protocol: 2 | 3; client: ClientKind }
  /** A protocol 3 client said hello on a host socket (RFD0032). */
  | { event: "host_client_hello" }
  /** A client's newer connection closed its older socket, or an older hello was refused (RFD0032). */
  | { event: "host_client_replaced"; outcome: "replaced" | "refused" }
  | { event: "client_stalled" }
  | { event: "client_follow_failed" }
  /** What a Mac asked its person, and how it ended (RFD0029); never the words. */
  | { event: "elicitation_requested"; kind: "confirm" | "input" }
  | { event: "elicitation_resolved"; outcome: "accept" | "decline" | "cancel" }
  | { event: "host_apps_call"; outcome: "result" | "error" | "unknown" | "refused" }
  | { event: "host_call"; outcome: "result" | "error" | "offline" | "disconnected" | "timeout" }
  /** One `axo.apps.*` call the account answered; `outcome` is "result" or the error code. */
  | { event: "apps_call"; method: string; outcome: string; durationMs: number };

export function recordApiEvent(event: ApiEvent): void {
  console.info(JSON.stringify(event));
}
