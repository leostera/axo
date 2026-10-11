//! Bounded local terminal plane, separate from control RPC and never cloud-routed.
//! Host/path/Origin guards are browser restrictions, not same-user authentication.
use crate::{
    bootstrap::{Discovery, Publication},
    local::{UpgradeStream, bounded_upgrade, native_upgrade},
    model::*,
    runtime::{Manager, Sink},
    terminal::{ErrorCode, Frame, RawBacklog},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    io,
    net::{Ipv4Addr, TcpListener, TcpStream},
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};
use tungstenite::{
    Message, WebSocket,
    handshake::server::{ErrorResponse, Request},
    protocol::WebSocketConfig,
};

const MAX_CLIENTS: usize = 32;
pub(crate) const FRAME_BYTES: usize = 48 * 1024;
const DELIVERY_BYTES: usize = 128 * 1024;
const DELIVERY_FRAMES: usize = 32;
const INPUT_BYTES: usize = 4096;
const CALLS_PER_SECOND: usize = 1000;
const PATH: &str = "/v1/terminal";

#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Command {
    Attach {
        version: u16,
        machine_id: MachineId,
        runtime: RuntimeRef,
    },
    Input {
        attachment: AttachmentRef,
        sequence: u64,
        data: Vec<u8>,
    },
    Resize {
        attachment: AttachmentRef,
        rows: u16,
        columns: u16,
    },
    Acknowledge {
        attachment: AttachmentRef,
        next_offset: u64,
    },
    Detach {
        attachment: AttachmentRef,
    },
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Event {
    Attached {
        version: u16,
        machine_id: MachineId,
        attachment: AttachmentRef,
        terminal: TerminalSnapshot,
        backlog: RawBacklog,
    },
    Output {
        attachment: AttachmentRef,
        offset: u64,
        data: Vec<u8>,
    },
    Exited {
        attachment: AttachmentRef,
        wait_status: i32,
    },
    InputApplied {
        attachment: AttachmentRef,
        sequence: u64,
        accepted_bytes: usize,
    },
    Resized {
        attachment: AttachmentRef,
        rows: u16,
        columns: u16,
    },
    Rejected {
        code: ErrorCode,
    },
}
impl Event {
    fn from_frame(frame: Frame, machine_id: MachineId) -> Self {
        match frame {
            Frame::Attached {
                attachment,
                terminal,
                backlog,
            } => Self::Attached {
                version: 1,
                machine_id,
                attachment,
                terminal,
                backlog,
            },
            Frame::Output {
                attachment,
                offset,
                data,
            } => Self::Output {
                attachment,
                offset,
                data,
            },
            Frame::Exited {
                attachment,
                wait_status,
            } => Self::Exited {
                attachment,
                wait_status,
            },
        }
    }
    fn next_offset(&self) -> Option<u64> {
        match self {
            Self::Attached { backlog, .. } => Some(backlog.next_offset),
            Self::Output { offset, data, .. } => offset.checked_add(data.len() as u64),
            _ => None,
        }
    }
}

