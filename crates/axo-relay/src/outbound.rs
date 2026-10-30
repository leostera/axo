//! How threads other than the relay loop talk to the cloud over the host's one relay socket
//! (RFD0016, Transport).
//!
//! Any thread may send a request, which waits for its reply, or a notification, each with a
//! priority class. The relay loop owns the socket: it drains what threads queued, sends frames
//! by priority (replies and control, then durable upload, then ephemeral progress), interleaving
//! fragments across classes and keeping messages in order within one, and routes replies back.
//! Everything belongs to one socket: when it closes, requests waiting on it fail with an outcome
//! that may have happened, and replies meant for it are dropped rather than sent on the next one.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use crate::fragments;

/// The order in which the relay spends its sending budget.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Priority {
    /// Replies, commands and connections calls.
    Control = 0,
    /// Transcript upload, flow-controlled by the cloud's commit acks.
    Durable = 1,
    /// Progress that may be dropped when the socket is busy.
    Ephemeral = 2,
}

/// Ephemeral messages kept waiting at most; older ones are dropped first.
const MAX_EPHEMERAL_QUEUED: usize = 32;
/// Bytes queued across classes before a send is refused.
const MAX_QUEUED_BYTES: usize = 16 * 1_048_576;
/// Frames the relay loop sends per turn; it turns about every 20 ms, so this stays well under the
/// cloud's 600 inbound frames a second.
pub(crate) const FRAMES_PER_TURN: usize = 8;

/// Why a request to the cloud did not get an answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayCallError {
    /// No relay socket: this Mac is unpaired or offline. Nothing was sent.
    NotConnected,
    /// The socket closed after the request was sent. It may have run.
    Disconnected,
    /// No reply in time. It may have run.
    TimedOut,
    /// The cloud answered with an error.
    Rejected { code: i64, message: String },
    /// The message is larger than the relay carries, or too much is queued. Nothing was sent.
    TooLarge,
}

impl std::fmt::Display for RelayCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotConnected => write!(f, "this Mac is not connected to its Axo account"),
            Self::Disconnected => write!(
                f,
                "the relay disconnected before the answer came; the request may have run"
            ),
            Self::TimedOut => write!(f, "no answer in time; the request may have run"),
            Self::Rejected { message, .. } => write!(f, "{message}"),
            Self::TooLarge => write!(f, "the request is too large for the relay"),
        }
    }
}

impl std::error::Error for RelayCallError {}

/// One message a thread asked the relay loop to send.
pub(crate) struct Outgoing {
    pub(crate) text: String,
    pub(crate) priority: Priority,
}

type Waiter = SyncSender<Result<Value, RelayCallError>>;

struct Live {
    epoch: u64,
    tx: Sender<Outgoing>,
}

/// The handle threads use to reach the cloud. Cheap to share.
pub struct RelayChannel {
    live: Mutex<Option<Live>>,
    pending: Mutex<HashMap<String, (u64, Waiter)>>,
    next_id: AtomicU64,
    next_epoch: AtomicU64,
}

impl Default for RelayChannel {
    fn default() -> Self {
        Self {
            live: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            next_epoch: AtomicU64::new(1),
        }
    }
}

impl RelayChannel {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Whether a relay socket is open now.
    pub fn connected(&self) -> bool {
        self.live.lock().map(|live| live.is_some()).unwrap_or(false)
    }

