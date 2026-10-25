use crate::credential::HostCredentialStore;
use crate::host::RelayHost;
use axo_protocol::{
    Event, HostKind, LayoutNode, RelayState, RelayStatus, RemoteSessionSnapshot, SessionId,
    ShellActivity, ShellId,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
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

pub const CONFIG_FILE: &str = "relay.json";
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
    account_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    credential_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pending_credential_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pending_host_generation: Option<String>,
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
pub struct ConfigureRelayRequest {
    relay_url: String,
    host_label: String,
    host_kind: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelaySettings {
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
    account_id: Option<String>,
    credential_id: Option<String>,
    pending_credential_id: Option<String>,
    access: Option<LoopbackAccess>,
}

impl std::fmt::Debug for LoopbackAccess {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("AccessAssertion([REDACTED])")
    }
}

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

impl RelayWorker {
    pub fn start(
        sessions: Arc<dyn RelayHost>,
        server_directory: &Path,
        credentials: Arc<dyn HostCredentialStore>,
    ) -> io::Result<Self> {
        let config_path = server_directory.join(CONFIG_FILE);
        let stop = Arc::new(AtomicBool::new(false));
        let observed_sessions = Arc::downgrade(&sessions);
        let control = Arc::new(
            RelayControl::new(local_host_name(), HostKind::MacOS).with_observer(Box::new(
                move |status| {
                    if let Some(sessions) = observed_sessions.upgrade() {
                        sessions.publish_relay_status(status);
                    }
                },
            )),
        );
        let worker_stop = Arc::clone(&stop);
        let worker_control = Arc::clone(&control);
        let worker = thread::Builder::new()
            .name("axo-cloud-relay".to_owned())
            .spawn(move || {
                run_reconnect_loop(
                    config_path,
                    sessions,
                    worker_stop,
                    worker_control,
                    credentials,
                )
            })?;
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
        account_id: None,
        credential_id: None,
        pending_credential_id: None,
        pending_host_generation: None,
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

pub fn unavailable_status() -> RelayStatus {
    RelayStatus {
        state: RelayState::Disconnected,
        connected_since_unix_millis: None,
        host_name: local_host_name(),
        host_kind: HostKind::MacOS,
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

    match (&raw.account_id, &raw.credential_id) {
        (None, None) => {}
        (Some(account_id), Some(credential_id))
            if is_uuid(account_id) && is_uuid(credential_id) => {}
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "paired relay configuration requires valid account and credential identifiers",
            ));
        }
    }
    match (&raw.pending_credential_id, &raw.pending_host_generation) {
        (None, None) => {}
        (Some(credential_id), Some(host_generation))
            if is_uuid(credential_id)
                && is_uuid(host_generation)
                && raw.credential_id.as_deref() != Some(credential_id) => {}
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "pending pairing identifiers are invalid",
            ));
        }
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
        account_id: raw.account_id,
        credential_id: raw.credential_id,
        pending_credential_id: raw.pending_credential_id,
        access: raw.access,
    })
}

pub fn settings(path: &Path) -> io::Result<RelaySettings> {
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

pub fn link_host(
    path: &Path,
    raw_code: &str,
    sessions: &dyn RelayHost,
    credentials: &dyn HostCredentialStore,
) -> io::Result<String> {
    crate::pairing::validate_code(raw_code)?;
    let mut raw = match read_raw_config(path)? {
        Some(raw) => raw,
        None => {
            let relay_url = std::env::var("AXO_RELAY_URL").map_err(|_| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "Axo relay endpoint is not configured",
                )
            })?;
            default_raw_config(relay_url)
        }
    };
    if let Ok(relay_url) = std::env::var("AXO_RELAY_URL") {
        if relay_url.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Axo relay endpoint is invalid",
            ));
        }
        raw.relay_url = relay_url;
        raw.allow_insecure_loopback = false;
    }
    raw.access = None;
    let config = parse_config(raw.clone())?;
    let (credential_id, pending_host_generation) = match (
        raw.pending_credential_id.clone(),
        raw.pending_host_generation.clone(),
    ) {
        (Some(credential_id), Some(host_generation)) => (credential_id, host_generation),
        (None, None) => {
            let credential_id = crate::pairing::prepare_credential(credentials)?;
            let host_generation = sessions.host_generation().to_owned();
            raw.pending_credential_id = Some(credential_id.clone());
            raw.pending_host_generation = Some(host_generation.clone());
            if let Err(error) = write_raw_config(path, &raw) {
                let _ = credentials.delete(&credential_id);
                return Err(error);
            }
            (credential_id, host_generation)
        }
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pending pairing state is incomplete",
            ));
        }
    };
    let result = crate::pairing::redeem(
        crate::pairing::RedemptionRequest {
            relay_url: &config.relay_url,
            code: raw_code,
            host_id: sessions.host_id(),
            host_generation: &pending_host_generation,
            credential_id: &credential_id,
            label: &config.host_label,
            host_kind: &config.host_kind,
        },
        credentials,
    )?;

    let previous_credential_id = raw.credential_id.clone();
    raw.account_id = Some(result.account_id);
    raw.credential_id = Some(result.credential_id.clone());
    raw.pending_credential_id = None;
    raw.pending_host_generation = None;
    write_raw_config(path, &raw)?;
    if let Some(previous_credential_id) = previous_credential_id
        && previous_credential_id != result.credential_id
    {
        let _ = credentials.delete(&previous_credential_id);
    }
    Ok(raw.host_label)
}

