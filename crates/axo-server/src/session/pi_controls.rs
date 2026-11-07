//! What a Session's Pi runs, as a person away from the Mac sees and changes it (RFD0033).
//!
//! pi-axo publishes `pi.state` (the model and thinking level), `pi.commands` (the slash commands
//! a client's prompt can run) and `pi.models` (the models it could switch to) on its bridge, on
//! start and whenever they change. Axod keeps the latest of each per Session: the state goes into
//! the Session's snapshot, and clients ask for the lists when they open the `/` menu or the model
//! picker. A Pi that exits leaves its last state in place; the next one publishes its own.
//!
//! Switching the model and restarting Pi are commands on the Pi's bridge.

use std::io;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use super::prompts::pi_command_sender;
use super::{SessionManager, SessionState};
use axo_agent::pi::protocol::{CommandResult, RejectReason};
use axo_agent::takeover::TakeoverPolicy;
use axo_protocol::{
    PaneRole, PiCommandInfo, PiModelInfo, PiRuntime, SessionId, ShellId, ThinkingLevel,
};
use serde_json::Value;

/// More than any Pi lists; pi-axo cuts its lists to these too.
const MAX_COMMANDS: usize = 500;
const MAX_MODELS: usize = 300;
/// How long Pi gets to answer a command on its bridge.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a restarted Pi gets to exit by itself before it is killed.
const EXIT_GRACE: Duration = Duration::from_secs(10);

/// What the Session's Pi last said it runs.
#[derive(Default)]
pub(super) struct PiControls {
    runtime: Option<PiRuntime>,
    commands: Vec<PiCommandInfo>,
    models: Vec<PiModelInfo>,
}

impl PiControls {
    pub(super) fn runtime(&self) -> Option<&PiRuntime> {
        self.runtime.as_ref()
    }
}

/// One of pi-axo's announcements of what it runs.
pub(super) enum PiControlEvent {
    State(PiRuntime),
    Commands(Vec<PiCommandInfo>),
    Models(Vec<PiModelInfo>),
}

impl PiControlEvent {
    /// `None` for any other event, or a payload that doesn't parse: it changes nothing.
    pub(super) fn parse(name: &str, data: &Value) -> Option<Self> {
        match name {
            "pi.state" => serde_json::from_value(data.clone()).ok().map(Self::State),
            "pi.commands" => {
                let mut commands: Vec<PiCommandInfo> =
                    serde_json::from_value(data["commands"].clone()).ok()?;
                commands.truncate(MAX_COMMANDS);
                Some(Self::Commands(commands))
            }
            "pi.models" => {
                let mut models: Vec<PiModelInfo> =
                    serde_json::from_value(data["models"].clone()).ok()?;
                models.truncate(MAX_MODELS);
                Some(Self::Models(models))
            }
            _ => None,
        }
    }

    /// Keeps it for `session_id`; says whether the Session's snapshot changed.
    pub(super) fn apply(self, state: &mut SessionState, session_id: SessionId) -> bool {
        let controls = state.pi_controls.entry(session_id).or_default();
        match self {
            Self::State(runtime) => {
                let changed = controls.runtime.as_ref() != Some(&runtime);
                controls.runtime = Some(runtime);
                changed
            }
            Self::Commands(commands) => {
                controls.commands = commands;
                false
            }
            Self::Models(models) => {
                controls.models = models;
                false
            }
        }
    }
}

/// The Session's Pi pane: running (with its process id), or gone and waiting to be started.
enum PiPane {
    Running { shell_id: ShellId, process_id: u32 },
    Unavailable { shell_id: ShellId },
}

fn pi_pane(state: &SessionState, session_id: SessionId) -> Option<PiPane> {
    state
        .panes
        .in_session(session_id)
        .find_map(|(shell_id, pane)| match pane {
            axo_panes::Pane::Running(shell) if shell.role == PaneRole::Pi => {
                Some(PiPane::Running {
                    shell_id,
                    process_id: shell.child.id(),
                })
            }
            axo_panes::Pane::Unavailable(_) => Some(PiPane::Unavailable { shell_id }),
            axo_panes::Pane::Running(_) => None,
        })
}

fn session_not_open() -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, "no such open Session")
}

impl SessionManager {
    fn open_session_controls<T>(
        &self,
        session_id: SessionId,
        read: impl FnOnce(Option<&PiControls>) -> T,
    ) -> io::Result<T> {
        let state = self.lock_state()?;
        if !state.panes.session_ids().contains(&session_id) {
            return Err(session_not_open());
        }
        Ok(read(state.pi_controls.get(&session_id)))
    }

