//! Native-only loopback JSON-RPC; browser guards are not application authentication. No terminal bytes or execution replay.
use crate::{
    bootstrap::{Discovery, Publication},
    model::MachineId,
    profiles::Profiles,
    rpc,
    rpc_owner::RpcOwner,
    runtime::Manager,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    io::{self, Cursor, Read, Write},
    net::{TcpListener, TcpStream},
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
    handshake::server::{ErrorResponse, Request, Response},
    protocol::WebSocketConfig,
};

const MAX_CLIENTS: usize = 16;
const HEADER_BYTES: usize = 8192;
const WRITE_DEADLINE: Duration = Duration::from_millis(500);
const REPLY_BYTES: usize = 131072;

pub(crate) struct LocalServer {
    _publication: Publication,
    _terminal: crate::terminal_transport::TerminalServer,
    stopping: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
impl LocalServer {
    pub fn start(
        root: &Path,
        machine: MachineId,
        manager: Arc<Manager>,
        profiles: Profiles,
        stopping: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        Self::start_owned(
            root,
            machine,
            RpcOwner::NativeHarness(manager),
            profiles,
            stopping,
        )
    }
    pub(crate) fn start_central(
        root: &Path,
        machine: MachineId,
        controller: Arc<crate::state::controller::Controller>,
        stopping: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        Self::start_owned(
            root,
            machine,
            RpcOwner::Central(controller),
            Profiles::default(),
            stopping,
        )
    }
    fn start_owned(
        root: &Path,
        machine: MachineId,
        owner: RpcOwner,
        profiles: Profiles,
        stopping: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        let manager = owner.runtime();
        let terminal = crate::terminal_transport::TerminalServer::start(
            root,
            machine,
            manager.clone(),
            stopping.clone(),
        )?;
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let authority = listener.local_addr()?.to_string();
        let discovery = Discovery {
            version: 1,
            protocol_version: 1,
            endpoint: format!("ws://{authority}/v1/rpc"),
            machine_id: machine,
            host_generation: manager.generation,
        };
        let publication = Publication::publish(root, &discovery)?;
        let context = Arc::new(Context {
            machine,
            owner,
            profiles,
            authority,
            stopping: stopping.clone(),
        });
        let worker = thread::Builder::new()
            .name("axod-local-rpc".into())
            .spawn(move || accept_clients(listener, context))?;
        Ok(Self {
            _publication: publication,
            _terminal: terminal,
            stopping,
            worker: Some(worker),
        })
    }
}
impl Drop for LocalServer {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
struct Context {
    machine: MachineId,
    owner: RpcOwner,
    profiles: Profiles,
    authority: String,
    stopping: Arc<AtomicBool>,
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
                    .name("axod-local-client".into())
                    .spawn(move || {
                        let _ = client(stream, &context);
                    })
                {
                    workers.push(worker);
                }
            }
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10))
            }
            Err(_) => {
                context.stopping.store(true, Ordering::SeqCst);
                break;
            }
        }
    }
    drop(listener);
    for worker in workers {
        let _ = worker.join();
    }
}

