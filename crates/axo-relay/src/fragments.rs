//! Relay messages larger than one frame (RFD0016, Transport; modelled in
//! `specs/relay-fragments.ts`, implemented in TypeScript in `packages/axo-api/src/fragments.ts`).
//!
//! A message that does not fit in one frame is cut into chunks of its UTF-8 bytes, each sent
//! base64-encoded in an `axo.transport.fragment` notification. The receiver collects every chunk
//! of a message, then handles the whole as if it had arrived in one frame. A partial message dies
//! with its socket: each connection has its own `Reassembler`.

use std::collections::HashMap;

use axo_protocol::base64;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const FRAGMENT_METHOD: &str = "axo.transport.fragment";
/// One relay frame.
pub const FRAME_BYTES: usize = 65_536;
/// Bytes of the message in one fragment: 61,440 base64 characters, under a frame with its envelope.
pub const CHUNK_BYTES: usize = 46_080;
/// The largest message that may be reassembled.
pub const MESSAGE_BYTES: usize = 2 * 1_048_576;
/// Fragments one message may have.
pub const MAX_FRAGMENTS: usize = MESSAGE_BYTES.div_ceil(CHUNK_BYTES);
/// Messages that may be partly received on one socket.
pub const PARTIAL_PER_SOCKET: usize = 4;

#[derive(Serialize)]
struct Fragment<'a> {
    jsonrpc: &'static str,
    method: &'static str,
    params: FragmentParams<'a>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FragmentParams<'a> {
    message_id: &'a str,
    index: usize,
    count: usize,
    data: &'a str,
}

