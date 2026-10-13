//! Bounded, synchronous public Axo RPC client. No execution retry or target selection.
pub use crate::bootstrap::Discovery;
use crate::{private_file::read_private, rpc};
use serde_json::{Value, json};
use std::{
    io::{self, Read, Write},
    net::{Ipv4Addr, SocketAddr, TcpStream},
    path::Path,
    time::{Duration, Instant},
};
use tungstenite::{Message, WebSocket, protocol::WebSocketConfig};

const CONNECT_DEADLINE: Duration = Duration::from_secs(2);
const CALL_DEADLINE: Duration = Duration::from_secs(12);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClientError {
    InvalidDiscovery,
    InvalidRequest,
    Offline,
    Protocol,
    /// Some/all request bytes may have crossed the transport. Never retry implicitly.
    OutcomeUnknown,
    Rpc(i32),
}
impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rpc(code) => write!(f, "Axo RPC error {code}"),
            Self::InvalidDiscovery => f.write_str("Invalid private Axo discovery"),
            Self::InvalidRequest => f.write_str("Invalid Axo request"),
            Self::Offline => f.write_str("Axo daemon unavailable"),
            Self::Protocol => f.write_str("Axo protocol negotiation failed"),
            Self::OutcomeUnknown => {
                f.write_str("Outcome unknown; reconcile commandId, do not replay")
            }
        }
    }
}
impl std::error::Error for ClientError {}

/// The entire operation has a deadline, not a fresh timeout for every incoming byte.
struct DeadlineStream {
    stream: TcpStream,
    deadline: Instant,
}
impl DeadlineStream {
    fn remaining(&self) -> io::Result<Duration> {
        self.deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "Axo transport deadline"))
    }
}
impl Read for DeadlineStream {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.stream.set_read_timeout(Some(self.remaining()?))?;
        self.stream.read(bytes)
    }
}
impl Write for DeadlineStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.stream
            .set_write_timeout(Some(self.remaining()?.min(Duration::from_millis(500))))?;
        self.stream.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.stream.flush()
    }
}