// Read the HTTP header under an absolute deadline and byte budget before tungstenite's
// parser. Replay preserves any pipelined frame prefix; no handwritten WebSocket framing.
pub(crate) struct UpgradeStream {
    prefix: Cursor<Vec<u8>>,
    pub(crate) tcp: TcpStream,
}
impl Read for UpgradeStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.prefix.position() < self.prefix.get_ref().len() as u64 {
            self.prefix.read(buffer)
        } else {
            self.tcp.read(buffer)
        }
    }
}
impl Write for UpgradeStream {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.tcp.write(buffer)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.tcp.flush()
    }
}
pub(crate) fn bounded_upgrade(mut tcp: TcpStream) -> io::Result<UpgradeStream> {
    tcp.set_nonblocking(false)?;
    tcp.set_write_timeout(Some(WRITE_DEADLINE))?;
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut header = Vec::new();
    while !header.windows(4).any(|value| value == b"\r\n\r\n") {
        if header.len() == HEADER_BYTES {
            return Err(io::Error::other("Upgrade limit"));
        }
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| io::Error::other("Upgrade deadline"))?;
        tcp.set_read_timeout(Some(remaining))?;
        let mut chunk = [0; 1024];
        let limit = chunk.len().min(HEADER_BYTES - header.len());
        let count = tcp.read(&mut chunk[..limit])?;
        if count == 0 {
            return Err(io::Error::other("Upgrade closed"));
        }
        header.extend_from_slice(&chunk[..count]);
    }
    Ok(UpgradeStream {
        prefix: Cursor::new(header),
        tcp,
    })
}
pub(crate) fn native_upgrade(request: &Request, authority: &str, path: &str) -> bool {
    let headers = request.headers();
    request.method() == "GET"
        && request.uri().path() == path
        && request.uri().scheme().is_none()
        && request.uri().authority().is_none()
        && request.uri().query().is_none()
        && !headers.contains_key("origin")
        && headers.get_all("host").iter().count() == 1
        && headers
            .get("host")
            .is_some_and(|value| value.as_bytes() == authority.as_bytes())
}
// tungstenite's Callback ABI requires an unboxed HTTP ErrorResponse.
#[allow(clippy::result_large_err)]
fn client(stream: TcpStream, context: &Context) -> io::Result<()> {
    let stream = bounded_upgrade(stream)?;
    let limits = WebSocketConfig::default()
        .max_message_size(Some(rpc::FRAME_BYTES))
        .max_frame_size(Some(rpc::FRAME_BYTES))
        .write_buffer_size(0)
        .max_write_buffer_size(REPLY_BYTES);
    let mut socket = tungstenite::accept_hdr_with_config(
        stream,
        |request: &Request, response| -> Result<Response, ErrorResponse> {
            if native_upgrade(request, &context.authority, "/v1/rpc")
                && !context.stopping.load(Ordering::SeqCst)
            {
                Ok(response)
            } else {
                Err(tungstenite::http::Response::builder()
                    .status(403)
                    .body(Some("Local admission denied".into()))
                    .expect("Static HTTP response"))
            }
        },
        Some(limits),
    )
    .map_err(|_| io::Error::other("Local admission failed"))?;
    socket
        .get_mut()
        .tcp
        .set_read_timeout(Some(Duration::from_millis(200)))?;
    let mut state = Connection::new();
    while !context.stopping.load(Ordering::SeqCst) {
        match socket.read() {
            Ok(Message::Text(raw)) => {
                if context.stopping.load(Ordering::SeqCst) {
                    break;
                }
                let message = rpc::decode(&raw);
                let count = message.as_ref().map_or(1, |message| message.entries.len());
                state.admit(count)?;
                let reply = state.respond(message, context)?;
                if let Some(reply) = reply {
                    send(&mut socket, &mut state, reply)?;
                }
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                state.admit(1)?;
                socket
                    .flush()
                    .map_err(|_| io::Error::other("Local flush failed"))?;
            }
            Ok(Message::Close(_)) => break,
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) => {}
            _ => return Err(io::Error::other("Local transport rejected")),
        }
    }
    let _ = socket.close(None);
    Ok(())
}