pub fn configure(
    path: &Path,
    request: ConfigureRelayRequest,
    credentials: &dyn HostCredentialStore,
) -> io::Result<RelaySettings> {
    let existing = read_raw_config(path)?;
    if existing
        .as_ref()
        .is_some_and(|raw| raw.account_id.is_some())
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "paired hosts must be revoked from the Axo account before reconfiguration",
        ));
    }
    let pending_credential_id = existing.and_then(|raw| raw.pending_credential_id);
    let config = RawRelayConfig {
        relay_url: request.relay_url,
        host_label: request.host_label,
        host_kind: request.host_kind,
        account_id: None,
        credential_id: None,
        pending_credential_id: None,
        pending_host_generation: None,
        access: None,
        allow_insecure_loopback: false,
    };
    parse_config(config.clone())?;
    write_raw_config(path, &config)?;
    if let Some(credential_id) = pending_credential_id {
        let _ = credentials.delete(&credential_id);
    }
    settings(path)
}

pub fn disable(path: &Path, credentials: &dyn HostCredentialStore) -> io::Result<()> {
    let credential_ids = read_raw_config(path)?
        .map(|raw| [raw.credential_id, raw.pending_credential_id])
        .unwrap_or_default();
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let mut delete_error = None;
    for credential_id in credential_ids.into_iter().flatten() {
        if let Err(error) = credentials.delete(&credential_id) {
            delete_error.get_or_insert(error);
        }
    }
    if let Some(error) = delete_error {
        return Err(error);
    }
    Ok(())
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

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

pub(crate) fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    }
}

