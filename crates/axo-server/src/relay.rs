use crate::session::SessionManager;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tungstenite::client::IntoClientRequest;
use tungstenite::client_tls_with_config;
use tungstenite::http::header::LOCATION;
use tungstenite::http::{HeaderValue, StatusCode};
use tungstenite::protocol::WebSocketConfig;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};
use url::{Host, Url};

pub(super) const CONFIG_FILE: &str = "relay.json";
const MAX_CONFIG_BYTES: u64 = 16 * 1024;
const MAX_FRAME_BYTES: usize = 65_536;
const SOCKET_READ_TIMEOUT: Duration = Duration::from_millis(20);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_WEBSOCKET_REDIRECTS: usize = 5;
const MAX_WEBSOCKET_REDIRECT_URL_BYTES: usize = 4_096;

type RelaySocket = WebSocket<MaybeTlsStream<TcpStream>>;
type RelayHandshakeResponse = tungstenite::http::Response<Option<Vec<u8>>>;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawRelayConfig {
    relay_url: String,
    host_label: String,
    host_kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    access: Option<LoopbackAccess>,
    #[serde(default)]
    allow_insecure_loopback: bool,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum LoopbackAccess {
    AccessAssertion { assertion: String },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ConfigureRelayRequest {
    relay_url: String,
    host_label: String,
    host_kind: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RelaySettings {
    enabled: bool,
    relay_url: Option<String>,
    host_label: Option<String>,
    host_kind: Option<String>,
}

#[derive(Debug)]
struct RelayConfig {
    relay_url: Url,
    host_label: String,
    host_kind: String,
    access: Option<LoopbackAccess>,
}

impl std::fmt::Debug for LoopbackAccess {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("AccessAssertion([REDACTED])")
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RelayStatus {
    state: String,
    connected_since_unix_millis: Option<u64>,
    host_name: String,
    host_kind: String,
    last_error: Option<String>,
}

pub(crate) struct RelayControl {
    status: Mutex<RelayStatus>,
    reconnect_requested: AtomicBool,
}

impl RelayControl {
    fn new(host_name: String, host_kind: String) -> Self {
        Self {
            status: Mutex::new(RelayStatus {
                state: "connecting".to_owned(),
                connected_since_unix_millis: None,
                host_name,
                host_kind,
                last_error: None,
            }),
            reconnect_requested: AtomicBool::new(false),
        }
    }

    pub(crate) fn snapshot(&self) -> io::Result<RelayStatus> {
        self.status
            .lock()
            .map(|status| status.clone())
            .map_err(|_| io::Error::other("relay status lock was poisoned"))
    }

    pub(crate) fn request_connect(&self) -> io::Result<()> {
        self.reconnect_requested.store(true, Ordering::Relaxed);
        let mut status = self
            .status
            .lock()
            .map_err(|_| io::Error::other("relay status lock was poisoned"))?;
        status.state = "connecting".to_owned();
        status.connected_since_unix_millis = None;
        status.last_error = None;
        Ok(())
    }

    fn mark_connecting(&self) {
        if let Ok(mut status) = self.status.lock() {
            status.state = "connecting".to_owned();
            status.connected_since_unix_millis = None;
            status.last_error = None;
        }
    }

    fn mark_connected(&self) {
        if let Ok(mut status) = self.status.lock() {
            status.state = "connected".to_owned();
            status.connected_since_unix_millis = Some(unix_timestamp_millis());
            status.last_error = None;
        }
    }

    fn mark_disconnected(&self, error: impl std::fmt::Display) {
        if let Ok(mut status) = self.status.lock() {
            status.state = "disconnected".to_owned();
            status.connected_since_unix_millis = None;
            status.last_error = Some(error.to_string().chars().take(512).collect());
        }
    }
}

pub(crate) struct RelayWorker {
    stop: Arc<AtomicBool>,
    control: Arc<RelayControl>,
    thread: Option<JoinHandle<()>>,
}

impl RelayWorker {
    pub(crate) fn start(
        sessions: Arc<SessionManager>,
        server_directory: &Path,
    ) -> io::Result<Option<Self>> {
        let config_path = server_directory.join(CONFIG_FILE);
        let Some(config) = load_runtime_config(&config_path)? else {
            return Ok(None);
        };
        let stop = Arc::new(AtomicBool::new(false));
        let control = Arc::new(RelayControl::new(
            config.host_label.clone(),
            config.host_kind.clone(),
        ));
        let worker_stop = Arc::clone(&stop);
        let worker_control = Arc::clone(&control);
        let worker = thread::Builder::new()
            .name("axo-cloud-relay".to_owned())
            .spawn(move || run_reconnect_loop(config, sessions, worker_stop, worker_control))?;
        Ok(Some(Self {
            stop,
            control,
            thread: Some(worker),
        }))
    }

    pub(crate) fn stop_handle(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.stop)
    }

    pub(crate) fn control_handle(&self) -> Arc<RelayControl> {
        Arc::clone(&self.control)
    }

    pub(crate) fn shutdown(&mut self) {
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

#[cfg(test)]
fn load_config(path: &Path) -> io::Result<Option<RelayConfig>> {
    let Some(raw) = read_raw_config(path)? else {
        return Ok(None);
    };
    parse_config(raw).map(Some)
}

fn load_runtime_config(path: &Path) -> io::Result<Option<RelayConfig>> {
    let bundled_url = match std::env::var("AXO_RELAY_URL") {
        Ok(url) if !url.trim().is_empty() => Some(url),
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "bundled relay URL must not be empty",
            ));
        }
        Err(std::env::VarError::NotPresent) => None,
        Err(std::env::VarError::NotUnicode(_)) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "bundled relay URL is not valid Unicode",
            ));
        }
    };

    let raw = match read_raw_config(path) {
        Ok(Some(mut raw)) => {
            if let Some(url) = &bundled_url {
                raw.relay_url.clone_from(url);
                raw.access = None;
                raw.allow_insecure_loopback = false;
            }
            Some(raw)
        }
        Ok(None) => bundled_url.map(default_raw_config),
        Err(error) if bundled_url.is_some() => {
            log::warn!("event=relay.legacy_config_ignored reason={error}; using bundled relay URL");
            bundled_url.map(default_raw_config)
        }
        Err(error) => return Err(error),
    };
    raw.map(parse_config).transpose()
}

