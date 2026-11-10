//! Axod's link to one running Pi over its bridge socket (RFD0041): a future that connects,
//! authenticates, follows Pi's records and sends commands, reconnecting while Pi restarts its
//! listener. It runs inside the Session's task for as long as that Pi is the Session's; the
//! Session drops it when the Pi goes.
//!
//! Pi's bridge serves one axod connection at a time, so commands are written on this one; a
//! command sent while the bridge is not bound is refused at once.

use std::collections::HashMap;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axo_protocol::commands::{CommandId, StopTarget};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::{Notify, mpsc, oneshot};

use crate::pi::BridgeSocketPath;
use crate::pi::connection::{Connection, ExpectedPane, Rejection, Step};
use crate::pi::protocol::{
    Action, CommandResult, ModelChoice, Outgoing, ProtocolVersion, QueuedDelivery, parse_record,
};

/// The largest record either side may send.
pub const MAX_RECORD_BYTES: usize = 8 * 1024 * 1024;
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// Waits between tries while Pi has no listener, doubling up to the last. A change in the bridge
/// sockets' directory (`wake`) tries again at once; these only bound a change nothing reported.
const RETRY_FIRST: Duration = Duration::from_millis(50);
const RETRY_LAST: Duration = Duration::from_secs(1);
/// Commands waiting to be written; more wait for room.
const QUEUED_COMMANDS: usize = 32;

/// Everything needed to reach and verify one running Pi.
#[derive(Clone, Debug)]
pub struct LinkConfig {
    pub session_uuid: String,
    pub pane_id: String,
    pub initial_pwd: PathBuf,
    pub session_file: PathBuf,
    pub bridge_socket: BridgeSocketPath,
    pub bridge_token: String,
    pub process_id: u32,
    /// Prefix for log lines, e.g. `session_id=… shell_id=2`.
    pub log_context: String,
}

/// What the link tells the Session, in the order it happens.
#[derive(Debug, PartialEq)]
pub enum LinkEvent {
    /// The connection proved it serves the pane; `pi_session_id` is Pi's own transcript id.
    Bound { pi_session_id: String },
    /// A bound connection ended; the link tries again.
    Disconnected,
    /// Pi's `/resume` picked a saved Session (`None` when the request was malformed).
    ResumeRequested { target_session_file: Option<String> },
    /// One Pi event, in stream order.
    Event {
        pi_session_id: String,
        stream_id: String,
        sequence: u64,
        name: String,
        data: Value,
    },
}

/// An [`Action`] that owns its strings, to cross to the link.
#[derive(Debug)]
enum OwnedAction {
    Send {
        text: String,
        delivery: Option<QueuedDelivery>,
        command_id: Option<CommandId>,
        attachments: Vec<axo_protocol::asset::FetchedAttachment>,
    },
    Stop(StopTarget),
    Shutdown,
    SetModel {
        model: Option<(String, String)>,
        thinking_level: Option<String>,
    },
}

impl OwnedAction {
    fn borrowed(&self) -> Action<'_> {
        match self {
            Self::Send {
                text,
                delivery,
                command_id,
                attachments,
            } => Action::Send {
                text,
                delivery: *delivery,
                command_id: command_id.as_ref(),
                attachments,
            },
            Self::Stop(stop) => Action::Stop(stop),
            Self::Shutdown => Action::Shutdown,
            Self::SetModel {
                model,
                thinking_level,
            } => Action::SetModel {
                model: model
                    .as_ref()
                    .map(|(provider, id)| ModelChoice { provider, id }),
                thinking_level: thinking_level.as_deref(),
            },
        }
    }
}

#[derive(Debug)]
struct Request {
    action: OwnedAction,
    reply: oneshot::Sender<io::Result<CommandResult>>,
}

/// Sends commands to the Pi a link follows. Cheap to clone; every clone reaches the same Pi.
#[derive(Clone, Debug)]
pub struct LinkCommands(mpsc::Sender<Request>);

/// The link's end of [`LinkCommands`].
#[derive(Debug)]
pub struct LinkRequests(mpsc::Receiver<Request>);

pub fn command_channel() -> (LinkCommands, LinkRequests) {
    let (sender, receiver) = mpsc::channel(QUEUED_COMMANDS);
    (LinkCommands(sender), LinkRequests(receiver))
}