fn run_reconnect_loop(
    config_path: PathBuf,
    sessions: Arc<dyn RelayHost>,
    stop: Arc<AtomicBool>,
    control: Arc<RelayControl>,
    credentials: Arc<dyn HostCredentialStore>,
) {
    let mut retry_delay = Duration::from_secs(1);
    while !stop.load(Ordering::Relaxed) {
        let config = match load_runtime_config(&config_path) {
            Ok(Some(config)) => config,
            Ok(None) => {
                control.mark_disconnected("This Mac is not linked to an Axo account.");
                wait_for_reconnect(&control, &stop, Duration::from_secs(1));
                retry_delay = Duration::from_secs(1);
                continue;
            }
            Err(error) => {
                control.mark_disconnected(&error);
                log::warn!("event=relay.configuration_unavailable reason={error}");
                wait_for_reconnect(&control, &stop, retry_delay);
                retry_delay = (retry_delay * 2).min(MAX_RECONNECT_DELAY);
                continue;
            }
        };

        if config.account_id.is_none() && config.pending_credential_id.is_some() {
            control.mark_disconnected("Pairing is ready to resume from Remote Access Settings.");
            wait_for_reconnect(&control, &stop, Duration::from_secs(1));
            retry_delay = Duration::from_secs(1);
            continue;
        }

        control.mark_connecting();
        match run_connection(&config, &sessions, &stop, &control, credentials.as_ref()) {
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
    config: &RelayConfig,
    sessions: &Arc<dyn RelayHost>,
    stop: &AtomicBool,
    control: &RelayControl,
    credentials: &dyn HostCredentialStore,
) -> io::Result<()> {
    let host_id = sessions.host_id().to_owned();
    let host_generation = sessions.host_generation().to_owned();
    let request = relay_websocket_request(config, &host_id, credentials)?;

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
    let registration = HostRegistration {
        protocol_version: 1,
        host_id: &host_id,
        host_generation: &host_generation,
        label: &config.host_label,
        host_kind: &config.host_kind,
        capabilities: HOST_CAPABILITIES,
        sessions: snapshots,
    };
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

fn relay_websocket_request(
    config: &RelayConfig,
    host_id: &str,
    credentials: &dyn HostCredentialStore,
) -> io::Result<tungstenite::http::Request<()>> {
    let (url, credential) = match (&config.account_id, &config.credential_id) {
        (Some(account_id), Some(credential_id)) => {
            let mut secret = credentials.load(credential_id)?;
            if secret.len() != 32 {
                secret.fill(0);
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "stored host credential is invalid",
                ));
            }
            let token = crate::pairing::encode_base64url(&secret);
            secret.fill(0);
            (
                account_host_websocket_url(&config.relay_url, account_id, host_id)?,
                Some((credential_id.as_str(), token)),
            )
        }
        (None, None) => (host_websocket_url(&config.relay_url, host_id)?, None),
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "paired relay configuration is incomplete",
            ));
        }
    };
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(io::Error::other)?;
    if let Some((credential_id, token)) = credential {
        request.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}")).map_err(io::Error::other)?,
        );
        request.headers_mut().insert(
            "X-Axo-Credential-Id",
            HeaderValue::from_str(credential_id).map_err(io::Error::other)?,
        );
    } else if let Some(LoopbackAccess::AccessAssertion { assertion }) = &config.access {
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

fn account_host_websocket_url(base: &Url, account_id: &str, host_id: &str) -> io::Result<Url> {
    if !is_uuid(account_id) || !is_uuid(host_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "paired host routing identifier is invalid",
        ));
    }
    let mut url = base.clone();
    url.set_path(&format!(
        "/api/v1/accounts/{account_id}/hosts/{host_id}/daemon"
    ));
    // `parse_config` admits `ws` only for a loopback relay in an isolated test that opted in.
    if url.scheme() != "wss" && !(url.scheme() == "ws" && is_loopback(&url)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "paired relay URL must use secure WebSockets",
        ));
    }
    Ok(url)
}

