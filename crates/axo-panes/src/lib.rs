//! The catalog's open panes and their lifecycle.
//!
//! A pane is either running a process or unavailable: a Pi pane whose process exited or could
//! not be restored, kept so its history can be recovered. One map holds both, so a pane that is
//! "running and unavailable at once" cannot be represented, and every query over a Session's
//! panes sees each pane exactly once.
//!
//! Unavailable panes carry their recovery state. A recovery is reserved (`begin_recovery`)
//! under the catalog lock, waits for Pi's transcript lock and spawns outside it, and is then
//! committed or released under the lock again. Only the reservation that is still current may
//! commit, so a close, a removal or a newer recovery always wins over a stale one.
//!
//! The table is generic over the process type so the transitions can be tested on their own.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use axo_protocol::{SessionId, ShellId};

/// A pane survives restarts; its runtime identity does not. Async callbacks carry this identity
/// rather than applying to whichever process now owns a pane. Recoveries use the same space.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeId(u64);

/// For logs only: the number has no meaning beyond telling runtimes apart.
impl std::fmt::Display for RuntimeId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

impl RuntimeId {
    /// A runtime identity never handed out before in this process.
    pub fn next() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        // 2^64 identities: at a million per second, half a million years.
        Self(NEXT.fetch_add(1, Ordering::Relaxed))
    }
}

/// What the table needs to know about a running process.
pub trait PaneProcess {
    fn session_id(&self) -> SessionId;
}

/// One open pane.
#[derive(Debug)]
pub enum Pane<P> {
    Running(P),
    Unavailable(UnavailablePane),
}

impl<P: PaneProcess> Pane<P> {
    pub fn session_id(&self) -> SessionId {
        match self {
            Pane::Running(process) => process.session_id(),
            Pane::Unavailable(pane) => pane.session_id,
        }
    }
}

/// A Pi pane without a process.
#[derive(Debug, Eq, PartialEq)]
pub struct UnavailablePane {
    pub session_id: SessionId,
    pub pane_id: Option<String>,
    pub initial_pwd: PathBuf,
    recovery: Recovery,
}

impl UnavailablePane {
    pub fn new(session_id: SessionId, pane_id: Option<String>, initial_pwd: PathBuf) -> Self {
        UnavailablePane {
            session_id,
            pane_id,
            initial_pwd,
            recovery: Recovery::Idle,
        }
    }

