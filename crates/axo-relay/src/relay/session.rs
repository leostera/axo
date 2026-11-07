//! One connected relay session: negotiating, registering the host, then answering the relay's
//! requests and forwarding local events until the socket closes.

use std::io;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axo_ipc::Stop;
use axo_protocol::Event;
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use serde_json::Value;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::time::MissedTickBehavior;
use tungstenite::Message;

use super::HEARTBEAT_INTERVAL;
use super::dispatch::remote_request_reply;
use super::elicitation::{
    ELICITATION_REQUESTED, ELICITATION_RESOLVE, ELICITATION_RESOLVED, resolve_elicitation,
};
use super::jobs::{start_bash, start_computer, start_prompt, start_sign_in};
use super::socket::{RelaySink, RelayStream, receive, send_json_async};
use super::status::RelayControl;
use super::wire::{HostIdentity, IncomingMessage, JSONRPC, OutgoingRequest, RequestId};
use crate::fragments::Reassembler;
use crate::host::RelayHost;
use crate::outbound::{FRAMES_PER_TURN, Outbox, Outgoing, Priority, RelayChannel, ReplySender};
use crate::sync::SyncWaker;

/// How long the relay has to answer a handshake request.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
/// How often half-received messages are checked for expiry.
const REASSEMBLY_CHECK: Duration = Duration::from_secs(1);
/// How long one wait for local events lasts; well inside the subscription's idle expiry.
const EVENT_WAIT: Duration = Duration::from_secs(30);

// The handshake answers the relay's own requests while it waits, so it needs the host too.
#[allow(clippy::too_many_arguments)]
pub(super) async fn rpc_call(
    sink: &mut RelaySink,
    stream: &mut RelayStream,
    reassembler: &mut Reassembler,
    request_number: &mut u64,
    method: &str,
    params: impl Serialize,
    sessions: &Arc<dyn RelayHost>,
    host_id: &str,
    host_generation: &str,
) -> io::Result<()> {
    *request_number = request_number.saturating_add(1);
    let id = format!("axod-{}", *request_number);
    send_json_async(
        sink,
        &OutgoingRequest {
            jsonrpc: JSONRPC,
            id: &id,
            method,
            params,
        },
    )
    .await?;
    let answered = async {
        loop {
            let message = stream.next().await;
            let Some(raw) = receive(sink, message, reassembler).await? else {
                continue;
            };
            let response: IncomingMessage = serde_json::from_str(&raw)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
            if response.method.is_none() && response.id == Some(RequestId::Text(id.clone())) {
                return response
                    .result
                    .map(drop)
                    .ok_or_else(|| io::Error::other("relay RPC request was rejected"));
            }
            let (sessions, host_id, host_generation) = (
                Arc::clone(sessions),
                host_id.to_owned(),
                host_generation.to_owned(),
            );
            let reply = tokio::task::spawn_blocking(move || {
                remote_request_reply(&response, &sessions, &host_id, &host_generation)
            })
            .await
            .map_err(io::Error::other)?;
            if let Some(reply) = reply {
                send_json_async(sink, &reply).await?;
            }
        }
    };
    tokio::time::timeout(HANDSHAKE_TIMEOUT, answered)
        .await
        .map_err(|_| {
            io::Error::new(
                io::ErrorKind::TimedOut,
                format!("relay did not answer {method}"),
            )
        })?
}

/// What one connected socket's loop, its answers and its jobs share.
pub(super) struct RelaySessionContext {
    pub(super) sessions: Arc<dyn RelayHost>,
    pub(super) host_id: String,
    pub(super) host_generation: String,
    pub(super) subscription_id: String,
    pub(super) stop: Stop,
    pub(super) control: Arc<RelayControl>,
    pub(super) channel: Arc<RelayChannel>,
    /// Replies to the cloud's requests on this socket, from threads that answer them later.
    pub(super) replies: ReplySender,
    /// Tells the uploader a Session changed, so its new lines go up at once.
    pub(super) waker: SyncWaker,
    pub(super) socket_id: String,
    /// The account this Mac is linked to; a command for any other is refused.
    pub(super) account_id: String,
    /// Where a prompt's attachments come from (RFD0030).
    pub(super) assets: Option<crate::assets::AssetSource>,
}

