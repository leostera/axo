use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::fragments::{self, Reassembler};
use crate::host::RelayHost;
use crate::link::{AccountLink, HostLinkStore, host_label};
use axo_protocol::{
    Event, HostKind, LayoutNode, RelayState, RelayStatus, RemoteSessionSnapshot, SessionId,
    ShellActivity, ShellId,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tungstenite::client::IntoClientRequest;
use tungstenite::client_tls_with_config;
use tungstenite::http::HeaderValue;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

const MAX_FRAME_BYTES: usize = fragments::FRAME_BYTES;
const SOCKET_READ_TIMEOUT: Duration = Duration::from_millis(20);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const NOT_LINKED: &str = "This Mac is not linked to an Axo account.";

type RelaySocket = WebSocket<MaybeTlsStream<TcpStream>>;

type RelayStatusObserver = Box<dyn Fn(&RelayStatus) + Send + Sync>;

pub struct RelayControl {
    status: Mutex<RelayStatus>,
    reconnect_requested: AtomicBool,
    /// Told about every status change, outside the status lock (publishes `relay.status`).
    observer: Option<RelayStatusObserver>,
}

impl RelayControl {
    fn new(host_name: String, host_kind: HostKind) -> Self {
        Self {
            status: Mutex::new(RelayStatus {
                state: RelayState::Disconnected,
                connected_since_unix_millis: None,
                host_name,
                host_kind,
                last_error: None,
            }),
            reconnect_requested: AtomicBool::new(false),
            observer: None,
        }
    }

    fn with_observer(mut self, observer: RelayStatusObserver) -> Self {
        self.observer = Some(observer);
        self
    }

    /// Applies `change` and notifies the observer only when the status actually changed.
    fn update(&self, change: impl FnOnce(&mut RelayStatus)) -> io::Result<()> {
        let changed = {
            let mut status = self
                .status
                .lock()
                .map_err(|_| io::Error::other("relay status lock was poisoned"))?;
            let before = status.clone();
            change(&mut status);
            (*status != before).then(|| status.clone())
        };
        if let (Some(status), Some(observer)) = (changed, &self.observer) {
            observer(&status);
        }
        Ok(())
    }

    pub fn snapshot(&self) -> io::Result<RelayStatus> {
        self.status
            .lock()
            .map(|status| status.clone())
            .map_err(|_| io::Error::other("relay status lock was poisoned"))
    }

    pub fn request_connect(&self) -> io::Result<()> {
        self.reconnect_requested.store(true, Ordering::Relaxed);
        self.update(Self::connecting)
    }

    fn connecting(status: &mut RelayStatus) {
        status.state = RelayState::Connecting;
        status.connected_since_unix_millis = None;
        status.last_error = None;
    }

    fn mark_connecting(&self) {
        let _ = self.update(Self::connecting);
    }

    fn mark_connected(&self) {
        let _ = self.update(|status| {
            if status.state != RelayState::Connected {
                status.state = RelayState::Connected;
                status.connected_since_unix_millis = Some(unix_timestamp_millis());
            }
            status.last_error = None;
        });
    }

    fn mark_disconnected(&self, error: impl std::fmt::Display) {
        let _ = self.update(|status| {
            status.state = RelayState::Disconnected;
            status.connected_since_unix_millis = None;
            status.last_error = Some(error.to_string().chars().take(512).collect());
        });
    }
}

pub struct RelayWorker {
    stop: Arc<AtomicBool>,
    control: Arc<RelayControl>,
    thread: Option<JoinHandle<()>>,
}

/// What the relay worker needs from axod.
pub struct RelayDependencies {
    pub host: Arc<dyn RelayHost>,
    pub endpoint: RelayEndpoint,
    pub links: Arc<dyn HostLinkStore>,
    pub credentials: Arc<dyn HostCredentialStore>,
}

impl RelayWorker {
    /// Starts the worker thread. It stays idle until the host is linked, then keeps one
    /// authenticated connection to the relay, reconnecting with backoff.
    pub fn start(dependencies: RelayDependencies) -> io::Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let observed_host = Arc::downgrade(&dependencies.host);
        let control = Arc::new(
            RelayControl::new(host_label(), HostKind::MacOS).with_observer(Box::new(
                move |status| {
                    if let Some(host) = observed_host.upgrade() {
                        host.publish_relay_status(status);
                    }
                },
            )),
        );
        let worker_stop = Arc::clone(&stop);
        let worker_control = Arc::clone(&control);
        let worker = thread::Builder::new()
            .name("axo-cloud-relay".to_owned())
            .spawn(move || run_reconnect_loop(dependencies, worker_stop, worker_control))?;
        Ok(Self {
            stop,
            control,
            thread: Some(worker),
        })
    }

    pub fn stop_handle(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.stop)
    }

    pub fn control_handle(&self) -> Arc<RelayControl> {
        Arc::clone(&self.control)
    }

    pub fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.thread.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for RelayWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