impl LinkCommands {
    /// Submits `text` as a user message and waits for Pi's answer, for at most `timeout`.
    pub async fn send_message(
        &self,
        text: &str,
        delivery: Option<QueuedDelivery>,
        command_id: Option<&CommandId>,
        attachments: &[axo_protocol::asset::FetchedAttachment],
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        self.command(
            OwnedAction::Send {
                text: text.to_owned(),
                delivery,
                command_id: command_id.cloned(),
                attachments: attachments.to_vec(),
            },
            timeout,
        )
        .await
    }

    /// Stops the running run if anything in `stop` belongs to it; see [`Action::Stop`].
    pub async fn stop_turn(
        &self,
        stop: StopTarget,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        self.command(OwnedAction::Stop(stop), timeout).await
    }

    /// Asks Pi to exit now, stopping any turn in progress; see [`Action::Shutdown`].
    pub async fn shutdown(&self, timeout: Duration) -> io::Result<CommandResult> {
        self.command(OwnedAction::Shutdown, timeout).await
    }

    /// Switches the model (`provider`, `id`), the thinking level, or both.
    pub async fn set_model(
        &self,
        model: Option<(&str, &str)>,
        thinking_level: Option<&str>,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        self.command(
            OwnedAction::SetModel {
                model: model.map(|(provider, id)| (provider.to_owned(), id.to_owned())),
                thinking_level: thinking_level.map(str::to_owned),
            },
            timeout,
        )
        .await
    }

    async fn command(&self, action: OwnedAction, timeout: Duration) -> io::Result<CommandResult> {
        let (reply, answer) = oneshot::channel();
        let asked = async {
            self.0
                .send(Request { action, reply })
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::NotConnected, "Pi's link has ended"))?;
            answer.await.unwrap_or_else(|_| {
                Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "Pi's bridge closed before answering",
                ))
            })
        };
        tokio::time::timeout(timeout, asked)
            .await
            .unwrap_or_else(|_| {
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Pi did not answer the command in time",
                ))
            })
    }
}

fn not_bound() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "Pi's bridge is not connected")
}

impl LinkRequests {
    /// Refuses every command waiting now: there is no bound connection to send it on.
    fn refuse_waiting(&mut self) {
        while let Ok(Request { reply, .. }) = self.0.try_recv() {
            let _ = reply.send(Err(not_bound()));
        }
    }
}

/// Why one connection ended.
enum Outcome {
    /// The stream ended; connect again.
    Closed,
    /// The connection broke the protocol, or the Session refused what it said: never trust
    /// this Pi again.
    Invalid,
}

/// Follows Pi until it breaks the protocol or `report` refuses an event; meanwhile reconnects
/// whenever the connection ends. Dropping the future ends the link. `wake` is notified when
/// something in the bridge sockets' directory changes, such as Pi creating its socket.
pub async fn run(
    config: LinkConfig,
    mut requests: LinkRequests,
    wake: Arc<Notify>,
    mut report: impl FnMut(LinkEvent) -> bool + Send,
) {
    let context = config.log_context.clone();
    let mut retry = RETRY_FIRST;
    let mut has_connected = false;
    loop {
        requests.refuse_waiting();
        let woken = wake.notified();
        tokio::pin!(woken);
        woken.as_mut().enable();
        let stream = match UnixStream::connect(config.bridge_socket.as_path()).await {
            Ok(stream) => stream,
            Err(_) => {
                let pause = tokio::time::sleep(retry);
                tokio::pin!(pause);
                loop {
                    tokio::select! {
                        () = &mut woken => break,
                        () = &mut pause => break,
                        request = requests.0.recv() => match request {
                            Some(Request { reply, .. }) => { let _ = reply.send(Err(not_bound())); }
                            // Nobody can command this Pi any more; the Session has let it go.
                            None => return,
                        },
                    }
                }
                retry = (retry * 2).min(RETRY_LAST);
                continue;
            }
        };
        retry = RETRY_FIRST;
        if !has_connected {
            log::info!("event=pi.bridge_connected {context}");
            has_connected = true;
        }
        let mut connection = Connection::new(ExpectedPane {
            session_uuid: &config.session_uuid,
            pane_id: &config.pane_id,
            session_file: &config.session_file,
            cwd: &config.initial_pwd,
            process_id: config.process_id,
        });
        let outcome = follow(
            stream,
            &config.bridge_token,
            &mut connection,
            &mut requests,
            &mut report,
            &context,
        )
        .await;
        if connection.is_bound() {
            report(LinkEvent::Disconnected);
        }
        if let Outcome::Invalid = outcome {
            requests.refuse_waiting();
            return;
        }
    }
}

