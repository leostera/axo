import type { RemoteMethod } from "@axo/protocol";

// Deliberately excludes identity, URLs, credentials, payloads, paths and arbitrary error text.
type ApiEvent =
  | { event: "host_registered" }
  | { event: "sign_in"; client: "web" | "native"; outcome: "started" | "completed" | "refused" | "failed"; stage?: string }
  | { event: "connection_closed"; role: "client" | "daemon"; code: number }
  | { event: "pi_event_not_stored"; reason: "unknown_session" | "invalid" | "conflict" }
  | { event: "pi_event_trimmed"; bytes: number }
  | { event: "relay_send_failed"; reason: "outbox_full" | "too_large" }
  | { event: "relay_message_discarded"; reason: "credit_timeout" }
  | {
      event: "relay_reply";
      method: RemoteMethod;
      outcome: "reply" | "unknown";
    };

export function recordApiEvent(event: ApiEvent): void {
  console.info(JSON.stringify(event));
}
