//! Following one running Pi over its bridge for as long as it is the pane's current process.

use std::collections::HashMap;
use std::io;
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::BridgeSocketPath;
use crate::bridge::{self, MAX_RECORD_BYTES};
use crate::connection::{Connection, ExpectedPane, Rejection, Step};
use crate::protocol::{
    Action, CommandResult, Outgoing, ProtocolVersion, QueuedDelivery, parse_record,
};
use crate::takeover::BRIDGE_REQUEST_TIMEOUT;

const RECONNECT_DELAY: Duration = Duration::from_millis(100);
const READ_POLL: Duration = Duration::from_millis(200);
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);

/// What the worker reports to whoever owns the pane.
pub trait BridgeHost {
    /// Whether the Pi this worker follows is still the pane's process. Once `false`, the
    /// worker exits.
    fn is_current(&self) -> bool;
    /// The connection proved it serves the pane. An error drops the connection for good.
    fn bound(&self, pi_session_id: &str) -> io::Result<()>;
    /// A bound connection ended.
    fn disconnected(&self);
    /// Pi's `/resume` picked a saved Session (`None` when the request was malformed).
    fn resume_requested(&self, target_session_file: Option<&str>);
    /// One Pi event, in stream order. `false` drops the connection for good.
    fn event(
        &self,
        pi_session_id: &str,
        stream_id: &str,
        sequence: u64,
        name: &str,
        data: Value,
    ) -> bool;
}

/// A command for the Pi a worker follows, and where its answer goes.
enum WorkerCommand {
    Send {
        text: String,
        delivery: Option<QueuedDelivery>,
        reply: mpsc::Sender<io::Result<CommandResult>>,
    },
}

/// Sends commands to a running Pi over its worker's bridge connection. Pi's bridge serves one
/// Axod connection at a time, so commands cannot open their own while the worker holds it.
#[derive(Clone, Debug)]
pub struct CommandSender(mpsc::Sender<WorkerCommand>);

impl std::fmt::Debug for WorkerCommand {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("WorkerCommand")
    }
}

/// The worker's end of a [`CommandSender`].
pub struct CommandReceiver(mpsc::Receiver<WorkerCommand>);

pub fn command_channel() -> (CommandSender, CommandReceiver) {
    let (sender, receiver) = mpsc::channel();
    (CommandSender(sender), CommandReceiver(receiver))
}

impl CommandSender {
    /// Submits `text` as a user message and waits for Pi's answer. Fails if the bridge is not
    /// bound, drops before answering, or Pi does not answer within `timeout`.
    pub fn send_message(
        &self,
        text: &str,
        delivery: Option<QueuedDelivery>,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        let (reply, answer) = mpsc::channel();
        self.0
            .send(WorkerCommand::Send {
                text: text.to_owned(),
                delivery,
                reply,
            })
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    "Pi's bridge worker has stopped",
                )
            })?;
        answer.recv_timeout(timeout).unwrap_or_else(|_| {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Pi did not answer the command in time",
            ))
        })
    }
}

impl CommandReceiver {
    /// Refuses every command waiting now: there is no bound connection to send it on.
    fn refuse_waiting(&self) {
        while let Ok(WorkerCommand::Send { reply, .. }) = self.0.try_recv() {
            let _ = reply.send(Err(not_bound()));
        }
    }
}

fn not_bound() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "Pi's bridge is not connected")
}

/// Everything needed to reach and verify one running Pi.
pub struct WorkerConfig {
    pub session_uuid: String,
    pub pane_id: String,
    pub initial_pwd: PathBuf,
    pub session_file: PathBuf,
    pub bridge_socket: BridgeSocketPath,
    pub bridge_token: String,
    pub process_id: u32,
    /// Prefix for log lines, e.g. `session_id=1 shell_id=2`.
    pub log_context: String,
    /// Commands to send while bound; see [`CommandSender`].
    pub commands: CommandReceiver,
}

/// Connects (and reconnects while Pi restarts its listener) until `stop` is set, the Pi is
/// replaced, or a connection breaks the protocol.
pub fn run(host: &impl BridgeHost, stop: &Arc<AtomicBool>, config: &WorkerConfig) {
    let context = &config.log_context;
    let mut has_connected = false;
    while !stop.load(Ordering::Relaxed) && host.is_current() {
        config.commands.refuse_waiting();
        let check_current = || {
            if stop.load(Ordering::Relaxed) || !host.is_current() {
                Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi bridge runtime is no longer current",
                ))
            } else {
                Ok(())
            }
        };
        let Ok(mut stream) = bridge::connect_until(
            config.bridge_socket.as_path(),
            Instant::now() + BRIDGE_REQUEST_TIMEOUT,
            &check_current,
        ) else {
            thread::sleep(RECONNECT_DELAY);
            continue;
        };
        if !has_connected {
            log::info!("event=pi.bridge_connected {context}");
            has_connected = true;
        }
        if stream
            .set_read_timeout(Some(READ_POLL))
            .and_then(|()| stream.set_write_timeout(Some(WRITE_TIMEOUT)))
            .is_err()
        {
            return;
        }
        let authenticate = Outgoing::Authenticate {
            protocol_version: ProtocolVersion,
            token: &config.bridge_token,
        };
        if bridge::write_record(&mut stream, &authenticate).is_err() {
            continue;
        }

        let mut connection = Connection::new(ExpectedPane {
            session_uuid: &config.session_uuid,
            pane_id: &config.pane_id,
            session_file: &config.session_file,
            cwd: &config.initial_pwd,
            process_id: config.process_id,
        });
        let outcome = follow(
            host,
            stop,
            &mut stream,
            &mut connection,
            &config.commands,
            context,
        );
        if connection.is_bound() {
            host.disconnected();
        }
        match outcome {
            Outcome::Closed => thread::sleep(RECONNECT_DELAY),
            Outcome::Stop | Outcome::Invalid => return,
        }
    }
}