fn default_raw_config(relay_url: String) -> RawRelayConfig {
    RawRelayConfig {
        relay_url,
        host_label: local_host_name(),
        host_kind: "macos".to_owned(),
        access: None,
        allow_insecure_loopback: false,
    }
}

fn local_host_name() -> String {
    let mut bytes = [0_u8; 256];
    // SAFETY: bytes is writable storage for gethostname's NUL-terminated output.
    if unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len()) } == 0 {
        let length = bytes
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(bytes.len());
        if let Ok(name) = std::str::from_utf8(&bytes[..length]) {
            let name = name.trim_end_matches('.').trim();
            if !name.is_empty() && name.len() <= 128 && !name.chars().any(char::is_control) {
                return name.to_owned();
            }
        }
    }
    "This Mac".to_owned()
}

pub(crate) fn unavailable_status() -> RelayStatus {
    RelayStatus {
        state: "disconnected".to_owned(),
        connected_since_unix_millis: None,
        host_name: local_host_name(),
        host_kind: "macos".to_owned(),
        last_error: Some("axod has no remote relay endpoint configured.".to_owned()),
    }
}

fn read_raw_config(path: &Path) -> io::Result<Option<RawRelayConfig>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "relay configuration must be a regular, non-symlink file",
        ));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "relay configuration permissions must be 0600 or stricter",
        ));
    }
    if metadata.len() > MAX_CONFIG_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "relay configuration exceeds its size limit",
        ));
    }

    let mut source = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_CONFIG_BYTES + 1).read_to_end(&mut source)?;
    if source.len() as u64 > MAX_CONFIG_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "relay configuration exceeds its size limit",
        ));
    }
    serde_json::from_slice(&source).map(Some).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "relay configuration is malformed",
        )
    })
}

