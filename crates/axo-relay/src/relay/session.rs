//! One connected relay session: negotiating, registering the host, then answering the relay's
//! requests and forwarding local events until the socket closes.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axo_protocol::Event;
use serde::Serialize;
use serde_json::Value;
use tungstenite::Message;

use super::HEARTBEAT_INTERVAL;
use super::dispatch::remote_request_reply;
use super::elicitation::{
    ELICITATION_REQUESTED, ELICITATION_RESOLVE, ELICITATION_RESOLVED, resolve_elicitation,
};
use super::jobs::{start_bash, start_computer, start_prompt_with_attachments, start_sign_in};
use super::socket::{RelaySocket, read_message, send_json};
use super::status::RelayControl;
use super::wire::{HostIdentity, IncomingMessage, JSONRPC, OutgoingRequest, RequestId};
use crate::fragments::Reassembler;
use crate::host::RelayHost;
use crate::outbound::{FRAMES_PER_TURN, Outbox, Priority, RelayChannel, ReplySender};
use crate::sync::SyncWaker;

// The handshake answers the relay's own requests while it waits, so it needs the host too.
#[allow(clippy::too_many_arguments)]
pub(super) fn rpc_call(
    socket: &mut RelaySocket,
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
    send_json(
        socket,
        &OutgoingRequest {
            jsonrpc: JSONRPC,
            id: &id,
            method,
            params,
        },
    )?;
    loop {
        let Some(raw) = read_message(socket, reassembler)? else {
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
        if let Some(reply) = remote_request_reply(&response, sessions, host_id, host_generation) {
            send_json(socket, &reply)?;
        }
    }
}

pub(super) struct RelaySessionContext<'a> {
    pub(super) sessions: &'a Arc<dyn RelayHost>,
    pub(super) host_id: &'a str,
    pub(super) host_generation: &'a str,
    pub(super) subscription_id: &'a str,
    pub(super) stop: &'a AtomicBool,
    pub(super) control: &'a RelayControl,
    pub(super) channel: &'a RelayChannel,
    /// What other threads queued for this socket.
    pub(super) outgoing: std::sync::mpsc::Receiver<crate::outbound::Outgoing>,
    /// Replies to the cloud's requests on this socket, from threads that answer them later.
    pub(super) replies: ReplySender,
    /// Tells the uploader a Session changed, so its new lines go up at once.
    pub(super) waker: &'a SyncWaker,
    pub(super) socket_id: String,
    /// The account this Mac is linked to; a command for any other is refused.
    pub(super) account_id: String,
    /// Where a prompt's attachments come from (RFD0030).
    pub(super) assets: Option<crate::assets::AssetSource>,
}

pub(super) fn relay_session(
    socket: &mut RelaySocket,
    reassembler: &mut Reassembler,
    request_number: &mut u64,
    context: RelaySessionContext<'_>,
) -> io::Result<()> {
    let mut next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
    let mut outbox = Outbox::default();
    while !context.stop.load(Ordering::Relaxed)
        && !context.control.reconnect_requested.load(Ordering::Relaxed)
    {
        // What other threads queued goes out by priority, a few frames a turn.
        while let Ok(queued) = context.outgoing.try_recv() {
            if !outbox.push(queued, &context.socket_id) {
                log::warn!("event=relay.outbound_refused reason=too_large_or_full");
            }
        }
        for _ in 0..FRAMES_PER_TURN {
            let Some(frame) = outbox.next_frame() else {
                break;
            };
            socket
                .send(Message::Text(frame.into()))
                .map_err(io::Error::other)?;
        }
        reassembler.expire(Instant::now());

        if Instant::now() >= next_heartbeat {
            *request_number = request_number.saturating_add(1);
            send_json(
                socket,
                &OutgoingRequest {
                    jsonrpc: JSONRPC,
                    id: &format!("axod-{}", *request_number),
                    method: "axo.host.heartbeat",
                    params: HostIdentity {
                        host_id: context.host_id,
                        host_generation: context.host_generation,
                    },
                },
            )?;
            next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
        }

        if let Some(event) = context
            .sessions
            .next_remote_event(context.subscription_id, Duration::ZERO)?
        {
            forward_event(event, &context);
        }

        let Some(raw) = read_message(socket, reassembler)? else {
            continue;
        };
        let value: Value = serde_json::from_str(&raw)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
        // A reply to a request another thread sent.
        if value.get("method").is_none() && context.channel.resolve(&value) {
            continue;
        }
        if value.get("method").and_then(Value::as_str) == Some(crate::computer::METHOD) {
            if let Some(id) = value.get("id").filter(|id| !id.is_null()) {
                start_computer(id.clone(), &value["params"], &context);
            }
            continue;
        }
        if value.get("method").and_then(Value::as_str) == Some(crate::computer::STATUS_METHOD) {
            if let Some(id) = value.get("id").filter(|id| !id.is_null()) {
                let outcome = crate::computer::parse_status(&value["params"], &context.account_id)
                    .map(|()| context.sessions.computer_status());
                context.replies.reply(id, outcome);
            }
            continue;
        }
        if value.get("method").and_then(Value::as_str) == Some(crate::bash::METHOD) {
            if let Some(id) = value.get("id").filter(|id| !id.is_null()) {
                start_bash(id.clone(), &value["params"], &context);
            }
            continue;
        }
        if value.get("method").and_then(Value::as_str) == Some(ELICITATION_RESOLVE) {
            if let Some(id) = value.get("id").filter(|id| !id.is_null()) {
                let outcome = resolve_elicitation(&value["params"], &context);
                send_json(
                    socket,
                    &match outcome {
                        Ok(()) => {
                            serde_json::json!({ "jsonrpc": JSONRPC, "id": id, "result": { "resolved": true } })
                        }
                        Err((code, message)) => {
                            serde_json::json!({ "jsonrpc": JSONRPC, "id": id, "error": { "code": code, "message": message } })
                        }
                    },
                )?;
            }
            continue;
        }
        if value.get("method").and_then(Value::as_str) == Some(crate::signin::METHOD) {
            if let Some(id) = value.get("id").filter(|id| !id.is_null()) {
                start_sign_in(id.clone(), &value["params"], &context);
            }
            continue;
        }
        // A prompt with attachments waits for them on a thread of its own (RFD0030).
        if value.get("method").and_then(Value::as_str) == Some("axo.remote.session.prompt")
            && value["params"]
                .get("attachments")
                .and_then(Value::as_array)
                .is_some_and(|attachments| !attachments.is_empty())
        {
            if let Some(id) = value.get("id").filter(|id| !id.is_null()) {
                start_prompt_with_attachments(id.clone(), &value["params"], &context);
            }
            continue;
        }
        let message: IncomingMessage = serde_json::from_value(value)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
        if let Some(reply) = remote_request_reply(
            &message,
            context.sessions,
            context.host_id,
            context.host_generation,
        ) {
            send_json(socket, &reply)?;
        }
    }
    let _ = socket.close(None);
    Ok(())
}

/// What a local event means for the cloud (RFD0018). Durable records come from the Pi file, so
/// an event only wakes the uploader; Pi's progress (`message.update`, `tool.update`, already
/// throttled by pi-axo) goes up as an ephemeral snapshot, the newest replacing the last. Terminal
/// output and everything else stays on the Mac.
fn forward_event(event: Event, context: &RelaySessionContext<'_>) {
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
        | Event::SessionFocus { .. }
        | Event::WorkspaceChanged { .. }
        | Event::RelayStatus { .. }
        | Event::PeerSessionsChanged
        | Event::DeviceRequested { .. }
        | Event::DevicesChanged => {}
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
