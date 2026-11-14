//! Bounded newline JSON-RPC, no retry of writes and no privileged caller impersonation.
use super::{Failure, output};
use axo_protocol::rpc::{self, method};
use serde_json::{Value, json};
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
const MAX_FRAME: u64 = 32 * 1024 * 1024;

pub(crate) struct Client {
    stream: BufReader<UnixStream>,
    next_id: u64,
    methods: Vec<String>,
}
impl Client {
    pub(crate) async fn connect(path: &Path) -> Result<Self, Failure> {
        let stream = tokio::time::timeout(Duration::from_secs(5), UnixStream::connect(path))
            .await
            .map_err(|_| {
                Failure::transport("axod connection timed out; open Axo or check --socket")
            })?
            .map_err(|_| {
                Failure::transport(
                    "cannot reach axod; open Axo and enable the daemon, or pass --socket",
                )
            })?;
        Ok(Self {
            stream: BufReader::new(stream),
            next_id: 0,
            methods: Vec::new(),
        })
    }
    pub(crate) async fn negotiate(&mut self) -> Result<Value, Failure> {
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            self.exchange(
                method::PROTOCOL_NEGOTIATE,
                json!({"protocolVersion":rpc::PROTOCOL_VERSION}),
            ),
        )
        .await
        .map_err(|_| Failure::transport("daemon protocol negotiation timed out"))??;
        let negotiated: rpc::ProtocolNegotiated = serde_json::from_value(result.clone())
            .map_err(|_| Failure::transport("invalid daemon negotiation response"))?;
        if negotiated.protocol_version != rpc::PROTOCOL_VERSION {
            return Err(Failure::transport(
                "unsupported daemon protocol; update Axo",
            ));
        }
        self.methods = negotiated.methods;
        Ok(result)
    }
    pub(crate) async fn call(&mut self, method: &str, params: Value) -> Result<Value, Failure> {
        if !self.methods.iter().any(|name| name == method) && method != method::PROTOCOL_NEGOTIATE {
            return Err(Failure::transport(format!(
                "the running daemon does not advertise {method}; update Axo or use a supported command"
            )));
        }
        self.exchange(method, params).await
    }
    async fn exchange(&mut self, method: &str, params: Value) -> Result<Value, Failure> {
        self.next_id += 1;
        let id = self.next_id;
        let mut line =
            serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
                .expect("JSON values serialize");
        if line.len() > 8 * 1024 * 1024 {
            return Err(Failure::input("request exceeds 8 MiB; nothing was sent"));
        }
        line.push(b'\n');
        self.stream.get_mut().write_all(&line).await.map_err(|_| {
            Failure::transport("daemon write failed; dispatched actions may have run")
        })?;
        let value = frame(&mut self.stream).await?;
        if value["jsonrpc"] != "2.0"
            || value["id"] != id
            || value.get("result").is_some() == value.get("error").is_some()
        {
            return Err(Failure::transport(
                "invalid or mismatched daemon reply; dispatched actions may have run",
            ));
        }
        if let Some(error) = value.get("error") {
            let code = error["code"]
                .as_i64()
                .ok_or_else(|| Failure::transport("invalid daemon RPC error"))?;
            let message = error["message"]
                .as_str()
                .ok_or_else(|| Failure::transport("invalid daemon RPC error"))?;
            return Err(Failure {
                code: 4,
                message: format!("{message} (RPC {code})"),
            });
        }
        Ok(value["result"].clone())
    }
}
async fn frame(stream: &mut BufReader<UnixStream>) -> Result<Value, Failure> {
    let mut line = Vec::new();
    let read = (&mut *stream)
        .take(MAX_FRAME + 1)
        .read_until(b'\n', &mut line)
        .await
        .map_err(|_| Failure::transport("daemon read failed; dispatched actions may have run"))?;
    if read == 0 {
        return Err(Failure::transport(
            "daemon closed the connection; dispatched actions may have run",
        ));
    }
    if line.len() as u64 > MAX_FRAME || !line.ends_with(b"\n") {
        return Err(Failure::transport("oversized or incomplete daemon reply"));
    }
    serde_json::from_slice(&line).map_err(|_| Failure::transport("daemon returned invalid JSON"))
}
pub(crate) async fn watch(
    path: &Path,
    params: Value,
    timeout: Option<Duration>,
) -> Result<(), Failure> {
    let serve = async {
        // Stream opening must be the first request on its own connection. Negotiate separately.
        let mut probe = Client::connect(path).await?;
        probe.negotiate().await?;
        drop(probe);
        let mut client = Client::connect(path).await?;
        let subscribed = tokio::time::timeout(
            Duration::from_secs(5),
            client.exchange("axo.session.events.stream", params),
        )
        .await
        .map_err(|_| Failure::transport("event subscription timed out"))??;
        output(&subscribed, true)?;
        loop {
            let value = frame(&mut client.stream).await?;
            if value["jsonrpc"] != "2.0" || value["method"] != "axo.session.events" {
                return Err(Failure::transport(
                    "unexpected event frame; relist Sessions",
                ));
            }
            let events: Vec<axo_protocol::Event> =
                serde_json::from_value(value["params"]["events"].clone())
                    .map_err(|_| Failure::transport("invalid event batch; relist Sessions"))?;
            let lagged = events
                .iter()
                .any(|event| matches!(event, axo_protocol::Event::SubscriptionLagged));
            output(&value, true)?;
            if lagged {
                return Err(Failure::transport(
                    "event subscription lagged; relist Sessions and subscribe again",
                ));
            }
        }
    };
    let deadline = async {
        match timeout {
            Some(timeout) => tokio::time::sleep(timeout).await,
            None => std::future::pending::<()>().await,
        }
    };
    tokio::select! {
        result = serve => result,
        _ = deadline => Err(Failure::transport("event watch deadline reached")),
        _ = tokio::signal::ctrl_c() => Err(Failure { code:130, message:"event watch interrupted".into() }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn mismatched_reply_is_never_treated_as_a_success() {
        let (client, mut server) = UnixStream::pair().unwrap();
        let task = tokio::spawn(async move {
            let mut input = [0u8; 1024];
            server.read(&mut input).await.unwrap();
            server
                .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{}}\n")
                .await
                .unwrap();
        });
        let mut client = Client {
            stream: BufReader::new(client),
            next_id: 0,
            methods: vec![],
        };
        assert!(client.exchange("test", json!({})).await.is_err());
        task.await.unwrap();
    }
}
