//! How tasks other than the relay loop talk to the cloud over the host's one relay socket
//! (RFD0016, Transport).
//!
//! Any task may send a request, which waits for its reply without holding a thread, or a
//! notification, each with a priority class. The relay loop owns the socket: it drains what tasks
//! queued, sends frames by priority (replies and control, then durable upload, then ephemeral
//! progress) within a frame budget, interleaving fragments across classes and keeping messages in
//! order within one, and routes replies back. When the budget holds frames back, ephemeral
//! progress queues up and its oldest is dropped.
//! Everything belongs to one socket: when it closes, requests waiting on it fail with an outcome
//! that may have happened, and replies meant for it are dropped rather than sent on the next one.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::sync::oneshot;

use axo_protocol::rpc::MethodError;
use serde_json::{Value, json};

use crate::fragments;

/// The order in which the relay spends its sending budget.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Priority {
    /// Replies, commands and apps calls.
    Control = 0,
    /// Transcript upload, paced by the cloud's commit acknowledgements (RFD0018).
    Durable = 1,
    /// Progress that may be dropped when the socket is busy.
    Ephemeral = 2,
}

/// Ephemeral messages kept waiting at most; older ones are dropped first.
const MAX_EPHEMERAL_QUEUED: usize = 32;
/// Bytes queued across classes before an upload or progress is refused (control is never refused
/// for room: replies are bounded by the cloud's pending limits). Room for a largest message (a 12 MiB
/// Pi line, as a 16 MiB append) with others still queued behind it.
const MAX_QUEUED_BYTES: usize = 3 * fragments::MESSAGE_BYTES;
/// Frames the relay loop sends in one go before it looks at everything else again.
pub(crate) const FRAMES_PER_TURN: usize = 8;
/// Frames a second the outbox sends at most. The cloud closes a host's socket that sends more than
/// 600 in a second (`DAEMON_FRAMES_PER_SECOND` in `axo-host-relay.ts`); this leaves room for the
/// burst below and for the few frames sent outside the outbox (the heartbeat, registering).
pub(crate) const FRAMES_PER_SECOND: u32 = 400;
/// Frames that may go at once after a quiet spell, on top of the rate.
const FRAME_BURST: u32 = 50;

/// How many frames the outbox may send now: a token bucket of [`FRAME_BURST`] that refills at
/// [`FRAMES_PER_SECOND`], so no second of the cloud's count sees more than the two together.
pub(crate) struct FrameBudget {
    tokens: f64,
    refilled: tokio::time::Instant,
}

impl FrameBudget {
    pub(crate) fn new(now: tokio::time::Instant) -> Self {
        Self {
            tokens: f64::from(FRAME_BURST),
            refilled: now,
        }
    }

    /// Takes up to `wanted` frames from the budget; returns how many may go now.
    pub(crate) fn take(&mut self, now: tokio::time::Instant, wanted: usize) -> usize {
        self.refill(now);
        let allowed = (self.tokens.floor() as usize).min(wanted);
        self.tokens -= allowed as f64;
        allowed
    }

    /// When the next frame may go: `now` if one may already.
    pub(crate) fn next_at(&mut self, now: tokio::time::Instant) -> tokio::time::Instant {
        self.refill(now);
        if self.tokens >= 1.0 {
            return now;
        }
        let wait = (1.0 - self.tokens) / f64::from(FRAMES_PER_SECOND);
        now + Duration::from_secs_f64(wait)
    }

    fn refill(&mut self, now: tokio::time::Instant) {
        let elapsed = now.saturating_duration_since(self.refilled).as_secs_f64();
        self.tokens =
            (self.tokens + elapsed * f64::from(FRAMES_PER_SECOND)).min(f64::from(FRAME_BURST));
        self.refilled = now;
    }
}

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
    /// The caller gave up waiting (RFD0034). It may have run; nothing waits for it here. The
    /// channel answers this when the request's cancellation fires.
    Abandoned,
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
            Self::Abandoned => write!(f, "the caller stopped waiting; the request may have run"),
        }
    }
}

impl std::error::Error for RelayCallError {}

/// One message a task asked the relay loop to send.
pub(crate) struct Outgoing {
    pub(crate) text: String,
    pub(crate) priority: Priority,
}

/// Which relay socket something belongs to: each socket the relay opens has its own, so a reply
/// or a request never outlives the socket it was meant for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SocketEpoch(u64);

