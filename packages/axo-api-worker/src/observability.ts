import type { RemoteMethod } from "@axo/protocol";
import type { OAuthProviderErrorCode } from "./auth/provider";

// Deliberately excludes identity, URLs, credentials, payloads, paths and arbitrary error text.
type ApiEvent =
  | { event: "host_registered" }
  | { event: "connection_closed"; role: "client" | "daemon"; code: number }
  | {
      event: "relay_reply";
      method: RemoteMethod;
      outcome: "reply" | "unknown";
    }
  | {
      event: "oauth_callback_failure";
      stage:
        | "configuration"
        | "durable_object_exports"
        | "token_exchange"
        | "token_response"
        | "userinfo_request"
        | "userinfo_response"
        | "identity_resolve"
        | "session_persist"
        | "session_cookie_seal";
      reason: "configuration" | "network" | "http" | "invalid_response" | "operation_failed";
      status?: number;
      providerCode?: OAuthProviderErrorCode;
    };

export function recordApiEvent(event: ApiEvent): void {
  console.info(JSON.stringify(event));
}