fn rpc_call(
    socket: &mut RelaySocket,
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
        let Some(raw) = read_text(socket)? else {
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

        let Some(raw) = read_text(socket)? else {
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

fn send_json(socket: &mut RelaySocket, value: &impl Serialize) -> io::Result<()> {
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
    host_kind: &'a str,
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
    InputAccepted {
        accepted: bool,
        sequence: u64,
    },
    ResizeAccepted {
        accepted: bool,
        rows: u32,
        columns: u32,
    },
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
            account_id: None,
            credential_id: None,
            pending_credential_id: None,
            pending_host_generation: None,
            access,
            allow_insecure_loopback: insecure,
        })
        .unwrap()
    }

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
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        let settings = configure(
            &path,
            ConfigureRelayRequest {
                relay_url: "https://api.example.test".to_owned(),
                host_label: "My Mac".to_owned(),
                host_kind: "macos".to_owned(),
            },
            &credentials,
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
            &credentials,
        )
        .unwrap();
        assert_eq!(updated.host_label.as_deref(), Some("Renamed Mac"));

        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        disable(&path, &credentials).unwrap();
        assert!(!path.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn disabling_remote_access_removes_an_unfinished_pairing_credential() {
        let directory = temporary_directory();
        fs::create_dir(&directory).unwrap();
        let path = directory.join(CONFIG_FILE);
        let credential_id = "0d98fcf1-e8b0-4b46-8ab5-4aa0a11c8a45";
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        crate::credential::HostCredentialStore::store(&credentials, credential_id, &[0x5a; 32])
            .unwrap();
        write_raw_config(
            &path,
            &RawRelayConfig {
                relay_url: "https://axo.leostera.dev".to_owned(),
                host_label: "Test host".to_owned(),
                host_kind: "macos".to_owned(),
                account_id: None,
                credential_id: None,
                pending_credential_id: Some(credential_id.to_owned()),
                pending_host_generation: Some("f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230".to_owned()),
                access: None,
                allow_insecure_loopback: false,
            },
        )
        .unwrap();

        disable(&path, &credentials).unwrap();

        assert!(!path.exists());
        assert!(crate::credential::HostCredentialStore::load(&credentials, credential_id).is_err());
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
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        assert!(configure(&path, invalid, &credentials).is_err());
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
                account_id: None,
                credential_id: None,
                pending_credential_id: None,
                pending_host_generation: None,
                access: None,
                allow_insecure_loopback: true,
            })
            .is_err()
        );
    }

    #[test]
    fn pending_pairing_config_pins_the_original_host_generation() {
        let credential_id = "0d98fcf1-e8b0-4b46-8ab5-4aa0a11c8a45";
        let host_generation = "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230";
        let config = parse_config(RawRelayConfig {
            relay_url: "https://axo.leostera.dev".to_owned(),
            host_label: "Test host".to_owned(),
            host_kind: "macos".to_owned(),
            account_id: None,
            credential_id: None,
            pending_credential_id: Some(credential_id.to_owned()),
            pending_host_generation: Some(host_generation.to_owned()),
            access: None,
            allow_insecure_loopback: false,
        })
        .unwrap();
        assert_eq!(config.pending_credential_id.as_deref(), Some(credential_id));

        assert!(
            parse_config(RawRelayConfig {
                relay_url: "https://axo.leostera.dev".to_owned(),
                host_label: "Test host".to_owned(),
                host_kind: "macos".to_owned(),
                account_id: None,
                credential_id: None,
                pending_credential_id: Some(credential_id.to_owned()),
                pending_host_generation: None,
                access: None,
                allow_insecure_loopback: false,
            })
            .is_err()
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

    #[test]
    fn production_relay_requests_call_the_api_without_access_headers() {
        let config = config(None, "https://api.example.test", false);
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        let request = relay_websocket_request(&config, "host-fixture", &credentials).unwrap();

        assert_eq!(request.uri().scheme_str(), Some("wss"));
        assert_eq!(request.uri().host(), Some("api.example.test"));
        assert!(request.headers().get("cf-access-token").is_none());
        assert!(request.headers().get("cf-access-client-id").is_none());
        assert!(request.headers().get("cf-access-client-secret").is_none());
        assert!(request.headers().get("origin").is_none());
    }

    #[test]
    fn paired_relay_requests_use_account_route_and_keychain_credential() {
        let account_id = "b6b4cc11-b541-40ca-8aa5-b84276fa9939";
        let host_id = "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe";
        let credential_id = "0d98fcf1-e8b0-4b46-8ab5-4aa0a11c8a45";
        let credentials = crate::credential::testing::MemoryCredentialStore::default();
        crate::credential::HostCredentialStore::store(&credentials, credential_id, &[0xff; 32])
            .unwrap();
        let config = parse_config(RawRelayConfig {
            relay_url: "https://axo.leostera.dev".to_owned(),
            host_label: "Test host".to_owned(),
            host_kind: "macos".to_owned(),
            account_id: Some(account_id.to_owned()),
            credential_id: Some(credential_id.to_owned()),
            pending_credential_id: None,
            pending_host_generation: None,
            access: None,
            allow_insecure_loopback: false,
        })
        .unwrap();

        let request = relay_websocket_request(&config, host_id, &credentials).unwrap();

        assert_eq!(
            request.uri().path(),
            format!("/api/v1/accounts/{account_id}/hosts/{host_id}/daemon")
        );
        assert_eq!(request.headers()["X-Axo-Credential-Id"], credential_id);
        let authorization = request.headers()["Authorization"].to_str().unwrap();
        assert!(authorization.starts_with("Bearer "));
        assert_eq!(authorization.len(), "Bearer ".len() + 43);
        assert!(request.headers().get("Cf-Access-Jwt-Assertion").is_none());
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
                account_id: None,
                credential_id: None,
                pending_credential_id: None,
                pending_host_generation: None,
                access: assertion,
                allow_insecure_loopback: false,
            })
            .is_err()
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