impl std::fmt::Display for SocketEpoch {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

/// The id of a request this Mac sent the cloud, which the cloud's reply carries back.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct RequestId(String);

impl RequestId {
    fn new(number: u64) -> Self {
        Self(format!("axod-c-{number}"))
    }

    fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::borrow::Borrow<str> for RequestId {
    fn borrow(&self) -> &str {
        &self.0
    }
}

/// What the cloud answered a request.
type Outcome = Result<Value, RelayCallError>;

/// A request sent on a socket and waiting for its reply.
struct PendingRequest {
    socket: SocketEpoch,
    waiter: oneshot::Sender<Outcome>,
}

/// The socket tasks queue onto now.
struct LiveSocket {
    epoch: SocketEpoch,
    outgoing: UnboundedSender<Outgoing>,
}

/// A socket the relay loop just opened, as the loop holds it: what tasks queue for it, and how
/// replies to the cloud's requests on it go out.
pub(crate) struct AttachedSocket {
    pub(crate) epoch: SocketEpoch,
    pub(crate) outgoing: UnboundedReceiver<Outgoing>,
    pub(crate) replies: ReplySender,
}

/// The handle tasks use to reach the cloud. Cheap to share.
pub struct RelayChannel {
    live: Mutex<Option<LiveSocket>>,
    pending: Mutex<HashMap<RequestId, PendingRequest>>,
    next_request: AtomicU64,
    next_epoch: AtomicU64,
}

impl Default for RelayChannel {
    fn default() -> Self {
        Self {
            live: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            next_request: AtomicU64::new(1),
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
        self.epoch().is_some()
    }

    /// Which socket is open now, if any.
    pub fn epoch(&self) -> Option<SocketEpoch> {
        lock(&self.live).as_ref().map(|live| live.epoch)
    }

    /// Sends a request and waits up to `timeout` for its reply. A caller that stops waiting
    /// (drops this future) is forgotten at once: its late reply is dropped.
    pub async fn request(
        &self,
        method: &str,
        params: Value,
        priority: Priority,
        timeout: Duration,
    ) -> Outcome {
        let cancellation = axo_ipc::cancel::current();
        if cancellation.is_cancelled() {
            return Err(RelayCallError::Abandoned);
        }
        let id = RequestId::new(self.next_request.fetch_add(1, Ordering::Relaxed));
        let text =
            json!({ "jsonrpc": "2.0", "id": id.as_str(), "method": method, "params": params })
                .to_string();
        if text.len() > fragments::MESSAGE_BYTES {
            return Err(RelayCallError::TooLarge);
        }
        let (waiter, answer) = oneshot::channel();
        {
            let live = lock(&self.live);
            let live = live.as_ref().ok_or(RelayCallError::NotConnected)?;
            lock(&self.pending).insert(
                id.clone(),
                PendingRequest {
                    socket: live.epoch,
                    waiter,
                },
            );
            if live.outgoing.send(Outgoing { text, priority }).is_err() {
                self.forget(&id);
                return Err(RelayCallError::NotConnected);
            }
        }
        let _waiting = Waiting { channel: self, id };
        tokio::select! {
            biased;
            () = cancellation.cancelled() => Err(RelayCallError::Abandoned),
            answer = tokio::time::timeout(timeout, answer) => match answer {
                Ok(Ok(outcome)) => outcome,
                Ok(Err(_)) => Err(RelayCallError::Disconnected),
                Err(_) => Err(RelayCallError::TimedOut),
            },
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
        let live = lock(&self.live);
        let live = live.as_ref().ok_or(RelayCallError::NotConnected)?;
        live.outgoing
            .send(Outgoing { text, priority })
            .map_err(|_| RelayCallError::NotConnected)
    }

    fn forget(&self, id: &RequestId) {
        lock(&self.pending).remove(id);
    }

    /// The relay loop opened a socket: from now on tasks queue onto it.
    pub(crate) fn attach(&self) -> AttachedSocket {
        let epoch = SocketEpoch(self.next_epoch.fetch_add(1, Ordering::Relaxed));
        let (outgoing, queued) = unbounded_channel();
        let replies = ReplySender {
            tx: outgoing.clone(),
        };
        *lock(&self.live) = Some(LiveSocket { epoch, outgoing });
        AttachedSocket {
            epoch,
            outgoing: queued,
            replies,
        }
    }

    /// The socket of `epoch` closed: requests sent on it fail, and nothing more queues onto it.
    pub(crate) fn detach(&self, epoch: SocketEpoch) {
        {
            let mut live = lock(&self.live);
            if live.as_ref().is_some_and(|live| live.epoch == epoch) {
                *live = None;
            }
        }
        let lost: Vec<PendingRequest> = {
            let mut pending = lock(&self.pending);
            let ids: Vec<RequestId> = pending
                .iter()
                .filter(|(_, request)| request.socket == epoch)
                .map(|(id, _)| id.clone())
                .collect();
            ids.iter().filter_map(|id| pending.remove(id)).collect()
        };
        for request in lost {
            let _ = request.waiter.send(Err(RelayCallError::Disconnected));
        }
    }

    /// Hands a reply from the cloud to the task waiting for it. False if nobody is.
    pub(crate) fn resolve(&self, message: &Value) -> bool {
        let Some(id) = message.get("id").and_then(Value::as_str) else {
            return false;
        };
        let Some(request) = lock(&self.pending).remove(id) else {
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
        let _ = request.waiter.send(outcome);
        true
    }
}

/// A request being waited for: forgotten when its wait ends, however it ends, so a reply that
/// comes after is dropped rather than kept for nobody.
struct Waiting<'a> {
    channel: &'a RelayChannel,
    id: RequestId,
}

impl Drop for Waiting<'_> {
    fn drop(&mut self) {
        self.channel.forget(&self.id);
    }
}

/// Every lock here guards a map or a slot that stays whole between statements, so a panic
/// elsewhere leaves it usable.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Sends replies to requests that came on one socket. When that socket closes, replies go
/// nowhere: they are never sent on the next one.
#[derive(Clone)]
pub struct ReplySender {
    tx: UnboundedSender<Outgoing>,
}

impl ReplySender {
    pub fn reply(&self, id: &Value, outcome: Result<Value, MethodError>) {
        let text = match outcome {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(error) => json!({ "jsonrpc": "2.0", "id": id, "error": error }),
        }
        .to_string();
        self.send(text);
    }

