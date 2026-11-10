//! The apps extension: `axo.apps.*` on `axod.sock` (RFD0016), a Session's apps calls going to
//! its account.
//!
//! Axod does not interpret them. Each call is forwarded unchanged over the relay, where the
//! host's HostDO hands it to the account, and the account's answer, or its error, comes back
//! as is. A call is sent once: if the relay drops or the answer is late, the call fails as
//! may-have-run, because a script may already have run commands or called services.

use std::time::Duration;

use axo_ipc::{ErrorCode, Extension, RpcError, TypedMethods};
use axo_protocol::SessionId;
use axo_protocol::rpc::forwarded;
use axo_relay::{Priority, RelayCallError, RelayChannel};
use jsonrpc_core::IoHandler;
use serde_json::{Map, Value};
use std::sync::Arc;

/// Error codes shared with `@axo/protocol`'s `APPS_ERRORS`.
pub const OUTCOME_UNKNOWN: i64 = -32004;
pub const LIMIT_EXCEEDED: i64 = -32020;
pub const NOT_CONNECTED: i64 = -32024;

/// The forwarded methods, through the relay's channel to the account. Without a relay worker,
/// each fails as not connected.
pub struct Apps {
    channel: Option<Arc<RelayChannel>>,
}

impl Apps {
    pub fn new(channel: Option<Arc<RelayChannel>>) -> Self {
        Self { channel }
    }
}

impl Extension for Apps {
    fn name(&self) -> &'static str {
        "apps"
    }

    fn register(&self, methods: &mut IoHandler) {
        for &(name, timeout) in forwarded::METHODS {
            let channel = self.channel.clone();
            methods.add_typed_async(
                name,
                "expected an object with sessionId (a Session ID)",
                move |params: Map<String, Value>| {
                    let channel = channel.clone();
                    async move { forward(channel.as_deref(), name, params, timeout).await }
                },
            );
        }
    }
}

async fn forward(
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
    // A caller that gives up (an agent that left) stops the wait; the cloud's call runs on.
    let cancellation = axo_ipc::cancel::current();
    let outcome = tokio::select! {
        result = channel.request(name, Value::Object(params), Priority::Control, timeout) => result,
        _ = cancellation.cancelled() => Err(RelayCallError::Abandoned),
    };
    log::info!(
        "event=apps.forwarded method={name} outcome={} duration_ms={}",
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
        RelayCallError::Abandoned => server_error(
            OUTCOME_UNKNOWN,
            "the caller stopped waiting; the call may have run".into(),
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
    use axo_protocol::rpc::method;
    use serde_json::json;

    fn handler(channel: Option<Arc<RelayChannel>>) -> IoHandler {
        let mut handler = IoHandler::new();
        Apps::new(channel).register(&mut handler);
        handler
    }

    fn call(handler: &IoHandler, method: &str, params: Value) -> Value {
        let request = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        serde_json::from_str(&handler.handle_request_sync(&request.to_string()).unwrap()).unwrap()
    }

    #[test]
    fn every_forwarded_method_is_advertised() {
        for (name, _) in forwarded::METHODS {
            assert!(method::ADVERTISED.contains(name), "{name}");
        }
    }

    #[test]
    fn a_call_needs_a_session_and_fails_as_not_connected_without_a_relay() {
        let unlinked = handler(None);
        let missing = call(&unlinked, method::APPS_LIST, json!({}));
        assert_eq!(missing["error"]["code"], -32602);
        let session = "0b8f4e2a-7c1d-4e6b-9a3f-5d2c8e1b7a49";
        let offline = call(
            &unlinked,
            method::APPS_LIST,
            json!({ "sessionId": session }),
        );
        assert_eq!(offline["error"]["code"], NOT_CONNECTED);

        // A relay worker with no socket open sends nothing and says so.
        let idle = handler(Some(RelayChannel::new()));
        let refused = call(
            &idle,
            method::APPS_RUN,
            json!({ "sessionId": session, "code": "async () => 1" }),
        );
        assert_eq!(refused["error"]["code"], NOT_CONNECTED);
    }
}
