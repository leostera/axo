//! What axod knows of the Pis it runs, beyond their panes: each Session's Pi activity and
//! controls, prompts waiting for a Pi to start, who prompted whom, dormant Pis, and whether the
//! launch still waits for them (RFD0034, step 8). It is the agent extension's part of the
//! Session manager's state, grouped here so that it can get an owner of its own.

use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::ops::{Deref, DerefMut};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::Instant;

use axo_protocol::{SessionId, ShellId};

use super::{SessionManager, TakeoverGrace, pi_controls, prompts, readiness};

thread_local! {
    /// Whether this thread holds the agents' lock, so taking the Session state's lock after it,
    /// the wrong order, is caught.
    static HOLDING: Cell<bool> = const { Cell::new(false) };
}

/// Whether this thread holds the agents' lock; the Session state's lock must not be taken then.
pub(super) fn holding() -> bool {
    HOLDING.with(Cell::get)
}

/// The agents' state, locked. While it is held, this thread takes no other Session lock.
pub(super) struct AgentsGuard<'a> {
    guard: MutexGuard<'a, AgentState>,
}

impl Deref for AgentsGuard<'_> {
    type Target = AgentState;
    fn deref(&self) -> &AgentState {
        &self.guard
    }
}

impl DerefMut for AgentsGuard<'_> {
    fn deref_mut(&mut self) -> &mut AgentState {
        &mut self.guard
    }
}

impl Drop for AgentsGuard<'_> {
    fn drop(&mut self) {
        HOLDING.with(|holding| holding.set(false));
    }
}

impl SessionManager {
    /// The agents' state. With the Session state too, lock that first: never the Session state
    /// while holding this. It holds no I/O; a lock poisoned by a panic is taken anyway, since
    /// each change to it is one assignment or one map operation.
    pub(super) fn lock_agents(&self) -> AgentsGuard<'_> {
        assert!(!holding(), "the agents' lock is taken once per thread");
        let guard = self.agents.lock().unwrap_or_else(|p| p.into_inner());
        HOLDING.with(|holding| holding.set(true));
        AgentsGuard { guard }
    }
}

#[derive(Default)]
pub(super) struct AgentState {
    /// What each Session's Pi is doing, as its bridge reports it.
    pub(super) activity: HashMap<SessionId, axo_agent::Activity>,
    /// What each Session's Pi last said it runs; see `pi_controls`.
    pub(super) controls: HashMap<SessionId, pi_controls::PiControls>,
    /// Pi panes left unstarted because their Session wasn't active when Axod started; each is
    /// also an unavailable pane in `panes`, and starts when the Session is wanted (see
    /// `stop_notice`'s `wake_dormant_pi`).
    pub(super) dormant: HashSet<ShellId>,
    /// Whether Axod has finished starting; see `readiness`.
    pub(super) launch: readiness::Launch,
    /// Prompts for a Pi that is still starting, sent once its bridge binds; see `prompts`.
    pub(super) queued_prompts: HashMap<SessionId, Vec<prompts::QueuedPrompt>>,
    /// Who prompted whom, for agent loop limits; see `prompts`.
    pub(super) provenance: prompts::PromptProvenance,
    /// How long an explicit Pi restart waits before escalating; shortened by tests.
    pub(super) takeover_grace: TakeoverGrace,
}

impl AgentState {
    /// The Session is gone: nothing about its Pi is kept.
    pub(super) fn forget(&mut self, session_id: SessionId) {
        self.activity.remove(&session_id);
        self.controls.remove(&session_id);
        self.queued_prompts.remove(&session_id);
        self.provenance.forget(session_id);
    }

    /// The Session's Pi exited: what it was doing, and prompts meant for it, are not carried over
    /// to whatever replaces it. Its controls and provenance stay with the Session.
    pub(super) fn pi_exited(&mut self, session_id: SessionId) {
        self.activity.remove(&session_id);
        self.queued_prompts.remove(&session_id);
    }
}

/// Wakes whoever waits for a Pi to bind its bridge: a Pi connected, a Pi pane went away, or the
/// waiting request was cancelled. A count read before looking at the state, and waited past
/// after, means no wake is missed between the two.
#[derive(Default)]
pub(super) struct PiWake {
    count: Mutex<u64>,
    changed: Condvar,
}

impl PiWake {
    pub(super) fn count(&self) -> u64 {
        *self.count.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub(super) fn wake(&self) {
        *self.count.lock().unwrap_or_else(|p| p.into_inner()) += 1;
        self.changed.notify_all();
    }

    /// Waits until woken since `seen`, or `deadline`.
    pub(super) fn wait_past(&self, seen: u64, deadline: Instant) {
        let mut count = self.count.lock().unwrap_or_else(|p| p.into_inner());
        while *count == seen {
            let now = Instant::now();
            if now >= deadline {
                return;
            }
            count = self
                .changed
                .wait_timeout(count, deadline - now)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn a_wake_since_the_count_was_read_is_never_missed() {
        let wake = Arc::new(PiWake::default());
        let seen = wake.count();
        wake.wake();
        let started = Instant::now();
        wake.wait_past(seen, started + Duration::from_secs(5));
        assert!(
            started.elapsed() < Duration::from_millis(100),
            "woken before it waited"
        );

        let seen = wake.count();
        let waker = Arc::clone(&wake);
        let waking = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            waker.wake();
        });
        let started = Instant::now();
        wake.wait_past(seen, started + Duration::from_secs(5));
        waking.join().unwrap();
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(100) && waited < Duration::from_secs(2));

        let started = Instant::now();
        wake.wait_past(wake.count(), started + Duration::from_millis(50));
        assert!(
            started.elapsed() >= Duration::from_millis(50),
            "nothing woke it"
        );
    }
}
