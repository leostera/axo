//! Typed consumer for the local terminal plane. No launch/stop or input replay.
use crate::{
    bootstrap::Discovery,
    client::native_discovery_address,
    model::*,
    private_file::read_private,
    terminal::{BACKLOG_BYTES, ErrorCode, OUTPUT_CHUNK},
    terminal_transport::{Command, Event, FRAME_BYTES},
};
use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    net::TcpStream,
    path::Path,
    time::{Duration, Instant},
};
use tungstenite::{Message, WebSocket, protocol::WebSocketConfig};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamError {
    InvalidDiscovery,
    Offline,
    Protocol,
    ProtocolFault(ProtocolFault),
    PresentationClosed,
    Capacity,
    InputPending,
    OutcomeUnknown,
    Rejected(ErrorCode),
}
/// Closed body-free failure locations, never packet data or identity values.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProtocolFault {
    OutputBinding,
    OutputOffset,
    OutputBytes,
    InputWithoutPending,
    InputReceipt,
    ResizeWithoutPending,
    ResizeReceipt,
    ExitReceipt,
    UnexpectedAttached,
    EventJson,
    WebsocketFrame,
}
impl std::fmt::Display for StreamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rejected(code) => write!(f, "Terminal request rejected ({code:?})"),
            Self::PresentationClosed => f.write_str("Terminal presentation closed (PresentationClosed); input delivery may be unknown, do not replay"),
            Self::OutcomeUnknown => {
                f.write_str("Terminal delivery unknown; input must not be replayed")
            }
            _ => write!(f, "Terminal connection error ({self:?})"),
        }
    }
}
impl std::error::Error for StreamError {}