async fn write_record(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    value: &impl serde::Serialize,
) -> io::Result<()> {
    let mut line = serde_json::to_vec(value).map_err(io::Error::other)?;
    line.push(b'\n');
    tokio::time::timeout(WRITE_TIMEOUT, writer.write_all(&line))
        .await
        .unwrap_or_else(|_| {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Pi's bridge is not reading",
            ))
        })
}

async fn follow(
    stream: UnixStream,
    token: &str,
    connection: &mut Connection<'_>,
    requests: &mut LinkRequests,
    report: &mut (impl FnMut(LinkEvent) -> bool + Send),
    context: &str,
) -> Outcome {
    let (mut reader, mut writer) = stream.into_split();
    let authenticate = Outgoing::Authenticate {
        protocol_version: ProtocolVersion,
        token,
    };
    if write_record(&mut writer, &authenticate).await.is_err() {
        return Outcome::Closed;
    }
    // Commands sent and not answered yet; dropping a reply fails its caller's wait.
    let mut pending: HashMap<String, oneshot::Sender<io::Result<CommandResult>>> = HashMap::new();
    let mut buffer = Vec::new();
    let mut chunk = vec![0_u8; 8192];
    let session_uuid = connection.session_uuid().to_owned();
    let outcome = loop {
        tokio::select! {
            read = reader.read(&mut chunk) => {
                let length = match read {
                    Ok(0) | Err(_) => break Outcome::Closed,
                    Ok(length) => length,
                };
                let fresh = &chunk[..length];
                // Only a newline ends a record: a chunk without one completes nothing, so a large
                // record is not searched again for every chunk of it.
                let completes = fresh.contains(&b'\n');
                buffer.extend_from_slice(fresh);
                if completes && let Some(outcome) = drain_records(&mut buffer, connection, &mut pending, report, context) {
                    break outcome;
                }
                if buffer.len() > MAX_RECORD_BYTES {
                    // An unterminated record this large: drop the connection and reconnect.
                    break Outcome::Closed;
                }
            }
            request = requests.0.recv() => {
                // The Session has let this Pi go.
                let Some(Request { action, reply }) = request else { break Outcome::Invalid };
                if !connection.is_bound() {
                    let _ = reply.send(Err(not_bound()));
                    continue;
                }
                let request_id = match axo_protocol::new_uuid_v4() {
                    Ok(uuid) => format!("axod-{uuid}"),
                    Err(error) => {
                        let _ = reply.send(Err(error));
                        continue;
                    }
                };
                let command = Outgoing::Command {
                    request_id: &request_id,
                    axo_session_id: &session_uuid,
                    action: action.borrowed(),
                };
                if let Err(error) = write_record(&mut writer, &command).await {
                    let _ = reply.send(Err(error));
                    break Outcome::Closed;
                }
                pending.insert(request_id, reply);
            }
        }
    };
    for (_, reply) in pending {
        let _ = reply.send(Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "Pi's bridge closed before answering",
        )));
    }
    outcome
}

/// Applies every whole record in `buffer`; `Some` when the connection must end.
fn drain_records(
    buffer: &mut Vec<u8>,
    connection: &mut Connection<'_>,
    pending: &mut HashMap<String, oneshot::Sender<io::Result<CommandResult>>>,
    report: &mut (impl FnMut(LinkEvent) -> bool + Send),
    context: &str,
) -> Option<Outcome> {
    let mut start = 0;
    let outcome = loop {
        let Some(length) = buffer[start..].iter().position(|byte| *byte == b'\n') else {
            break None;
        };
        let line = start..start + length;
        start = line.end + 1;
        if line.len() > MAX_RECORD_BYTES {
            break Some(Outcome::Invalid);
        }
        if let Some(outcome) = apply_record(&buffer[line], connection, pending, report, context) {
            break Some(outcome);
        }
    };
    buffer.drain(..start);
    outcome
}

