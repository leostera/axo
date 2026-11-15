//! Shared local axod client: bounded JSON-RPC, negotiated methods, no implicit retries,
//! runtime startup, credential reads, or privileged caller impersonation.
mod catalog;
mod catalog_watch;
mod settings;
mod viewport_reporter;
pub use catalog::LocalCatalog;
pub use catalog_watch::{CatalogSnapshot, CatalogState, CatalogWatch, CatalogWatcher};
pub use viewport_reporter::{ViewportPhase, ViewportReporter, ViewportStatus, ViewportWorker};

use axo_protocol::rpc::{self, method};
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::{fmt, path::Path, time::Duration};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

const MAX_FRAME: u64 = 32 * 1024 * 1024;
const MAX_REQUEST: usize = 8 * 1024 * 1024;

#[derive(Debug)]
pub enum Error {
    Input(String),
    Transport(String),
    Rejected { code: i64, message: String },
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Input(message) | Self::Transport(message) => f.write_str(message),
            Self::Rejected { code, message } => write!(f, "{message} (RPC {code})"),
        }
    }
}
impl std::error::Error for Error {}
fn transport(message: impl Into<String>) -> Error {
    Error::Transport(message.into())
}

/// One serial request connection. Callers own operation deadlines. If an exchange
/// is cancelled or its reply is malformed, the connection is discarded: it must
/// never mistake a late reply for a subsequent operation or retry a write.
pub struct Client {
    stream: Option<BufReader<UnixStream>>,
    next_id: u64,
    methods: Vec<String>,
}
impl Client {
    pub async fn connect(path: &Path) -> Result<Self, Error> {
        let stream = tokio::time::timeout(Duration::from_secs(5), UnixStream::connect(path))
            .await
            .map_err(|_| transport("axod connection timed out; open Axo or check --socket"))?
            .map_err(|_| {
                transport("cannot reach axod; open Axo and enable the daemon, or pass --socket")
            })?;
        Ok(Self {
            stream: Some(BufReader::new(stream)),
            next_id: 0,
            methods: Vec::new(),
        })
    }

    pub async fn negotiate(&mut self) -> Result<Value, Error> {
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            self.exchange(
                method::PROTOCOL_NEGOTIATE,
                json!({"protocolVersion":rpc::PROTOCOL_VERSION}),
            ),
        )
        .await
        .map_err(|_| transport("daemon protocol negotiation timed out"))??;
        let parsed = serde_json::from_value::<rpc::ProtocolNegotiated>(result.clone());
        let negotiated = match parsed {
            Ok(negotiated) if negotiated.protocol_version == rpc::PROTOCOL_VERSION => negotiated,
            Ok(_) => {
                self.stream.take();
                return Err(transport("unsupported daemon protocol; update Axo"));
            }
            Err(_) => {
                self.stream.take();
                return Err(transport("invalid daemon negotiation response"));
            }
        };
        self.methods = negotiated.methods;
        Ok(result)
    }

    pub fn supports(&self, method: &str) -> bool {
        self.methods.iter().any(|name| name == method)
    }

    pub async fn call(&mut self, method: &str, params: Value) -> Result<Value, Error> {
        if !self.supports(method) && method != method::PROTOCOL_NEGOTIATE {
            return Err(transport(format!(
                "the running daemon does not advertise {method}; update Axo or use a supported command"
            )));
        }
        self.exchange(method, params).await
    }

    pub async fn call_typed<T: DeserializeOwned>(
        &mut self,
        method: &str,
        params: Value,
    ) -> Result<T, Error> {
        serde_json::from_value(self.call(method, params).await?)
            .map_err(|_| transport(format!("daemon returned an invalid response for {method}")))
    }

    async fn exchange(&mut self, method: &str, params: Value) -> Result<Value, Error> {
        self.next_id = self
            .next_id
            .checked_add(1)
            .ok_or_else(|| transport("request ID space exhausted"))?;
        let id = self.next_id;
        let mut line =
            serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
                .expect("JSON values serialize");
        if line.len() > MAX_REQUEST {
            return Err(Error::Input(
                "request exceeds 8 MiB; nothing was sent".into(),
            ));
        }
        line.push(b'\n');
        // Taking ownership across await makes cancellation close/poison this connection.
        let mut stream = self.stream.take().ok_or_else(|| {
            transport(
                "daemon connection is no longer usable; reconnect without blindly retrying writes",
            )
        })?;
        stream
            .get_mut()
            .write_all(&line)
            .await
            .map_err(|_| transport("daemon write failed; dispatched actions may have run"))?;
        let value = frame(&mut stream).await?;
        if value["jsonrpc"] != "2.0"
            || value["id"] != id
            || value.get("result").is_some() == value.get("error").is_some()
        {
            return Err(transport(
                "invalid or mismatched daemon reply; dispatched actions may have run",
            ));
        }
        let result = if let Some(error) = value.get("error") {
            let code = error["code"]
                .as_i64()
                .ok_or_else(|| transport("invalid daemon RPC error"))?;
            let message = error["message"]
                .as_str()
                .ok_or_else(|| transport("invalid daemon RPC error"))?;
            Err(Error::Rejected {
                code,
                message: message.into(),
            })
        } else {
            Ok(value["result"].clone())
        };
        self.stream = Some(stream); // An ordinary RPC rejection still leaves framing aligned.
        result
    }
}