fn parse_config(raw: RawRelayConfig) -> io::Result<RelayConfig> {
    let mut relay_url = Url::parse(&raw.relay_url)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "relay URL is invalid"))?;
    if relay_url.username() != ""
        || relay_url.password().is_some()
        || relay_url.query().is_some()
        || relay_url.fragment().is_some()
        || !matches!(relay_url.path(), "" | "/")
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "relay URL must be an origin without credentials, path, query, or fragment",
        ));
    }

    match relay_url.scheme() {
        "https" => relay_url
            .set_scheme("wss")
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid secure relay URL"))?,
        "wss" => {}
        "http" | "ws" if raw.allow_insecure_loopback && is_loopback(&relay_url) => {
            if relay_url.scheme() == "http" {
                relay_url.set_scheme("ws").map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidInput, "invalid local relay URL")
                })?;
            }
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "relay URL must use https/wss; insecure transport is allowed only for loopback tests",
            ));
        }
    }

    if raw.host_label.trim().is_empty()
        || raw.host_label.len() > 128
        || raw.host_label.chars().any(char::is_control)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "host label must contain 1 to 128 printable characters",
        ));
    }
    if raw.host_kind.is_empty()
        || raw.host_kind.len() > 64
        || !raw.host_kind.as_bytes()[0].is_ascii_lowercase()
        || !raw
            .host_kind
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "host kind must be a lowercase protocol slug",
        ));
    }

    if let Some(LoopbackAccess::AccessAssertion { assertion }) = &raw.access
        && (assertion.trim().is_empty() || assertion.len() > 8192 || !is_loopback(&relay_url))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "raw Access assertions are supported only for isolated loopback tests",
        ));
    }

    Ok(RelayConfig {
        relay_url,
        host_label: raw.host_label,
        host_kind: raw.host_kind,
        access: raw.access,
    })
}

pub(crate) fn settings(path: &Path) -> io::Result<RelaySettings> {
    let Some(raw) = read_raw_config(path)? else {
        return Ok(RelaySettings {
            enabled: false,
            relay_url: None,
            host_label: None,
            host_kind: None,
        });
    };
    parse_config(raw.clone())?;
    Ok(RelaySettings {
        enabled: true,
        relay_url: Some(raw.relay_url),
        host_label: Some(raw.host_label),
        host_kind: Some(raw.host_kind),
    })
}

pub(crate) fn configure(path: &Path, request: ConfigureRelayRequest) -> io::Result<RelaySettings> {
    let config = RawRelayConfig {
        relay_url: request.relay_url,
        host_label: request.host_label,
        host_kind: request.host_kind,
        access: None,
        allow_insecure_loopback: false,
    };
    parse_config(config.clone())?;
    write_raw_config(path, &config)?;
    settings(path)
}

pub(crate) fn disable(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn write_raw_config(path: &Path, config: &RawRelayConfig) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => {}
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "relay configuration must be a regular file",
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "relay path has no parent"))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary_path = parent.join(format!(".relay.json.{}.{}.tmp", std::process::id(), nonce));
    let write_result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary_path)?;
        serde_json::to_writer(&mut file, config)
            .map_err(|_| io::Error::other("could not encode remote access settings"))?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary_path, path)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    write_result
}

fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    }
}