pub fn unavailable_status() -> RelayStatus {
    RelayStatus {
        state: RelayState::Disconnected,
        connected_since_unix_millis: None,
        host_name: host_label(),
        host_kind: HostKind::MacOS,
        last_error: Some("Remote access is unavailable on this Mac.".to_owned()),
    }
}

fn run_reconnect_loop(
    dependencies: RelayDependencies,
    stop: Arc<AtomicBool>,
    control: Arc<RelayControl>,
) {
    let mut retry_delay = Duration::from_secs(1);
    while !stop.load(Ordering::Relaxed) {
        let link = match dependencies.links.load_link() {
            Ok(link) => link,
            Err(error) => {
                control.mark_disconnected(&error);
                log::warn!("event=relay.link_unavailable reason={error}");
                wait_for_reconnect(&control, &stop, retry_delay);
                retry_delay = (retry_delay * 2).min(MAX_RECONNECT_DELAY);
                continue;
            }
        };
        // Only a linked host connects; linking requests a reconnect, which ends this wait.
        let Some(account) = link.account() else {
            control.mark_disconnected(NOT_LINKED);
            wait_for_reconnect(&control, &stop, Duration::from_secs(1));
            retry_delay = Duration::from_secs(1);
            continue;
        };

        control.mark_connecting();
        match run_connection(&dependencies, account, &stop, &control) {
            Ok(()) if stop.load(Ordering::Relaxed) => break,
            Ok(()) => {
                control.mark_disconnected("relay connection ended");
                log::warn!("event=relay.connection_ended");
            }
            Err(error) => {
                control.mark_disconnected(&error);
                log::warn!("event=relay.connection_retry reason={error}");
            }
        }
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let requested_now = wait_for_reconnect(&control, &stop, retry_delay);
        retry_delay = if requested_now {
            Duration::from_secs(1)
        } else {
            (retry_delay * 2).min(MAX_RECONNECT_DELAY)
        };
    }
}

fn wait_for_reconnect(control: &RelayControl, stop: &AtomicBool, delay: Duration) -> bool {
    let until = Instant::now() + delay;
    while Instant::now() < until && !stop.load(Ordering::Relaxed) {
        if control.reconnect_requested.swap(false, Ordering::Relaxed) {
            return true;
        }
        thread::sleep(Duration::from_millis(100));
    }
    false
}

fn run_connection(
    dependencies: &RelayDependencies,
    account: &AccountLink,
    stop: &AtomicBool,
    control: &RelayControl,
) -> io::Result<()> {
    let sessions = &dependencies.host;
    let host_id = sessions.host_id().to_owned();
    let host_generation = sessions.host_generation().to_owned();
    let request = relay_websocket_request(
        &dependencies.endpoint,
        account,
        &host_id,
        dependencies.credentials.as_ref(),
    )?;

    let websocket_config = WebSocketConfig::default()
        .read_buffer_size(8192)
        .write_buffer_size(4096)
        .max_write_buffer_size(131_072)
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let mut socket = connect_websocket(request, websocket_config)?;
    set_read_timeout(&mut socket, SOCKET_READ_TIMEOUT)?;

    let mut request_number = 0_u64;
    // Partial messages die with this socket (RFD0016, Transport).
    let mut reassembler = Reassembler::default();
    rpc_call(
        &mut socket,
        &mut reassembler,
        &mut request_number,
        "axo.protocol.negotiate",
        NegotiateParams {
            protocol_version: 1,
        },
        sessions,
        &host_id,
        &host_generation,
    )?;
    let subscription_id = sessions.subscribe_remote_events()?;
    let snapshots = match sessions.remote_session_snapshots(&current_timestamp()) {
        Ok(snapshots) => snapshots,
        Err(error) => {
            let _ = sessions.unsubscribe_remote_events(&subscription_id);
            return Err(error);
        }
    };
    let label = host_label();
    let registration = HostRegistration {
        protocol_version: 1,
        host_id: &host_id,
        host_generation: &host_generation,
        label: &label,
        host_kind: HostKind::MacOS,
        capabilities: HOST_CAPABILITIES,
        sessions: snapshots,
    };
    if let Err(error) = rpc_call(
        &mut socket,
        &mut reassembler,
        &mut request_number,
        "axo.host.register",
        registration,
        sessions,
        &host_id,
        &host_generation,
    ) {
        let _ = sessions.unsubscribe_remote_events(&subscription_id);
        return Err(error);
    }
    control.mark_connected();

    let result = relay_session(
        &mut socket,
        &mut reassembler,
        &mut request_number,
        RelaySessionContext {
            sessions,
            host_id: &host_id,
            host_generation: &host_generation,
            subscription_id: &subscription_id,
            stop,
            control,
        },
    );
    let _ = sessions.unsubscribe_remote_events(&subscription_id);
    result
}