    /// Sends a request and waits up to `timeout` for its reply.
    pub fn request(
        &self,
        method: &str,
        params: Value,
        priority: Priority,
        timeout: Duration,
    ) -> Result<Value, RelayCallError> {
        let id = format!("axod-c-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let text =
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }).to_string();
        let (waiter, answer) = mpsc::sync_channel(1);
        {
            let live = self.live.lock().map_err(|_| RelayCallError::NotConnected)?;
            let Some(live) = live.as_ref() else {
                return Err(RelayCallError::NotConnected);
            };
            if text.len() > fragments::MESSAGE_BYTES {
                return Err(RelayCallError::TooLarge);
            }
            self.pending
                .lock()
                .map_err(|_| RelayCallError::NotConnected)?
                .insert(id.clone(), (live.epoch, waiter));
            if live.tx.send(Outgoing { text, priority }).is_err() {
                self.forget(&id);
                return Err(RelayCallError::NotConnected);
            }
        }
        match answer.recv_timeout(timeout) {
            Ok(outcome) => outcome,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                self.forget(&id);
                Err(RelayCallError::TimedOut)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(RelayCallError::Disconnected),
        }
    }

    /// Sends a notification; it has no reply.
    pub fn notify(
        &self,
        method: &str,
        params: Value,
        priority: Priority,
    ) -> Result<(), RelayCallError> {
        let text = json!({ "jsonrpc": "2.0", "method": method, "params": params }).to_string();
        if text.len() > fragments::MESSAGE_BYTES {
            return Err(RelayCallError::TooLarge);
        }
        let live = self.live.lock().map_err(|_| RelayCallError::NotConnected)?;
        let live = live.as_ref().ok_or(RelayCallError::NotConnected)?;
        live.tx
            .send(Outgoing { text, priority })
            .map_err(|_| RelayCallError::NotConnected)
    }

    fn forget(&self, id: &str) {
        if let Ok(mut pending) = self.pending.lock() {
            pending.remove(id);
        }
    }

    /// The relay loop opened a socket: from now on threads queue onto it.
    pub(crate) fn attach(&self) -> (u64, Receiver<Outgoing>, ReplySender) {
        let epoch = self.next_epoch.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        let replies = ReplySender { tx: tx.clone() };
        if let Ok(mut live) = self.live.lock() {
            *live = Some(Live { epoch, tx });
        }
        (epoch, rx, replies)
    }

    /// The socket of `epoch` closed: requests sent on it fail, and nothing more queues onto it.
    pub(crate) fn detach(&self, epoch: u64) {
        if let Ok(mut live) = self.live.lock()
            && live.as_ref().is_some_and(|live| live.epoch == epoch)
        {
            *live = None;
        }
        if let Ok(mut pending) = self.pending.lock() {
            let lost: Vec<String> = pending
                .iter()
                .filter(|(_, (e, _))| *e == epoch)
                .map(|(id, _)| id.clone())
                .collect();
            for id in lost {
                if let Some((_, waiter)) = pending.remove(&id) {
                    let _ = waiter.try_send(Err(RelayCallError::Disconnected));
                }
            }
        }
    }

    /// Hands a reply from the cloud to the thread waiting for it. False if nobody is.
    pub(crate) fn resolve(&self, message: &Value) -> bool {
        let Some(id) = message.get("id").and_then(Value::as_str) else {
            return false;
        };
        let Some((_, waiter)) = self.pending.lock().ok().and_then(|mut p| p.remove(id)) else {
            return false;
        };
        let outcome = if let Some(error) = message.get("error") {
            Err(RelayCallError::Rejected {
                code: error["code"].as_i64().unwrap_or(-32000),
                message: error["message"]
                    .as_str()
                    .unwrap_or("the cloud refused the request")
                    .chars()
                    .take(512)
                    .collect(),
            })
        } else {
            Ok(message.get("result").cloned().unwrap_or(Value::Null))
        };
        let _ = waiter.try_send(outcome);
        true
    }
}

/// Sends replies to requests that came on one socket. When that socket closes, replies go
/// nowhere: they are never sent on the next one.
#[derive(Clone)]
pub struct ReplySender {
    tx: Sender<Outgoing>,
}

impl ReplySender {
    pub fn reply(&self, id: &Value, outcome: Result<Value, (i64, String)>) {
        let text = match outcome {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err((code, message)) => {
                json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
            }
        }
        .to_string();
        let _ = self.tx.send(Outgoing {
            text,
            priority: Priority::Control,
        });
    }
}

struct Queued {
    frames: VecDeque<String>,
    started: bool,
}

/// Frames waiting to go out on one socket, by priority class.
#[derive(Default)]
pub(crate) struct Outbox {
    /// Per class, messages in order, each its frames in order.
    classes: [VecDeque<Queued>; 3],
    bytes: usize,
    next_message: u64,
}

impl Outbox {
    /// Queues a message, split into fragments when larger than a frame. False if refused.
    pub(crate) fn push(&mut self, outgoing: Outgoing, socket_id: &str) -> bool {
        self.next_message += 1;
        let message_id = format!("{socket_id}-{}", self.next_message);
        let Some(frames) = fragments::split(&outgoing.text, &message_id) else {
            return false;
        };
        let size: usize = frames.iter().map(String::len).sum();
        if self.bytes + size > MAX_QUEUED_BYTES {
            return false;
        }
        let class = &mut self.classes[outgoing.priority as usize];
        if outgoing.priority == Priority::Ephemeral && class.len() >= MAX_EPHEMERAL_QUEUED {
            // Drop the oldest ephemeral message that has not started going out.
            let start = usize::from(class.front().is_some_and(|m| m.started));
            if let Some(dropped) = class.remove(start) {
                self.bytes -= dropped.frames.iter().map(String::len).sum::<usize>();
            }
        }
        self.bytes += size;
        class.push_back(Queued {
            frames: frames.into(),
            started: false,
        });
        true
    }

