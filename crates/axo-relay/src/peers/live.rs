//! What the peers socket knows that axod's remote panes follow: progress, listings and the
//! commands this Mac sends to the others (RFD0024).

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{oneshot, watch};

use serde_json::Value;

use super::mirror::Place;

/// A command the cloud refused or could not settle, as JSON-RPC reports it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerCommandError {
    pub code: i64,
    pub message: String,
}

impl PeerCommandError {
    /// Nothing was sent: the next try may go ahead (RFD0018's `-32005`).
    pub fn offline() -> Self {
        Self {
            code: -32005,
            message: "Host offline; nothing queued".to_owned(),
        }
    }

    /// It may have reached the Mac: try again with the same commandId (RFD0024).
    pub fn unknown() -> Self {
        Self {
            code: -32004,
            message: "Outcome unknown; reconcile commandId".to_owned(),
        }
    }
}

/// This Mac's own Session to fetch back from the cloud whole (RFD0027).
pub(super) struct RestoreRequest {
    pub(super) place: Place,
    pub(super) count: u64,
    pub(super) reply: oneshot::Sender<io::Result<PathBuf>>,
}

/// A restore under way on the socket.
pub(super) struct Restoring {
    pub(super) count: u64,
    pub(super) reply: oneshot::Sender<io::Result<PathBuf>>,
}

pub(super) struct PeerCommand {
    pub(super) host_id: String,
    pub(super) method: String,
    pub(super) params: Value,
    pub(super) reply: oneshot::Sender<Result<Value, PeerCommandError>>,
}

#[derive(Default)]
struct LiveState {
    /// Bumped by every change a remote pane may show: records, progress, listing, the socket.
    version: u64,
    /// The newest snapshot of each progress slot, by Session.
    progress: HashMap<String, BTreeMap<String, Value>>,
    /// Commands waiting for the socket to send them.
    outbox: VecDeque<PeerCommand>,
    connected: bool,
    /// Sessions a remote pane shows: copied even when archived.
    wanted: HashSet<String>,
    /// This Mac's transcripts to fetch back from the cloud.
    restores: Vec<RestoreRequest>,
}

type Observer = Box<dyn Fn() + Send + Sync>;

/// What the peers socket knows that axod's remote panes follow, and the way their commands go
/// out. Shared between the peers worker, which fills it, and axod's handlers, which read it.
pub struct PeerLive {
    state: Mutex<LiveState>,
    changed: watch::Sender<u64>,
    /// Wakes the peers socket's loop: a pane, a command or a restore wants something.
    woken: tokio::sync::Notify,
    listing_observer: Mutex<Option<Observer>>,
}

impl Default for PeerLive {
    fn default() -> Self {
        Self {
            state: Mutex::default(),
            changed: watch::channel(0).0,
            woken: tokio::sync::Notify::new(),
            listing_observer: Mutex::default(),
        }
    }
}

impl PeerLive {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Called whenever the listing of the other Macs or their Sessions changes.
    pub fn observe_listing(&self, observer: impl Fn() + Send + Sync + 'static) {
        if let Ok(mut slot) = self.listing_observer.lock() {
            *slot = Some(Box::new(observer));
        }
    }

    pub fn version(&self) -> u64 {
        self.state.lock().map_or(0, |state| state.version)
    }

    pub fn is_connected(&self) -> bool {
        self.state.lock().is_ok_and(|state| state.connected)
    }

    /// Waits until something changes after `since`, or `timeout` passes; returns the version.
    pub async fn wait_for_change(&self, since: u64, timeout: Duration) -> u64 {
        let mut changed = self.changed.subscribe();
        let _ = tokio::time::timeout(timeout, changed.wait_for(|version| *version > since)).await;
        self.version()
    }

    /// A remote pane shows this Session: keep its copy, archived or not.
    pub fn want(&self, session_id: &str) {
        self.update(|state| {
            state.wanted.insert(session_id.to_owned());
        });
    }

    /// No pane shows it any more: an archived Session's copy may go.
    pub fn unwant(&self, session_id: &str) {
        self.update(|state| {
            state.wanted.remove(session_id);
        });
    }