/// The account-scoped daemon WebSocket, authenticated with the host credential.
fn relay_websocket_request(
    endpoint: &RelayEndpoint,
    account: &AccountLink,
    host_id: &str,
    credentials: &dyn HostCredentialStore,
) -> io::Result<tungstenite::http::Request<()>> {
    let mut secret = credentials.load(account.credential_id())?;
    if secret.len() != 32 {
        secret.fill(0);
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "stored host credential is invalid",
        ));
    }
    let token = crate::pairing::encode_base64url(&secret);
    secret.fill(0);
    let mut request = endpoint
        .daemon_url(account.account_id(), host_id)
        .as_str()
        .into_client_request()
        .map_err(io::Error::other)?;
    let headers = request.headers_mut();
    headers.insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {token}")).map_err(io::Error::other)?,
    );
    headers.insert(
        "X-Axo-Credential-Id",
        HeaderValue::from_str(account.credential_id()).map_err(io::Error::other)?,
    );
    Ok(request)
}

/// One connection attempt. The daemon route authenticates with the host credential and never
/// redirects; a redirect means something in front of it (usually a Cloudflare Access login)
/// is intercepting the route, which is reported instead of followed.
fn connect_websocket(
    request: tungstenite::http::Request<()>,
    config: WebSocketConfig,
) -> io::Result<RelaySocket> {
    let uri = request.uri();
    let host = uri
        .host()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "relay URL has no host"))?;
    let host = host
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .unwrap_or(host);
    let port = uri
        .port_u16()
        .unwrap_or(if uri.scheme_str() == Some("wss") {
            443
        } else {
            80
        });
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let mut connected = None;
    let mut last_error = None;
    for address in (host, port).to_socket_addrs()? {
        let timeout = deadline.saturating_duration_since(Instant::now());
        if timeout.is_zero() {
            break;
        }
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(stream) => {
                connected = Some(stream);
                break;
            }
            Err(error) => last_error = Some(error),
        }
    }
    let stream = connected.ok_or_else(|| {
        last_error.unwrap_or_else(|| {
            io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                "relay host has no usable address",
            )
        })
    })?;
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(CONNECT_TIMEOUT))?;
    stream.set_write_timeout(Some(CONNECT_TIMEOUT))?;

    match client_tls_with_config(request, stream, Some(config), None) {
        Ok((socket, _)) => Ok(socket),
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response)))
            if response.status().is_redirection() =>
        {
            Err(io::Error::other(format!(
                "relay redirected the host connection (HTTP {}); the daemon route must not be behind a login",
                response.status().as_u16()
            )))
        }
        Err(error) => Err(io::Error::other(error)),
    }
}

fn rpc_call(
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

struct RelaySessionContext<'a> {
    sessions: &'a Arc<dyn RelayHost>,
    host_id: &'a str,
    host_generation: &'a str,
    subscription_id: &'a str,
    stop: &'a AtomicBool,
    control: &'a RelayControl,
}

fn relay_session(
    socket: &mut RelaySocket,
    reassembler: &mut Reassembler,
    request_number: &mut u64,
    context: RelaySessionContext<'_>,
) -> io::Result<()> {
    let mut next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
    while !context.stop.load(Ordering::Relaxed)
        && !context.control.reconnect_requested.load(Ordering::Relaxed)
    {
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

        let events = match context
            .sessions
            .next_remote_event(context.subscription_id, Duration::ZERO)?
        {
            // The local queue overflowed; replace the gap with current snapshots.
            Some(Event::SubscriptionLagged) => {
                log::warn!("event=relay.events_lagged action=resync");
                context.sessions.remote_resync_events()?
            }
            Some(event) => vec![event],
            None => Vec::new(),
        };
        for event in events {
            if let Some(notification) =
                host_notification(event, context.host_id, context.host_generation)
            {
                send_json(socket, &notification)?;
            }
        }

        let Some(raw) = read_message(socket, reassembler)? else {
            continue;
        };
        let message: IncomingMessage = serde_json::from_str(&raw)
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

/// One whole message: a frame, or the last fragment's frame completing a larger message. A
/// fragment that breaks the rules ends the connection.
fn read_message(
    socket: &mut RelaySocket,
    reassembler: &mut Reassembler,
) -> io::Result<Option<String>> {
    let Some(raw) = read_text(socket)? else {
        return Ok(None);
    };
    if !raw.contains(fragments::FRAGMENT_METHOD) {
        return Ok(Some(raw));
    }
    let value: Value = serde_json::from_str(&raw)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
    let Some(params) = fragments::fragment_params(&value) else {
        return Ok(Some(raw));
    };
    reassembler
        .receive(params)
        .map_err(|fragments::InvalidFragment(reason)| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("relay sent an invalid fragment: {reason}"),
            )
        })
}

