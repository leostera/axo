//! A minimal typed JSON-RPC client over axod's Unix socket: one persistent connection, one
//! request in flight at a time.

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

pub struct Client {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
    line: String,
}

#[derive(Serialize)]
struct Request<'a, P> {
    jsonrpc: &'static str,
    id: u64,
    method: &'a str,
    params: &'a P,
}

#[derive(Deserialize)]
struct Response<R> {
    id: u64,
    result: Option<R>,
    error: Option<RpcError>,
}

#[derive(Debug, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

#[derive(Debug)]
pub enum CallError {
    Io(io::Error),
    Rpc(RpcError),
    Protocol(String),
}

impl std::fmt::Display for CallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CallError::Io(error) => write!(f, "io: {error}"),
            CallError::Rpc(error) => write!(f, "rpc {}: {}", error.code, error.message),
            CallError::Protocol(message) => write!(f, "protocol: {message}"),
        }
    }
}

impl From<io::Error> for CallError {
    fn from(error: io::Error) -> Self {
        CallError::Io(error)
    }
}

impl Client {
    pub fn connect(socket: &Path, timeout: Duration) -> io::Result<Self> {
        let stream = UnixStream::connect(socket)?;
        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;
        Ok(Client {
            reader: BufReader::new(stream.try_clone()?),
            writer: stream,
            next_id: 1,
            line: String::new(),
        })
    }

    pub fn call<P: Serialize, R: DeserializeOwned>(
        &mut self,
        method: &str,
        params: &P,
    ) -> Result<R, CallError> {
        let id = self.next_id;
        self.next_id += 1;
        let mut request = serde_json::to_vec(&Request {
            jsonrpc: "2.0",
            id,
            method,
            params,
        })
        .map_err(|error| CallError::Protocol(error.to_string()))?;
        request.push(b'\n');
        self.writer.write_all(&request)?;
        self.line.clear();
        if self.reader.read_line(&mut self.line)? == 0 {
            return Err(CallError::Protocol("connection closed".to_owned()));
        }
        let response: Response<R> = serde_json::from_str(&self.line)
            .map_err(|error| CallError::Protocol(format!("{method}: {error}")))?;
        if response.id != id {
            return Err(CallError::Protocol(format!(
                "{method}: response id mismatch"
            )));
        }
        match (response.result, response.error) {
            (_, Some(error)) => Err(CallError::Rpc(error)),
            (Some(result), None) => Ok(result),
            (None, None) => Err(CallError::Protocol(format!("{method}: empty response"))),
        }
    }
}

// Wire shapes the load test needs. Unknown fields are ignored: this is a client, not a schema.

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum PaneRole {
    Pi,
    Terminal,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shell {
    pub id: i64,
    pub role: PaneRole,
    pub attach_socket_path: PathBuf,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Session {
    pub id: i64,
    pub shells: Vec<Shell>,
}

#[derive(Debug, Deserialize)]
pub struct SessionList {
    pub sessions: Vec<Session>,
}

#[derive(Serialize)]
pub struct NoParams {}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRef {
    pub session_id: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellRef {
    pub session_id: i64,
    pub shell_id: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Resize {
    pub session_id: i64,
    pub shell_id: i64,
    pub rows: u32,
    pub columns: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalInput {
    pub session_id: i64,
    pub shell_id: i64,
    pub sequence: u64,
    /// Base64.
    pub data: String,
}

#[derive(Serialize)]
pub struct ConfigGet {
    pub key: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Subscribe {
    pub session_id: Option<i64>,
    pub include_terminal_output: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Subscription {
    pub subscription_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NextEvents<'a> {
    pub subscription_id: &'a str,
    pub timeout_ms: u64,
    pub max_events: u32,
}

#[derive(Deserialize)]
pub struct EventBatch {
    pub events: Vec<Event>,
}

#[derive(Deserialize)]
pub struct Event {
    #[serde(rename = "type")]
    pub kind: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetLayout<'a> {
    pub session_id: i64,
    pub layout: &'a Layout,
}

/// A session layout tree (`kind`-tagged, as on the wire).
#[derive(Clone, Debug, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Layout {
    Pane {
        shell_id: i64,
    },
    Split {
        id: String,
        direction: &'static str,
        ratio: f64,
        first: Box<Layout>,
        second: Box<Layout>,
    },
}

impl Layout {
    /// A right-leaning chain of splits containing every shell once.
    pub fn chain(shell_ids: &[i64], ratio: f64) -> Option<Layout> {
        let (&last, rest) = shell_ids.split_last()?;
        let mut layout = Layout::Pane { shell_id: last };
        for (index, &shell_id) in rest.iter().enumerate().rev() {
            layout = Layout::Split {
                // Split IDs are UUIDs on the wire.
                id: format!("00000000-0000-4000-8000-{index:012}"),
                direction: if index % 2 == 0 { "right" } else { "down" },
                ratio,
                first: Box::new(Layout::Pane { shell_id }),
                second: Box::new(layout),
            };
        }
        Some(layout)
    }
}

#[derive(Deserialize)]
pub struct Ignored {}

pub fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for (i, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            if i <= chunk.len() {
                out.push(TABLE[((n >> shift) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_rfc4648_vectors() {
        for (input, expected) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(input.as_bytes()), expected);
        }
    }

    #[test]
    fn layout_chain_contains_each_shell_once() {
        let json = serde_json::to_string(&Layout::chain(&[1, 2, 3], 0.5).unwrap()).unwrap();
        for id in ["\"shellId\":1", "\"shellId\":2", "\"shellId\":3"] {
            assert_eq!(json.matches(id).count(), 1);
        }
        assert!(Layout::chain(&[], 0.5).is_none());
        assert!(json.contains("\"id\":\"00000000-0000-4000-8000-000000000000\""));
    }
}