/// Payload-bearing values deliberately have no Debug/Display implementation.
pub struct OutputChunk {
    attachment: AttachmentRef,
    offset: u64,
    next_offset: u64,
    data: Vec<u8>,
}
impl OutputChunk {
    pub fn data(&self) -> &[u8] {
        &self.data
    }
    pub fn offset(&self) -> u64 {
        self.offset
    }
    pub fn next_offset(&self) -> u64 {
        self.next_offset
    }
}
pub struct InitialAttachment {
    pub terminal: TerminalSnapshot,
    pub backlog: OutputChunk,
    pub truncated: bool,
}
pub enum StreamEvent {
    Output(OutputChunk),
    Exited {
        wait_status: i32,
    },
    InputApplied {
        sequence: u64,
        accepted_bytes: usize,
    },
    Resized {
        rows: u16,
        columns: u16,
    },
}
struct PendingInput {
    sequence: u64,
    bytes: usize,
    deadline: Instant,
}
struct PendingResize {
    size: TerminalSize,
    deadline: Instant,
}
struct StreamState {
    attachment: AttachmentRef,
    next_offset: u64,
    next_sequence: u64,
    pending_input: Option<PendingInput>,
    pending_resize: Option<PendingResize>,
    deliveries: VecDeque<(u64, usize)>,
    delivery_bytes: usize,
    exited: bool,
}
impl StreamState {
    fn reserve(&mut self, next_offset: u64, bytes: usize) -> Result<(), StreamError> {
        if self.deliveries.len() >= 32 || self.delivery_bytes + bytes > 128 * 1024 {
            return Err(StreamError::Capacity);
        }
        self.deliveries.push_back((next_offset, bytes));
        self.delivery_bytes += bytes;
        Ok(())
    }
    fn consume(&mut self, event: Event, bytes: usize) -> Result<StreamEvent, StreamError> {
        match event {
            Event::Output {
                attachment,
                offset,
                data,
            } => {
                if attachment != self.attachment || self.exited {
                    return Err(StreamError::ProtocolFault(ProtocolFault::OutputBinding));
                }
                if offset != self.next_offset {
                    return Err(StreamError::ProtocolFault(ProtocolFault::OutputOffset));
                }
                if data.is_empty() || data.len() > OUTPUT_CHUNK {
                    return Err(StreamError::ProtocolFault(ProtocolFault::OutputBytes));
                }
                let next_offset = offset
                    .checked_add(data.len() as u64)
                    .ok_or(StreamError::Capacity)?;
                self.reserve(next_offset, bytes)?;
                self.next_offset = next_offset;
                Ok(StreamEvent::Output(OutputChunk {
                    attachment,
                    offset,
                    next_offset,
                    data,
                }))
            }
            Event::InputApplied {
                attachment,
                sequence,
                accepted_bytes,
            } => {
                let pending = self
                    .pending_input
                    .as_ref()
                    .ok_or(StreamError::ProtocolFault(
                        ProtocolFault::InputWithoutPending,
                    ))?;
                if attachment != self.attachment
                    || pending.sequence != sequence
                    || accepted_bytes > pending.bytes
                {
                    return Err(StreamError::ProtocolFault(ProtocolFault::InputReceipt));
                }
                self.pending_input = None;
                Ok(StreamEvent::InputApplied {
                    sequence,
                    accepted_bytes,
                })
            }
            Event::Resized {
                attachment,
                rows,
                columns,
            } => {
                let pending = self
                    .pending_resize
                    .as_ref()
                    .ok_or(StreamError::ProtocolFault(
                        ProtocolFault::ResizeWithoutPending,
                    ))?;
                if attachment != self.attachment
                    || pending.size.rows() != rows
                    || pending.size.columns() != columns
                {
                    return Err(StreamError::ProtocolFault(ProtocolFault::ResizeReceipt));
                }
                self.pending_resize = None;
                Ok(StreamEvent::Resized { rows, columns })
            }
            Event::Exited {
                attachment,
                wait_status,
            } => {
                if attachment != self.attachment || self.exited {
                    return Err(StreamError::ProtocolFault(ProtocolFault::ExitReceipt));
                }
                self.exited = true;
                Ok(StreamEvent::Exited { wait_status })
            }
            Event::Rejected { code } => Err(StreamError::Rejected(code)),
            Event::Attached { .. } => Err(StreamError::ProtocolFault(
                ProtocolFault::UnexpectedAttached,
            )),
        }
    }
    fn acknowledge(&mut self, chunk: &OutputChunk) -> Result<(), StreamError> {
        if chunk.attachment != self.attachment {
            return Err(StreamError::Protocol);
        }
        let index = self
            .deliveries
            .iter()
            .position(|(end, _)| *end == chunk.next_offset)
            .ok_or(StreamError::Protocol)?;
        for _ in 0..=index {
            self.delivery_bytes -= self.deliveries.pop_front().expect("Validated delivery").1;
        }
        Ok(())
    }
    fn expired(&self) -> bool {
        let now = Instant::now();
        self.pending_input
            .as_ref()
            .is_some_and(|pending| now >= pending.deadline)
            || self
                .pending_resize
                .as_ref()
                .is_some_and(|pending| now >= pending.deadline)
    }
}
struct StreamIo {
    tcp: TcpStream,
    handshake_deadline: Option<Instant>,
    write_deadline: Instant,
}
impl Read for StreamIo {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let timeout = match self.handshake_deadline {
            Some(deadline) => deadline
                .checked_duration_since(Instant::now())
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::TimedOut, "Terminal handshake deadline")
                })?,
            None => Duration::from_millis(10),
        };
        self.tcp.set_read_timeout(Some(timeout))?;
        self.tcp.read(buffer)
    }
}
impl Write for StreamIo {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let remaining = self
            .write_deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "Terminal write deadline"))?;
        self.tcp.set_write_timeout(Some(remaining))?;
        self.tcp.write(buffer)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.tcp.flush()
    }
}
pub struct TerminalClient {
    socket: WebSocket<StreamIo>,
    state: StreamState,
    usable: bool,
}
impl TerminalClient {
    pub fn connect(
        root: &Path,
        machine: MachineId,
        runtime: RuntimeRef,
    ) -> Result<(Self, InitialAttachment), StreamError> {
        let discovery: Discovery = serde_json::from_slice(
            &read_private(&root.join("terminal-endpoint.json"), 4096)
                .map_err(|_| StreamError::InvalidDiscovery)?,
        )
        .map_err(|_| StreamError::InvalidDiscovery)?;
        if discovery.machine_id != machine || discovery.host_generation != runtime.host_generation {
            return Err(StreamError::InvalidDiscovery);
        }
        let address = native_discovery_address(&discovery, "/v1/terminal")
            .map_err(|_| StreamError::InvalidDiscovery)?;
        let tcp = TcpStream::connect_timeout(&address, Duration::from_secs(2))
            .map_err(|_| StreamError::Offline)?;
        let io = StreamIo {
            tcp,
            handshake_deadline: Some(Instant::now() + Duration::from_secs(2)),
            write_deadline: Instant::now() + Duration::from_secs(2),
        };
        let limits = WebSocketConfig::default()
            .max_message_size(Some(FRAME_BYTES))
            .max_frame_size(Some(FRAME_BYTES))
            .write_buffer_size(0)
            .max_write_buffer_size(FRAME_BYTES + 1024);
        let (mut socket, _) =
            tungstenite::client::client_with_config(discovery.endpoint.as_str(), io, Some(limits))
                .map_err(|_| StreamError::Offline)?;
        send(
            &mut socket,
            Command::Attach {
                version: 1,
                machine_id: machine,
                runtime,
            },
        )?;
        let (event, wire_bytes) = receive(&mut socket)?.ok_or(StreamError::Protocol)?;
        let Event::Attached {
            version: 1,
            machine_id,
            attachment,
            terminal,
            backlog,
        } = event
        else {
            return match event {
                Event::Rejected { code } => Err(StreamError::Rejected(code)),
                _ => Err(StreamError::Protocol),
            };
        };
        if machine_id != machine
            || attachment.runtime != runtime
            || terminal.runtime != runtime
            || !terminal.attached
            || !matches!(terminal.process, ProcessState::Running { .. })
            || terminal.backlog_bytes != backlog.data.len()
            || backlog.data.len() > BACKLOG_BYTES
            || backlog.next_offset.checked_sub(backlog.start_offset)
                != Some(backlog.data.len() as u64)
            || backlog.truncated != (backlog.start_offset != 0)
        {
            return Err(StreamError::Protocol);
        }
        let mut state = StreamState {
            attachment,
            next_offset: backlog.next_offset,
            next_sequence: 0,
            pending_input: None,
            pending_resize: None,
            deliveries: VecDeque::new(),
            delivery_bytes: 0,
            exited: false,
        };
        state.reserve(backlog.next_offset, wire_bytes)?;
        let initial = InitialAttachment {
            terminal,
            truncated: backlog.truncated,
            backlog: OutputChunk {
                attachment,
                offset: backlog.start_offset,
                next_offset: backlog.next_offset,
                data: backlog.data,
            },
        };
        socket.get_mut().handshake_deadline = None;
        Ok((
            Self {
                socket,
                state,
                usable: true,
            },
            initial,
        ))
    }
    pub fn attachment(&self) -> AttachmentRef {
        self.state.attachment
    }
    pub fn input_pending(&self) -> bool {
        self.state.pending_input.is_some()
    }
    pub fn resize_pending(&self) -> bool {
        self.state.pending_resize.is_some()
    }
    fn require_usable(&mut self) -> Result<(), StreamError> {
        if !self.usable || self.state.expired() {
            self.usable = false;
            return Err(StreamError::OutcomeUnknown);
        }
        Ok(())
    }
    fn send(&mut self, command: Command) -> Result<(), StreamError> {
        self.require_usable()?;
        if let Err(error) = send(&mut self.socket, command) {
            self.usable = false;
            return Err(error);
        }
        Ok(())
    }
    pub fn input(&mut self, data: &[u8]) -> Result<u64, StreamError> {
        self.require_usable()?;
        if self.state.exited || data.is_empty() || data.len() > 4096 {
            return Err(StreamError::Protocol);
        }
        if self.input_pending() {
            return Err(StreamError::InputPending);
        }
        let sequence = self.state.next_sequence;
        self.state.next_sequence = sequence.checked_add(1).ok_or(StreamError::Capacity)?;
        self.state.pending_input = Some(PendingInput {
            sequence,
            bytes: data.len(),
            deadline: Instant::now() + Duration::from_secs(12),
        });
        self.send(Command::Input {
            attachment: self.state.attachment,
            sequence,
            data: data.to_vec(),
        })?;
        Ok(sequence)
    }
    pub fn resize(&mut self, size: TerminalSize) -> Result<(), StreamError> {
        self.require_usable()?;
        if self.state.exited || self.resize_pending() {
            return Err(StreamError::Protocol);
        }
        self.state.pending_resize = Some(PendingResize {
            size,
            deadline: Instant::now() + Duration::from_secs(12),
        });
        self.send(Command::Resize {
            attachment: self.state.attachment,
            rows: size.rows(),
            columns: size.columns(),
        })
    }
    /// Call only after the entire chunk has been consumed by the renderer/TTY.
    pub fn acknowledge(&mut self, chunk: &OutputChunk) -> Result<(), StreamError> {
        self.require_usable()?;
        self.state.acknowledge(chunk)?;
        self.send(Command::Acknowledge {
            attachment: self.state.attachment,
            next_offset: chunk.next_offset,
        })
    }
    pub fn read(&mut self) -> Result<Option<StreamEvent>, StreamError> {
        self.require_usable()?;
        let result = receive(&mut self.socket).and_then(|event| {
            event
                .map(|(event, bytes)| self.state.consume(event, bytes))
                .transpose()
        });
        if result.is_err() {
            self.usable = false;
        }
        result
    }
    pub fn detach(mut self) -> Result<(), StreamError> {
        self.send(Command::Detach {
            attachment: self.state.attachment,
        })
    }
}
impl Drop for TerminalClient {
    fn drop(&mut self) {
        self.socket.get_mut().write_deadline = Instant::now() + Duration::from_millis(500);
        let _ = self.socket.close(None);
    }
}
fn send(socket: &mut WebSocket<StreamIo>, command: Command) -> Result<(), StreamError> {
    let raw = serde_json::to_string(&command).map_err(|_| StreamError::Protocol)?;
    if raw.len() > FRAME_BYTES {
        return Err(StreamError::Capacity);
    }
    socket.get_mut().write_deadline = Instant::now() + Duration::from_millis(500);
    socket
        .send(Message::Text(raw.into()))
        .map_err(|_| StreamError::OutcomeUnknown)
}
fn receive(socket: &mut WebSocket<StreamIo>) -> Result<Option<(Event, usize)>, StreamError> {
    match socket.read() {
        Ok(Message::Text(raw)) => serde_json::from_str(&raw)
            .map(|event| Some((event, raw.len())))
            .map_err(|_| StreamError::ProtocolFault(ProtocolFault::EventJson)),
        Ok(Message::Close(_)) => Err(StreamError::PresentationClosed),
        Ok(_) => Err(StreamError::ProtocolFault(ProtocolFault::WebsocketFrame)),
        Err(tungstenite::Error::Io(error))
            if matches!(
                error.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            ) =>
        {
            Ok(None)
        }
        Err(_) => Err(StreamError::OutcomeUnknown),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn new_state() -> StreamState {
        StreamState {
            attachment: AttachmentRef {
                runtime: RuntimeRef {
                    host_generation: HostGeneration::new(),
                    target: TerminalTarget {
                        session_id: SessionId::new(),
                        pane_id: PaneId::new(),
                    },
                    runtime_generation: RuntimeGeneration::new(),
                },
                attachment_id: AttachmentId::new(),
            },
            next_offset: 0,
            next_sequence: 0,
            pending_input: None,
            pending_resize: None,
            deliveries: VecDeque::new(),
            delivery_bytes: 0,
            exited: false,
        }
    }
    #[test]
    fn output_identity_offsets_bounds_and_credits_are_exact() {
        let mut state = new_state();
        let attachment = state.attachment;
        for (offset, data, fault) in [
            (1, vec![0], ProtocolFault::OutputOffset),
            (0, vec![], ProtocolFault::OutputBytes),
            (0, vec![0; OUTPUT_CHUNK + 1], ProtocolFault::OutputBytes),
        ] {
            assert!(matches!(
                state.consume(
                    Event::Output {
                        attachment,
                        offset,
                        data
                    },
                    100
                ),
                Err(StreamError::ProtocolFault(actual)) if actual == fault
            ));
            assert_eq!(state.next_offset, 0);
        }
        let StreamEvent::Output(chunk) = state
            .consume(
                Event::Output {
                    attachment,
                    offset: 0,
                    data: vec![0; 10],
                },
                100,
            )
            .unwrap()
        else {
            panic!("Expected chunk");
        };
        assert_eq!(state.next_offset, 10);
        state.acknowledge(&chunk).unwrap();
        assert_eq!(state.delivery_bytes, 0);
        assert_eq!(state.acknowledge(&chunk), Err(StreamError::Protocol));
        let mut other = new_state();
        assert_eq!(other.acknowledge(&chunk), Err(StreamError::Protocol));
    }
    #[test]
    fn input_and_resize_receipts_require_one_exact_pending_operation() {
        let mut state = new_state();
        let attachment = state.attachment;
        assert!(matches!(
            state.consume(
                Event::InputApplied {
                    attachment,
                    sequence: 0,
                    accepted_bytes: 1
                },
                100
            ),
            Err(StreamError::ProtocolFault(
                ProtocolFault::InputWithoutPending
            ))
        ));
        state.pending_input = Some(PendingInput {
            sequence: 0,
            bytes: 2,
            deadline: Instant::now() + Duration::from_secs(12),
        });
        for (sequence, accepted_bytes) in [(1, 1), (0, 3)] {
            assert!(matches!(
                state.consume(
                    Event::InputApplied {
                        attachment,
                        sequence,
                        accepted_bytes
                    },
                    100
                ),
                Err(StreamError::ProtocolFault(ProtocolFault::InputReceipt))
            ));
            assert!(state.pending_input.is_some());
        }
        assert!(matches!(
            state.consume(
                Event::InputApplied {
                    attachment,
                    sequence: 0,
                    accepted_bytes: 1
                },
                100
            ),
            Ok(StreamEvent::InputApplied {
                accepted_bytes: 1,
                ..
            })
        ));
        assert!(state.pending_input.is_none());
        state.pending_resize = Some(PendingResize {
            size: TerminalSize::new(30, 100).unwrap(),
            deadline: Instant::now() + Duration::from_secs(12),
        });
        assert!(matches!(
            state.consume(
                Event::Resized {
                    attachment,
                    rows: 31,
                    columns: 100
                },
                100
            ),
            Err(StreamError::ProtocolFault(ProtocolFault::ResizeReceipt))
        ));
        assert!(state.pending_resize.is_some());
        assert!(matches!(
            state.consume(
                Event::Resized {
                    attachment,
                    rows: 30,
                    columns: 100
                },
                100
            ),
            Ok(StreamEvent::Resized { .. })
        ));
    }
    #[test]
    fn terminal_delivery_and_deadline_exhaustion_never_authorize_replay() {
        let mut state = new_state();
        state.pending_input = Some(PendingInput {
            sequence: 0,
            bytes: 1,
            deadline: Instant::now(),
        });
        assert!(state.expired());
        for offset in 0..32 {
            state.reserve(offset, 100).unwrap();
        }
        assert_eq!(state.reserve(33, 100), Err(StreamError::Capacity));
        let attachment = state.attachment;
        assert!(matches!(
            state.consume(
                Event::Exited {
                    attachment,
                    wait_status: 0
                },
                100
            ),
            Ok(StreamEvent::Exited { .. })
        ));
        assert!(matches!(
            state.consume(
                Event::Exited {
                    attachment,
                    wait_status: 0
                },
                100
            ),
            Err(StreamError::ProtocolFault(ProtocolFault::ExitReceipt))
        ));
    }
}
