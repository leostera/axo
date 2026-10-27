//! Following one running Pi over its bridge for as long as it is the pane's current process.

use std::io::{self, Read};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::BridgeSocketPath;
use crate::bridge::{self, MAX_RECORD_BYTES};
use crate::connection::{Connection, ExpectedPane, Rejection, Step};
use crate::protocol::{Outgoing, ProtocolVersion, parse_record};
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
}

/// Connects (and reconnects while Pi restarts its listener) until `stop` is set, the Pi is
/// replaced, or a connection breaks the protocol.
pub fn run(host: &impl BridgeHost, stop: &Arc<AtomicBool>, config: &WorkerConfig) {
    let context = &config.log_context;
    let mut has_connected = false;
    while !stop.load(Ordering::Relaxed) && host.is_current() {
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
        let outcome = follow(host, stop, &mut stream, &mut connection, context);
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
    stream: &mut impl Read,
    connection: &mut Connection<'_>,
    context: &str,
) -> Outcome {
    let mut buffer = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        if stop.load(Ordering::Relaxed) || !host.is_current() {
            return Outcome::Stop;
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
            log::warn!("event=pi.event_skipped {context} name={name} bytes={bytes} reason=too_large");
            true
        }
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