enum Outcome {
    /// The stream ended; reconnect.
    Closed,
    /// The worker should exit.
    Stop,
    /// The connection broke the protocol; never trust this Pi again.
    Invalid,
}

fn follow(
    host: &impl BridgeHost,
    stop: &AtomicBool,
    stream: &mut UnixStream,
    connection: &mut Connection<'_>,
    commands: &CommandReceiver,
    context: &str,
) -> Outcome {
    // Commands sent and not answered yet; dropping a reply fails its caller's wait.
    let mut pending: HashMap<String, mpsc::Sender<io::Result<CommandResult>>> = HashMap::new();
    let outcome = follow_records(
        host,
        stop,
        stream,
        connection,
        commands,
        &mut pending,
        context,
    );
    for (_, reply) in pending {
        let _ = reply.send(Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "Pi's bridge closed before answering",
        )));
    }
    outcome
}

/// Writes waiting commands once bound; refuses them before that.
fn send_waiting(
    stream: &mut UnixStream,
    connection: &Connection<'_>,
    commands: &CommandReceiver,
    pending: &mut HashMap<String, mpsc::Sender<io::Result<CommandResult>>>,
    session_uuid: &str,
) -> bool {
    if !connection.is_bound() {
        commands.refuse_waiting();
        return true;
    }
    while let Ok(WorkerCommand::Send {
        text,
        delivery,
        reply,
    }) = commands.0.try_recv()
    {
        let request_id = match axo_protocol::new_uuid_v4() {
            Ok(uuid) => format!("axod-{uuid}"),
            Err(error) => {
                let _ = reply.send(Err(error));
                continue;
            }
        };
        let command = Outgoing::Command {
            request_id: &request_id,
            axo_session_id: session_uuid,
            action: Action::Send {
                text: &text,
                delivery,
            },
        };
        if let Err(error) = bridge::write_record(stream, &command) {
            let _ = reply.send(Err(error));
            return false;
        }
        pending.insert(request_id, reply);
    }
    true
}

fn follow_records(
    host: &impl BridgeHost,
    stop: &AtomicBool,
    stream: &mut UnixStream,
    connection: &mut Connection<'_>,
    commands: &CommandReceiver,
    pending: &mut HashMap<String, mpsc::Sender<io::Result<CommandResult>>>,
    context: &str,
) -> Outcome {
    let mut buffer = Vec::new();
    let mut chunk = [0_u8; 8192];
    let session_uuid = connection.session_uuid().to_owned();
    loop {
        if stop.load(Ordering::Relaxed) || !host.is_current() {
            return Outcome::Stop;
        }
        if !send_waiting(stream, connection, commands, pending, &session_uuid) {
            return Outcome::Closed;
        }
        let length = match stream.read(&mut chunk) {
            Ok(0) => return Outcome::Closed,
            Ok(length) => length,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(_) => return Outcome::Closed,
        };
        buffer.extend_from_slice(&chunk[..length]);
        while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = buffer.drain(..=newline).collect();
            if line.len() > MAX_RECORD_BYTES {
                return Outcome::Invalid;
            }
            let Ok(record) = parse_record(&line[..line.len() - 1]) else {
                log::warn!("event=pi.bridge_protocol_rejected {context} reason=malformed_record");
                return Outcome::Invalid;
            };
            match connection.receive(record) {
                Ok(Step::CommandResult { request_id, result }) => {
                    // An answer nobody waits for (it timed out) is dropped.
                    if let Some(reply) = pending.remove(&request_id) {
                        let _ = reply.send(Ok(result));
                    }
                }
                Ok(step) => {
                    if !apply(host, step, context) {
                        return Outcome::Invalid;
                    }
                }
                Err(rejection) => {
                    log_rejection(&rejection, context);
                    return Outcome::Invalid;
                }
            }
        }
        if buffer.len() > MAX_RECORD_BYTES {
            // An unterminated record this large: drop the connection and reconnect.
            return Outcome::Closed;
        }
    }
}

fn apply(host: &impl BridgeHost, step: Step, context: &str) -> bool {
    match step {
        Step::Authenticated => {
            log::info!("event=pi.bridge_authenticated {context}");
            true
        }
        Step::Bound { pi_session_id } => {
            if host.bound(&pi_session_id).is_err() {
                return false;
            }
            log::info!("event=pi.session_binding_verified {context}");
            true
        }
        Step::ResumeRequested {
            target_session_file,
        } => {
            host.resume_requested(target_session_file.as_deref());
            true
        }
        Step::Event {
            pi_session_id,
            stream_id,
            sequence,
            name,
            data,
        } => host.event(&pi_session_id, &stream_id, sequence, &name, data),
        Step::Oversized { name, bytes } => {
            log::warn!(
                "event=pi.event_skipped {context} name={name} bytes={bytes} reason=too_large"
            );
            true
        }
        // Routed to its caller in `follow_records`.
        Step::CommandResult { .. } => true,
    }
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
