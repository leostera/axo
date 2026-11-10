//! What is open, as every Session's task last described itself (RFD0041): a `watch` channel that
//! anyone reads without asking a task. Each Session's task is the only writer of its entry; the
//! registry removes the entry when the Session closes.

use std::collections::BTreeMap;

use axo_protocol::{SessionId, SessionRecord, ShellId};
use tokio::sync::watch;

/// How far a Session's Pi has come.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum PiPhase {
    /// No Pi runs or is starting: none, dormant, or gone.
    #[default]
    Absent,
    /// Being launched.
    Launching,
    /// Running, its bridge not bound yet.
    Running,
    /// Running, and its bridge is bound: it takes prompts.
    Connected,
}

impl PiPhase {
    /// Whether a Pi is on its way up: launching, or running and not bound yet.
    pub(crate) fn starting(self) -> bool {
        matches!(self, Self::Launching | Self::Running)
    }
}

/// One open Session.
#[derive(Clone, Debug)]
pub(crate) struct Entry {
    pub(crate) record: SessionRecord,
    pub(crate) pi: PiPhase,
    /// Whether its Pi is in the middle of a turn.
    pub(crate) working: bool,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct View {
    pub(crate) sessions: BTreeMap<SessionId, Entry>,
}

impl View {
    /// Open Sessions, oldest first.
    pub(crate) fn records(&self) -> Vec<SessionRecord> {
        let mut records: Vec<SessionRecord> = self
            .sessions
            .values()
            .map(|entry| entry.record.clone())
            .collect();
        records.sort_by_key(|record| (record.created_at, record.id));
        records
    }

    /// The open Session a pane belongs to.
    pub(crate) fn owner_of(&self, shell_id: ShellId) -> Option<SessionId> {
        self.sessions
            .values()
            .find(|entry| entry.record.shells.iter().any(|shell| shell.id == shell_id))
            .map(|entry| entry.record.id)
    }
}

pub(crate) struct Catalog(watch::Sender<View>);

impl Default for Catalog {
    fn default() -> Self {
        Self(watch::channel(View::default()).0)
    }
}

impl Catalog {
    pub(crate) fn view(&self) -> watch::Ref<'_, View> {
        self.0.borrow()
    }

    pub(crate) fn subscribe(&self) -> watch::Receiver<View> {
        self.0.subscribe()
    }

    pub(crate) fn records(&self) -> Vec<SessionRecord> {
        self.view().records()
    }

    pub(crate) fn record(&self, session_id: SessionId) -> Option<SessionRecord> {
        self.view()
            .sessions
            .get(&session_id)
            .map(|entry| entry.record.clone())
    }

    pub(crate) fn contains(&self, session_id: SessionId) -> bool {
        self.view().sessions.contains_key(&session_id)
    }

    /// Writes a Session's entry, unless it has been `closed`: checked under the channel's lock,
    /// so an entry the registry removed is never written back.
    pub(crate) fn put(&self, entry: Entry, closed: &std::sync::atomic::AtomicBool) {
        self.0.send_if_modified(|view| {
            if closed.load(std::sync::atomic::Ordering::Acquire) {
                return false;
            }
            view.sessions.insert(entry.record.id, entry);
            true
        });
    }

    pub(crate) fn remove(&self, session_id: SessionId) {
        self.0
            .send_if_modified(|view| view.sessions.remove(&session_id).is_some());
    }
}