async fn frame(stream: &mut BufReader<UnixStream>) -> Result<Value, Error> {
    let mut line = Vec::new();
    let read = (&mut *stream)
        .take(MAX_FRAME + 1)
        .read_until(b'\n', &mut line)
        .await
        .map_err(|_| transport("daemon read failed; dispatched actions may have run"))?;
    if read == 0 {
        return Err(transport(
            "daemon closed the connection; dispatched actions may have run",
        ));
    }
    if line.len() as u64 > MAX_FRAME || !line.ends_with(b"\n") {
        return Err(transport("oversized or incomplete daemon reply"));
    }
    serde_json::from_slice(&line).map_err(|_| transport("daemon returned invalid JSON"))
}

/// A parsed event notification; retains the wire value for JSON/CLI consumers.
pub struct EventBatch {
    wire: Value,
    events: Vec<axo_protocol::Event>,
}
impl EventBatch {
    pub fn wire(&self) -> &Value {
        &self.wire
    }
    pub fn events(&self) -> &[axo_protocol::Event] {
        &self.events
    }
    pub fn lagged(&self) -> bool {
        self.events
            .iter()
            .any(|event| matches!(event, axo_protocol::Event::SubscriptionLagged))
    }
}

pub struct EventStream {
    stream: Option<BufReader<UnixStream>>,
    acknowledgement: Value,
}
impl EventStream {
    pub async fn open(path: &Path, params: Value) -> Result<Self, Error> {
        // Stream opening is the first request on its connection. Negotiate separately.
        let mut probe = Client::connect(path).await?;
        probe.negotiate().await?;
        drop(probe);
        let mut client = Client::connect(path).await?;
        let acknowledgement = tokio::time::timeout(
            Duration::from_secs(5),
            client.exchange("axo.session.events.stream", params),
        )
        .await
        .map_err(|_| transport("event subscription timed out"))??;
        let subscribed: rpc::Subscribed = serde_json::from_value(acknowledgement.clone())
            .map_err(|_| transport("invalid event subscription acknowledgement"))?;
        if subscribed.subscription_id.is_empty() {
            return Err(transport("empty event subscription identity"));
        }
        Ok(Self {
            stream: client.stream.take(),
            acknowledgement,
        })
    }
    pub fn acknowledgement(&self) -> &Value {
        &self.acknowledgement
    }

    /// Cancellation or an invalid/lagged batch ends this subscription. Relist and
    /// resubscribe rather than projecting stale state as live.
    pub async fn next(&mut self) -> Result<EventBatch, Error> {
        let mut stream = self
            .stream
            .take()
            .ok_or_else(|| transport("event stream ended; relist Sessions"))?;
        let value = frame(&mut stream).await?;
        if value["jsonrpc"] != "2.0" || value["method"] != "axo.session.events" {
            return Err(transport("unexpected event frame; relist Sessions"));
        }
        let events = serde_json::from_value(value["params"]["events"].clone())
            .map_err(|_| transport("invalid event batch; relist Sessions"))?;
        let batch = EventBatch {
            wire: value,
            events,
        };
        if !batch.lagged() {
            self.stream = Some(stream);
        }
        Ok(batch)
    }
}

#[cfg(test)]
mod tests;