pub(crate) struct TerminalServer {
    stopping: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
struct Context {
    _publication: Publication,
    unavailable: AtomicBool,
    machine: MachineId,
    manager: Arc<Manager>,
    authority: String,
    stopping: Arc<AtomicBool>,
}
impl TerminalServer {
    pub fn start(
        root: &Path,
        machine: MachineId,
        manager: Arc<Manager>,
        stopping: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let authority = listener.local_addr()?.to_string();
        let discovery = Discovery {
            version: 1,
            protocol_version: 1,
            endpoint: format!("ws://{authority}{PATH}"),
            machine_id: machine,
            host_generation: manager.generation,
        };
        let publication = Publication::publish_terminal(root, &discovery)?;
        let context = Arc::new(Context {
            _publication: publication,
            unavailable: AtomicBool::new(false),
            machine,
            manager,
            authority,
            stopping: stopping.clone(),
        });
        let worker = thread::Builder::new()
            .name("axod-terminal-plane".into())
            .spawn(move || accept_clients(listener, context))?;
        Ok(Self {
            stopping,
            worker: Some(worker),
        })
    }
}
impl Drop for TerminalServer {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn accept_clients(listener: TcpListener, context: Arc<Context>) {
    let mut workers: Vec<JoinHandle<()>> = Vec::new();
    while !context.stopping.load(Ordering::SeqCst) {
        let mut index = 0;
        while index < workers.len() {
            if workers[index].is_finished() {
                let _ = workers.swap_remove(index).join();
            } else {
                index += 1;
            }
        }
        match listener.accept() {
            Ok((stream, address)) if address.ip().is_loopback() && workers.len() < MAX_CLIENTS => {
                let context = context.clone();
                if let Ok(worker) = thread::Builder::new()
                    .name("axod-terminal-client".into())
                    .spawn(move || {
                        if let Err(error) = client(stream, &context) {
                            let class = match error.to_string().as_str() {
                                "Invalid terminal command" => "CommandJson",
                                "Terminal connection closed or unsupported message" => {
                                    "UnsupportedCommandFrame"
                                }
                                "Terminal transport closed" => "SocketEnded",
                                "Terminal rate limit" => "RateLimit",
                                "Terminal credit limit" => "CreditLimit",
                                "Terminal delivery unknown; input must not be replayed" => {
                                    "WriteUnknown"
                                }
                                _ => "OtherIo",
                            };
                            eprintln!("Terminal presentation failed: {class}");
                        }
                    })
                {
                    workers.push(worker);
                }
            }
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10))
            }
            Err(_) => break, // A terminal listener failure never stops accepted work.
        }
    }
    context.unavailable.store(true, Ordering::SeqCst);
    for worker in workers {
        let _ = worker.join();
    }
}
#[allow(clippy::result_large_err)]
fn client(stream: TcpStream, context: &Context) -> io::Result<()> {
    let limits = WebSocketConfig::default()
        .max_message_size(Some(FRAME_BYTES))
        .max_frame_size(Some(FRAME_BYTES))
        .write_buffer_size(0)
        .max_write_buffer_size(FRAME_BYTES + 1024);
    let mut socket = tungstenite::accept_hdr_with_config(
        bounded_upgrade(stream)?,
        |request: &Request, response| -> Result<_, ErrorResponse> {
            if native_upgrade(request, &context.authority, PATH)
                && !context.stopping.load(Ordering::SeqCst)
                && !context.unavailable.load(Ordering::SeqCst)
            {
                Ok(response)
            } else {
                Err(tungstenite::http::Response::builder()
                    .status(403)
                    .body(Some("Local terminal admission denied".into()))
                    .expect("Static response"))
            }
        },
        Some(limits),
    )
    .map_err(|_| io::Error::other("Terminal admission failed"))?;
    socket
        .get_mut()
        .tcp
        .set_read_timeout(Some(Duration::from_secs(2)))?;
    let command = read_command(&mut socket)?
        .ok_or_else(|| io::Error::other("Terminal attachment required"))?;
    let Command::Attach {
        version: 1,
        machine_id,
        runtime,
    } = command
    else {
        return send(
            &mut socket,
            &Event::Rejected {
                code: ErrorCode::InvalidRequest,
            },
        );
    };
    if machine_id != context.machine {
        return send(
            &mut socket,
            &Event::Rejected {
                code: ErrorCode::StaleHost,
            },
        );
    }
    let owner = ClientId::new();
    let _lease = ClientLease {
        manager: context.manager.clone(),
        owner,
    };
    let (sink, receiver) = Sink::bounded(DELIVERY_FRAMES);
    let attached = match context.manager.attach(runtime, owner, sink) {
        Ok(attached) => attached,
        Err(code) => return send(&mut socket, &Event::Rejected { code }),
    };
    socket
        .get_mut()
        .tcp
        .set_read_timeout(Some(Duration::from_millis(10)))?;
    let mut state = Connection::new(attached.attachment);
    while !context.stopping.load(Ordering::SeqCst)
        && !context.unavailable.load(Ordering::SeqCst)
        && !receiver.is_disconnected()
    {
        // The manager always drains its PTY. Slow clients lose only this lease,
        // never work; the bounded queue/credits cannot stall the process reader.
        for _ in 0..DELIVERY_FRAMES {
            if !state.credits.available() {
                break;
            }
            let Ok(frame) = receiver.try_recv() else {
                break;
            };
            let event = Event::from_frame(frame, context.machine);
            state.credits.reserve(&event)?;
            send(&mut socket, &event)?;
        }
        if let Some(command) = read_command(&mut socket)? {
            if !state.admit() {
                return Err(io::Error::other("Terminal rate limit"));
            }
            match state.apply(command, &context.manager, owner) {
                Ok(Action::InputApplied {
                    sequence,
                    accepted_bytes,
                }) => send(
                    &mut socket,
                    &Event::InputApplied {
                        attachment: state.attachment,
                        sequence,
                        accepted_bytes,
                    },
                )?,
                Ok(Action::Resized { rows, columns }) => send(
                    &mut socket,
                    &Event::Resized {
                        attachment: state.attachment,
                        rows,
                        columns,
                    },
                )?,
                Ok(Action::Continue) => (),
                Ok(Action::Detach) => {
                    let _ = socket.close(None);
                    return Ok(());
                }
                Err(code) => {
                    eprintln!("Terminal command rejected: {code:?}");
                    send(&mut socket, &Event::Rejected { code })?;
                    return Ok(());
                }
            }
        }
    }
    if receiver.is_disconnected() {
        eprintln!("Terminal presentation closed: QueueCapacity");
    } else if context.unavailable.load(Ordering::SeqCst) {
        eprintln!("Terminal presentation closed: TransportUnavailable");
    } else {
        eprintln!("Terminal presentation closed: DaemonStopping");
    }
    let _ = socket.close(None);
    Ok(())
}
struct ClientLease {
    manager: Arc<Manager>,
    owner: ClientId,
}
impl Drop for ClientLease {
    fn drop(&mut self) {
        self.manager.disconnect(self.owner);
    }
}
fn read_command(socket: &mut WebSocket<UpgradeStream>) -> io::Result<Option<Command>> {
    match socket.read() {
        Ok(Message::Text(raw)) => serde_json::from_str(&raw)
            .map(Some)
            .map_err(|_| io::Error::other("Invalid terminal command")),
        // Do not accept unsolicited pings as an unmetered write/amplification path.
        Ok(_) => Err(io::Error::other(
            "Terminal connection closed or unsupported message",
        )),
        Err(tungstenite::Error::Io(error))
            if matches!(
                error.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            ) =>
        {
            Ok(None)
        }
        Err(_) => Err(io::Error::other("Terminal transport closed")),
    }
}
fn send(socket: &mut WebSocket<UpgradeStream>, event: &Event) -> io::Result<()> {
    let raw = serde_json::to_string(event)?;
    if raw.len() > FRAME_BYTES {
        return Err(io::Error::other("Terminal frame limit"));
    }
    socket
        .send(Message::Text(raw.into()))
        .map_err(|_| io::Error::other("Terminal delivery unknown; input must not be replayed"))
}