fn run_reconnect_loop(
    config: RelayConfig,
    sessions: Arc<SessionManager>,
    stop: Arc<AtomicBool>,
    control: Arc<RelayControl>,
) {
    let mut retry_delay = Duration::from_secs(1);
    while !stop.load(Ordering::Relaxed) {
        control.mark_connecting();
        match run_connection(&config, &sessions, &stop, &control) {
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
        let until = Instant::now() + retry_delay;
        let mut requested_now = false;
        while Instant::now() < until && !stop.load(Ordering::Relaxed) {
            if control.reconnect_requested.swap(false, Ordering::Relaxed) {
                requested_now = true;
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        retry_delay = if requested_now {
            Duration::from_secs(1)
        } else {
            (retry_delay * 2).min(MAX_RECONNECT_DELAY)
        };
    }
}

fn run_connection(
    config: &RelayConfig,
    sessions: &Arc<SessionManager>,
    stop: &AtomicBool,
    control: &RelayControl,
) -> io::Result<()> {
    let host_id = sessions.host_id().to_owned();
    let host_generation = sessions.host_generation().to_owned();
    let request = relay_websocket_request(config, &host_id)?;

    let websocket_config = WebSocketConfig::default()
        .read_buffer_size(8192)
        .write_buffer_size(4096)
        .max_write_buffer_size(131_072)
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let (mut socket, _) = connect_websocket(request, websocket_config)?;
    set_read_timeout(&mut socket, SOCKET_READ_TIMEOUT)?;

    let mut request_number = 0_u64;
    rpc_call(
        &mut socket,
        &mut request_number,
        "axo.protocol.negotiate",
        json!({ "protocolVersion": 1 }),
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
    let registration = json!({
        "protocolVersion": 1,
        "hostId": host_id,
        "hostGeneration": host_generation,
        "label": config.host_label,
        "hostKind": config.host_kind,
        "sessions": snapshots,
    });
    if let Err(error) = rpc_call(
        &mut socket,
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
        &mut request_number,
        sessions,
        &host_id,
        &host_generation,
        &subscription_id,
        stop,
    );
    let _ = sessions.unsubscribe_remote_events(&subscription_id);
    result
}

fn relay_websocket_request(
    config: &RelayConfig,
    host_id: &str,
) -> io::Result<tungstenite::http::Request<()>> {
    let url = host_websocket_url(&config.relay_url, host_id)?;
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(io::Error::other)?;
    if let Some(LoopbackAccess::AccessAssertion { assertion }) = &config.access {
        request.headers_mut().insert(
            "Cf-Access-Jwt-Assertion",
            HeaderValue::from_str(assertion).map_err(io::Error::other)?,
        );
    }
    Ok(request)
}

enum WebSocketConnectAttempt {
    Connected(RelaySocket, RelayHandshakeResponse),
    Redirect {
        request: tungstenite::http::Request<()>,
        status: StatusCode,
        host: String,
    },
}

fn connect_websocket(
    mut request: tungstenite::http::Request<()>,
    config: WebSocketConfig,
) -> io::Result<(RelaySocket, RelayHandshakeResponse)> {
    let mut redirects_followed = 0;
    let mut redirect_host = None;

    loop {
        let attempt = match connect_websocket_once(request, config) {
            Ok(attempt) => attempt,
            Err(error) => {
                return match redirect_host {
                    Some(host) => Err(io::Error::other(format!(
                        "WebSocket redirect target {host} failed: {error}"
                    ))),
                    None => Err(error),
                };
            }
        };

        match attempt {
            WebSocketConnectAttempt::Connected(socket, response) => return Ok((socket, response)),
            WebSocketConnectAttempt::Redirect {
                request: redirected_request,
                status,
                host,
            } => {
                if redirects_followed == MAX_WEBSOCKET_REDIRECTS {
                    return Err(io::Error::other(format!(
                        "WebSocket redirect limit exceeded after HTTP {status}"
                    )));
                }
                log::info!("event=relay.websocket_redirect status={status} host={host}");
                redirects_followed += 1;
                redirect_host = Some(host);
                request = redirected_request;
            }
        }
    }
}

fn connect_websocket_once(
    request: tungstenite::http::Request<()>,
    config: WebSocketConfig,
) -> io::Result<WebSocketConnectAttempt> {
    let current_url = Url::parse(&request.uri().to_string()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "relay WebSocket URL is invalid",
        )
    })?;
    let access_assertion = request.headers().get("Cf-Access-Jwt-Assertion").cloned();
    let uri = request.uri();
    let host = uri
        .host()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "relay URL has no host"))?;
    let host = host
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .unwrap_or(host);
    let scheme = uri.scheme_str().unwrap_or_default();
    let port = uri.port_u16().unwrap_or(match scheme {
        "ws" => 80,
        "wss" => 443,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "relay URL has an unsupported WebSocket scheme",
            ));
        }
    });
    let addresses = (host, port).to_socket_addrs()?;
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let mut connected = None;
    let mut last_error = None;
    for address in addresses {
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
        Ok((socket, response)) => Ok(WebSocketConnectAttempt::Connected(socket, response)),
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response))) => {
            let status = response.status();
            let Some(target_url) = websocket_redirect_target(&current_url, &response)? else {
                return Err(io::Error::other(tungstenite::Error::Http(response)));
            };
            let same_origin = same_web_origin(&current_url, &target_url);
            let mut redirected_request = target_url
                .as_str()
                .into_client_request()
                .map_err(io::Error::other)?;
            if same_origin && let Some(assertion) = access_assertion {
                redirected_request
                    .headers_mut()
                    .insert("Cf-Access-Jwt-Assertion", assertion);
            }
            let host = target_url.host_str().unwrap_or("unknown host").to_owned();
            Ok(WebSocketConnectAttempt::Redirect {
                request: redirected_request,
                status,
                host,
            })
        }
        Err(error) => Err(io::Error::other(error)),
    }
}