    /// The slash commands the Session's Pi last listed; none before it has said.
    pub(super) fn pi_commands(&self, session_id: SessionId) -> io::Result<Vec<PiCommandInfo>> {
        self.open_session_controls(session_id, |controls| {
            controls.map_or_else(Vec::new, |controls| controls.commands.clone())
        })
    }

    /// The models the Session's Pi last listed; none before it has said.
    pub(super) fn pi_models(&self, session_id: SessionId) -> io::Result<Vec<PiModelInfo>> {
        self.open_session_controls(session_id, |controls| {
            controls.map_or_else(Vec::new, |controls| controls.models.clone())
        })
    }

    /// Switches the Session's model, thinking level, or both. Pi announces the result itself, in
    /// `pi.state`, which reaches clients in the snapshot.
    pub(super) fn set_pi_model(
        &self,
        session_id: SessionId,
        model: Option<(&str, &str)>,
        thinking_level: Option<ThinkingLevel>,
    ) -> io::Result<()> {
        let sender = {
            let state = self.lock_state()?;
            pi_command_sender(&state, session_id)?
        };
        let answer = sender.set_model(
            model,
            thinking_level.map(ThinkingLevel::as_str),
            ANSWER_TIMEOUT,
        )?;
        log::info!(
            "event=session.pi_model_set session_id={session_id} outcome={}",
            match answer {
                CommandResult::Accepted => "accepted".to_owned(),
                CommandResult::Rejected(reason) => reason.to_string(),
            }
        );
        match answer {
            CommandResult::Accepted => Ok(()),
            CommandResult::Rejected(RejectReason::Invalid) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi has no such model",
            )),
            CommandResult::Rejected(RejectReason::Unavailable) => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Pi is not signed in to that model's provider",
            )),
            CommandResult::Rejected(reason) => Err(io::Error::other(format!(
                "Pi did not switch the model: {reason}"
            ))),
        }
    }

    /// Restarts the Session's Pi for a person away from the Mac, whether it runs, is stuck, or
    /// has exited: a running one is asked to exit (stopping any turn), killed if it doesn't, and
    /// started again on its conversation. Returns once the restart has begun; clients follow it
    /// in the Session's status.
    pub(super) fn restart_pi_for_client(self: &Arc<Self>, session_id: SessionId) -> io::Result<()> {
        let pane = {
            let state = self.lock_state()?;
            if state.shutting_down {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Axod is shutting down",
                ));
            }
            pi_pane(&state, session_id).ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "the Session has no Pi pane")
            })?
        };
        let sender = {
            let state = self.lock_state()?;
            pi_command_sender(&state, session_id).ok()
        };
        log::info!(
            "event=session.pi_restart_requested session_id={session_id} running={}",
            matches!(pane, PiPane::Running { .. })
        );
        let manager = Arc::clone(self);
        thread::Builder::new()
            .name(format!("axo-pi-restart-{session_id}"))
            .spawn(move || {
                let shell_id = match pane {
                    PiPane::Unavailable { shell_id } => shell_id,
                    PiPane::Running {
                        shell_id,
                        process_id,
                    } => {
                        if let Some(sender) = sender {
                            // Pi stops its turn and exits; its answer doesn't matter.
                            let _ = sender.shutdown(ANSWER_TIMEOUT);
                        }
                        if !manager.wait_until_unavailable(shell_id, process_id, EXIT_GRACE) {
                            log::warn!(
                                "event=session.pi_restart_kill session_id={session_id} process_id={process_id}"
                            );
                            // SAFETY: a signal to the Pi process axod started, still its child.
                            unsafe { libc::kill(process_id as libc::pid_t, libc::SIGKILL) };
                            manager.wait_until_unavailable(shell_id, process_id, EXIT_GRACE);
                        }
                        shell_id
                    }
                };
                match manager.restart_unavailable_pi(
                    session_id,
                    shell_id,
                    TakeoverPolicy::ExplicitUserRestart,
                ) {
                    Ok(_) => log::info!("event=session.pi_restarted session_id={session_id}"),
                    // Another restart got there first; that one is the restart asked for.
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(error) => log::warn!(
                        "event=session.pi_restart_failed session_id={session_id} reason={error}"
                    ),
                }
            })?;
        Ok(())
    }

    /// Whether the Pi `process_id` in `shell_id` has exited within `timeout`.
    fn wait_until_unavailable(
        &self,
        shell_id: ShellId,
        process_id: u32,
        timeout: Duration,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let exited = self.lock_state().map_or(true, |state| {
                state
                    .panes
                    .running(shell_id)
                    .is_none_or(|shell| shell.child.id() != process_id)
            });
            if exited {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(Duration::from_millis(50));
        }
    }
}