fn read_text(socket: &mut RelaySocket) -> io::Result<Option<String>> {
    match socket.read() {
        Ok(Message::Text(text)) => {
            send_json(
                socket,
                &OutgoingNotification {
                    jsonrpc: JSONRPC,
                    method: "axo.transport.ack",
                    params: TransportAck { frames: 1 },
                },
            )?;
            Ok(Some(text.to_string()))
        }
        Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
            socket.flush().map_err(io::Error::other)?;
            Ok(None)
        }
        Ok(Message::Close(_)) => Err(io::Error::new(
            io::ErrorKind::ConnectionAborted,
            "relay connection closed",
        )),
        Ok(Message::Binary(_)) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "relay sent a binary frame",
        )),
        Ok(Message::Frame(_)) => Ok(None),
        Err(tungstenite::Error::Io(error))
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            ) =>
        {
            Ok(None)
        }
        Err(error) => Err(io::Error::other(error)),
    }
}

/// Sends one message: in one frame, or as fragments when it is larger (RFD0016, Transport).
fn send_json(socket: &mut RelaySocket, value: &impl Serialize) -> io::Result<()> {
    static MESSAGES: AtomicU64 = AtomicU64::new(0);
    let text = serde_json::to_string(value).map_err(io::Error::other)?;
    let message_id = format!(
        "axod-{}-{}",
        std::process::id(),
        MESSAGES.fetch_add(1, Ordering::Relaxed)
    );
    let frames = fragments::split(&text, &message_id).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "relay message exceeds the largest message the relay reassembles",
        )
    })?;
    for frame in frames {
        socket
            .send(Message::Text(frame.into()))
            .map_err(io::Error::other)?;
    }
    Ok(())
}

fn set_read_timeout(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    timeout: Duration,
) -> io::Result<()> {
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => stream.set_read_timeout(Some(timeout)),
        MaybeTlsStream::NativeTls(stream) => stream.get_mut().set_read_timeout(Some(timeout)),
        _ => Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "unsupported WebSocket TLS stream",
        )),
    }
}

/// The largest integer JavaScript clients can represent exactly.
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// Projects a local event for the cloud: remote snapshots carry terminal panes only and no local
/// paths. Events the relay does not forward (focus, workspace and relay status, lag markers)
/// and sequences beyond `MAX_SAFE_INTEGER` yield `None`.
fn host_notification<'a>(
    local_event: Event,
    host_id: &'a str,
    host_generation: &'a str,
) -> Option<OutgoingNotification<'static, HostEventParams<'a>>> {
    let event = match local_event {
        Event::SessionSnapshot { session } => HostEvent::SessionSnapshot {
            snapshot: RemoteSessionSnapshot::from_record(&session, host_id, &current_timestamp()),
        },
        Event::SessionRemoved { session_id } => HostEvent::SessionRemoved { session_id },
        Event::ShellActivity {
            session_id,
            shell_id,
            activity,
        } => HostEvent::ShellActivity {
            session_id,
            shell_id,
            activity,
        },
        Event::TerminalOutput {
            session_id,
            shell_id,
            sequence,
            data,
        } => {
            if sequence > MAX_SAFE_INTEGER {
                return None;
            }
            HostEvent::TerminalOutput {
                session_id,
                shell_id,
                sequence,
                data,
            }
        }
        Event::PiEvent {
            session_id,
            pi_session_id,
            stream_id,
            sequence,
            name,
            data,
        } => {
            if sequence == 0 || sequence > MAX_SAFE_INTEGER {
                return None;
            }
            HostEvent::PiEvent {
                session_id,
                pi_session_id,
                stream_id,
                sequence,
                name,
                data,
            }
        }
        Event::SessionFocus { .. }
        | Event::WorkspaceChanged { .. }
        | Event::RelayStatus { .. }
        | Event::SubscriptionLagged => return None,
    };
    Some(OutgoingNotification {
        jsonrpc: JSONRPC,
        method: "axo.host.event",
        params: HostEventParams {
            kind: "host.data",
            host_id,
            host_generation,
            event,
        },
    })
}

const JSONRPC: &str = "2.0";

#[derive(Serialize)]
struct OutgoingRequest<'a, P> {
    jsonrpc: &'static str,
    id: &'a str,
    method: &'a str,
    params: P,
}

#[derive(Serialize)]
struct OutgoingNotification<'a, P> {
    jsonrpc: &'static str,
    method: &'a str,
    params: P,
}

/// A JSON-RPC request ID chosen by the relay.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(untagged)]
enum RequestId {
    Number(i64),
    Text(String),
}

#[derive(Serialize)]
struct OutgoingResult {
    jsonrpc: &'static str,
    id: RequestId,
    result: RemoteResult,
}

#[derive(Serialize)]
struct OutgoingError {
    jsonrpc: &'static str,
    id: RequestId,
    error: ErrorBody,
}

#[derive(Serialize)]
struct ErrorBody {
    code: i64,
    message: &'static str,
}

#[derive(Serialize)]
#[serde(untagged)]
enum OutgoingResponse {
    Result(Box<OutgoingResult>),
    Error(OutgoingError),
}