/// Applies one record; `Some` when the connection must end.
fn apply_record(
    line: &[u8],
    connection: &mut Connection<'_>,
    pending: &mut HashMap<String, oneshot::Sender<io::Result<CommandResult>>>,
    report: &mut (impl FnMut(LinkEvent) -> bool + Send),
    context: &str,
) -> Option<Outcome> {
    let Ok(record) = parse_record(line) else {
        log::warn!("event=pi.bridge_protocol_rejected {context} reason=malformed_record");
        return Some(Outcome::Invalid);
    };
    let step = match connection.receive(record) {
        Ok(step) => step,
        Err(rejection) => {
            log_rejection(&rejection, context);
            return Some(Outcome::Invalid);
        }
    };
    let accepted = match step {
        Step::Authenticated => {
            log::info!("event=pi.bridge_authenticated {context}");
            true
        }
        Step::Bound { pi_session_id } => {
            log::info!("event=pi.session_binding_verified {context}");
            report(LinkEvent::Bound { pi_session_id })
        }
        Step::ResumeRequested {
            target_session_file,
        } => report(LinkEvent::ResumeRequested {
            target_session_file,
        }),
        Step::Event {
            pi_session_id,
            stream_id,
            sequence,
            name,
            data,
        } => report(LinkEvent::Event {
            pi_session_id,
            stream_id,
            sequence,
            name,
            data,
        }),
        Step::Oversized { name, bytes } => {
            log::warn!(
                "event=pi.event_skipped {context} name={name} bytes={bytes} reason=too_large"
            );
            true
        }
        Step::CommandResult { request_id, result } => {
            // An answer nobody waits for (it timed out) is dropped.
            if let Some(reply) = pending.remove(&request_id) {
                let _ = reply.send(Ok(result));
            }
            true
        }
    };
    (!accepted).then_some(Outcome::Invalid)
}