    /// Fetches this Mac's own transcript at `place` back from the cloud, all `count` records
    /// of it, into the restore folder (RFD0027). Returns where it is there; the caller checks
    /// it and moves it into place.
    pub async fn restore(
        &self,
        place: Place,
        count: u64,
        timeout: Duration,
    ) -> io::Result<PathBuf> {
        let (reply, answer) = oneshot::channel();
        self.update(|state| {
            state.restores.push(RestoreRequest {
                place,
                count,
                reply,
            })
        });
        match tokio::time::timeout(timeout, answer).await {
            Ok(Ok(outcome)) => outcome,
            _ => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "the transcript could not be fetched from the cloud",
            )),
        }
    }

    pub(super) fn take_restores(&self) -> Vec<RestoreRequest> {
        self.state
            .lock()
            .map(|mut state| state.restores.drain(..).collect())
            .unwrap_or_default()
    }

    pub(super) fn wanted(&self) -> HashSet<String> {
        self.state
            .lock()
            .map(|state| state.wanted.clone())
            .unwrap_or_default()
    }

    /// The newest snapshot of each progress slot of a Session, by slot.
    pub fn progress(&self, session_id: &str) -> Vec<(String, Value)> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.progress.get(session_id).cloned())
            .map(|slots| slots.into_iter().collect())
            .unwrap_or_default()
    }

    /// Sends `method` to the Mac `host_id` names, as a client would, and waits for its answer.
    /// With no socket nothing is sent (`offline`); a reply that does not come in time, or a socket
    /// that ends first, leaves the outcome unknown.
    pub async fn command(
        &self,
        host_id: &str,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, PeerCommandError> {
        let (reply, answer) = oneshot::channel();
        {
            let mut state = self.state.lock().map_err(|_| PeerCommandError::offline())?;
            if !state.connected {
                return Err(PeerCommandError::offline());
            }
            state.outbox.push_back(PeerCommand {
                host_id: host_id.to_owned(),
                method: method.to_owned(),
                params,
                reply,
            });
        }
        self.woken.notify_one();
        match tokio::time::timeout(timeout, answer).await {
            Ok(Ok(outcome)) => outcome,
            _ => Err(PeerCommandError::unknown()),
        }
    }

    fn update(&self, change: impl FnOnce(&mut LiveState)) {
        if let Ok(mut state) = self.state.lock() {
            change(&mut state);
            state.version += 1;
            self.changed.send_replace(state.version);
        }
        self.woken.notify_one();
    }

    /// Until something wakes the peers socket's loop (at once if it was woken meanwhile).
    pub(super) async fn woken(&self) {
        self.woken.notified().await;
    }

    pub(super) fn touch(&self) {
        self.update(|_| {});
    }

    pub(super) fn listing_changed(&self) {
        self.touch();
        if let Ok(observer) = self.listing_observer.lock()
            && let Some(observer) = observer.as_ref()
        {
            observer();
        }
    }

    pub(super) fn set_progress(&self, session_id: &str, slot: &str, snapshot: Value) {
        self.update(|state| {
            let slots = state.progress.entry(session_id.to_owned()).or_default();
            if snapshot.is_null() {
                slots.remove(slot);
            } else {
                slots.insert(slot.to_owned(), snapshot);
            }
        });
    }

    pub(super) fn replace_progress(&self, session_id: &str, entries: &[Value]) {
        self.update(|state| {
            let slots = state.progress.entry(session_id.to_owned()).or_default();
            slots.clear();
            for entry in entries {
                if let Some(slot) = entry["slot"].as_str()
                    && !entry["snapshot"].is_null()
                {
                    slots.insert(slot.to_owned(), entry["snapshot"].clone());
                }
            }
        });
    }

    pub(super) fn connected(&self) {
        self.update(|state| state.connected = true);
    }

    /// The socket ended: what it never sent was not sent, and what it sent is unknown. Progress
    /// is forgotten, since nothing keeps it current now.
    pub(super) fn disconnected(
        &self,
        in_flight: Vec<oneshot::Sender<Result<Value, PeerCommandError>>>,
    ) {
        let mut unsent = Vec::new();
        self.update(|state| {
            state.connected = false;
            state.progress.clear();
            unsent.extend(state.outbox.drain(..));
        });
        for command in unsent {
            let _ = command.reply.send(Err(PeerCommandError::offline()));
        }
        for reply in in_flight {
            let _ = reply.send(Err(PeerCommandError::unknown()));
        }
    }

    pub(super) fn take_commands(&self) -> Vec<PeerCommand> {
        self.state
            .lock()
            .map(|mut state| state.outbox.drain(..).collect())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use serde_json::json;

    use crate::peers::test_support::{HOST, SESSION};

    #[tokio::test]
    async fn a_command_with_no_socket_is_not_sent_and_one_cut_off_is_unknown() {
        let live = PeerLive::new();
        let offline = live
            .command(
                HOST,
                "axo.remote.session.prompt",
                json!({}),
                Duration::from_secs(1),
            )
            .await;
        assert_eq!(offline, Err(PeerCommandError::offline()));

        live.connected();
        let follower = Arc::clone(&live);
        let sent = tokio::spawn(async move {
            follower
                .command(
                    HOST,
                    "axo.remote.session.prompt",
                    json!({ "text": "yes" }),
                    Duration::from_secs(5),
                )
                .await
        });
        let command = loop {
            if let Some(command) = live.take_commands().pop() {
                break command;
            }
            tokio::task::yield_now().await;
        };
        assert_eq!(command.params["text"], "yes");
        // The socket ends after sending it: it may have reached the Mac.
        live.disconnected(vec![command.reply]);
        assert_eq!(sent.await.unwrap(), Err(PeerCommandError::unknown()));
        assert!(!live.is_connected());
    }

    #[tokio::test]
    async fn progress_is_kept_per_slot_and_a_change_wakes_a_waiting_pane() {
        let live = PeerLive::new();
        let before = live.version();
        let waiter = Arc::clone(&live);
        let woke =
            tokio::spawn(
                async move { waiter.wait_for_change(before, Duration::from_secs(5)).await },
            );
        live.set_progress(SESSION, "message", json!({ "text": "Wor" }));
        assert!(woke.await.unwrap() > before);
        live.set_progress(SESSION, "call-1", json!({ "toolCallId": "call-1" }));
        live.set_progress(SESSION, "message", Value::Null);
        assert_eq!(
            live.progress(SESSION),
            vec![("call-1".to_owned(), json!({ "toolCallId": "call-1" }))]
        );
        live.replace_progress(
            SESSION,
            &[json!({ "slot": "question", "snapshot": { "kind": "confirm" } })],
        );
        assert_eq!(live.progress(SESSION).len(), 1);
        assert_eq!(live.progress(SESSION)[0].0, "question");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn many_waiting_panes_share_one_thread_and_all_see_the_change() {
        let live = PeerLive::new();
        let before = live.version();
        let mut panes = tokio::task::JoinSet::new();
        for _ in 0..128 {
            let live = Arc::clone(&live);
            panes.spawn(async move { live.wait_for_change(before, Duration::from_secs(5)).await });
        }
        tokio::task::yield_now().await;
        live.set_progress(SESSION, "message", json!({ "text": "hello" }));
        while let Some(version) = panes.join_next().await {
            assert!(version.unwrap() > before);
        }
        // A change before subscribing must not be missed, either.
        assert!(live.wait_for_change(before, Duration::ZERO).await > before);
    }

    #[tokio::test]
    async fn a_command_never_sent_is_offline_and_a_late_reply_has_no_waiter() {
        let live = PeerLive::new();
        live.connected();
        let caller = Arc::clone(&live);
        let pending = tokio::spawn(async move {
            caller
                .command(
                    HOST,
                    "axo.remote.session.stop",
                    json!({}),
                    Duration::from_secs(5),
                )
                .await
        });
        live.woken().await;
        live.disconnected(Vec::new());
        assert_eq!(pending.await.unwrap(), Err(PeerCommandError::offline()));

        live.connected();
        assert_eq!(
            live.command(HOST, "axo.remote.session.stop", json!({}), Duration::ZERO)
                .await,
            Err(PeerCommandError::unknown())
        );
        let command = live.take_commands().pop().unwrap();
        assert!(command.reply.is_closed());
        assert!(command.reply.send(Ok(json!({}))).is_err());
    }

    #[test]
    fn panes_mark_the_sessions_they_show_and_each_change_wakes_a_waiting_pane() {
        let live = PeerLive::new();
        let before = live.version();
        live.want(SESSION);
        assert!(live.wanted().contains(SESSION));
        assert!(live.version() > before);
        live.unwant(SESSION);
        assert!(live.wanted().is_empty());
    }
}