    pub fn is_recovering(&self) -> bool {
        matches!(self.recovery, Recovery::InProgress(_))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Recovery {
    Idle,
    InProgress(RuntimeId),
}

/// Why a recovery could not be reserved.
#[derive(Debug, Eq, PartialEq)]
pub enum RecoveryRefused {
    /// The pane is not an unavailable pane of that Session.
    NotUnavailable,
    /// Another recovery holds the reservation.
    AlreadyRecovering,
}

pub struct Panes<P> {
    panes: HashMap<ShellId, Pane<P>>,
}

impl<P: PaneProcess> Default for Panes<P> {
    fn default() -> Self {
        Panes {
            panes: HashMap::new(),
        }
    }
}

impl<P: PaneProcess> Panes<P> {
    // MARK: Queries

    pub fn contains(&self, shell_id: ShellId) -> bool {
        self.panes.contains_key(&shell_id)
    }

    pub fn get(&self, shell_id: ShellId) -> Option<&Pane<P>> {
        self.panes.get(&shell_id)
    }

    pub fn running(&self, shell_id: ShellId) -> Option<&P> {
        match self.panes.get(&shell_id) {
            Some(Pane::Running(process)) => Some(process),
            _ => None,
        }
    }

    pub fn running_mut(&mut self, shell_id: ShellId) -> Option<&mut P> {
        match self.panes.get_mut(&shell_id) {
            Some(Pane::Running(process)) => Some(process),
            _ => None,
        }
    }

    /// The pane's process, if it runs and belongs to `session_id`.
    pub fn running_in(&self, session_id: SessionId, shell_id: ShellId) -> Option<&P> {
        self.running(shell_id)
            .filter(|process| process.session_id() == session_id)
    }

    pub fn running_in_mut(&mut self, session_id: SessionId, shell_id: ShellId) -> Option<&mut P> {
        self.running_mut(shell_id)
            .filter(|process| process.session_id() == session_id)
    }

    pub fn unavailable(&self, shell_id: ShellId) -> Option<&UnavailablePane> {
        match self.panes.get(&shell_id) {
            Some(Pane::Unavailable(pane)) => Some(pane),
            _ => None,
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = (ShellId, &Pane<P>)> {
        self.panes.iter().map(|(id, pane)| (*id, pane))
    }

    pub fn running_iter_mut(&mut self) -> impl Iterator<Item = (ShellId, &mut P)> {
        self.panes.iter_mut().filter_map(|(id, pane)| match pane {
            Pane::Running(process) => Some((*id, process)),
            Pane::Unavailable(_) => None,
        })
    }

    /// The panes of one Session, running or not.
    pub fn in_session(&self, session_id: SessionId) -> impl Iterator<Item = (ShellId, &Pane<P>)> {
        self.iter()
            .filter(move |(_, pane)| pane.session_id() == session_id)
    }

    pub fn shell_ids_in(&self, session_id: SessionId) -> HashSet<ShellId> {
        self.in_session(session_id).map(|(id, _)| id).collect()
    }

    pub fn has_session(&self, session_id: SessionId) -> bool {
        self.in_session(session_id).next().is_some()
    }

    /// Every Session with at least one open pane.
    pub fn session_ids(&self) -> HashSet<SessionId> {
        self.panes.values().map(Pane::session_id).collect()
    }

    /// Whether no pane is running a process (unavailable panes may remain).
    pub fn running_is_empty(&self) -> bool {
        !self
            .panes
            .values()
            .any(|pane| matches!(pane, Pane::Running(_)))
    }

    // MARK: Transitions

    /// A process enters the catalog, replacing whatever the pane held.
    pub fn insert_running(&mut self, shell_id: ShellId, process: P) -> Option<Pane<P>> {
        self.panes.insert(shell_id, Pane::Running(process))
    }

    /// A Pi pane is restored without a process. Refused (returned) if the pane is already open.
    pub fn insert_unavailable(
        &mut self,
        shell_id: ShellId,
        pane: UnavailablePane,
    ) -> Result<(), UnavailablePane> {
        if self.panes.contains_key(&shell_id) {
            return Err(pane);
        }
        self.panes.insert(shell_id, Pane::Unavailable(pane));
        Ok(())
    }

    /// A running pane's process exited and the pane stays open without one. Returns the
    /// exited process; `None` (and no change) when the pane was not running.
    pub fn process_exited(
        &mut self,
        shell_id: ShellId,
        unavailable: impl FnOnce(&P) -> UnavailablePane,
    ) -> Option<P> {
        let Some(Pane::Running(process)) = self.panes.get(&shell_id) else {
            return None;
        };
        let pane = unavailable(process);
        match self.panes.insert(shell_id, Pane::Unavailable(pane)) {
            Some(Pane::Running(process)) => Some(process),
            _ => unreachable!("the pane was running a moment ago, under the same borrow"),
        }
    }

    /// Reserves recovery of an unavailable pane of `session_id`.
    pub fn begin_recovery(
        &mut self,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> Result<RuntimeId, RecoveryRefused> {
        let Some(Pane::Unavailable(pane)) = self.panes.get_mut(&shell_id) else {
            return Err(RecoveryRefused::NotUnavailable);
        };
        if pane.session_id != session_id {
            return Err(RecoveryRefused::NotUnavailable);
        }
        if pane.is_recovering() {
            return Err(RecoveryRefused::AlreadyRecovering);
        }
        let recovery = RuntimeId::next();
        pane.recovery = Recovery::InProgress(recovery);
        Ok(recovery)
    }

    /// Whether `recovery` still holds the reservation for this pane.
    pub fn is_recovering(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        recovery: RuntimeId,
    ) -> bool {
        self.unavailable(shell_id).is_some_and(|pane| {
            pane.session_id == session_id && pane.recovery == Recovery::InProgress(recovery)
        })
    }

    /// Gives up a reservation (the recovery failed). A no-op for a stale one.
    pub fn release_recovery(&mut self, shell_id: ShellId, recovery: RuntimeId) {
        if let Some(Pane::Unavailable(pane)) = self.panes.get_mut(&shell_id)
            && pane.recovery == Recovery::InProgress(recovery)
        {
            pane.recovery = Recovery::Idle;
        }
    }

    /// The recovered process takes over the pane, if `recovery` still holds its reservation;
    /// otherwise the process is handed back for the caller to stop.
    pub fn commit_recovery(
        &mut self,
        session_id: SessionId,
        shell_id: ShellId,
        recovery: RuntimeId,
        process: P,
    ) -> Result<(), P> {
        if !self.is_recovering(session_id, shell_id, recovery) {
            return Err(process);
        }
        self.panes.insert(shell_id, Pane::Running(process));
        Ok(())
    }

    /// Closes one pane; returns its process, if it had one, for the caller to stop.
    pub fn remove(&mut self, shell_id: ShellId) -> Option<P> {
        match self.panes.remove(&shell_id) {
            Some(Pane::Running(process)) => Some(process),
            Some(Pane::Unavailable(_)) | None => None,
        }
    }

    /// Closes every pane of a Session; returns their processes.
    pub fn remove_session(&mut self, session_id: SessionId) -> Vec<P> {
        let shell_ids: Vec<_> = self.shell_ids_in(session_id).into_iter().collect();
        shell_ids
            .into_iter()
            .filter_map(|shell_id| self.remove(shell_id))
            .collect()
    }

    /// Closes every pane (shutdown); returns all processes.
    pub fn drain(&mut self) -> Vec<P> {
        self.panes
            .drain()
            .filter_map(|(_, pane)| match pane {
                Pane::Running(process) => Some(process),
                Pane::Unavailable(_) => None,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Eq, PartialEq)]
    struct Process {
        session_id: SessionId,
        name: &'static str,
    }

    impl PaneProcess for Process {
        fn session_id(&self) -> SessionId {
            self.session_id
        }
    }

    fn sid(value: i64) -> SessionId {
        SessionId::new(value).unwrap()
    }

    fn shid(value: i64) -> ShellId {
        ShellId::new(value).unwrap()
    }

    fn process(session: i64, name: &'static str) -> Process {
        Process {
            session_id: sid(session),
            name,
        }
    }

    fn unavailable(session: i64) -> UnavailablePane {
        UnavailablePane::new(sid(session), Some("pane".into()), PathBuf::from("/"))
    }

    /// The state of one pane, as a small vocabulary the tests can enumerate.
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum State {
        Absent,
        Running,
        Idle,
        Recovering,
    }

    fn state(panes: &Panes<Process>, shell_id: ShellId) -> State {
        match panes.get(shell_id) {
            None => State::Absent,
            Some(Pane::Running(_)) => State::Running,
            Some(Pane::Unavailable(pane)) if pane.is_recovering() => State::Recovering,
            Some(Pane::Unavailable(_)) => State::Idle,
        }
    }

    /// A table with pane 1 of Session 1 in `state`; returns the recovery holding it, if any.
    fn table_in(state: State) -> (Panes<Process>, Option<RuntimeId>) {
        let mut panes = Panes::default();
        let mut recovery = None;
        match state {
            State::Absent => {}
            State::Running => {
                panes.insert_running(shid(1), process(1, "old"));
            }
            State::Idle => panes.insert_unavailable(shid(1), unavailable(1)).unwrap(),
            State::Recovering => {
                panes.insert_unavailable(shid(1), unavailable(1)).unwrap();
                recovery = Some(panes.begin_recovery(sid(1), shid(1)).unwrap());
            }
        }
        (panes, recovery)
    }

    const STATES: [State; 4] = [
        State::Absent,
        State::Running,
        State::Idle,
        State::Recovering,
    ];

    #[test]
    fn inserting_a_process_always_leaves_it_running() {
        for from in STATES {
            let (mut panes, _) = table_in(from);
            let replaced = panes.insert_running(shid(1), process(1, "new"));
            assert_eq!(replaced.is_some(), from != State::Absent, "from {from:?}");
            assert_eq!(state(&panes, shid(1)), State::Running);
            assert_eq!(panes.running(shid(1)).unwrap().name, "new");
        }
    }

    #[test]
    fn restoring_an_unavailable_pane_never_replaces_an_open_one() {
        for from in STATES {
            let (mut panes, _) = table_in(from);
            let result = panes.insert_unavailable(shid(1), unavailable(1));
            assert_eq!(result.is_ok(), from == State::Absent, "from {from:?}");
            let expected = if from == State::Absent {
                State::Idle
            } else {
                from
            };
            assert_eq!(state(&panes, shid(1)), expected, "from {from:?}");
        }
    }

    #[test]
    fn only_a_running_pane_becomes_unavailable_when_its_process_exits() {
        for from in STATES {
            let (mut panes, _) = table_in(from);
            let exited = panes.process_exited(shid(1), |process| {
                UnavailablePane::new(process.session_id, None, PathBuf::from("/"))
            });
            assert_eq!(exited.is_some(), from == State::Running, "from {from:?}");
            let expected = if from == State::Running {
                State::Idle
            } else {
                from
            };
            assert_eq!(state(&panes, shid(1)), expected, "from {from:?}");
        }
    }

    #[test]
    fn recovery_is_reserved_only_from_an_idle_unavailable_pane() {
        for from in STATES {
            let (mut panes, _) = table_in(from);
            let result = panes.begin_recovery(sid(1), shid(1));
            let expected = match from {
                State::Idle => Ok(()),
                State::Recovering => Err(RecoveryRefused::AlreadyRecovering),
                State::Absent | State::Running => Err(RecoveryRefused::NotUnavailable),
            };
            assert_eq!(result.map(|_| ()), expected, "from {from:?}");
            let after = if from == State::Idle {
                State::Recovering
            } else {
                from
            };
            assert_eq!(state(&panes, shid(1)), after, "from {from:?}");
        }
    }

    #[test]
    fn recovery_of_another_sessions_pane_is_refused() {
        let (mut panes, _) = table_in(State::Idle);
        assert_eq!(
            panes.begin_recovery(sid(2), shid(1)),
            Err(RecoveryRefused::NotUnavailable)
        );
        assert_eq!(state(&panes, shid(1)), State::Idle);
    }

    #[test]
    fn only_the_current_reservation_commits_or_releases() {
        // From every state, a reservation that is not the pane's current one changes nothing.
        let stale = RuntimeId::next();
        for from in STATES {
            let (mut panes, _) = table_in(from);
            panes.release_recovery(shid(1), stale);
            assert_eq!(state(&panes, shid(1)), from, "release from {from:?}");
            let refused = panes.commit_recovery(sid(1), shid(1), stale, process(1, "late"));
            assert_eq!(refused.unwrap_err().name, "late", "commit from {from:?}");
            assert_eq!(state(&panes, shid(1)), from, "commit from {from:?}");
        }

        let (mut panes, recovery) = table_in(State::Recovering);
        let recovery = recovery.unwrap();
        assert!(panes.is_recovering(sid(1), shid(1), recovery));
        assert!(!panes.is_recovering(sid(2), shid(1), recovery));
        assert!(
            panes
                .commit_recovery(sid(2), shid(1), recovery, process(1, "wrong session"))
                .is_err()
        );
        panes
            .commit_recovery(sid(1), shid(1), recovery, process(1, "recovered"))
            .unwrap();
        assert_eq!(panes.running(shid(1)).unwrap().name, "recovered");

        let (mut panes, recovery) = table_in(State::Recovering);
        panes.release_recovery(shid(1), recovery.unwrap());
        assert_eq!(state(&panes, shid(1)), State::Idle);
        // The released reservation cannot commit afterwards.
        assert!(
            panes
                .commit_recovery(sid(1), shid(1), recovery.unwrap(), process(1, "late"))
                .is_err()
        );
    }

    #[test]
    fn closing_a_pane_cancels_its_recovery() {
        let (mut panes, recovery) = table_in(State::Recovering);
        assert_eq!(panes.remove(shid(1)), None);
        assert!(
            panes
                .commit_recovery(sid(1), shid(1), recovery.unwrap(), process(1, "late"))
                .is_err()
        );
        assert_eq!(state(&panes, shid(1)), State::Absent);
        // Reopened and reserved again, the old reservation still cannot commit.
        panes.insert_unavailable(shid(1), unavailable(1)).unwrap();
        let newer = panes.begin_recovery(sid(1), shid(1)).unwrap();
        assert!(
            panes
                .commit_recovery(sid(1), shid(1), recovery.unwrap(), process(1, "stale"))
                .is_err()
        );
        assert!(panes.is_recovering(sid(1), shid(1), newer));
    }

    #[test]
    fn session_queries_see_each_pane_once_whatever_its_state() {
        let mut panes = Panes::default();
        panes.insert_running(shid(1), process(1, "shell"));
        panes.insert_unavailable(shid(2), unavailable(1)).unwrap();
        panes.insert_running(shid(3), process(2, "other"));
        assert_eq!(
            panes.shell_ids_in(sid(1)),
            HashSet::from([shid(1), shid(2)])
        );
        assert_eq!(panes.session_ids(), HashSet::from([sid(1), sid(2)]));
        assert!(panes.running_in(sid(1), shid(1)).is_some());
        assert!(panes.running_in(sid(2), shid(1)).is_none());
        assert!(panes.running_in(sid(1), shid(2)).is_none());

        let removed = panes.remove_session(sid(1));
        assert_eq!(removed, vec![process(1, "shell")]);
        assert!(!panes.has_session(sid(1)));
        assert_eq!(panes.drain(), vec![process(2, "other")]);
        assert!(panes.session_ids().is_empty());
    }
}
