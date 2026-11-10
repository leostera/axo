//! Calling axod's own methods from inside axod (RFD0034): the in-process twin of a socket
//! connection, for code such as the MCP server that runs in axod but speaks to it as a client.
//!
//! A call goes through the same handler, parameter parsing and caller checks as a request on the
//! socket: it carries the peer of the connection it acts for, so a method for one kind of caller
//! (`Only`) refuses it exactly as it would refuse that peer. Each call has its own
//! [`Cancellation`]. Firing it is what closing a connection does to its unanswered requests: the
//! handler sees its request cancelled, and the caller stops waiting at once, whether or not the
//! handler has noticed.

use std::sync::Arc;
use std::time::Duration;

use jsonrpc_core::IoHandler;
use serde_json::{Value, json};

use crate::cancel::Cancellation;
use crate::peer::Peer;

/// A client of axod's methods, in axod's own process.
#[derive(Clone)]
pub struct Local {
    handler: Arc<IoHandler>,
    peer: Peer,
}

/// Why a [`Local`] call has no result.
#[derive(Debug, PartialEq)]
pub enum LocalError {
    /// The method answered with an error.
    Refused { code: i64, message: String },
    /// No answer within the call's time.
    TimedOut,
    /// The call was given up.
    Cancelled,
}

impl Local {
    /// Calls `handler`'s methods as `peer`.
    pub fn new(handler: Arc<IoHandler>, peer: Peer) -> Self {
        Self { handler, peer }
    }

    /// The peer calls are made as.
    pub fn peer(&self) -> Peer {
        self.peer
    }

    /// Calls `method` and waits for its answer, at most `timeout`, or until `cancellation`
    /// fires.
    pub async fn call(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
        cancellation: &Cancellation,
    ) -> Result<Value, LocalError> {
        if cancellation.is_cancelled() {
            return Err(LocalError::Cancelled);
        }
        let request = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let request = request.to_string();
        let handler = Arc::clone(&self.handler);
        let handled = crate::cancel::scope(
            cancellation.clone(),
            crate::peer::scope(
                self.peer,
                async move { handler.handle_request(&request).await },
            ),
        );
        let within = tokio::time::timeout(timeout, handled);
        let answer = tokio::select! {
            biased;
            () = cancellation.cancelled() => return Err(LocalError::Cancelled),
            answer = within => answer,
        };
        let response = match answer {
            Ok(Some(response)) => response,
            // A request with an id always has a response; none would be a handler bug.
            Ok(None) => {
                return Err(LocalError::Refused {
                    code: -32603,
                    message: "the method sent no answer".into(),
                });
            }
            Err(_) => return Err(LocalError::TimedOut),
        };
        let mut response: Value =
            serde_json::from_str(&response).map_err(|_| LocalError::Refused {
                code: -32603,
                message: "the method sent a malformed answer".into(),
            })?;
        if let Some(error) = response.get("error") {
            return Err(LocalError::Refused {
                code: error["code"].as_i64().unwrap_or(-32603),
                message: error["message"].as_str().unwrap_or_default().to_owned(),
            });
        }
        Ok(response["result"].take())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::peer::{Caller, Signer};
    use crate::{Only, TypedMethods};
    use std::time::Instant;

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap()
    }

    fn handler() -> IoHandler {
        let mut handler = IoHandler::new();
        handler.add_typed("echo", "expected {said}", |params: Value| async move {
            Ok(params)
        });
        handler.add_typed("wait", "expected no parameters", |_: Value| async {
            let cancellation = crate::cancel::current();
            let _ = tokio::time::timeout(Duration::from_secs(5), cancellation.cancelled()).await;
            Ok(json!({ "cancelled": cancellation.is_cancelled() }))
        });
        handler.add_typed_only(
            Only {
                caller: Caller::Signed(Signer::ThisBinary),
                code: -32003,
                message: "axod only",
            },
            "only",
            "expected no parameters",
            |_: Value| async { Ok(json!("ran")) },
        );
        handler
    }

    #[test]
    fn a_call_reaches_the_method_and_brings_back_its_result_or_error() {
        let runtime = runtime();
        let local = Local::new(Arc::new(handler()), Peer::default());
        let never = Cancellation::default();
        let second = Duration::from_secs(1);
        assert_eq!(
            runtime.block_on(local.call("echo", json!({ "said": "hi" }), second, &never)),
            Ok(json!({ "said": "hi" }))
        );
        assert_eq!(
            runtime.block_on(local.call("nope", json!({}), second, &never)),
            Err(LocalError::Refused {
                code: -32601,
                message: "Method not found".into()
            })
        );
    }

    #[test]
    fn a_call_is_checked_as_the_peer_it_acts_for() {
        let runtime = runtime();
        let local = Local::new(Arc::new(handler()), Peer::default());
        assert_eq!(
            runtime.block_on(local.call(
                "only",
                json!({}),
                Duration::from_secs(1),
                &Cancellation::default()
            )),
            Err(LocalError::Refused {
                code: -32003,
                message: "axod only".into()
            })
        );
    }

    #[test]
    fn giving_up_stops_the_wait_and_tells_the_method() {
        let runtime = runtime();
        let local = Local::new(Arc::new(handler()), Peer::default());
        let cancellation = Cancellation::default();
        let giving_up = {
            let cancellation = cancellation.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(100));
                cancellation.cancel();
            })
        };
        let started = Instant::now();
        assert_eq!(
            runtime.block_on(local.call("wait", json!({}), Duration::from_secs(10), &cancellation)),
            Err(LocalError::Cancelled)
        );
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
        giving_up.join().unwrap();
        assert_eq!(
            runtime.block_on(local.call("echo", json!({}), Duration::from_secs(1), &cancellation)),
            Err(LocalError::Cancelled),
            "nothing more is asked for a call given up"
        );
    }

    #[test]
    fn a_call_waits_no_longer_than_its_time() {
        let runtime = runtime();
        let local = Local::new(Arc::new(handler()), Peer::default());
        let started = Instant::now();
        assert_eq!(
            runtime.block_on(local.call(
                "wait",
                json!({}),
                Duration::from_millis(100),
                &Cancellation::default()
            )),
            Err(LocalError::TimedOut)
        );
        assert!(started.elapsed() < Duration::from_secs(2));
        // The method still waits on the blocking pool; don't wait for it.
        runtime.shutdown_background();
    }
}
