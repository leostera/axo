//! The account's prompts, delivered in the order they came, one Session at a time (RFD0024:
//! pi-axo queues remote prompts in arrival order).
//!
//! A prompt is answered only once its attachments are fetched and Pi has it in its log (RFD0030,
//! RFD0033), which may take minutes, so it must not hold up the socket or the calls answered in
//! order. Each Session has a lane: a task that delivers that Session's prompts one after the
//! other, so a prompt sent second never overtakes one still fetching its attachments. Sessions'
//! lanes run beside one another. A lane lives as long as its socket: when the socket's context
//! goes, its senders do, and each lane ends after the prompts it already took.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::Value;
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};

use super::forward;
use crate::host::RelayHost;
use crate::outbound::ReplySender;

pub(super) struct PromptLanes {
    sessions: Arc<dyn RelayHost>,
    replies: ReplySender,
    /// Per `sessionId` as the prompt names it; the host refuses one that names no Session.
    lanes: Mutex<HashMap<String, UnboundedSender<Value>>>,
}

impl PromptLanes {
    pub(super) fn new(sessions: Arc<dyn RelayHost>, replies: ReplySender) -> Self {
        Self {
            sessions,
            replies,
            lanes: Mutex::default(),
        }
    }

    /// Queues `request`, a whole `axo.remote.session.prompt`, behind its Session's earlier ones.
    pub(super) fn deliver(&self, request: Value) {
        let session = request["params"]["sessionId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let mut lanes = self.lanes.lock().unwrap_or_else(|p| p.into_inner());
        let lane = lanes.entry(session).or_insert_with(|| self.open_lane());
        // A lane's task ends only when its sender goes, so a send to a live lane is taken.
        let _ = lane.send(request);
    }

    fn open_lane(&self) -> UnboundedSender<Value> {
        let (lane, mut prompts) = unbounded_channel::<Value>();
        let (sessions, replies) = (Arc::clone(&self.sessions), self.replies.clone());
        tokio::spawn(async move {
            while let Some(request) = prompts.recv().await {
                let Some(reply) = forward::answer(&request, sessions.as_ref()).await else {
                    continue;
                };
                match serde_json::to_string(&reply) {
                    Ok(text) => replies.send(text),
                    Err(error) => log::warn!("event=relay.reply_unserializable error={error}"),
                }
            }
        });
        lane
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use serde_json::{Value, json};

    use super::super::test_support::{RecordingHost, context, sent};

    fn prompt(id: u32, session: &str, text: &str) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "axo.remote.session.prompt",
            "params": { "sessionId": session, "text": text },
        })
    }

    /// A prompt with an attachment takes its time reaching Pi.
    fn attachments_take_time(request: &Value) -> Duration {
        match request["params"]["text"].as_str() {
            Some("with a photo") => Duration::from_millis(300),
            _ => Duration::ZERO,
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_sessions_prompts_reach_it_in_the_order_they_came() {
        let host = RecordingHost::new(attachments_take_time);
        let (context, mut outgoing) = context(host.clone());
        context.prompts.deliver(prompt(1, "a", "with a photo"));
        context
            .prompts
            .deliver(prompt(2, "a", "now fix what you see"));
        context
            .prompts
            .deliver(prompt(3, "b", "meanwhile, elsewhere"));
        let answered: Vec<Value> = [
            sent(&mut outgoing).await,
            sent(&mut outgoing).await,
            sent(&mut outgoing).await,
        ]
        .into_iter()
        .map(|reply| reply["id"].clone())
        .collect();
        // Another Session's prompt does not wait behind this one's attachments.
        assert_eq!(answered, [json!(3), json!(1), json!(2)]);
        let reached: Vec<Value> = host
            .reached
            .lock()
            .unwrap()
            .iter()
            .map(|p| p["text"].clone())
            .collect();
        assert_eq!(
            reached,
            [
                json!("meanwhile, elsewhere"),
                json!("with a photo"),
                json!("now fix what you see")
            ]
        );
    }
}
