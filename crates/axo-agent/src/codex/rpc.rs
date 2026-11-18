//! The app-server's JSON-RPC, as it is on the wire: one JSON object per WebSocket text frame,
//! without JSON-RPC 2.0's `"jsonrpc"` member (Codex 0.170.0).
//!
//! Everything the server sends is parsed here into an [`Incoming`] before anything acts on it;
//! a frame that is not one of the four shapes is refused whole.

use serde::Serialize;
use serde_json::{Map, Value};

/// The largest frame axod reads. A thread's resume answer carries its history, so it is big.
pub const MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;

/// A request id. axod numbers its own requests; the server's are passed back as they came.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(untagged)]
pub enum RequestId {
    Number(i64),
    Text(String),
}

impl RequestId {
    fn parse(value: &Value) -> Option<Self> {
        match value {
            Value::Number(number) => number.as_i64().map(RequestId::Number),
            Value::String(text) => Some(RequestId::Text(text.clone())),
            _ => None,
        }
    }
}

/// A frame from the app-server.
#[derive(Clone, Debug, PartialEq)]
pub enum Incoming {
    /// The answer to one of axod's requests.
    Response { id: RequestId, result: Value },
    /// A request of axod's that failed.
    Failure { id: RequestId, error: RpcError },
    /// Something that happened; nothing answers it.
    Notification { method: String, params: Value },
    /// A question for the clients of a thread (an approval, user input). axod never answers
    /// these: the person does, in the TUI (RFD0072, Open question 4).
    Request {
        id: RequestId,
        method: String,
        params: Value,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

/// Why a frame was refused.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FrameError {
    TooLarge(usize),
    NotJson,
    NotAnObject,
    /// An object that is none of the four shapes.
    Malformed(&'static str),
}

/// Parses one text frame.
pub fn parse(frame: &str) -> Result<Incoming, FrameError> {
    if frame.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(frame.len()));
    }
    let value: Value = serde_json::from_str(frame).map_err(|_| FrameError::NotJson)?;
    let Value::Object(mut object) = value else {
        return Err(FrameError::NotAnObject);
    };
    let method = match object.remove("method") {
        None => None,
        Some(Value::String(method)) if !method.is_empty() => Some(method),
        Some(_) => return Err(FrameError::Malformed("method is not a name")),
    };
    let id = match object.get("id") {
        None | Some(Value::Null) => None,
        Some(id) => Some(RequestId::parse(id).ok_or(FrameError::Malformed("id is not an id"))?),
    };
    let params = object.remove("params").unwrap_or(Value::Null);
    match (method, id) {
        (Some(method), None) => Ok(Incoming::Notification { method, params }),
        (Some(method), Some(id)) => Ok(Incoming::Request { id, method, params }),
        (None, Some(id)) => answer(id, &mut object),
        (None, None) => Err(FrameError::Malformed("neither a method nor an id")),
    }
}

fn answer(id: RequestId, object: &mut Map<String, Value>) -> Result<Incoming, FrameError> {
    match (object.remove("result"), object.remove("error")) {
        (Some(result), None) => Ok(Incoming::Response { id, result }),
        (None, Some(Value::Object(error))) => {
            let code = error
                .get("code")
                .and_then(Value::as_i64)
                .ok_or(FrameError::Malformed("error without a code"))?;
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            Ok(Incoming::Failure {
                id,
                error: RpcError { code, message },
            })
        }
        (None, Some(_)) => Err(FrameError::Malformed("error is not an object")),
        (Some(_), Some(_)) => Err(FrameError::Malformed("both a result and an error")),
        (None, None) => Err(FrameError::Malformed("an answer without a result or error")),
    }
}

/// A request of axod's, ready to send.
pub fn request(id: i64, method: &str, params: Value) -> String {
    serde_json::json!({ "id": id, "method": method, "params": params }).to_string()
}

