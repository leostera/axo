//! Server-sent events as OpenCode's `GET /api/event` writes them: `data: <json>` lines, a
//! blank line between events, `: heartbeat` comments every fifteen seconds. Fed bytes as they
//! arrive, in pieces of any size.

use serde_json::Value;

/// The longest event kept; anything longer is dropped whole (a tool's output is bounded far
/// below this).
pub const MAX_EVENT_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Default)]
pub struct EventStream {
    /// Bytes of the line being read.
    line: Vec<u8>,
    /// The `data` lines of the event being read, joined by newlines.
    data: Vec<u8>,
    /// The event being read grew past the limit: dropped at its end.
    overflowed: bool,
}

impl EventStream {
    /// The events `bytes` completes, in order: each a JSON value; events whose data is not JSON
    /// are skipped.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Value> {
        let mut events = Vec::new();
        for &byte in bytes {
            if byte != b'\n' {
                if self.line.len() + self.data.len() < MAX_EVENT_BYTES {
                    self.line.push(byte);
                } else {
                    self.overflowed = true;
                }
                continue;
            }
            let mut line = std::mem::take(&mut self.line);
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            if line.is_empty() {
                let data = std::mem::take(&mut self.data);
                if !std::mem::take(&mut self.overflowed)
                    && !data.is_empty()
                    && let Ok(value) = serde_json::from_slice(&data)
                {
                    events.push(value);
                }
                continue;
            }
            if let Some(value) = line.strip_prefix(b"data:") {
                let value = value.strip_prefix(b" ").unwrap_or(value);
                if !self.data.is_empty() {
                    self.data.push(b'\n');
                }
                self.data.extend_from_slice(value);
            }
            // `:` comments, `event:`, `id:` and `retry:` say nothing axod uses.
        }
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn events_are_read_across_any_split_and_comments_are_skipped() {
        let wire = b": heartbeat\n\ndata: {\"type\":\"server.connected\",\"data\":{}}\n\ndata: {\"type\":\"a\",\r\ndata: \"n\":1}\r\n\r\n";
        for split in 0..wire.len() {
            let mut stream = EventStream::default();
            let mut events = stream.push(&wire[..split]);
            events.extend(stream.push(&wire[split..]));
            assert_eq!(
                events,
                [json!({ "type": "server.connected", "data": {} }), json!({ "type": "a", "n": 1 })],
                "split at {split}"
            );
        }
    }

    #[test]
    fn data_that_is_not_json_and_events_past_the_limit_are_dropped() {
        let mut stream = EventStream::default();
        assert!(stream.push(b"data: nope\n\n").is_empty());
        let mut huge = b"data: \"".to_vec();
        huge.extend(std::iter::repeat_n(b'x', MAX_EVENT_BYTES + 10));
        huge.extend_from_slice(b"\"\n\n");
        assert!(stream.push(&huge).is_empty());
        assert_eq!(stream.push(b"data: 1\n\n"), [json!(1)], "the stream goes on");
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut seed = 0x1234_5678_9abc_def1_u64;
        for _ in 0..2_000 {
            let mut stream = EventStream::default();
            let bytes: Vec<u8> = (0..(seed % 200))
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    [b'd', b'a', b't', b':', b' ', b'\n', b'\r', b'{', b'}', b'1', b'"'][(seed % 11) as usize]
                })
                .collect();
            let _ = stream.push(&bytes);
        }
    }
}