fn log_rejection(rejection: &Rejection, context: &str) {
    match rejection {
        Rejection::IdentityMismatch(matched) => log::warn!(
            "event=pi.binding_rejected {context} session_match={} pane_match={} file_match={} process_match={} cwd_match={}",
            matched.session,
            matched.pane,
            matched.file,
            matched.process,
            matched.cwd
        ),
        Rejection::InvalidPiSessionId => {
            log::warn!("event=pi.binding_rejected {context} reason=invalid_pi_session_id")
        }
        Rejection::Unexpected { phase, record } => {
            log::warn!("event=pi.bridge_protocol_rejected {context} phase={phase} record={record}")
        }
        other => log::warn!("event=pi.bridge_protocol_rejected {context} reason={other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::io::{AsyncBufReadExt, BufReader};
    use tokio::net::UnixListener;

    const SESSION: &str = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
    const PANE: &str = "9b9e14e0-d1c6-46b8-b289-bab4fda8774f";
    const STREAM: &str = "0f00f22d-a24c-4cbc-9196-74dbed95ca80";
    const TOKEN: &str = "5d3c1f6e-0a1b-4c2d-8e3f-9a0b1c2d3e4f";

    fn config(directory: &std::path::Path) -> LinkConfig {
        LinkConfig {
            session_uuid: SESSION.into(),
            pane_id: PANE.into(),
            initial_pwd: directory.to_path_buf(),
            session_file: directory.join("session.jsonl"),
            bridge_socket: BridgeSocketPath::parse(directory.join("b.sock")).unwrap(),
            bridge_token: TOKEN.into(),
            process_id: 42,
            log_context: "test".into(),
        }
    }

    async fn send(stream: &mut tokio::net::unix::OwnedWriteHalf, value: Value) {
        let mut line = value.to_string();
        line.push('\n');
        stream.write_all(line.as_bytes()).await.unwrap();
    }

    /// A Pi's side of the bridge: authenticates axod, says who it is, then hands the
    /// connection to the test.
    async fn accept_as_pi(
        listener: &UnixListener,
        directory: &std::path::Path,
    ) -> (
        tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
        tokio::net::unix::OwnedWriteHalf,
    ) {
        let (stream, _) = listener.accept().await.unwrap();
        let (reader, mut writer) = stream.into_split();
        let mut lines = BufReader::new(reader).lines();
        let authenticate: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(authenticate["token"], TOKEN);
        send(
            &mut writer,
            json!({ "type": "authenticated", "protocolVersion": 1 }),
        )
        .await;
        send(
            &mut writer,
            json!({ "type": "hello", "protocolVersion": 1, "identity": {
                "axoSessionId": SESSION, "axoPaneId": PANE, "piSessionId": "pi-1",
                "sessionFile": directory.join("session.jsonl"), "cwd": directory, "processId": 42,
            }}),
        )
        .await;
        (lines, writer)
    }

    #[tokio::test]
    async fn the_link_waits_for_pi_binds_follows_events_answers_commands_and_reconnects() {
        let directory = crate::test_directory();
        let config = config(&directory);
        let (commands, requests) = command_channel();
        let (events, mut heard) = mpsc::unbounded_channel();
        let wake = Arc::new(Notify::new());
        let link = tokio::spawn(run(config, requests, Arc::clone(&wake), move |event| {
            events.send(event).is_ok()
        }));
        // Nothing listens yet: a command is refused, not held.
        let refused = commands.shutdown(Duration::from_secs(2)).await.unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::NotConnected);

        let listener = UnixListener::bind(directory.join("b.sock")).unwrap();
        wake.notify_waiters();
        let (mut lines, mut writer) = accept_as_pi(&listener, &directory).await;
        assert_eq!(
            heard.recv().await.unwrap(),
            LinkEvent::Bound {
                pi_session_id: "pi-1".into()
            }
        );
        send(
            &mut writer,
            json!({ "type": "event", "streamId": STREAM, "sequence": 1, "name": "agent.start", "data": {} }),
        )
        .await;
        assert!(
            matches!(heard.recv().await.unwrap(), LinkEvent::Event { name, .. } if name == "agent.start")
        );

        let asking = tokio::spawn({
            let commands = commands.clone();
            async move { commands.shutdown(Duration::from_secs(5)).await }
        });
        let command: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(command["action"]["kind"], "shutdown");
        send(
            &mut writer,
            json!({ "type": "commandResult", "requestId": command["requestId"], "result": { "accepted": true } }),
        )
        .await;
        assert_eq!(asking.await.unwrap().unwrap(), CommandResult::Accepted);

        // Pi restarts its listener: the link says so, and comes back.
        drop((lines, writer));
        assert_eq!(heard.recv().await.unwrap(), LinkEvent::Disconnected);
        let _again = accept_as_pi(&listener, &directory).await;
        assert!(matches!(
            heard.recv().await.unwrap(),
            LinkEvent::Bound { .. }
        ));
        link.abort();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn records_split_across_writes_or_sharing_one_arrive_whole_and_in_order() {
        let directory = crate::test_directory();
        let (_commands, requests) = command_channel();
        let (events, mut heard) = mpsc::unbounded_channel();
        let listener = UnixListener::bind(directory.join("b.sock")).unwrap();
        let link = tokio::spawn(run(
            config(&directory),
            requests,
            Arc::new(Notify::new()),
            move |event| events.send(event).is_ok(),
        ));
        let (_lines, mut writer) = accept_as_pi(&listener, &directory).await;
        assert!(matches!(
            heard.recv().await.unwrap(),
            LinkEvent::Bound { .. }
        ));
        let event = |sequence: u64, text: &str| {
            let mut line = json!({ "type": "event", "streamId": STREAM, "sequence": sequence, "name": "message", "data": { "text": text } }).to_string();
            line.push('\n');
            line
        };
        // A large record, a byte at a time for its first stretch and then in small pieces.
        let long = crate::pi::connection::MAX_EVENT_DATA_BYTES - 100;
        let large = event(1, &"x".repeat(long));
        let (head, tail) = large.as_bytes().split_at(64);
        for byte in head {
            writer.write_all(std::slice::from_ref(byte)).await.unwrap();
        }
        for piece in tail.chunks(1000) {
            writer.write_all(piece).await.unwrap();
        }
        // Then two records and the start of a third in one write, and the rest of it.
        let third = event(4, "c");
        let (third_head, third_tail) = third.as_bytes().split_at(10);
        let mut joined = event(2, "a").into_bytes();
        joined.extend(event(3, "b").into_bytes());
        joined.extend(third_head);
        writer.write_all(&joined).await.unwrap();
        writer.write_all(third_tail).await.unwrap();
        for (expected, length) in [(1, long), (2, 1), (3, 1), (4, 1)] {
            let LinkEvent::Event { sequence, data, .. } = heard.recv().await.unwrap() else {
                panic!("an event");
            };
            assert_eq!(sequence, expected);
            assert_eq!(data["text"].as_str().unwrap().len(), length);
        }
        link.abort();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn a_pi_that_breaks_the_protocol_is_never_followed_again() {
        let directory = crate::test_directory();
        let (_commands, requests) = command_channel();
        let listener = UnixListener::bind(directory.join("b.sock")).unwrap();
        let link = tokio::spawn(run(
            config(&directory),
            requests,
            Arc::new(Notify::new()),
            |_| true,
        ));
        let (stream, _) = listener.accept().await.unwrap();
        let (_reader, mut writer) = stream.into_split();
        send(&mut writer, json!({ "type": "hello" })).await;
        tokio::time::timeout(Duration::from_secs(5), link)
            .await
            .expect("the link gives up on a Pi that breaks the protocol")
            .unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }
}