/// A notification of axod's, ready to send.
pub fn notification(method: &str) -> String {
    serde_json::json!({ "method": method }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_four_shapes_parse() {
        assert_eq!(
            parse(r#"{"id":1,"result":{"userAgent":"axod/0.170.0"}}"#),
            Ok(Incoming::Response {
                id: RequestId::Number(1),
                result: json!({ "userAgent": "axod/0.170.0" })
            })
        );
        assert_eq!(
            parse(r#"{"error":{"code":-32600,"message":"no rollout found"},"id":2}"#),
            Ok(Incoming::Failure {
                id: RequestId::Number(2),
                error: RpcError {
                    code: -32600,
                    message: "no rollout found".into()
                }
            })
        );
        assert_eq!(
            parse(r#"{"method":"thread/name/updated","params":{"threadId":"t","threadName":"x"},"emittedAtMs":1}"#),
            Ok(Incoming::Notification {
                method: "thread/name/updated".into(),
                params: json!({ "threadId": "t", "threadName": "x" })
            })
        );
        assert_eq!(
            parse(r#"{"id":"s-1","method":"item/commandExecution/requestApproval","params":{}}"#),
            Ok(Incoming::Request {
                id: RequestId::Text("s-1".into()),
                method: "item/commandExecution/requestApproval".into(),
                params: json!({})
            })
        );
        assert_eq!(
            parse(r#"{"method":"initialized"}"#),
            Ok(Incoming::Notification {
                method: "initialized".into(),
                params: Value::Null
            })
        );
    }

    #[test]
    fn anything_else_is_refused() {
        for frame in [
            "",
            "[]",
            "1",
            "{",
            r#"{}"#,
            r#"{"method":7}"#,
            r#"{"method":""}"#,
            r#"{"id":{},"result":1}"#,
            r#"{"id":1.5,"result":1}"#,
            r#"{"id":1}"#,
            r#"{"id":1,"result":1,"error":{"code":1}}"#,
            r#"{"id":1,"error":"bad"}"#,
            r#"{"id":1,"error":{"message":"no code"}}"#,
        ] {
            assert!(parse(frame).is_err(), "{frame}");
        }
        assert_eq!(
            parse(&" ".repeat(MAX_FRAME_BYTES + 1)),
            Err(FrameError::TooLarge(MAX_FRAME_BYTES + 1))
        );
    }

    #[test]
    fn outgoing_frames_are_what_codex_reads() {
        assert_eq!(
            serde_json::from_str::<Value>(&request(3, "turn/interrupt", json!({ "threadId": "t", "turnId": "u" }))).unwrap(),
            json!({ "id": 3, "method": "turn/interrupt", "params": { "threadId": "t", "turnId": "u" } })
        );
        assert_eq!(notification("initialized"), r#"{"method":"initialized"}"#);
    }

    #[test]
    fn mutated_frames_never_panic_the_parser() {
        // Fuzzing by a seeded generator over real frames: flip, drop, duplicate and insert bytes.
        let corpus = [
            r#"{"id":1,"result":{"thread":{"id":"01a1"},"model":"gpt-5"}}"#,
            r#"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"completed","items":[]}}}"#,
            r#"{"error":{"code":-32600,"message":"x"},"id":2}"#,
            r#"{"id":"s","method":"item/fileChange/requestApproval","params":{"itemId":"i"}}"#,
        ];
        let mut state = 0x2545_f491_4f6c_dd1d_u64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for _ in 0..20_000 {
            let mut bytes = corpus[(next() % corpus.len() as u64) as usize]
                .as_bytes()
                .to_vec();
            for _ in 0..=(next() % 4) {
                let at = (next() % (bytes.len() as u64 + 1)) as usize;
                match next() % 4 {
                    0 if at < bytes.len() => bytes[at] = (next() % 256) as u8,
                    1 if at < bytes.len() => {
                        bytes.remove(at);
                    }
                    2 => bytes.insert(at, b"{}[]\":,0-9e"[(next() % 11) as usize]),
                    _ => {
                        let copy = bytes[..at].to_vec();
                        bytes.extend(copy);
                    }
                }
            }
            if let Ok(text) = std::str::from_utf8(&bytes) {
                let _ = parse(text);
            }
        }
    }
}
