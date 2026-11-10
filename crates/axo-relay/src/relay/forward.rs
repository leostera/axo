//! Carrying the account's calls to the host and its answers back (RFD0034 step 6).
//!
//! The relay knows none of the methods: only that the account may call `axo.remote.*` and
//! nothing else, so no local method is ever reached from the cloud. The host answers them as
//! ordinary methods for the account (`RelayHost::answer_remote`).

use axo_protocol::rpc::MethodError;
use serde_json::{Value, json};

use crate::host::RelayHost;

/// The only methods the account may call through the relay.
const REMOTE_PREFIX: &str = "axo.remote.";

/// What the relay does with one message from the account.
#[derive(Debug, PartialEq)]
pub(super) enum AccountCall {
    /// No id: nothing would hear an answer, so it is not run.
    Notification,
    /// Not a method the account may call; this is its error reply.
    Refused(Value),
    /// A call for the host, rewritten as a well-formed request.
    Remote(Value),
}

impl AccountCall {
    pub(super) fn of(message: &Value) -> Self {
        let Some(id) = message.get("id").filter(|id| !id.is_null()).cloned() else {
            return Self::Notification;
        };
        let method = message.get("method").and_then(Value::as_str).unwrap_or("");
        if !method.starts_with(REMOTE_PREFIX) {
            return Self::Refused(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": MethodError::method_not_found(),
            }));
        }
        let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
        Self::Remote(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))
    }
}

/// The reply to a message from the account; `None` for a notification.
pub(super) async fn answer(message: &Value, host: &dyn RelayHost) -> Option<Value> {
    match AccountCall::of(message) {
        AccountCall::Notification => None,
        AccountCall::Refused(reply) => Some(reply),
        AccountCall::Remote(request) => host.answer_remote(request).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_accounts_calls_reach_the_host_whole_and_well_formed() {
        assert_eq!(
            AccountCall::of(
                &json!({ "id": "r-1", "method": "axo.remote.session.create", "params": { "target": {} } })
            ),
            AccountCall::Remote(
                json!({ "jsonrpc": "2.0", "id": "r-1", "method": "axo.remote.session.create", "params": { "target": {} } })
            )
        );
        assert_eq!(
            AccountCall::of(&json!({ "id": 2, "method": "axo.remote.session.list" })),
            AccountCall::Remote(
                json!({ "jsonrpc": "2.0", "id": 2, "method": "axo.remote.session.list", "params": {} })
            ),
            "absent params are an empty object"
        );
    }

    #[test]
    fn nothing_but_remote_calls_reaches_the_host() {
        for method in ["axo.config.set", "axo.session.create", "axo.remotex", ""] {
            let AccountCall::Refused(reply) =
                AccountCall::of(&json!({ "id": 7, "method": method, "params": {} }))
            else {
                panic!("{method} reached the host");
            };
            assert_eq!(reply["error"]["code"], -32601, "{method}");
            assert_eq!(reply["id"], 7);
        }
        // A notification is not run, remote or not.
        for notification in [
            json!({ "method": "axo.remote.session.create" }),
            json!({ "id": null, "method": "axo.remote.session.create" }),
        ] {
            assert_eq!(AccountCall::of(&notification), AccountCall::Notification);
        }
    }
}