    /// The next frame to send: from the highest class with anything queued, continuing the
    /// message that class started.
    pub(crate) fn next_frame(&mut self) -> Option<String> {
        for class in &mut self.classes {
            if let Some(message) = class.front_mut() {
                let frame = message
                    .frames
                    .pop_front()
                    .expect("queued messages are never empty");
                message.started = true;
                if message.frames.is_empty() {
                    class.pop_front();
                }
                self.bytes -= frame.len();
                return Some(frame);
            }
        }
        None
    }

    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.classes.iter().all(VecDeque::is_empty)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn big(priority: Priority, fill: char) -> Outgoing {
        Outgoing {
            text: json!({ "jsonrpc": "2.0", "method": "x", "params": { "v": fill.to_string().repeat(150_000) } })
                .to_string(),
            priority,
        }
    }

    #[test]
    fn a_reply_overtakes_an_upload_between_its_fragments() {
        let mut outbox = Outbox::default();
        assert!(outbox.push(big(Priority::Durable, 'u'), "s"));
        let first = outbox.next_frame().unwrap();
        assert!(first.contains("axo.transport.fragment"));
        assert!(outbox.push(
            Outgoing {
                text: "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".into(),
                priority: Priority::Control
            },
            "s"
        ));
        assert_eq!(
            outbox.next_frame().unwrap(),
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        );
        let mut rest = 0;
        while let Some(frame) = outbox.next_frame() {
            assert!(frame.contains("axo.transport.fragment"));
            rest += 1;
        }
        assert!(rest >= 2);
        assert!(outbox.is_empty());
    }

    #[test]
    fn messages_in_one_class_go_in_order_so_only_one_is_partly_sent() {
        let mut outbox = Outbox::default();
        outbox.push(big(Priority::Control, 'a'), "s");
        outbox.push(big(Priority::Control, 'b'), "s");
        let frames: Vec<String> = std::iter::from_fn(|| outbox.next_frame()).collect();
        let ids: Vec<String> = frames
            .iter()
            .map(|f| {
                serde_json::from_str::<Value>(f).unwrap()["params"]["messageId"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        let switch = ids.windows(2).filter(|w| w[0] != w[1]).count();
        assert_eq!(switch, 1);
    }

    #[test]
    fn requests_wait_for_their_reply_and_fail_when_the_socket_closes() {
        let channel = RelayChannel::new();
        assert_eq!(
            channel.request("m", json!({}), Priority::Control, Duration::from_secs(1)),
            Err(RelayCallError::NotConnected)
        );

        let (epoch, rx, _replies) = channel.attach();
        let caller = {
            let channel = Arc::clone(&channel);
            thread::spawn(move || {
                channel.request("m", json!({}), Priority::Control, Duration::from_secs(5))
            })
        };
        let sent: Value = serde_json::from_str(&rx.recv().unwrap().text).unwrap();
        assert!(
            channel
                .resolve(&json!({ "jsonrpc": "2.0", "id": sent["id"], "result": { "ok": true } }))
        );
        assert_eq!(caller.join().unwrap(), Ok(json!({ "ok": true })));

        let caller = {
            let channel = Arc::clone(&channel);
            thread::spawn(move || {
                channel.request("m", json!({}), Priority::Control, Duration::from_secs(5))
            })
        };
        rx.recv().unwrap();
        channel.detach(epoch);
        assert_eq!(caller.join().unwrap(), Err(RelayCallError::Disconnected));
        assert!(!channel.connected());
    }

    #[test]
    fn a_reply_for_a_closed_socket_is_never_sent_on_the_next() {
        let channel = RelayChannel::new();
        let (old, old_rx, old_replies) = channel.attach();
        drop(old_rx);
        channel.detach(old);
        let (_new, new_rx, _) = channel.attach();
        old_replies.reply(&json!("call-1"), Ok(json!({})));
        assert!(new_rx.try_recv().is_err());
    }
}
