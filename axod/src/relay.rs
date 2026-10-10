//! Outbound authenticated relay adapter. Reconnect never replays execution calls.
use crate::{model::*, private_file::read_private, rpc, runtime::Manager};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{self, Write},
    net::{TcpStream, ToSocketAddrs},
    os::unix::fs::OpenOptionsExt,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use tungstenite::{
    Message, WebSocket, client::IntoClientRequest, protocol::WebSocketConfig,
    stream::MaybeTlsStream,
};
use url::Url;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    relay_url: String,
    label: String,
    #[serde(default)]
    allow_insecure_loopback: bool,
    credentials: Credentials,
    #[serde(default)]
    profiles: BTreeMap<String, TerminalLaunch>,
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Credentials {
    ServiceToken {
        client_id: String,
        client_secret: String,
    },
    AccessAssertion {
        assertion: String,
    },
}
impl Config {
    pub fn read(path: &Path) -> io::Result<Self> {
        let bytes = read_private(path, rpc::FRAME_BYTES)?;
        let config: Self = serde_json::from_slice(&bytes)
            .map_err(|_| io::Error::other("Invalid relay configuration"))?;
        config.base_url()?;
        config.validate_credentials()?;
        if config.label.is_empty()
            || config.label.encode_utf16().count() > 80
            || config.profiles.len() > 16
            || config.profiles.keys().any(|key| {
                key.is_empty()
                    || key.len() > 64
                    || !key
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
            })
        {
            return Err(io::Error::other("Invalid relay label/profiles"));
        }
        crate::profiles::Profiles::validate(config.profiles.clone())?;
        Ok(config)
    }
    pub(crate) fn profiles(&self) -> crate::profiles::Profiles {
        crate::profiles::Profiles(self.profiles.clone())
    }
    pub(crate) fn use_profiles(&mut self, profiles: &crate::profiles::Profiles) -> io::Result<()> {
        if !self.profiles.is_empty()
            && serde_json::to_value(&self.profiles)? != serde_json::to_value(&profiles.0)?
        {
            return Err(io::Error::other("Conflicting local/cloud profiles"));
        }
        self.profiles = profiles.0.clone();
        Ok(())
    }
    fn validate_credentials(&self) -> io::Result<()> {
        let values: Vec<&str> = match &self.credentials {
            Credentials::ServiceToken {
                client_id,
                client_secret,
            } => vec![client_id, client_secret],
            Credentials::AccessAssertion { assertion } => vec![assertion],
        };
        for value in values {
            if value.is_empty()
                || value.len() > 8192
                || tungstenite::http::HeaderValue::from_str(value).is_err()
            {
                return Err(io::Error::other("Invalid relay credential"));
            }
        }
        Ok(())
    }
    fn base_url(&self) -> io::Result<Url> {
        let url = Url::parse(&self.relay_url).map_err(|_| io::Error::other("Invalid relay URL"))?;
        let local = self.allow_insecure_loopback
            && url.scheme() == "ws"
            && matches!(url.host_str(), Some("127.0.0.1" | "[::1]"));
        if (url.scheme() != "wss" && !local)
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.path() != "/"
        {
            return Err(io::Error::other(
                "Relay requires WSS (explicit numeric loopback exception only)",
            ));
        }
        Ok(url)
    }
}
pub fn machine_id(root: &Path) -> io::Result<MachineId> {
    let path = root.join("machine-id.json");
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
    {
        Ok(mut file) => {
            let identity = MachineId::new();
            file.write_all(&serde_json::to_vec(&identity)?)?;
            file.sync_all()?;
            File::open(root)?.sync_all()?;
            Ok(identity)
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            serde_json::from_slice(&read_private(&path, 128)?)
                .map_err(|_| io::Error::other("Invalid persisted machine identity"))
        }
        Err(error) => Err(error),
    }
}
type Socket = WebSocket<MaybeTlsStream<TcpStream>>;
fn connect(config: &Config, machine: MachineId) -> io::Result<Socket> {
    let mut url = config.base_url()?;
    let machine: Value = serde_json::to_value(machine)?;
    url.set_path(&format!(
        "/v1/machines/{}/daemon",
        machine.as_str().expect("UUID string")
    ));
    let host = url
        .host_str()
        .ok_or_else(|| io::Error::other("Relay host required"))?;
    let port = url
        .port_or_known_default()
        .ok_or_else(|| io::Error::other("Relay port required"))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut stream = None;
    for address in (host.trim_start_matches('[').trim_end_matches(']'), port)
        .to_socket_addrs()?
        .take(4)
    {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        if let Ok(value) = TcpStream::connect_timeout(&address, remaining) {
            stream = Some(value);
            break;
        }
    }
    let stream = stream.ok_or_else(|| io::Error::other("Relay unavailable"))?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(|_| io::Error::other("Relay request invalid"))?;
    let headers = request.headers_mut();
    match &config.credentials {
        Credentials::ServiceToken {
            client_id,
            client_secret,
        } => {
            headers.insert(
                "CF-Access-Client-Id",
                client_id
                    .parse()
                    .map_err(|_| io::Error::other("Invalid credential"))?,
            );
            headers.insert(
                "CF-Access-Client-Secret",
                client_secret
                    .parse()
                    .map_err(|_| io::Error::other("Invalid credential"))?,
            );
        }
        Credentials::AccessAssertion { assertion } => {
            headers.insert(
                "Cf-Access-Jwt-Assertion",
                assertion
                    .parse()
                    .map_err(|_| io::Error::other("Invalid credential"))?,
            );
        }
    }
    // client_tls does not follow redirects and thereby cannot leak Access secrets to another host.
    let limits = WebSocketConfig::default()
        .max_message_size(Some(rpc::FRAME_BYTES))
        .max_frame_size(Some(rpc::FRAME_BYTES))
        .write_buffer_size(0)
        .max_write_buffer_size(131072);
    let (mut socket, _) = tungstenite::client_tls_with_config(request, stream, Some(limits), None)
        .map_err(|error| {
            io::Error::other(match error {
                tungstenite::HandshakeError::Failure(tungstenite::Error::Tls(_)) => {
                    "Relay TLS failed"
                }
                tungstenite::HandshakeError::Failure(tungstenite::Error::Http(_)) => {
                    "Relay HTTP rejected"
                }
                tungstenite::HandshakeError::Failure(tungstenite::Error::Io(error))
                    if error.kind() == io::ErrorKind::InvalidData =>
                {
                    match error
                        .get_ref()
                        .and_then(|cause| cause.downcast_ref::<rustls::Error>())
                    {
                        Some(rustls::Error::InvalidCertificate(
                            rustls::CertificateError::UnknownIssuer,
                        )) => "Relay certificate issuer unknown",
                        Some(rustls::Error::InvalidCertificate(
                            rustls::CertificateError::BadSignature,
                        )) => "Relay certificate signature invalid",
                        Some(rustls::Error::InvalidCertificate(rustls::CertificateError::UnsupportedSignatureAlgorithmContext { .. } | rustls::CertificateError::UnsupportedSignatureAlgorithmForPublicKeyContext { .. })) => "Relay certificate algorithm unsupported",
                        Some(rustls::Error::InvalidCertificate(_)) => "Relay certificate rejected",
                        _ => "Relay TLS data rejected",
                    }
                }
                tungstenite::HandshakeError::Failure(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                    ) =>
                {
                    "Relay handshake timeout"
                }
                tungstenite::HandshakeError::Interrupted(_) => "Relay handshake interrupted",
                tungstenite::HandshakeError::Failure(tungstenite::Error::Protocol(_)) => {
                    "Relay handshake protocol rejected"
                }
                _ => "Relay handshake failed",
            })
        })?;
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => {
            stream.set_read_timeout(Some(Duration::from_millis(200)))?
        }
        MaybeTlsStream::Rustls(stream) => stream
            .sock
            .set_read_timeout(Some(Duration::from_millis(200)))?,
        _ => return Err(io::Error::other("Unsupported relay stream")),
    }
    Ok(socket)
}
fn send(socket: &mut Socket, value: Value) -> io::Result<()> {
    let raw = serde_json::to_string(&value)?;
    if raw.len() > rpc::FRAME_BYTES {
        return Err(io::Error::other("Relay response limit"));
    }
    socket
        .send(Message::Text(raw.into()))
        .map_err(|_| io::Error::other("Relay write failed"))
}
fn call(socket: &mut Socket, id: &str, method: &str, params: Value) -> io::Result<()> {
    send(
        socket,
        json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
    )
}
fn receive(socket: &mut Socket) -> io::Result<Option<String>> {
    match socket.read() {
        Ok(Message::Text(raw)) => {
            send(
                socket,
                json!({"jsonrpc":"2.0","method":"axo.transport.ack","params":{"frames":1}}),
            )?;
            Ok(Some(raw.to_string()))
        }
        Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
            socket
                .flush()
                .map_err(|_| io::Error::other("Relay flush failed"))?;
            Ok(None)
        }
        Err(tungstenite::Error::Io(error))
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            ) =>
        {
            Ok(None)
        }
        _ => Err(io::Error::other("Relay disconnected")),
    }
}
fn handshake_reply(socket: &mut Socket, id: &str, stopping: &AtomicBool) -> io::Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !stopping.load(Ordering::SeqCst) && Instant::now() < deadline {
        if let Some(raw) = receive(socket)? {
            let value: Value =
                serde_json::from_str(&raw).map_err(|_| io::Error::other("Invalid relay reply"))?;
            if value["jsonrpc"] != "2.0"
                || value["id"] != id
                || value.get("error").is_some()
                || value.get("result").is_none()
            {
                return Err(io::Error::other("Relay admission rejected"));
            }
            return Ok(value["result"].clone());
        }
    }
    Err(io::Error::other("Relay admission deadline"))
}
fn session(
    config: &Config,
    machine: MachineId,
    manager: &Manager,
    stopping: &AtomicBool,
) -> io::Result<()> {
    let mut socket = connect(config, machine)?;
    call(
        &mut socket,
        "negotiate",
        "axo.protocol.negotiate",
        json!({"protocolVersion":1}),
    )?;
    let negotiated = handshake_reply(&mut socket, "negotiate", stopping)?;
    if negotiated["protocolVersion"] != 1 {
        return Err(io::Error::other("Relay protocol mismatch"));
    }
    call(
        &mut socket,
        "register",
        "axo.machine.register",
        json!({"protocolVersion":1,"machineId":machine,"hostGeneration":manager.generation,"label":config.label}),
    )?;
    let registered = handshake_reply(&mut socket, "register", stopping)?;
    let lease_id = registered["leaseId"]
        .as_str()
        .and_then(|value| uuid::Uuid::parse_str(value).ok())
        .ok_or_else(|| io::Error::other("Invalid route lease"))?;
    if registered["hostGeneration"] != serde_json::to_value(manager.generation)? {
        return Err(io::Error::other("Wrong route generation"));
    }
    let mut heartbeat = Instant::now();
    let mut heartbeat_pending = false;
    while !stopping.load(Ordering::SeqCst) {
        if heartbeat.elapsed() >= Duration::from_secs(10) {
            if heartbeat_pending {
                return Err(io::Error::other("Relay heartbeat deadline"));
            }
            call(
                &mut socket,
                "heartbeat",
                "axo.machine.heartbeat",
                json!({"leaseId":lease_id}),
            )?;
            heartbeat = Instant::now();
            heartbeat_pending = true;
        }
        let Some(raw) = receive(&mut socket)? else {
            continue;
        };
        if stopping.load(Ordering::SeqCst) {
            break;
        }
        let value: Value =
            serde_json::from_str(&raw).map_err(|_| io::Error::other("Invalid relay frame"))?;
        if value.get("method").is_none() && value["id"] == "heartbeat" {
            if !heartbeat_pending
                || value["result"]["leaseId"] != lease_id.to_string()
                || value.get("error").is_some()
            {
                return Err(io::Error::other("Heartbeat rejected"));
            }
            heartbeat_pending = false;
            continue;
        }
        let message = rpc::decode(&raw).map_err(|_| io::Error::other("Invalid relay call"))?;
        let mut replies = Vec::new();
        for entry in message.entries {
            match entry {
                Ok(call) => {
                    if let Some(reply) = rpc::dispatch(call, manager, machine, &config.profiles) {
                        replies.push(reply);
                    }
                }
                Err(reply) => replies.push(reply),
            }
        }
        if let Some(reply) = rpc::bounded_replies(message.batch, replies) {
            send(&mut socket, reply)?;
        }
    }
    let _ = socket.close(None);
    Ok(())
}
pub fn run(config: Config, machine: MachineId, manager: Arc<Manager>, stopping: Arc<AtomicBool>) {
    let mut last_failure = None;
    while !stopping.load(Ordering::SeqCst) {
        // Only fixed classifications are logged, and only when the failure changes.
        if let Err(error) = session(&config, machine, &manager, &stopping) {
            let reason = match error.to_string().as_str() {
                "Relay TLS failed" => "tls",
                "Relay HTTP rejected" => "http_admission",
                "Relay handshake failed" => "handshake",
                "Relay TLS data rejected" => "tls_data",
                "Relay certificate issuer unknown" => "certificate_issuer",
                "Relay certificate signature invalid" => "certificate_signature",
                "Relay certificate rejected" => "certificate",
                "Relay certificate algorithm unsupported" => "certificate_algorithm",
                "Relay handshake timeout" => "handshake_timeout",
                "Relay handshake interrupted" => "handshake_interrupted",
                "Relay handshake protocol rejected" => "handshake_protocol",
                "Relay admission rejected" => "protocol_admission",
                "Relay admission deadline" => "protocol_deadline",
                "Relay heartbeat deadline" => "heartbeat_deadline",
                _ => "transport",
            };
            if last_failure != Some(reason) {
                eprintln!("axod relay unavailable: {reason}");
                last_failure = Some(reason);
            }
        } else {
            last_failure = None;
        }
        for _ in 0..10 {
            if stopping.load(Ordering::SeqCst) {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}
