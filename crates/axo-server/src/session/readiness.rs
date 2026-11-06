//! When Axod is ready: not when it answers (that is as soon as the Sessions are restored), but
//! once the Pis it started at launch have come up, so a client showing Axod's Sessions finds
//! their agents taking prompts. A Pi that dies on the way stops counting, and after
//! [`LAUNCH_READY_LIMIT`] Axod is ready whatever is still starting, so one stuck Pi can't hold
//! everyone back. Clients learn it from `axo.daemon.health`'s `ready` and from the one
//! `daemon.ready` event Axod publishes when it gets there.

use std::collections::HashSet;
use std::io;
use std::time::{Duration, Instant};

use axo_panes::Pane;
use axo_protocol::{Event, PaneRole, SessionId};

use super::{SessionManager, SessionState};

/// The longest Axod waits for the Pis it started before calling itself ready.
pub(super) const LAUNCH_READY_LIMIT: Duration = Duration::from_secs(15);

/// Where Axod is in starting up.
#[derive(Debug, Default)]
pub(super) enum Launch {
    /// Restoring Sessions; nothing to wait for is known yet.
    #[default]
    Restoring,
    /// Waiting for these Sessions' Pis to come up, until `deadline`.
    Starting {
        waiting: HashSet<SessionId>,
        deadline: Instant,
    },
    Ready,
}

/// Whether the Session's Pi is still on its way up: running, but its bridge not connected yet.
fn still_starting(state: &SessionState, session_id: SessionId) -> bool {
    let running_pi = state
        .panes
        .in_session(session_id)
        .any(|(_, pane)| matches!(pane, Pane::Running(shell) if shell.role == PaneRole::Pi));
    let connected = state
        .pi_activity
        .get(&session_id)
        .is_some_and(|activity| activity.connected);
    running_pi && !connected
}

impl SessionManager {
    /// Called once Sessions are restored: Axod now waits for the Pis that are starting.
    pub(super) fn begin_launch(&self) -> io::Result<()> {
        {
            let mut state = self.lock_state()?;
            let waiting: HashSet<SessionId> = state
                .panes
                .session_ids()
                .into_iter()
                .filter(|session_id| still_starting(&state, *session_id))
                .collect();
            log::info!("event=daemon.launch_waiting pis={}", waiting.len());
            state.launch = Launch::Starting {
                waiting,
                deadline: Instant::now() + LAUNCH_READY_LIMIT,
            };
        }
        self.check_launch_ready();
        Ok(())
    }

    /// Whether Axod has finished starting, for `axo.daemon.health`.
    pub fn is_ready(&self) -> bool {
        self.lock_state()
            .is_ok_and(|state| matches!(state.launch, Launch::Ready))
    }

    /// Ends the launch once nothing it waits for is still starting, or its time is up, and
    /// tells every subscriber. Cheap to call often.
    pub(super) fn check_launch_ready(&self) {
        let Ok(mut state) = self.lock_state() else {
            return;
        };
        let Launch::Starting { waiting, deadline } = &state.launch else {
            return;
        };
        let deadline = *deadline;
        let still: HashSet<SessionId> = waiting
            .iter()
            .copied()
            .filter(|session_id| still_starting(&state, *session_id))
            .collect();
        let timed_out = Instant::now() >= deadline;
        if !still.is_empty() && !timed_out {
            state.launch = Launch::Starting {
                waiting: still,
                deadline,
            };
            return;
        }
        state.launch = Launch::Ready;
        drop(state);
        log::info!(
            "event=daemon.launch_ready still_starting={} timed_out={timed_out}",
            still.len()
        );
        self.publish_event(Event::DaemonReady);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::pi_bridge::PiRuntimeBinding;
    use crate::session::test_support::PiRecoveryFixture;

    /// Every Pi the manager is running, as its bridge worker would name it.
    fn running_pis(manager: &SessionManager) -> Vec<PiRuntimeBinding> {
        let state = manager.lock_state().unwrap();
        state
            .panes
            .iter()
            .filter_map(|(shell_id, pane)| match pane {
                Pane::Running(shell) if shell.role == PaneRole::Pi => Some(PiRuntimeBinding {
                    session_id: shell.session_id,
                    shell_id,
                    runtime_id: shell.runtime_id,
                }),
                _ => None,
            })
            .collect()
    }

    /// Through two Axods: the next one answers at once but is ready only when the Pi it
    /// restored has connected, or, for a Pi that never does, at the time limit.
    #[test]
    fn axod_is_ready_once_the_pis_it_started_are_up() {
        let fixture = PiRecoveryFixture::new();
        let directory = fixture.lifecycle.directory.clone();
        fixture.lifecycle.manager.shutdown();

        let next = SessionManager::open(&directory, &directory.join("sessions")).unwrap();
        assert!(!next.is_ready(), "its Pi is still starting");
        let subscription = next.subscribe(None, false).unwrap();
        let events = || -> Vec<Event> {
            next.next_events(&subscription, Duration::from_millis(50), 100)
                .unwrap()
                .into_iter()
                .map(|event| (*event).clone())
                .collect()
        };
        events();
        // The restored Session's and the Home Workspace's: ready only when both are up.
        let pis = running_pis(&next);
        assert_eq!(pis.len(), 2);
        assert!(pis.iter().any(|pi| pi.session_id == fixture.session_id));
        next.set_pi_connection(pis[0], true).unwrap();
        assert!(!next.is_ready());
        next.set_pi_connection(pis[1], true).unwrap();
        assert!(next.is_ready());
        assert!(events().contains(&Event::DaemonReady));
        next.check_launch_ready();
        assert_eq!(
            events()
                .iter()
                .filter(|event| **event == Event::DaemonReady)
                .count(),
            0,
            "published once"
        );
        next.shutdown();

        // A Pi that never connects holds Axod back only until the limit.
        let stuck = SessionManager::open(&directory, &directory.join("sessions")).unwrap();
        assert!(!stuck.is_ready());
        if let Launch::Starting { deadline, .. } = &mut stuck.lock_state().unwrap().launch {
            *deadline = Instant::now();
        }
        stuck.check_launch_ready();
        assert!(stuck.is_ready());
        stuck.shutdown();
    }
}
