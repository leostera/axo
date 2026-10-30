//! Relay messages larger than one frame (RFD0016, Transport; modelled in
//! `specs/relay-fragments.ts`, implemented in TypeScript in `packages/axo-api/src/fragments.ts`).
//!
//! A message that does not fit in one frame is cut into chunks of its UTF-8 bytes, each sent
//! base64-encoded in an `axo.transport.fragment` notification. The receiver collects every chunk
//! of a message, then handles the whole as if it had arrived in one frame. A partial message dies
//! with its socket: each connection has its own `Reassembler`.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use axo_protocol::base64;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const FRAGMENT_METHOD: &str = "axo.transport.fragment";
pub const DISCARD_METHOD: &str = "axo.transport.discard";
/// A partial message that gets no fragment for this long is dropped.
pub const PARTIAL_TIMEOUT: Duration = Duration::from_secs(60);
/// Dropped messages remembered per socket, so their late fragments are ignored.
pub const DISCARDED_PER_SOCKET: usize = 64;
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
    last: Instant,
}

/// The partial messages of one socket.
#[derive(Default)]
pub struct Reassembler {
    partial: HashMap<String, Partial>,
    discarded: VecDeque<String>,
}

impl Reassembler {
    /// Drops a message's partial, and ignores its fragments from now on: its sender gave up on it.
    pub fn discard(&mut self, message_id: &str) {
        self.partial.remove(message_id);
        if !self.discarded.iter().any(|id| id == message_id) {
            self.discarded.push_back(message_id.to_owned());
            if self.discarded.len() > DISCARDED_PER_SOCKET {
                self.discarded.pop_front();
            }
        }
    }

    /// Drops partials that got no fragment for `PARTIAL_TIMEOUT`: their discard notice was lost.
    pub fn expire(&mut self, now: Instant) {
        let stale: Vec<String> = self
            .partial
            .iter()
            .filter(|(_, p)| now.duration_since(p.last) >= PARTIAL_TIMEOUT)
            .map(|(id, _)| id.clone())
            .collect();
        for id in stale {
            self.discard(&id);
        }
    }

    /// Takes a discard notice's params.
    pub fn receive_discard(&mut self, params: &Value) -> Result<(), InvalidFragment> {
        let id = params
            .get("messageId")
            .and_then(Value::as_str)
            .filter(|id| valid_message_id(id))
            .ok_or(InvalidFragment("malformed discard"))?;
        self.discard(id);
        Ok(())
    }

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
        if !valid_message_id(message_id) || !(2..=MAX_FRAGMENTS).contains(&count) || index >= count
        {
            return Err(InvalidFragment("malformed fragment"));
        }
        if self.discarded.iter().any(|id| id == message_id) {
            return Ok(None);
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
                last: Instant::now(),
            });
        if partial.count != count {
            return Err(InvalidFragment("fragment count changed"));
        }
        if partial.chunks[index].is_some() {
            return Err(InvalidFragment("fragment repeated"));
        }
        partial.bytes += chunk.len();
        partial.chunks[index] = Some(chunk);
        partial.last = Instant::now();
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

fn valid_message_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
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
    fn a_discarded_message_is_dropped_and_its_late_fragments_ignored() {
        let frames = split(&message(3 * FRAME_BYTES, "a"), "m").unwrap();
        let mut reassembler = Reassembler::default();
        let params =
            |frame: &String| serde_json::from_str::<Value>(frame).unwrap()["params"].clone();
        assert_eq!(reassembler.receive(&params(&frames[0])), Ok(None));
        reassembler
            .receive_discard(&json!({ "messageId": "m" }))
            .unwrap();
        for frame in &frames[1..] {
            assert_eq!(reassembler.receive(&params(frame)), Ok(None));
        }
        assert!(reassembler.partial.is_empty());
    }

    #[test]
    fn a_partial_with_no_new_fragment_for_a_minute_is_dropped() {
        let frames = split(&message(3 * FRAME_BYTES, "a"), "m").unwrap();
        let mut reassembler = Reassembler::default();
        let first: Value = serde_json::from_str(&frames[0]).unwrap();
        reassembler.receive(&first["params"]).unwrap();
        reassembler.expire(Instant::now());
        assert_eq!(reassembler.partial.len(), 1);
        reassembler.expire(Instant::now() + PARTIAL_TIMEOUT);
        assert!(reassembler.partial.is_empty());
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