/// A request from the cloud that the host answers at once, in the order they came.
pub(super) enum HostRequest {
    ComputerStatus { id: Value, params: Value },
    ResolveElicitation { id: Value, params: Value },
    Call(IncomingMessage),
}

/// Serves one connected socket until it closes, axod stops, or a reconnect is asked for.
///
/// The loop waits on everything at once: the cloud's messages, local events, what threads queued
/// to send (`outgoing`), the heartbeat, stopping and the control's wake-up. Requests the host
/// answers at once go to `requests`, answered in order on the blocking pool; slower ones (bash,
/// computer use, prompts, sign-ins) start their jobs. Neither holds up the socket.
pub(super) async fn relay_session(
    sink: &mut RelaySink,
    stream: &mut RelayStream,
    reassembler: &mut Reassembler,
    request_number: &mut u64,
    context: &RelaySessionContext,
    mut outgoing: UnboundedReceiver<Outgoing>,
    requests: UnboundedSender<HostRequest>,
) -> io::Result<()> {
    let start = tokio::time::Instant::now();
    let mut heartbeat = tokio::time::interval_at(start + HEARTBEAT_INTERVAL, HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut expiry = tokio::time::interval_at(start + REASSEMBLY_CHECK, REASSEMBLY_CHECK);
    let mut outbox = Outbox::default();
    let queue = |outbox: &mut Outbox, queued: Outgoing| {
        if !outbox.push(queued, &context.socket_id) {
            log::warn!("event=relay.outbound_refused reason=too_large_or_full");
        }
    };
    while !context.stop.is_stopped() && !context.control.reconnect_requested.load(Ordering::Relaxed)
    {
        tokio::select! {
            () = context.stop.stopped() => {}
            () = context.control.woken() => {}
            events = context.sessions.next_remote_events(&context.subscription_id, EVENT_WAIT) => {
                for event in events? {
                    forward_event(event, context);
                }
            }
            queued = outgoing.recv() => {
                let Some(queued) = queued else { break };
                queue(&mut outbox, queued);
                while let Ok(queued) = outgoing.try_recv() {
                    queue(&mut outbox, queued);
                }
            }
            // What threads queued goes out by priority, a few frames a turn, so a reply can
            // overtake an upload between its fragments.
            () = std::future::ready(()), if !outbox.is_empty() => {
                for _ in 0..FRAMES_PER_TURN {
                    while let Ok(queued) = outgoing.try_recv() {
                        queue(&mut outbox, queued);
                    }
                    let Some(frame) = outbox.next_frame() else {
                        break;
                    };
                    sink.send(Message::Text(frame.into()))
                        .await
                        .map_err(io::Error::other)?;
                }
            }
            _ = heartbeat.tick() => {
                *request_number = request_number.saturating_add(1);
                send_json_async(
                    sink,
                    &OutgoingRequest {
                        jsonrpc: JSONRPC,
                        id: &format!("axod-{}", *request_number),
                        method: "axo.host.heartbeat",
                        params: HostIdentity {
                            host_id: &context.host_id,
                            host_generation: &context.host_generation,
                        },
                    },
                )
                .await?;
            }
            _ = expiry.tick() => reassembler.expire(Instant::now()),
            message = stream.next() => {
                if let Some(raw) = receive(sink, message, reassembler).await? {
                    take_message(&raw, context, &requests)?;
                }
            }
        }
    }
    let _ = sink.close().await;
    Ok(())
}

/// One whole message from the cloud: a reply to a thread's request, a job to start, or a request
/// for the host to answer.
fn take_message(
    raw: &str,
    context: &RelaySessionContext,
    requests: &UnboundedSender<HostRequest>,
) -> io::Result<()> {
    let value: Value = serde_json::from_str(raw)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
    // A reply to a request another thread sent.
    if value.get("method").is_none() && context.channel.resolve(&value) {
        return Ok(());
    }
    let method = value.get("method").and_then(Value::as_str);
    let id = value.get("id").filter(|id| !id.is_null()).cloned();
    let params = &value["params"];
    let request = match method {
        Some(crate::computer::METHOD) => {
            if let Some(id) = id {
                start_computer(id, params, context);
            }
            return Ok(());
        }
        Some(crate::bash::METHOD) => {
            if let Some(id) = id {
                start_bash(id, params, context);
            }
            return Ok(());
        }
        Some(crate::signin::METHOD) => {
            if let Some(id) = id {
                start_sign_in(id, params, context);
            }
            return Ok(());
        }
        // A prompt is answered once Pi has it in its log, after its attachments are fetched
        // (RFD0030) and Pi has started (RFD0033): on a thread of its own.
        Some("axo.remote.session.prompt") => {
            if let Some(id) = id {
                start_prompt(id, params, context);
            }
            return Ok(());
        }
        Some(crate::computer::STATUS_METHOD) => match id {
            Some(id) => HostRequest::ComputerStatus {
                id,
                params: params.clone(),
            },
            None => return Ok(()),
        },
        Some(ELICITATION_RESOLVE) => match id {
            Some(id) => HostRequest::ResolveElicitation {
                id,
                params: params.clone(),
            },
            None => return Ok(()),
        },
        _ => HostRequest::Call(
            serde_json::from_value(value)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?,
        ),
    };
    let _ = requests.send(request);
    Ok(())
}

/// Answers the host's requests in the order they came, each on the blocking pool, until the
/// socket's loop ends.
pub(super) async fn answer_requests(
    mut requests: UnboundedReceiver<HostRequest>,
    context: Arc<RelaySessionContext>,
) {
    while let Some(request) = requests.recv().await {
        let context = Arc::clone(&context);
        let _ = tokio::task::spawn_blocking(move || answer(request, &context)).await;
    }
}

fn answer(request: HostRequest, context: &RelaySessionContext) {
    match request {
        HostRequest::ComputerStatus { id, params } => {
            let outcome = crate::computer::parse_status(&params, &context.account_id)
                .map(|()| context.sessions.computer_status());
            context.replies.reply(&id, outcome);
        }
        HostRequest::ResolveElicitation { id, params } => {
            let outcome = resolve_elicitation(&params, context)
                .map(|()| serde_json::json!({ "resolved": true }));
            context.replies.reply(&id, outcome);
        }
        HostRequest::Call(message) => {
            if let Some(reply) = remote_request_reply(
                &message,
                &context.sessions,
                &context.host_id,
                &context.host_generation,
            ) {
                match serde_json::to_string(&reply) {
                    Ok(text) => context.replies.send(text),
                    Err(error) => log::warn!("event=relay.reply_unserializable error={error}"),
                }
            }
        }
    }
}

/// What a local event means for the cloud (RFD0018). Durable records come from the Pi file, so
/// an event only wakes the uploader; Pi's progress (`message.update`, `tool.update`, already
/// throttled by pi-axo) goes up as an ephemeral snapshot, the newest replacing the last. Terminal
/// output and everything else stays on the Mac.
fn forward_event(event: Event, context: &RelaySessionContext) {
    match event {
        Event::PiEvent {
            session_id,
            name,
            data,
            ..
        } => {
            // Streaming updates only show progress; anything else may have written a line.
            if !matches!(name.as_str(), "message.update" | "tool.update") {
                context.waker.wake();
            }
            if let Some((slot, snapshot)) = progress_snapshot(&name, data) {
                let _ = context.channel.notify(
                    "axo.host.session.progress",
                    serde_json::json!({
                        "sessionId": session_id,
                        "slot": slot,
                        "snapshot": snapshot,
                        "at": unix_timestamp_millis() / 1000,
                    }),
                    Priority::Ephemeral,
                );
            }
        }
        Event::ElicitationRequested { elicitation } => {
            let _ = context.channel.notify(
                ELICITATION_REQUESTED,
                serde_json::to_value(&elicitation).expect("an elicitation serializes"),
                Priority::Control,
            );
        }
        Event::ElicitationResolved {
            id,
            session_id,
            action,
        } => {
            let _ = context.channel.notify(
                ELICITATION_RESOLVED,
                serde_json::json!({ "id": id, "sessionId": session_id, "action": action }),
                Priority::Control,
            );
        }
        Event::SessionSnapshot { .. }
        | Event::SessionRemoved { .. }
        | Event::SubscriptionLagged => {
            context.waker.wake();
        }
        Event::ShellActivity { .. }
        | Event::TerminalOutput { .. }
        | Event::DaemonReady
        | Event::SessionFocus { .. }
        | Event::WorkspaceChanged { .. }
        | Event::RelayStatus { .. }
        | Event::PeerSessionsChanged => {}
    }
}

/// The progress slot and snapshot of a Pi event, if it is progress: `"message"` for the reply
/// being written, the tool call's id for a running tool, and `"question"` while Pi asks the
/// person something. A null snapshot clears the slot: the end of a turn clears the reply even
/// when no line recorded it (an aborted reply), and the end of a question clears the question.
fn progress_snapshot(name: &str, data: Value) -> Option<(String, Value)> {
    match name {
        "message.update" => Some(("message".to_owned(), data)),
        "agent.end" | "agent.settled" => Some(("message".to_owned(), Value::Null)),
        "ui.prompt.start" => Some(("question".to_owned(), data)),
        "ui.prompt.end" => Some(("question".to_owned(), Value::Null)),
        "tool.update" => {
            let slot = data
                .get("toolCallId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty() && id.len() <= 128)?
                .to_owned();
            Some((slot, data))
        }
        _ => None,
    }
}

pub(super) fn unix_timestamp_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

pub(super) fn current_timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = now.as_secs() as libc::time_t;
    let mut broken_down = std::mem::MaybeUninit::<libc::tm>::zeroed();
    // SAFETY: gmtime_r initializes the provided tm on success; seconds is a valid timestamp.
    if unsafe { libc::gmtime_r(&seconds, broken_down.as_mut_ptr()) }.is_null() {
        return "1970-01-01T00:00:00Z".to_owned();
    }
    // SAFETY: gmtime_r returned a non-null pointer and initialized broken_down.
    let tm = unsafe { broken_down.assume_init() };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        now.subsec_millis(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn pi_progress_goes_up_as_a_snapshot_per_slot_and_other_events_do_not() {
        let message = json!({ "type": "message_update", "message": { "role": "assistant" } });
        assert_eq!(
            progress_snapshot("message.update", message.clone()),
            Some(("message".to_owned(), message))
        );
        let tool = json!({ "toolCallId": "call_1", "partialResult": "a" });
        assert_eq!(
            progress_snapshot("tool.update", tool.clone()),
            Some(("call_1".to_owned(), tool))
        );
        assert_eq!(progress_snapshot("tool.update", json!({})), None);
        assert_eq!(progress_snapshot("message.end", json!({})), None);
        assert_eq!(
            progress_snapshot("ui.prompt.start", json!({"kind": "confirm"})),
            Some(("question".to_owned(), json!({"kind": "confirm"})))
        );
        assert_eq!(
            progress_snapshot("ui.prompt.end", json!({})),
            Some(("question".to_owned(), Value::Null))
        );
        assert_eq!(
            progress_snapshot("agent.end", json!({})),
            Some(("message".to_owned(), Value::Null))
        );
    }
}