/// One message from the relay: a request for this host, or a response to one of ours.
/// `params` stays raw until the method is known (each method has its own parameter type).
#[derive(Deserialize)]
struct IncomingMessage {
    id: Option<RequestId>,
    method: Option<String>,
    #[serde(default)]
    params: Value,
    result: Option<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NegotiateParams {
    protocol_version: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostIdentity<'a> {
    host_id: &'a str,
    host_generation: &'a str,
}

#[derive(Serialize)]
struct TransportAck {
    frames: u32,
}

#[derive(Serialize)]
struct Capability {
    id: &'static str,
    version: u32,
}

const HOST_CAPABILITIES: &[Capability] = &[
    Capability {
        id: "agent.pi",
        version: 1,
    },
    Capability {
        id: "terminal.pty",
        version: 1,
    },
    Capability {
        id: "workspace.filesystem",
        version: 1,
    },
];

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostRegistration<'a> {
    protocol_version: u32,
    host_id: &'a str,
    host_generation: &'a str,
    label: &'a str,
    host_kind: HostKind,
    capabilities: &'static [Capability],
    sessions: Vec<RemoteSessionSnapshot>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostEventParams<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    host_id: &'a str,
    host_generation: &'a str,
    event: HostEvent,
}

/// Events as the cloud relay sees them.
#[derive(Serialize)]
#[serde(tag = "type", rename_all_fields = "camelCase")]
enum HostEvent {
    #[serde(rename = "session.snapshot")]
    SessionSnapshot { snapshot: RemoteSessionSnapshot },
    #[serde(rename = "session.removed")]
    SessionRemoved { session_id: SessionId },
    #[serde(rename = "shell.activity")]
    ShellActivity {
        session_id: SessionId,
        shell_id: ShellId,
        activity: ShellActivity,
    },
    #[serde(rename = "terminal.output")]
    TerminalOutput {
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        data: String,
    },
    #[serde(rename = "pi.event")]
    PiEvent {
        session_id: SessionId,
        pi_session_id: String,
        stream_id: String,
        sequence: u64,
        name: String,
        /// Pi's own payload, forwarded unchanged.
        data: Value,
    },
}