    /// Sends a reply already written out.
    pub(crate) fn send(&self, text: String) {
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
        if outgoing.priority != Priority::Control && self.bytes + size > MAX_QUEUED_BYTES {
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

    /// Whether nothing waits to be sent.
    pub(crate) fn is_empty(&self) -> bool {
        self.classes.iter().all(VecDeque::is_empty)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_second_sends_more_frames_than_the_cloud_takes() {
        let start = tokio::time::Instant::now();
        let mut budget = FrameBudget::new(start);
        // As fast as the loop can ask, for three seconds, in steps of a millisecond.
        let mut per_second = [0_usize; 3];
        for millisecond in 0..3000_u64 {
            let now = start + Duration::from_millis(millisecond);
            per_second[(millisecond / 1000) as usize] += budget.take(now, FRAMES_PER_TURN);
        }
        let ceiling = (FRAMES_PER_SECOND + FRAME_BURST) as usize;
        assert!(
            per_second.iter().all(|&sent| sent <= ceiling),
            "{per_second:?}"
        );
        assert!(ceiling < 600, "the cloud closes a socket past 600 a second");
        // And it does not starve: steady state is the rate.
        assert!(
            per_second[2] >= FRAMES_PER_SECOND as usize - 1,
            "{per_second:?}"
        );
    }

    #[test]
    fn an_empty_budget_says_when_the_next_frame_may_go() {
        let start = tokio::time::Instant::now();
        let mut budget = FrameBudget::new(start);
        assert_eq!(budget.next_at(start), start);
        assert_eq!(budget.take(start, usize::MAX), FRAME_BURST as usize);
        let next = budget.next_at(start);
        assert!(
            next > start && next <= start + Duration::from_millis(3),
            "{:?}",
            next - start
        );
        assert_eq!(budget.take(next, 1), 1);
    }

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
    fn a_full_queue_refuses_uploads_but_never_a_reply() {
        let mut outbox = Outbox::default();
        let line = |priority| {
            Outgoing {
            text: json!({ "jsonrpc": "2.0", "method": "x", "params": { "v": "u".repeat(fragments::MESSAGE_BYTES / 2) } })
                .to_string(),
            priority,
        }
        };
        while outbox.push(line(Priority::Durable), "s") {}
        assert!(!outbox.push(line(Priority::Ephemeral), "s"));
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

    #[tokio::test]
    async fn requests_wait_for_their_reply_and_fail_when_the_socket_closes() {
        let channel = RelayChannel::new();
        assert_eq!(
            channel
                .request("m", json!({}), Priority::Control, Duration::from_secs(1))
                .await,
            Err(RelayCallError::NotConnected)
        );

        let AttachedSocket {
            epoch,
            outgoing: mut rx,
            ..
        } = channel.attach();
        let request = |channel: &Arc<RelayChannel>| {
            let channel = Arc::clone(channel);
            tokio::spawn(async move {
                channel
                    .request("m", json!({}), Priority::Control, Duration::from_secs(5))
                    .await
            })
        };
        let caller = request(&channel);
        let sent: Value = serde_json::from_str(&rx.recv().await.unwrap().text).unwrap();
        assert!(
            channel
                .resolve(&json!({ "jsonrpc": "2.0", "id": sent["id"], "result": { "ok": true } }))
        );
        assert_eq!(caller.await.unwrap(), Ok(json!({ "ok": true })));

        let caller = request(&channel);
        rx.recv().await.unwrap();
        channel.detach(epoch);
        assert_eq!(caller.await.unwrap(), Err(RelayCallError::Disconnected));
        assert!(!channel.connected());
    }

    #[tokio::test]
    async fn a_request_whose_caller_gives_up_stops_waiting_at_once_and_its_reply_is_dropped() {
        let channel = RelayChannel::new();
        let AttachedSocket {
            outgoing: mut rx, ..
        } = channel.attach();
        let gave_up = std::time::Instant::now();
        let waited = tokio::time::timeout(
            Duration::from_millis(50),
            channel.request("m", json!({}), Priority::Control, Duration::from_secs(30)),
        )
        .await;
        assert!(waited.is_err());
        assert!(gave_up.elapsed() < Duration::from_secs(1));
        let sent: Value = serde_json::from_str(&rx.recv().await.unwrap().text).unwrap();
        assert!(
            !channel.resolve(&json!({ "jsonrpc": "2.0", "id": sent["id"], "result": {} })),
            "nobody waits for it any more"
        );
    }

    #[tokio::test]
    async fn cancellation_forgets_the_request_and_an_already_cancelled_call_sends_nothing() {
        let channel = RelayChannel::new();
        let AttachedSocket {
            outgoing: mut rx, ..
        } = channel.attach();
        let cancellation = axo_ipc::cancel::Cancellation::default();
        let calling = Arc::clone(&channel);
        let caller = tokio::spawn(axo_ipc::cancel::scope(cancellation.clone(), async move {
            calling
                .request("m", json!({}), Priority::Control, Duration::from_secs(30))
                .await
        }));
        let sent: Value = serde_json::from_str(&rx.recv().await.unwrap().text).unwrap();
        cancellation.cancel();
        assert_eq!(caller.await.unwrap(), Err(RelayCallError::Abandoned));
        assert!(!channel.resolve(&json!({ "jsonrpc": "2.0", "id": sent["id"], "result": {} })));
        let outcome = axo_ipc::cancel::scope(
            cancellation,
            channel.request("m", json!({}), Priority::Control, Duration::from_secs(30)),
        )
        .await;
        assert_eq!(outcome, Err(RelayCallError::Abandoned));
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn a_request_with_no_reply_times_out_and_is_forgotten() {
        let channel = RelayChannel::new();
        let AttachedSocket {
            outgoing: mut rx, ..
        } = channel.attach();
        assert_eq!(
            channel
                .request("m", json!({}), Priority::Control, Duration::from_millis(20))
                .await,
            Err(RelayCallError::TimedOut)
        );
        let sent: Value = serde_json::from_str(&rx.recv().await.unwrap().text).unwrap();
        assert!(!channel.resolve(&json!({ "jsonrpc": "2.0", "id": sent["id"], "result": {} })));
    }

    #[test]
    fn a_reply_for_a_closed_socket_is_never_sent_on_the_next() {
        let channel = RelayChannel::new();
        let old = channel.attach();
        let old_replies = old.replies.clone();
        channel.detach(old.epoch);
        drop(old);
        let mut new = channel.attach();
        old_replies.reply(&json!("call-1"), Ok(json!({})));
        assert!(new.outgoing.try_recv().is_err());
    }
}