pub struct Client {
    pub discovery: Discovery,
    socket: WebSocket<DeadlineStream>,
    usable: bool,
}
impl Client {
    pub fn connect(path: &Path) -> Result<Self, ClientError> {
        let discovery: Discovery = serde_json::from_slice(
            &read_private(path, 4096).map_err(|_| ClientError::InvalidDiscovery)?,
        )
        .map_err(|_| ClientError::InvalidDiscovery)?;
        let address = discovery_address(&discovery)?;
        let stream = TcpStream::connect_timeout(&address, CONNECT_DEADLINE)
            .map_err(|_| ClientError::Offline)?;
        let stream = DeadlineStream {
            stream,
            deadline: Instant::now() + CONNECT_DEADLINE,
        };
        let limits = WebSocketConfig::default()
            .max_message_size(Some(rpc::FRAME_BYTES))
            .max_frame_size(Some(rpc::FRAME_BYTES))
            .write_buffer_size(0)
            .max_write_buffer_size(rpc::FRAME_BYTES * 2);
        let (socket, _) = tungstenite::client::client_with_config(
            discovery.endpoint.as_str(),
            stream,
            Some(limits),
        )
        .map_err(|_| ClientError::Offline)?;
        let mut client = Self {
            discovery,
            socket,
            usable: true,
        };
        let negotiated = client
            .call("axo.protocol.negotiate", json!({"protocolVersion":1}))
            .map_err(|_| ClientError::Protocol)?;
        let Some(fields) = negotiated.as_object() else {
            return Err(ClientError::Protocol);
        };
        let Some(methods) = fields.get("methods").and_then(Value::as_array) else {
            return Err(ClientError::Protocol);
        };
        let method_names = methods.iter().filter_map(Value::as_str).collect::<Vec<_>>();
        if fields.len() != 2
            || fields.get("protocolVersion") != Some(&json!(1))
            || methods.len() > 128
            || methods.iter().any(|method| {
                method.as_str().is_none_or(|name| {
                    name.is_empty() || name.len() > 128 || name.chars().any(char::is_control)
                })
            })
            || method_names
                .iter()
                .collect::<std::collections::HashSet<_>>()
                .len()
                != methods.len()
        {
            return Err(ClientError::Protocol);
        }
        Ok(client)
    }
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, ClientError> {
        if !self.usable {
            return Err(ClientError::OutcomeUnknown);
        }
        let id = Value::String(uuid::Uuid::new_v4().to_string());
        let request = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
        let raw = serde_json::to_string(&request).map_err(|_| ClientError::InvalidRequest)?;
        rpc::decode(&raw).map_err(|_| ClientError::InvalidRequest)?;
        self.socket.get_mut().deadline = Instant::now() + CALL_DEADLINE;
        // After this boundary neither write failure nor missing/invalid reply proves rejection.
        self.usable = false;
        self.socket
            .send(Message::Text(raw.into()))
            .map_err(|_| ClientError::OutcomeUnknown)?;
        let deadline = Instant::now() + CALL_DEADLINE;
        loop {
            if Instant::now() >= deadline {
                return Err(ClientError::OutcomeUnknown);
            }
            match self
                .socket
                .read()
                .map_err(|_| ClientError::OutcomeUnknown)?
            {
                Message::Text(raw) => {
                    let reply = validate_reply(&raw, &id)?;
                    if let Ok(result) = &reply
                        && let Some(expected) = request["params"]["target"].get("hostGeneration")
                        && result.get("hostGeneration") != Some(expected)
                    {
                        return Err(ClientError::OutcomeUnknown);
                    }
                    if let Ok(result) = &reply
                        && let Some(expected) = request["params"]["target"].get("storeGeneration")
                        && result.get("storeGeneration") != Some(expected)
                    {
                        return Err(ClientError::OutcomeUnknown);
                    }
                    // Failure to return credit does not erase an already validated result.
                    let acknowledged = self.socket.send(Message::Text(
                        json!({"jsonrpc":"2.0","method":"axo.transport.ack","params":{"frames":1}}).to_string().into()
                    )).is_ok();
                    self.usable = acknowledged;
                    return reply;
                }
                Message::Ping(_) => {
                    self.socket
                        .flush()
                        .map_err(|_| ClientError::OutcomeUnknown)?;
                }
                Message::Pong(_) => (),
                _ => return Err(ClientError::OutcomeUnknown),
            }
        }
    }
}
fn discovery_address(discovery: &Discovery) -> Result<SocketAddr, ClientError> {
    native_discovery_address(discovery, "/v1/rpc")
}
pub(crate) fn native_discovery_address(
    discovery: &Discovery,
    path: &str,
) -> Result<SocketAddr, ClientError> {
    let url = url::Url::parse(&discovery.endpoint).map_err(|_| ClientError::InvalidDiscovery)?;
    let port = url
        .port()
        .filter(|port| *port != 0)
        .ok_or(ClientError::InvalidDiscovery)?;
    if discovery.version != 1
        || discovery.protocol_version != 1
        || discovery.endpoint != format!("ws://127.0.0.1:{port}{path}")
    {
        return Err(ClientError::InvalidDiscovery);
    }
    Ok(SocketAddr::from((Ipv4Addr::LOCALHOST, port)))
}
/// Payload exceptions/messages are never copied into diagnostics.
fn validate_reply(raw: &str, id: &Value) -> Result<Result<Value, ClientError>, ClientError> {
    if raw.len() > rpc::FRAME_BYTES {
        return Err(ClientError::OutcomeUnknown);
    }
    let value: Value = serde_json::from_str(raw).map_err(|_| ClientError::OutcomeUnknown)?;
    let object = value.as_object().ok_or(ClientError::OutcomeUnknown)?;
    if object.get("jsonrpc") != Some(&json!("2.0"))
        || object.get("id") != Some(id)
        || object
            .keys()
            .any(|key| !["jsonrpc", "id", "result", "error"].contains(&key.as_str()))
        || object.contains_key("result") == object.contains_key("error")
    {
        return Err(ClientError::OutcomeUnknown);
    }
    if let Some(result) = object.get("result") {
        return Ok(Ok(result.clone()));
    }
    let error = object["error"]
        .as_object()
        .ok_or(ClientError::OutcomeUnknown)?;
    let code = error
        .get("code")
        .and_then(Value::as_i64)
        .and_then(|code| i32::try_from(code).ok())
        .ok_or(ClientError::OutcomeUnknown)?;
    if !error.get("message").is_some_and(Value::is_string)
        || error
            .keys()
            .any(|key| !["code", "message", "data"].contains(&key.as_str()))
    {
        return Err(ClientError::OutcomeUnknown);
    }
    Ok(Err(ClientError::Rpc(code)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn malformed_post_dispatch_results_never_become_known_rejection() {
        let id = json!("hop");
        for raw in [
            "null",
            "[]",
            r#"{"jsonrpc":"2.0","id":"other","result":{}}"#,
            r#"{"jsonrpc":"2.0","id":"hop","result":null,"error":{}}"#,
            r#"{"jsonrpc":"2.0","id":"hop","error":{"code":1.5,"message":"body"}}"#,
        ] {
            assert_eq!(validate_reply(raw, &id), Err(ClientError::OutcomeUnknown));
        }
        assert_eq!(
            validate_reply(r#"{"jsonrpc":"2.0","id":"hop","result":null}"#, &id),
            Ok(Ok(Value::Null))
        );
        assert_eq!(
            validate_reply(
                r#"{"jsonrpc":"2.0","id":"hop","error":{"code":-32007,"message":"ignored"}}"#,
                &id
            ),
            Ok(Err(ClientError::Rpc(-32007)))
        );
    }
    #[test]
    fn descriptor_is_numeric_loopback_exact_path_without_url_authority_tricks() {
        for endpoint in [
            "ws://localhost:1234/v1/rpc",
            "ws://127.1:1234/v1/rpc",
            "ws://127.0.0.1:1234/v1/rpc?q=x",
            "ws://user@127.0.0.1:1234/v1/rpc",
            "ws://127.0.0.1:0/v1/rpc",
            "wss://127.0.0.1:1234/v1/rpc",
        ] {
            let discovery = Discovery {
                version: 1,
                protocol_version: 1,
                endpoint: endpoint.into(),
                machine_id: crate::model::MachineId::new(),
                host_generation: crate::model::HostGeneration::new(),
            };
            assert!(discovery_address(&discovery).is_err());
        }
    }
}