fn websocket_redirect_target(
    current_url: &Url,
    response: &RelayHandshakeResponse,
) -> io::Result<Option<Url>> {
    let status = response.status();
    if !matches!(status.as_u16(), 301 | 302 | 303 | 307 | 308) {
        return Ok(None);
    }

    let location = response.headers().get(LOCATION).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("HTTP {status} redirect did not include a Location header"),
        )
    })?;
    let location = location.to_str().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "WebSocket redirect Location header was not valid text",
        )
    })?;
    if location.len() > MAX_WEBSOCKET_REDIRECT_URL_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "WebSocket redirect Location exceeded its size limit",
        ));
    }

    let mut target_url = current_url.join(location).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "WebSocket redirect Location was not a valid URL",
        )
    })?;
    match target_url.scheme() {
        "https" => target_url.set_scheme("wss").map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid secure WebSocket redirect",
            )
        })?,
        "http" => target_url.set_scheme("ws").map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid local WebSocket redirect",
            )
        })?,
        "wss" | "ws" => {}
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "WebSocket redirect used an unsupported URL scheme",
            ));
        }
    }

    if !target_url.username().is_empty() || target_url.password().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "WebSocket redirect URL must not contain credentials",
        ));
    }
    if current_url.scheme() == "wss" && target_url.scheme() != "wss" {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "secure WebSocket redirect attempted to downgrade transport",
        ));
    }
    if target_url.scheme() == "ws" && !is_loopback(&target_url) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "insecure WebSocket redirects are allowed only for loopback tests",
        ));
    }

    target_url.set_fragment(None);
    Ok(Some(target_url))
}

fn same_web_origin(left: &Url, right: &Url) -> bool {
    left.scheme() == right.scheme()
        && left.host_str() == right.host_str()
        && left.port_or_known_default() == right.port_or_known_default()
}

fn host_websocket_url(base: &Url, host_id: &str) -> io::Result<Url> {
    let mut url = base.clone();
    url.set_path(&format!("/v1/hosts/{host_id}/daemon"));
    if url.scheme() != "wss" && url.scheme() != "ws" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "relay URL did not resolve to a WebSocket scheme",
        ));
    }
    Ok(url)
}

fn rpc_call(
    socket: &mut RelaySocket,
    request_number: &mut u64,
    method: &str,
    params: Value,
    sessions: &Arc<SessionManager>,
    host_id: &str,
    host_generation: &str,
) -> io::Result<Value> {
    *request_number = request_number.saturating_add(1);
    let id = format!("axod-{}", *request_number);
    send_json(
        socket,
        &json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }),
    )?;
    loop {
        let Some(raw) = read_text(socket)? else {
            continue;
        };
        let response: Value = serde_json::from_str(&raw)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
        if response.get("id") == Some(&Value::String(id.clone())) {
            if let Some(result) = response.get("result") {
                return Ok(result.clone());
            }
            return Err(io::Error::other("relay RPC request was rejected"));
        }
        if let Some(reply) = remote_request_reply(&response, sessions, host_id, host_generation) {
            send_json(socket, &reply)?;
        }
    }
}

fn relay_session(
    socket: &mut RelaySocket,
    request_number: &mut u64,
    sessions: &Arc<SessionManager>,
    host_id: &str,
    host_generation: &str,
    subscription_id: &str,
    stop: &AtomicBool,
) -> io::Result<()> {
    let mut next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
    while !stop.load(Ordering::Relaxed) {
        if Instant::now() >= next_heartbeat {
            *request_number = request_number.saturating_add(1);
            send_json(
                socket,
                &json!({
                    "jsonrpc": "2.0",
                    "id": format!("axod-{}", *request_number),
                    "method": "axo.host.heartbeat",
                    "params": { "hostId": host_id, "hostGeneration": host_generation }
                }),
            )?;
            next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
        }

        let notification = sessions
            .next_remote_event(subscription_id, Duration::ZERO)?
            .and_then(|event| host_notification(event, host_id, host_generation));
        if let Some(notification) = notification {
            send_json(socket, &notification)?;
        }

        let Some(raw) = read_text(socket)? else {
            continue;
        };
        let message: Value = serde_json::from_str(&raw)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid relay JSON"))?;
        if let Some(reply) = remote_request_reply(&message, sessions, host_id, host_generation) {
            send_json(socket, &reply)?;
        }
    }
    let _ = socket.close(None);
    Ok(())
}

