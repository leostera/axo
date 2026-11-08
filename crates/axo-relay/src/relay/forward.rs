//! Carrying the account's calls to the host and its answers back (RFD0034 step 6).
//!
//! The relay knows none of the methods: only that the account may call `axo.remote.*` and
//! nothing else, so no local method is ever reached from the cloud. The host answers them as
//! ordinary methods for the account (`RelayHost::answer_remote`).

use serde_json::{Value, json};

/// The only methods the account may call through the relay.
const REMOTE_PREFIX: &str = "axo.remote.";

/// The response to a request from the account, from `host` (`RelayHost::answer_remote`);
/// `None` for a notification, which is not run.
pub(super) fn answer(request: &Value, host: impl FnOnce(Value) -> Option<Value>) -> Option<Value> {
    let id = request.get("id").filter(|id| !id.is_null())?.clone();
    let method = request.get("method").and_then(Value::as_str).unwrap_or("");
    if !method.starts_with(REMOTE_PREFIX) {
        return Some(json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32601, "message": "Method not found" },
        }));
    }
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    host(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// A host that records what it was asked and answers each request with its own method.
    #[derive(Default)]
    struct Recording(Mutex<Vec<Value>>);

    impl Recording {
        fn asked(&self) -> Vec<Value> {
            self.0.lock().unwrap().clone()
        }

        fn answer(&self) -> impl FnOnce(Value) -> Option<Value> + '_ {
            |request| {
                self.0.lock().unwrap().push(request.clone());
                Some(json!({ "jsonrpc": "2.0", "id": request["id"], "result": request["method"] }))
            }
        }
    }

    #[test]
    fn the_accounts_calls_reach_the_host_whole_and_well_formed() {
        let host = Recording::default();
        let reply = answer(
            &json!({ "id": "r-1", "method": "axo.remote.session.create", "params": { "target": {} } }),
            host.answer(),
        )
        .unwrap();
        assert_eq!(reply["result"], "axo.remote.session.create");
        assert_eq!(
            host.asked(),
            [
                json!({ "jsonrpc": "2.0", "id": "r-1", "method": "axo.remote.session.create", "params": { "target": {} } })
            ]
        );
    }

    #[test]
    fn nothing_but_remote_calls_reaches_the_host() {
        let host = Recording::default();
        for method in ["axo.config.set", "axo.session.create", "axo.remotex", ""] {
            let reply = answer(
                &json!({ "id": 7, "method": method, "params": {} }),
                host.answer(),
            )
            .unwrap();
            assert_eq!(reply["error"]["code"], -32601, "{method}");
            assert_eq!(reply["id"], 7);
        }
        // A notification is not run, remote or not.
        assert!(
            answer(
                &json!({ "method": "axo.remote.session.create" }),
                host.answer()
            )
            .is_none()
        );
        assert!(
            answer(
                &json!({ "id": null, "method": "axo.remote.session.create" }),
                host.answer()
            )
            .is_none()
        );
        assert!(host.asked().is_empty());
    }
}
