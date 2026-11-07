//! What axod knows of the Pis it runs, beyond their panes: each Session's Pi activity and
//! controls, prompts waiting for a Pi to start, who prompted whom, dormant Pis, and whether the
//! launch still waits for them (RFD0034, step 8). It is the agent extension's part of the
//! Session manager's state, grouped here so that it can get an owner of its own.

use std::collections::{HashMap, HashSet};

use axo_protocol::{SessionId, ShellId};

use super::{TakeoverGrace, pi_controls, prompts, readiness};

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