struct Credits {
    outstanding: VecDeque<(u64, usize)>,
    bytes: usize,
}
impl Credits {
    fn available(&self) -> bool {
        self.outstanding.len() < DELIVERY_FRAMES && self.bytes + FRAME_BYTES <= DELIVERY_BYTES
    }
    fn reserve(&mut self, event: &Event) -> io::Result<()> {
        if let Some(next_offset) = event.next_offset() {
            let bytes = serde_json::to_vec(event)?.len();
            if !self.available() || bytes > FRAME_BYTES {
                return Err(io::Error::other("Terminal credit limit"));
            }
            self.outstanding.push_back((next_offset, bytes));
            self.bytes += bytes;
        }
        Ok(())
    }
    fn acknowledge(&mut self, next_offset: u64) -> Result<(), ErrorCode> {
        let index = self
            .outstanding
            .iter()
            .position(|(offset, _)| *offset == next_offset)
            .ok_or(ErrorCode::InvalidRequest)?;
        for _ in 0..=index {
            self.bytes -= self.outstanding.pop_front().expect("Validated credit").1;
        }
        Ok(())
    }
}
struct Connection {
    attachment: AttachmentRef,
    next_input: u64,
    credits: Credits,
    window: Instant,
    calls: usize,
}
enum Action {
    InputApplied {
        sequence: u64,
        accepted_bytes: usize,
    },
    Resized {
        rows: u16,
        columns: u16,
    },
    Continue,
    Detach,
}
impl Connection {
    fn new(attachment: AttachmentRef) -> Self {
        Self {
            attachment,
            next_input: 0,
            credits: Credits {
                outstanding: VecDeque::new(),
                bytes: 0,
            },
            window: Instant::now(),
            calls: 0,
        }
    }
    fn admit(&mut self) -> bool {
        if self.window.elapsed() >= Duration::from_secs(1) {
            self.calls = 0;
            self.window = Instant::now();
        }
        self.calls += 1;
        self.calls <= CALLS_PER_SECOND
    }
    fn apply(
        &mut self,
        command: Command,
        manager: &Manager,
        owner: ClientId,
    ) -> Result<Action, ErrorCode> {
        let attachment = match &command {
            Command::Attach { .. } => return Err(ErrorCode::InvalidTransition),
            Command::Input { attachment, .. }
            | Command::Resize { attachment, .. }
            | Command::Acknowledge { attachment, .. }
            | Command::Detach { attachment } => *attachment,
        };
        if attachment != self.attachment {
            return Err(ErrorCode::StaleAttachment);
        }
        match command {
            Command::Input { sequence, data, .. } => {
                if sequence != self.next_input || data.is_empty() || data.len() > INPUT_BYTES {
                    return Err(ErrorCode::InvalidRequest);
                }
                // Only this live connection admits each input once. Delivery loss is
                // uncertainty, not permission to replay on another connection.
                self.next_input = self.next_input.checked_add(1).ok_or(ErrorCode::Capacity)?;
                let accepted_bytes = manager.input(attachment, owner, &data)?;
                Ok(Action::InputApplied {
                    sequence,
                    accepted_bytes,
                })
            }
            Command::Resize { rows, columns, .. } => {
                manager.resize(attachment, owner, rows, columns)?;
                Ok(Action::Resized { rows, columns })
            }
            Command::Acknowledge { next_offset, .. } => {
                self.credits.acknowledge(next_offset)?;
                Ok(Action::Continue)
            }
            Command::Detach { .. } => {
                manager.detach(attachment, owner)?;
                Ok(Action::Detach)
            }
            Command::Attach { .. } => Err(ErrorCode::InvalidTransition),
        }
    }
}

#[cfg(test)]
mod tests;