/// Results of `axo.remote.*` calls.
#[derive(Serialize)]
#[serde(untagged, rename_all_fields = "camelCase")]
enum RemoteResult {
    Session {
        session: RemoteSessionSnapshot,
    },
    SessionClosed {
        closed: bool,
        session_id: SessionId,
        replacement: Option<RemoteSessionSnapshot>,
    },
    ShellCreated {
        host_id: String,
        session_id: SessionId,
        shell_id: ShellId,
    },
    ShellClosed {
        closed: bool,
        host_id: String,
        session_id: SessionId,
        shell_id: ShellId,
    },
    Saved {
        saved: bool,
    },
    Workspaces {
        workspaces: Vec<axo_protocol::RemoteWorkspace>,
    },
    InputAccepted {
        accepted: bool,
        sequence: u64,
    },
    ResizeAccepted {
        accepted: bool,
        rows: u32,
        columns: u32,
    },
    PromptAccepted {
        accepted: bool,
    },
    KeyAccepted {
        accepted: bool,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct KeyParams {
    target: HostRef,
    session_id: SessionId,
    key: crate::PiKey,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PromptParams {
    target: HostRef,
    session_id: SessionId,
    text: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HostRef {
    host_id: String,
    host_generation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TargetParams {
    target: HostRef,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionTargetParams {
    target: HostRef,
    session_id: SessionId,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RenameSessionParams {
    target: HostRef,
    session_id: SessionId,
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceSessionTargetParams {
    target: HostRef,
    workspace_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShellTargetParams {
    target: HostRef,
    session_id: SessionId,
    shell_id: ShellId,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LayoutSetParams {
    target: HostRef,
    session_id: SessionId,
    layout: LayoutNode,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalInputParams {
    target: HostRef,
    session_id: SessionId,
    shell_id: ShellId,
    sequence: u64,
    data: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalResizeParams {
    target: HostRef,
    session_id: SessionId,
    shell_id: ShellId,
    rows: u32,
    columns: u32,
}

/// Answers a request from the relay; `None` for anything that is not a request.
fn remote_request_reply(
    message: &IncomingMessage,
    sessions: &Arc<dyn RelayHost>,
    host_id: &str,
    host_generation: &str,
) -> Option<OutgoingResponse> {
    let id = message.id.clone()?;
    let method = message.method.as_deref()?;
    let result = dispatch_remote_call(method, &message.params, sessions, host_id, host_generation);
    Some(match result {
        Ok(result) => OutgoingResponse::Result(Box::new(OutgoingResult {
            jsonrpc: JSONRPC,
            id,
            result,
        })),
        Err((code, message)) => OutgoingResponse::Error(OutgoingError {
            jsonrpc: JSONRPC,
            id,
            error: ErrorBody { code, message },
        }),
    })
}

fn dispatch_remote_call(
    method: &str,
    params: &Value,
    sessions: &Arc<dyn RelayHost>,
    host_id: &str,
    host_generation: &str,
) -> Result<RemoteResult, (i64, &'static str)> {
    macro_rules! parsed {
        ($type:ty) => {
            serde_json::from_value::<$type>(params.clone())
                .map_err(|_| (-32602, "Invalid params"))?
        };
    }
    macro_rules! target_ok {
        ($target:expr) => {
            if $target.host_id != host_id || $target.host_generation != host_generation {
                return Err((-32002, "Stale host"));
            }
        };
    }

    match method {
        "axo.remote.session.create" => {
            let request = parsed!(TargetParams);
            target_ok!(request.target);
            let session = sessions
                .remote_create_session(&current_timestamp())
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Session { session })
        }
        "axo.remote.workspace.session.create" => {
            let request = parsed!(WorkspaceSessionTargetParams);
            target_ok!(request.target);
            let session = sessions
                .remote_create_workspace_session(&request.workspace_id, &current_timestamp())
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Session { session })
        }
        "axo.remote.session.close" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let replacement = sessions
                .remote_close_session(request.session_id, &current_timestamp())
                .map_err(map_operation_error)?;
            Ok(RemoteResult::SessionClosed {
                closed: true,
                session_id: request.session_id,
                replacement,
            })
        }
        "axo.remote.workspace.list" => {
            let request = parsed!(TargetParams);
            target_ok!(request.target);
            let workspaces = sessions.remote_workspaces().map_err(map_operation_error)?;
            Ok(RemoteResult::Workspaces { workspaces })
        }
        "axo.remote.session.rename" => {
            let request = parsed!(RenameSessionParams);
            target_ok!(request.target);
            sessions
                .remote_rename_session(request.session_id, &request.name)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Saved { saved: true })
        }
        "axo.remote.shell.create" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let shell_id = sessions
                .remote_create_shell(request.session_id)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::ShellCreated {
                host_id: host_id.to_owned(),
                session_id: request.session_id,
                shell_id,
            })
        }
        "axo.remote.shell.close" => {
            let request = parsed!(ShellTargetParams);
            target_ok!(request.target);
            sessions
                .remote_close_shell(request.session_id, request.shell_id)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::ShellClosed {
                closed: true,
                host_id: host_id.to_owned(),
                session_id: request.session_id,
                shell_id: request.shell_id,
            })
        }
        "axo.remote.session.layout.set" => {
            let request = parsed!(LayoutSetParams);
            target_ok!(request.target);
            sessions
                .remote_set_layout(request.session_id, request.layout)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::Saved { saved: true })
        }
        "axo.remote.terminal.input" => {
            let request = parsed!(TerminalInputParams);
            target_ok!(request.target);
            sessions
                .remote_terminal_input(
                    request.session_id,
                    request.shell_id,
                    request.sequence,
                    &request.data,
                )
                .map_err(map_operation_error)?;
            Ok(RemoteResult::InputAccepted {
                accepted: true,
                sequence: request.sequence,
            })
        }
        "axo.remote.session.prompt" => {
            let request = parsed!(PromptParams);
            target_ok!(request.target);
            sessions
                .remote_prompt_pi(request.session_id, &request.text)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::PromptAccepted { accepted: true })
        }
        "axo.remote.session.key" => {
            let request = parsed!(KeyParams);
            target_ok!(request.target);
            sessions
                .remote_press_pi_key(request.session_id, request.key)
                .map_err(map_operation_error)?;
            Ok(RemoteResult::KeyAccepted { accepted: true })
        }
        "axo.remote.terminal.resize" => {
            let request = parsed!(TerminalResizeParams);
            target_ok!(request.target);
            sessions
                .remote_terminal_resize(
                    request.session_id,
                    request.shell_id,
                    request.rows,
                    request.columns,
                )
                .map_err(map_operation_error)?;
            Ok(RemoteResult::ResizeAccepted {
                accepted: true,
                rows: request.rows,
                columns: request.columns,
            })
        }
        _ => Err((-32601, "Method not found")),
    }
}

fn map_operation_error(error: io::Error) -> (i64, &'static str) {
    match error.kind() {
        io::ErrorKind::InvalidInput => (-32602, "Invalid params"),
        io::ErrorKind::NotFound => (-32004, "Resource not found"),
        io::ErrorKind::AddrInUse | io::ErrorKind::WouldBlock => (-32006, "Resource busy"),
        _ => (-32003, "Operation failed"),
    }
}

fn unix_timestamp_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

fn current_timestamp() -> String {
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
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn accept_with_timeout(listener: &TcpListener) -> TcpStream {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    // Darwin can inherit O_NONBLOCK from the listener; a read
                    // timeout alone does not turn the accepted socket blocking.
                    stream.set_nonblocking(false).unwrap();
                    return stream;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "timed out waiting for redirected request"
                    );
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("could not accept WebSocket request: {error}"),
            }
        }
    }

