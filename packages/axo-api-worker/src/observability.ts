import type { RemoteMethod } from "@axo/protocol";

// Deliberately excludes identity, URLs, credentials, payloads, paths and arbitrary error text.
type ApiEvent =
  | { event: "host_registered" }
  | { event: "connection_closed"; role: "client" | "daemon"; code: number }
  | {
      event: "relay_reply";
      method: RemoteMethod;
      outcome: "reply" | "unknown";
    };

export function recordApiEvent(event: ApiEvent): void {
  console.info(JSON.stringify(event));
}
