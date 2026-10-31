//! `axo.connections.*` on `axod.sock` (RFD0016): a Session's connections calls go to its account.
//!
//! Axod does not interpret them. Each call is forwarded unchanged over the relay, where the
//! host's HostDO hands it to the account, and the account's answer, or its error, comes back
//! as is. A call is sent once: if the relay drops or the answer is late, the call fails as
//! may-have-run, because a script may already have run commands or called services.

use std::time::Duration;

use axo_ipc::{ErrorCode, RpcError, TypedMethods};
use axo_protocol::SessionId;
use axo_protocol::rpc::method;
use axo_relay::{Priority, RelayCallError, RelayChannel};
use jsonrpc_core::IoHandler;
use serde_json::{Map, Value};
use std::sync::Arc;

/// Error codes shared with `@axo/protocol`'s `CONNECTIONS_ERRORS`.
pub const OUTCOME_UNKNOWN: i64 = -32004;
pub const LIMIT_EXCEEDED: i64 = -32020;
pub const NOT_CONNECTED: i64 = -32024;

/// A script may run for five minutes; its answer then has this long to arrive.
const SCRIPT_TIMEOUT: Duration = Duration::from_secs(5 * 60 + 30);
const QUICK_TIMEOUT: Duration = Duration::from_secs(30);

/// Every forwarded method and how long axod waits for its answer.
pub const FORWARDED: &[(&str, Duration)] = &[
    (method::CONNECTIONS_LIST, QUICK_TIMEOUT),
    (method::CONNECTIONS_SEARCH, SCRIPT_TIMEOUT),
    (method::CONNECTIONS_EXECUTE, SCRIPT_TIMEOUT),
    (method::CONNECTIONS_LOG, QUICK_TIMEOUT),
    // Adding tries the server and may register a client with it.
    (method::CONNECTIONS_ADD, Duration::from_secs(60)),
    (method::CONNECTIONS_REMOVE, QUICK_TIMEOUT),
];

/// How long a caller of `method` should wait for axod's answer, beyond axod's own wait.
pub fn timeout_for(method: &str) -> Option<Duration> {
    FORWARDED
        .iter()
        .find(|(name, _)| *name == method)
        .map(|(_, timeout)| *timeout + Duration::from_secs(5))
}

/// Registers the forwarded methods. Without a relay worker, each fails as not connected.
pub fn add_methods(handler: &mut IoHandler, channel: Option<Arc<RelayChannel>>) {
    for &(name, timeout) in FORWARDED {
        let channel = channel.clone();
        handler.add_typed(
            name,
            "expected an object with sessionId (a Session ID)",
            move |params: Map<String, Value>| forward(channel.as_deref(), name, params, timeout),
        );
    }
}

fn forward(
    channel: Option<&RelayChannel>,
    name: &'static str,
    params: Map<String, Value>,
    timeout: Duration,
) -> Result<Value, RpcError> {
    let session = params.get("sessionId").and_then(Value::as_str);
    if session.and_then(SessionId::parse).is_none() {
        return Err(RpcError {
            code: ErrorCode::InvalidParams,
            message: "sessionId must name a Session (a UUID)".into(),
            data: None,
        });
    }
    let Some(channel) = channel else {
        return Err(not_connected());
    };
    let started = std::time::Instant::now();
    let outcome = channel.request(name, Value::Object(params), Priority::Control, timeout);
    log::info!(
        "event=connections.forwarded method={name} outcome={} duration_ms={}",
        match &outcome {
            Ok(_) => "result".to_owned(),
            Err(RelayCallError::Rejected { code, .. }) => code.to_string(),
            Err(error) => format!("{error:?}"),
        },
        started.elapsed().as_millis()
    );
    outcome.map_err(|error| match error {
        RelayCallError::NotConnected => not_connected(),
        RelayCallError::Rejected { code, message } => server_error(code, message),
        RelayCallError::TooLarge => server_error(
            LIMIT_EXCEEDED,
            "the request is larger than the relay carries".into(),
        ),
        RelayCallError::Disconnected => server_error(
            OUTCOME_UNKNOWN,
            "the connection to Axo's cloud dropped; the call may have run".into(),
        ),
        RelayCallError::TimedOut => server_error(
            OUTCOME_UNKNOWN,
            "Axo's cloud did not answer in time; the call may have run".into(),
        ),
    })
}

fn not_connected() -> RpcError {
    server_error(
        NOT_CONNECTED,
        "this Mac is not connected to its Axo account; link it under Settings > Remote Access, or check that it is online".into(),
    )
}

fn server_error(code: i64, message: String) -> RpcError {
    RpcError {
        code: ErrorCode::ServerError(code),
        message,
        data: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn handler(channel: Option<Arc<RelayChannel>>) -> IoHandler {
        let mut handler = IoHandler::new();
        add_methods(&mut handler, channel);
        handler
    }

    fn call(handler: &IoHandler, method: &str, params: Value) -> Value {
        let request = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        serde_json::from_str(&handler.handle_request_sync(&request.to_string()).unwrap()).unwrap()
    }

    #[test]
    fn every_forwarded_method_is_advertised() {
        for (name, _) in FORWARDED {
            assert!(method::ADVERTISED.contains(name), "{name}");
        }
    }

    #[test]
    fn a_call_needs_a_session_and_fails_as_not_connected_without_a_relay() {
        let unlinked = handler(None);
        let missing = call(&unlinked, method::CONNECTIONS_LIST, json!({}));
        assert_eq!(missing["error"]["code"], -32602);
        let session = "0b8f4e2a-7c1d-4e6b-9a3f-5d2c8e1b7a49";
        let offline = call(
            &unlinked,
            method::CONNECTIONS_LIST,
            json!({ "sessionId": session }),
        );
        assert_eq!(offline["error"]["code"], NOT_CONNECTED);

        // A relay worker with no socket open sends nothing and says so.
        let idle = handler(Some(RelayChannel::new()));
        let refused = call(
            &idle,
            method::CONNECTIONS_EXECUTE,
            json!({ "sessionId": session, "code": "async () => 1" }),
        );
        assert_eq!(refused["error"]["code"], NOT_CONNECTED);
    }
}