    fn read_http_request(stream: &mut TcpStream) -> String {
        let mut request = Vec::new();
        let mut byte = [0_u8; 1];
        while !request.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
            assert!(
                request.len() <= 16 * 1024,
                "WebSocket request headers exceeded the test limit"
            );
        }
        String::from_utf8(request).unwrap()
    }

    #[test]
    fn every_remote_call_the_parity_table_promises_is_dispatched() {
        use axo_protocol::parity::{PARITY, Remote};
        let host: Arc<dyn RelayHost> = Arc::new(crate::link::testing::IdentityOnlyHost);
        for parity in PARITY {
            let Remote::Call(name) = parity.remote else {
                continue;
            };
            // Empty params fail parsing, so no host method runs; "method not found" is the
            // only answer that means the call is not wired.
            let answer = dispatch_remote_call(name, &json!({}), &host, "host", "generation");
            assert!(
                matches!(answer, Err((-32602, _))),
                "{name} is promised but not dispatched: {:?}",
                answer.map(|_| ())
            );
        }
    }

    #[test]
    fn planned_remote_calls_are_not_dispatched_yet() {
        use axo_protocol::parity::{PARITY, Remote};
        let host: Arc<dyn RelayHost> = Arc::new(crate::link::testing::IdentityOnlyHost);
        for parity in PARITY {
            if let Remote::Planned(name) = parity.remote {
                let answer = dispatch_remote_call(name, &json!({}), &host, "host", "generation");
                assert!(
                    matches!(answer, Err((-32601, _))),
                    "{name} is dispatched: move it to Remote::Call"
                );
            }
        }
    }

    #[test]
    fn a_redirected_host_connection_is_reported_not_followed() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let mut initial = accept_with_timeout(&listener);
            initial
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            assert!(read_http_request(&mut initial).starts_with("GET /daemon HTTP/1.1\r\n"));
            initial
                .write_all(
                    b"HTTP/1.1 302 Found\r\nLocation: /cdn-cgi/access/login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
            drop(initial);
            thread::sleep(Duration::from_millis(200));
            assert!(
                listener.accept().is_err(),
                "the redirect must not be followed"
            );
        });

        let request = format!("ws://{address}/daemon")
            .into_client_request()
            .unwrap();
        let error = match connect_websocket(request, WebSocketConfig::default()) {
            Ok(_) => panic!("a redirect must not be accepted as a relay"),
            Err(error) => error,
        };
        assert!(
            error
                .to_string()
                .contains("relay redirected the host connection (HTTP 302)")
        );
        server.join().unwrap();
    }

    #[test]
    fn linked_hosts_connect_to_their_account_route_with_their_credential() {
        let account_id = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";
        let host_id = "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe";
        let credential_id = "0d98fcf1-e8b0-4b46-8ab5-4aa0a11c8a45";
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        crate::credential::HostCredentialStore::store(&credentials, credential_id, &[0xff; 32])
            .unwrap();
        let account = AccountLink::parse(account_id.to_owned(), credential_id.to_owned()).unwrap();

        let request = relay_websocket_request(
            &RelayEndpoint::production(),
            &account,
            host_id,
            &credentials,
        )
        .unwrap();

        assert_eq!(request.uri().scheme_str(), Some("wss"));
        assert_eq!(
            request.uri().path(),
            format!("/api/v1/accounts/{account_id}/hosts/{host_id}/daemon")
        );
        assert_eq!(request.headers()["X-Axo-Credential-Id"], credential_id);
        let authorization = request.headers()["Authorization"].to_str().unwrap();
        assert!(authorization.starts_with("Bearer "));
        assert_eq!(authorization.len(), "Bearer ".len() + 43);
        assert!(request.headers().get("origin").is_none());
        assert!(request.headers().get("Cf-Access-Jwt-Assertion").is_none());

        crate::credential::HostCredentialStore::store(&credentials, credential_id, &[0xff; 16])
            .unwrap();
        assert!(
            relay_websocket_request(
                &RelayEndpoint::production(),
                &account,
                host_id,
                &credentials,
            )
            .is_err(),
            "a credential of the wrong size is never sent"
        );
    }

    #[test]
    fn relay_status_tracks_connection_and_manual_retry_states() {
        let control = RelayControl::new("Test Mac".to_owned(), HostKind::MacOS);
        assert_eq!(control.snapshot().unwrap().state, RelayState::Disconnected);

        control.mark_connected();
        let connected = control.snapshot().unwrap();
        assert_eq!(connected.state, RelayState::Connected);
        assert!(connected.connected_since_unix_millis.is_some());
        assert_eq!(connected.host_name, "Test Mac");

        control.mark_disconnected("HTTP error: 302 Found");
        let disconnected = control.snapshot().unwrap();
        assert_eq!(disconnected.state, RelayState::Disconnected);
        assert_eq!(
            disconnected.last_error.as_deref(),
            Some("HTTP error: 302 Found")
        );

        control.request_connect().unwrap();
        let retrying = control.snapshot().unwrap();
        assert_eq!(retrying.state, RelayState::Connecting);
        assert_eq!(retrying.connected_since_unix_millis, None);
        assert_eq!(retrying.last_error, None);
        assert!(control.reconnect_requested.swap(false, Ordering::Relaxed));
    }

    #[test]
    fn relay_status_observer_sees_only_real_changes() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorder = Arc::clone(&seen);
        let control = RelayControl::new("Test Mac".to_owned(), HostKind::MacOS).with_observer(
            Box::new(move |status| recorder.lock().unwrap().push(status.state)),
        );
        control.mark_connecting();
        control.mark_connecting();
        control.mark_connected();
        let connected_since = control.snapshot().unwrap().connected_since_unix_millis;
        control.mark_connected();
        assert_eq!(
            control.snapshot().unwrap().connected_since_unix_millis,
            connected_since,
            "a repeated connected mark must not reset the connection time"
        );
        control.mark_disconnected("gone");
        assert_eq!(
            *seen.lock().unwrap(),
            [
                RelayState::Connecting,
                RelayState::Connected,
                RelayState::Disconnected
            ]
        );
    }

    /// Projects a wire event the way the relay forwards it, as wire JSON.
    fn project(local_event: Value, host_id: &str, host_generation: &str) -> Option<Value> {
        let event: Event = serde_json::from_value(local_event).unwrap();
        host_notification(event, host_id, host_generation)
            .map(|notification| serde_json::to_value(notification).unwrap())
    }

    #[test]
    fn host_notifications_project_agent_metadata_and_relay_structured_pi_events() {
        let snapshot = project(
            json!({
                "type": "session.snapshot",
                "session": {
                    "id": 17,
                    "sessionUuid": "70fa4f38-71d9-42f8-9013-43b4fd688693",
                    "piSessionFile": "/Users/me/.axo/server/pi-sessions/session.jsonl",
                    "piSessionId": "pi-session-1",
                    "workspaceId": "7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2",
                    "workspaceName": "Axo",
                    "name": "Session 1",
                    "manualName": null,
                    "emoji": "🦀",
                    "lastMessageAt": 1_800_000_100_i64,
                    "createdAt": 1_800_000_000_i64,
                    "status": "working",
                    "initialPwd": "/Users/me/axo",
                    "shells": [
                        {
                            "id": 20, "paneId": "2896bac4-a44b-44b2-9869-f4facf3adf33", "role": "pi",
                            "processId": 100, "initialPwd": "/Users/me/axo", "ptyDevice": "/dev/ttys001",
                            "attachSocketPath": "/Users/me/.axo/server/attach.sock",
                            "available": true, "availabilityReason": null
                        },
                        {
                            "id": 21, "paneId": null, "role": "terminal",
                            "processId": 101, "initialPwd": "/Users/me/axo", "ptyDevice": "/dev/ttys002",
                            "attachSocketPath": "/Users/me/.axo/server/attach.sock",
                            "available": true, "availabilityReason": null
                        }
                    ],
                    "layout": {
                        "kind": "split",
                        "id": "0f00f22d-a24c-4cbc-9196-74dbed95ca80",
                        "direction": "right",
                        "ratio": 0.5,
                        "first": { "kind": "pane", "shellId": 20 },
                        "second": { "kind": "pane", "shellId": 21 }
                    }
                }
            }),
            "70fa4f38-71d9-42f8-9013-43b4fd688693",
            "7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2",
        )
        .unwrap();
        let snapshot = &snapshot["params"]["event"]["snapshot"];
        assert_eq!(snapshot["hasAgent"], true);
        assert_eq!(snapshot["workspaceName"], "Axo");
        assert_eq!(snapshot["emoji"], "🦀");
        assert_eq!(snapshot["status"], "working");
        assert_eq!(snapshot["shells"], json!([{ "shellId": 21 }]));
        assert_eq!(snapshot["layout"], json!({ "kind": "pane", "shellId": 21 }));
        // The phone and web list chats by these, as the Mac's recent list does.
        assert_eq!(snapshot["lastMessageAt"], 1_800_000_100_i64);
        assert_eq!(snapshot["createdAt"], 1_800_000_000_i64);

        let pi_event = project(
            json!({
                "type": "pi.event",
                "sessionId": 17,
                "piSessionId": "pi-session-1",
                "streamId": "0f00f22d-a24c-4cbc-9196-74dbed95ca80",
                "sequence": 1,
                "name": "message.end",
                "data": { "role": "assistant", "text": "Persist me" }
            }),
            "70fa4f38-71d9-42f8-9013-43b4fd688693",
            "7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2",
        )
        .unwrap();
        assert_eq!(pi_event["params"]["event"]["type"], "pi.event");
        assert_eq!(pi_event["params"]["event"]["data"]["text"], "Persist me");
    }
}