struct Connection {
    negotiated: bool,
    outstanding: VecDeque<usize>,
    bytes: usize,
    window: Instant,
    calls: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Negotiation {
    protocol_version: u16,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Acknowledgement {
    frames: usize,
}
impl Connection {
    fn new() -> Self {
        Self {
            negotiated: false,
            outstanding: VecDeque::new(),
            bytes: 0,
            window: Instant::now(),
            calls: 0,
        }
    }
    fn admit(&mut self, count: usize) -> io::Result<()> {
        if self.window.elapsed() >= Duration::from_secs(1) {
            self.calls = 0;
            self.window = Instant::now();
        }
        self.calls += count;
        if self.calls > 30 {
            return Err(io::Error::other("Local rate limit"));
        }
        Ok(())
    }
    fn ensure_reply_capacity(&self) -> io::Result<()> {
        if self.outstanding.len() >= 32 || self.bytes + rpc::FRAME_BYTES > REPLY_BYTES {
            return Err(io::Error::other("Local delivery capacity"));
        }
        Ok(())
    }
    fn acknowledge(&mut self, call: rpc::Call) -> io::Result<()> {
        let ack: Acknowledgement = serde_json::from_value(call.params.unwrap_or(Value::Null))
            .map_err(|_| io::Error::other("Invalid acknowledgement"))?;
        if call.id.is_some() || ack.frames == 0 || ack.frames > self.outstanding.len() {
            return Err(io::Error::other("Invalid acknowledgement"));
        }
        for _ in 0..ack.frames {
            self.bytes -= self.outstanding.pop_front().expect("Validated credits");
        }
        Ok(())
    }
    fn respond(
        &mut self,
        message: Result<rpc::Message, Value>,
        context: &Context,
    ) -> io::Result<Option<Value>> {
        let message = match message {
            Ok(message) => message,
            Err(reply) => return Ok(Some(reply)),
        };
        let mut replies = Vec::new();
        for entry in message.entries {
            match entry {
                Ok(call) if call.method == "axo.transport.ack" => self.acknowledge(call)?,
                Ok(call) => {
                    // Reserve one worst-case reply frame before dispatch, not after mutation.
                    if call.id.is_some() {
                        self.ensure_reply_capacity()?;
                    }
                    if let Some(reply) = self.dispatch(call, context) {
                        replies.push(reply);
                    }
                }
                Err(reply) => replies.push(reply),
            }
        }
        Ok(rpc::bounded_replies(message.batch, replies))
    }
    fn dispatch(&mut self, call: rpc::Call, context: &Context) -> Option<Value> {
        let id = call.id.clone()?;
        if call.method == "axo.protocol.negotiate" {
            let valid = serde_json::from_value::<Negotiation>(call.params.unwrap_or(Value::Null))
                .is_ok_and(|value| value.protocol_version == 1);
            if !valid {
                return Some(rpc::error(id, -32602, "Invalid params"));
            }
            self.negotiated = true;
            return Some(json!({
                "jsonrpc":"2.0",
                "id":id,
                "result":{"protocolVersion":1,"methods":context.owner.local_methods()}
            }));
        }
        if !self.negotiated {
            return Some(rpc::error(id, -32001, "Negotiation required"));
        }
        context
            .owner
            .dispatch(call, context.machine, &context.profiles.0, true)
    }
}
fn send(
    socket: &mut WebSocket<UpgradeStream>,
    state: &mut Connection,
    reply: Value,
) -> io::Result<()> {
    let raw = serde_json::to_string(&reply)?;
    if raw.len() > rpc::FRAME_BYTES
        || state.outstanding.len() >= 32
        || state.bytes + raw.len() > REPLY_BYTES
    {
        return Err(io::Error::other("Local delivery capacity"));
    }
    state.outstanding.push_back(raw.len());
    state.bytes += raw.len();
    socket
        .send(Message::Text(raw.into()))
        .map_err(|_| io::Error::other("Local write failed; outcome unknown"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pre_dispatch_credit_covers_worst_case_bytes_as_well_as_frame_slots() {
        let mut state = Connection::new();
        state.bytes = REPLY_BYTES - rpc::FRAME_BYTES;
        state.outstanding = VecDeque::from(vec![state.bytes - 36, 36]);
        assert!(state.ensure_reply_capacity().is_ok());
        state.bytes += 1;
        *state.outstanding.front_mut().unwrap() += 1;
        assert!(state.ensure_reply_capacity().is_err());
        state.bytes = 36 * 32;
        state.outstanding = VecDeque::from(vec![36; 32]);
        assert!(state.ensure_reply_capacity().is_err());
    }
}