/// Why a fragment was refused; the receiver closes the socket.
#[derive(Debug, PartialEq, Eq)]
pub struct InvalidFragment(pub &'static str);

/// The frames that carry `text`: itself when it fits in one frame, otherwise its fragments in
/// order. `None` when it is larger than any reassembled message may be.
pub fn split(text: &str, message_id: &str) -> Option<Vec<String>> {
    let bytes = text.as_bytes();
    if bytes.len() <= FRAME_BYTES {
        return Some(vec![text.to_owned()]);
    }
    if bytes.len() > MESSAGE_BYTES {
        return None;
    }
    let count = bytes.len().div_ceil(CHUNK_BYTES);
    Some(
        bytes
            .chunks(CHUNK_BYTES)
            .enumerate()
            .map(|(index, chunk)| {
                let data = base64::encode(chunk);
                serde_json::to_string(&Fragment {
                    jsonrpc: "2.0",
                    method: FRAGMENT_METHOD,
                    params: FragmentParams {
                        message_id,
                        index,
                        count,
                        data: &data,
                    },
                })
                .expect("a fragment serializes")
            })
            .collect(),
    )
}

/// Whether `message` is a fragment notification, and its params if so.
pub fn fragment_params(message: &Value) -> Option<&Value> {
    (message.get("method")?.as_str()? == FRAGMENT_METHOD).then(|| &message["params"])
}

struct Partial {
    count: usize,
    bytes: usize,
    chunks: Vec<Option<Vec<u8>>>,
}

/// The partial messages of one socket.
#[derive(Default)]
pub struct Reassembler {
    partial: HashMap<String, Partial>,
}

impl Reassembler {
    /// Takes one fragment's params. `Ok(Some(text))` once every fragment of its message is here.
    pub fn receive(&mut self, params: &Value) -> Result<Option<String>, InvalidFragment> {
        let params: FragmentParams = FragmentParams::deserialize(params)
            .map_err(|_| InvalidFragment("malformed fragment"))?;
        let FragmentParams {
            message_id,
            index,
            count,
            data,
        } = params;
        let id_ok = !message_id.is_empty()
            && message_id.len() <= 64
            && message_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if !id_ok || !(2..=MAX_FRAGMENTS).contains(&count) || index >= count {
            return Err(InvalidFragment("malformed fragment"));
        }
        let chunk = base64::decode(data).map_err(|_| InvalidFragment("malformed fragment"))?;
        // Every fragment but the last is exactly one chunk, so a message cannot outgrow its count.
        let size_ok = if index < count - 1 {
            chunk.len() == CHUNK_BYTES
        } else {
            !chunk.is_empty() && chunk.len() <= CHUNK_BYTES
        };
        if !size_ok {
            return Err(InvalidFragment("fragment size"));
        }
        if !self.partial.contains_key(message_id) && self.partial.len() >= PARTIAL_PER_SOCKET {
            return Err(InvalidFragment("too many partial messages"));
        }
        let partial = self
            .partial
            .entry(message_id.to_owned())
            .or_insert_with(|| Partial {
                count,
                bytes: 0,
                chunks: vec![None; count],
            });
        if partial.count != count {
            return Err(InvalidFragment("fragment count changed"));
        }
        if partial.chunks[index].is_some() {
            return Err(InvalidFragment("fragment repeated"));
        }
        partial.bytes += chunk.len();
        partial.chunks[index] = Some(chunk);
        if partial.chunks.iter().any(Option::is_none) {
            return Ok(None);
        }
        let partial = self.partial.remove(message_id).expect("present");
        let mut whole = Vec::with_capacity(partial.bytes);
        for chunk in partial.chunks.into_iter().flatten() {
            whole.extend_from_slice(&chunk);
        }
        String::from_utf8(whole)
            .map(Some)
            .map_err(|_| InvalidFragment("message is not UTF-8"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn message(bytes: usize, fill: &str) -> String {
        let text = fill.repeat(bytes / fill.len());
        json!({ "jsonrpc": "2.0", "id": 1, "result": { "text": text } }).to_string()
    }

    fn deliver(frames: &[String], reassembler: &mut Reassembler) -> Vec<Option<String>> {
        frames
            .iter()
            .map(|frame| {
                let value: Value = serde_json::from_str(frame).unwrap();
                reassembler
                    .receive(fragment_params(&value).unwrap())
                    .unwrap()
            })
            .collect()
    }

    #[test]
    fn a_message_that_fits_in_a_frame_is_sent_as_it_is() {
        let text = message(1000, "a");
        assert_eq!(split(&text, "m").unwrap(), vec![text]);
    }

    #[test]
    fn a_large_message_crosses_in_fragments_and_comes_back_whole() {
        let text = message(5 * FRAME_BYTES + 17, "🦎");
        let frames = split(&text, "m").unwrap();
        assert!(frames.len() > 1);
        assert!(frames.iter().all(|frame| frame.len() <= FRAME_BYTES));
        let mut reversed = frames.clone();
        reversed.reverse();
        let outcomes = deliver(&reversed, &mut Reassembler::default());
        assert!(outcomes[..outcomes.len() - 1].iter().all(Option::is_none));
        assert_eq!(outcomes.last().unwrap().as_deref(), Some(text.as_str()));
    }

    #[test]
    fn the_largest_message_fits_and_a_larger_one_is_refused() {
        let largest = message(MESSAGE_BYTES - 64, "a");
        let frames = split(&largest, "m").unwrap();
        assert!(frames.len() <= MAX_FRAGMENTS);
        assert_eq!(
            deliver(&frames, &mut Reassembler::default())
                .last()
                .unwrap()
                .as_deref(),
            Some(largest.as_str())
        );
        assert!(split(&message(MESSAGE_BYTES + 1, "a"), "m").is_none());
    }

    #[test]
    fn a_peer_that_breaks_the_rules_is_refused() {
        let frames = split(&message(3 * FRAME_BYTES, "a"), "m").unwrap();
        let first: Value = serde_json::from_str(&frames[0]).unwrap();
        let params = &first["params"];
        let with = |key: &str, value: Value| {
            let mut changed = params.clone();
            changed[key] = value;
            changed
        };
        let refuse = |params: &Value| Reassembler::default().receive(params).unwrap_err();
        assert_eq!(
            refuse(&with("count", json!(MAX_FRAGMENTS + 1))).0,
            "malformed fragment"
        );
        assert_eq!(refuse(&with("data", json!("!!!!"))).0, "malformed fragment");
        assert_eq!(
            refuse(&with("data", json!(base64::encode(b"short")))).0,
            "fragment size"
        );

        let mut repeated = Reassembler::default();
        repeated.receive(params).unwrap();
        assert_eq!(repeated.receive(params).unwrap_err().0, "fragment repeated");

        let mut full = Reassembler::default();
        for n in 0..PARTIAL_PER_SOCKET {
            full.receive(&with("messageId", json!(format!("m{n}"))))
                .unwrap();
        }
        assert_eq!(
            full.receive(&with("messageId", json!("one-more")))
                .unwrap_err()
                .0,
            "too many partial messages"
        );
    }

    #[test]
    fn fragments_made_in_typescript_reassemble_here() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../schemas/axo.leostera.dev/v1/fixtures/transport-fragment.relay.json"
        ))
        .unwrap();
        let mut reassembler = Reassembler::default();
        assert_eq!(reassembler.receive(&fixture["params"]), Ok(None));
    }
}