fn read_text(socket: &mut RelaySocket) -> io::Result<Option<String>> {
    match socket.read() {
        Ok(Message::Text(text)) => {
            send_json(
                socket,
                &json!({ "jsonrpc": "2.0", "method": "axo.transport.ack", "params": { "frames": 1 } }),
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

fn send_json(socket: &mut RelaySocket, value: &Value) -> io::Result<()> {
    let text = serde_json::to_string(value).map_err(io::Error::other)?;
    if text.len() > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "relay message exceeds its frame limit",
        ));
    }
    socket
        .send(Message::Text(text.into()))
        .map_err(io::Error::other)
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

fn host_notification(local_event: Value, host_id: &str, host_generation: &str) -> Option<Value> {
    let event_type = local_event.get("type")?.as_str()?;
    let event = match event_type {
        "session.snapshot" => {
            let session = local_event.get("session")?.as_object()?;
            let session_id = session.get("id")?.as_i64()?;
            let shells = session.get("shells")?.as_array()?;
            let shell_ids = shells
                .iter()
                .map(|shell| Some(json!({ "shellId": shell.get("id")?.as_i64()? })))
                .collect::<Option<Vec<_>>>()?;
            json!({
                "type": "session.snapshot",
                "snapshot": {
                    "hostId": host_id,
                    "sessionId": session_id,
                    "shells": shell_ids,
                    "layout": session.get("layout")?,
                    "updatedAt": current_timestamp(),
                }
            })
        }
        "session.removed" => json!({
            "type": "session.removed",
            "sessionId": local_event.get("sessionId")?.as_i64()?,
        }),
        "shell.activity" => json!({
            "type": "shell.activity",
            "sessionId": local_event.get("sessionId")?.as_i64()?,
            "shellId": local_event.get("shellId")?.as_i64()?,
            "activity": local_event.get("activity")?.as_str()?,
        }),
        "terminal.output" => {
            let sequence = local_event.get("sequence")?.as_u64()?;
            if sequence > 9_007_199_254_740_991 {
                return None;
            }
            json!({
                "type": "terminal.output",
                "sessionId": local_event.get("sessionId")?.as_i64()?,
                "shellId": local_event.get("shellId")?.as_i64()?,
                "sequence": sequence,
                "data": local_event.get("data")?.as_str()?,
            })
        }
        _ => return None,
    };
    Some(json!({
        "jsonrpc": "2.0",
        "method": "axo.host.event",
        "params": {
            "type": "host.data",
            "hostId": host_id,
            "hostGeneration": host_generation,
            "event": event,
        }
    }))
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
    session_id: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShellTargetParams {
    target: HostRef,
    session_id: i64,
    shell_id: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LayoutSetParams {
    target: HostRef,
    session_id: i64,
    layout: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalInputParams {
    target: HostRef,
    session_id: i64,
    shell_id: i64,
    sequence: u64,
    data: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalResizeParams {
    target: HostRef,
    session_id: i64,
    shell_id: i64,
    rows: u32,
    columns: u32,
}

fn remote_request_reply(
    message: &Value,
    sessions: &SessionManager,
    host_id: &str,
    host_generation: &str,
) -> Option<Value> {
    let id = message.get("id")?.clone();
    let method = message.get("method")?.as_str()?;
    let params = message.get("params").unwrap_or(&Value::Null);
    let result = dispatch_remote_call(method, params, sessions, host_id, host_generation);
    Some(match result {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, message)) => {
            json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
        }
    })
}

fn dispatch_remote_call(
    method: &str,
    params: &Value,
    sessions: &SessionManager,
    host_id: &str,
    host_generation: &str,
) -> Result<Value, (i64, &'static str)> {
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
            Ok(json!({ "session": session }))
        }
        "axo.remote.session.close" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let replacement = sessions
                .remote_close_session(request.session_id, &current_timestamp())
                .map_err(map_operation_error)?;
            Ok(
                json!({ "closed": true, "sessionId": request.session_id, "replacement": replacement }),
            )
        }
        "axo.remote.shell.create" => {
            let request = parsed!(SessionTargetParams);
            target_ok!(request.target);
            let shell_id = sessions
                .remote_create_shell(request.session_id)
                .map_err(map_operation_error)?;
            Ok(json!({ "hostId": host_id, "sessionId": request.session_id, "shellId": shell_id }))
        }
        "axo.remote.shell.close" => {
            let request = parsed!(ShellTargetParams);
            target_ok!(request.target);
            sessions
                .remote_close_shell(request.session_id, request.shell_id)
                .map_err(map_operation_error)?;
            Ok(
                json!({ "closed": true, "hostId": host_id, "sessionId": request.session_id, "shellId": request.shell_id }),
            )
        }
        "axo.remote.session.layout.set" => {
            let request = parsed!(LayoutSetParams);
            target_ok!(request.target);
            sessions
                .remote_set_layout(request.session_id, request.layout)
                .map_err(map_operation_error)?;
            Ok(json!({ "saved": true }))
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
            Ok(json!({ "accepted": true, "sequence": request.sequence }))
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
            Ok(json!({ "accepted": true, "rows": request.rows, "columns": request.columns }))
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
    use std::fs;
    use std::net::TcpListener;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    fn temporary_directory() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "axo-relay-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ))
    }

    fn config(access: Option<LoopbackAccess>, relay_url: &str, insecure: bool) -> RelayConfig {
        parse_config(RawRelayConfig {
            relay_url: relay_url.to_owned(),
            host_label: "Test host".to_owned(),
            host_kind: "macos".to_owned(),
            access,
            allow_insecure_loopback: insecure,
        })
        .unwrap()
    }

    fn accept_with_timeout(listener: &TcpListener) -> TcpStream {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match listener.accept() {
                Ok((stream, _)) => return stream,
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
    fn websocket_client_follows_redirect_before_accepting_the_relay() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let mut initial = accept_with_timeout(&listener);
            initial
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let initial_request = read_http_request(&mut initial);
            assert!(initial_request.starts_with("GET /daemon HTTP/1.1\r\n"));
            initial
                .write_all(
                    b"HTTP/1.1 302 Found\r\nLocation: /login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
            drop(initial);

            let mut redirected = accept_with_timeout(&listener);
            redirected
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let redirected_request = read_http_request(&mut redirected);
            assert!(redirected_request.starts_with("GET /login HTTP/1.1\r\n"));
            redirected
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .unwrap();
        });

        let request = format!("ws://{address}/daemon")
            .into_client_request()
            .unwrap();
        let error = match connect_websocket(request, WebSocketConfig::default()) {
            Ok(_) => panic!("an HTTP login page must not be accepted as a WebSocket relay"),
            Err(error) => error,
        };
        assert!(
            error
                .to_string()
                .contains("WebSocket redirect target 127.0.0.1 failed: HTTP error: 200 OK")
        );
        server.join().unwrap();
    }

    #[test]
    fn remote_access_settings_write_only_connection_metadata() {
        let directory = temporary_directory();
        fs::create_dir(&directory).unwrap();
        let path = directory.join(CONFIG_FILE);
        let settings = configure(
            &path,
            ConfigureRelayRequest {
                relay_url: "https://api.example.test".to_owned(),
                host_label: "My Mac".to_owned(),
                host_kind: "macos".to_owned(),
            },
        )
        .unwrap();

        assert!(settings.enabled);
        assert_eq!(settings.host_label.as_deref(), Some("My Mac"));
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let stored_config = fs::read_to_string(&path).unwrap();
        assert!(!stored_config.contains("clientId"));
        assert!(!stored_config.contains("clientSecret"));
        assert!(!stored_config.contains("access"));
        assert!(load_config(&path).unwrap().unwrap().access.is_none());

        let updated = configure(
            &path,
            ConfigureRelayRequest {
                relay_url: "https://api.example.test".to_owned(),
                host_label: "Renamed Mac".to_owned(),
                host_kind: "macos".to_owned(),
            },
        )
        .unwrap();
        assert_eq!(updated.host_label.as_deref(), Some("Renamed Mac"));

        disable(&path).unwrap();
        assert!(!path.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn invalid_remote_access_settings_do_not_write_config() {
        let directory = temporary_directory();
        fs::create_dir(&directory).unwrap();
        let path = directory.join(CONFIG_FILE);
        let invalid = ConfigureRelayRequest {
            relay_url: "http://api.example.test".to_owned(),
            host_label: "My Mac".to_owned(),
            host_kind: "macos".to_owned(),
        };
        assert!(configure(&path, invalid).is_err());
        assert!(!path.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn direct_relay_config_uses_tls_for_remote_hosts() {
        assert_eq!(
            config(None, "https://api.example.test", false)
                .relay_url
                .scheme(),
            "wss"
        );
        assert!(
            parse_config(RawRelayConfig {
                relay_url: "http://example.test".to_owned(),
                host_label: "Test host".to_owned(),
                host_kind: "macos".to_owned(),
                access: None,
                allow_insecure_loopback: true,
            })
            .is_err()
        );
    }

    #[test]
    fn relay_status_tracks_connection_and_manual_retry_states() {
        let control = RelayControl::new("Test Mac".to_owned(), "macos".to_owned());
        assert_eq!(control.snapshot().unwrap().state, "connecting");

        control.mark_connected();
        let connected = control.snapshot().unwrap();
        assert_eq!(connected.state, "connected");
        assert!(connected.connected_since_unix_millis.is_some());
        assert_eq!(connected.host_name, "Test Mac");

        control.mark_disconnected("HTTP error: 302 Found");
        let disconnected = control.snapshot().unwrap();
        assert_eq!(disconnected.state, "disconnected");
        assert_eq!(
            disconnected.last_error.as_deref(),
            Some("HTTP error: 302 Found")
        );

        control.request_connect().unwrap();
        let retrying = control.snapshot().unwrap();
        assert_eq!(retrying.state, "connecting");
        assert_eq!(retrying.connected_since_unix_millis, None);
        assert_eq!(retrying.last_error, None);
        assert!(control.reconnect_requested.swap(false, Ordering::Relaxed));
    }

    #[test]
    fn production_relay_requests_call_the_api_without_access_headers() {
        let config = config(None, "https://api.example.test", false);
        let request = relay_websocket_request(&config, "host-fixture").unwrap();

        assert_eq!(request.uri().scheme_str(), Some("wss"));
        assert_eq!(request.uri().host(), Some("api.example.test"));
        assert!(request.headers().get("cf-access-token").is_none());
        assert!(request.headers().get("cf-access-client-id").is_none());
        assert!(request.headers().get("cf-access-client-secret").is_none());
        assert!(request.headers().get("origin").is_none());
    }

    #[test]
    fn raw_access_assertions_are_limited_to_loopback() {
        let assertion = Some(LoopbackAccess::AccessAssertion {
            assertion: "fixture-only".to_owned(),
        });
        assert_eq!(
            config(assertion, "http://127.0.0.1:8787", true)
                .relay_url
                .scheme(),
            "ws"
        );
        let assertion = Some(LoopbackAccess::AccessAssertion {
            assertion: "fixture-only".to_owned(),
        });
        assert!(
            parse_config(RawRelayConfig {
                relay_url: "https://api.example.test".to_owned(),
                host_label: "Test host".to_owned(),
                host_kind: "macos".to_owned(),
                access: assertion,
                allow_insecure_loopback: false,
            })
            .is_err()
        );
    }

    #[test]
    fn relay_configuration_rejects_group_readable_files_and_symlinks() {
        let directory = std::env::temp_dir().join(format!(
            "axo-relay-config-{}-{}",
            std::process::id(),
            current_timestamp().replace(':', "-")
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("relay.json");
        let target = directory.join("target.json");
        fs::write(&path, "{}").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            load_config(&path).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );

        fs::write(&target, "{}").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(load_config(&path).is_err());
        let _ = fs::remove_dir_all(directory);
    }
}
