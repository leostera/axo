//! A relay session's context for tests: a host that records what reaches it, and the socket's
//! replies as they would go out.

use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axo_protocol::{Event, HostKind, RelayStatus};
use serde_json::Value;
use tokio::sync::mpsc::UnboundedReceiver;

use super::owned_jobs::OwnedJobs;
use super::session::RelaySessionContext;
use super::status::RelayControl;
use crate::host::{HostFuture, HostIdentity, RelayHost};
use crate::outbound::{Outgoing, RelayChannel};

pub(super) const ACCOUNT: &str = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";

/// Answers every account call after `delay(call)`, and records the calls in the order they
/// reached it.
pub(super) struct RecordingHost {
    identity: HostIdentity,
    delay: fn(&Value) -> Duration,
    pub(super) reached: Mutex<Vec<Value>>,
}

impl RecordingHost {
    pub(super) fn new(delay: fn(&Value) -> Duration) -> Arc<Self> {
        Arc::new(Self {
            identity: HostIdentity {
                host_id: "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe".into(),
                host_generation: "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230".into(),
            },
            delay,
            reached: Mutex::new(Vec::new()),
        })
    }
}

impl RelayHost for RecordingHost {
    fn identity(&self) -> &HostIdentity {
        &self.identity
    }
    fn publish_relay_status(&self, _: &RelayStatus) {}
    fn subscribe_remote_events(&self) -> io::Result<String> {
        Ok("subscription".into())
    }
    fn next_remote_events<'a>(
        &'a self,
        _: &'a str,
        timeout: Duration,
    ) -> HostFuture<'a, io::Result<Vec<Event>>> {
        Box::pin(async move {
            tokio::time::sleep(timeout).await;
            Ok(Vec::new())
        })
    }
    fn unsubscribe_remote_events(&self, _: &str) -> io::Result<()> {
        Ok(())
    }
    fn answer_remote(&self, request: Value) -> HostFuture<'_, Option<Value>> {
        Box::pin(async move {
            tokio::time::sleep((self.delay)(&request)).await;
            self.reached.lock().unwrap().push(request["params"].clone());
            Some(serde_json::json!({ "jsonrpc": "2.0", "id": request["id"], "result": {} }))
        })
    }
}

/// One socket's context over `host`, and what it sends.
pub(super) fn context(
    host: Arc<dyn RelayHost>,
) -> (Arc<RelaySessionContext>, UnboundedReceiver<Outgoing>) {
    let channel = RelayChannel::new();
    let socket = channel.attach();
    let context = RelaySessionContext {
        jobs: Arc::new(OwnedJobs::default()),
        identity: host.identity().clone(),
        prompts: super::prompts::PromptLanes::new(Arc::clone(&host), socket.replies.clone()),
        sessions: host,
        subscription_id: "subscription".into(),
        stop: axo_ipc::Stop::default(),
        control: Arc::new(RelayControl::new("Test Mac".into(), HostKind::MacOS)),
        channel,
        replies: socket.replies,
        waker: crate::sync::SyncWaker::default(),
        socket_id: "axod-test-1".into(),
        account_id: ACCOUNT.into(),
        assets: None,
    };
    (Arc::new(context), socket.outgoing)
}

/// The next message the socket sends, as JSON.
pub(super) async fn sent(outgoing: &mut UnboundedReceiver<Outgoing>) -> Value {
    let message = tokio::time::timeout(Duration::from_secs(10), outgoing.recv())
        .await
        .expect("a message within the test's time")
        .expect("the socket is open");
    serde_json::from_str(&message.text).unwrap()
}
