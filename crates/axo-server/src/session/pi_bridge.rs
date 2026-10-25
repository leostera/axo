//! The bridge to each Pi: its worker, the events Pi reports, and the Session state they update.

use std::io;
use std::sync::{Arc, Weak};
use std::thread;
use std::time::{Duration, Instant};

use super::lifecycle::{valid_session_emoji, valid_session_title};
use super::{SessionManager, SessionState};
use crate::panes::RuntimeId;
use axo_pi::{BridgeSocketPath, SocketCleanup, worker};
use axo_protocol::{Event, PaneRole, SessionId, SessionRecord, ShellId};
use axo_store::Connection;
use axo_store::{StoredPiSession, open_pi_session, pi_bridge_sockets};
use axo_store::{bind_pi_session_id, describe_session};
use serde_json::Value;

pub(super) const PENDING_FOCUS_LIFETIME: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug)]
pub(super) struct PiRuntimeBinding {
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
    pub(super) runtime_id: RuntimeId,
}

impl PiRuntimeBinding {
    pub(super) fn is_current(self, state: &SessionState) -> bool {
        state
            .panes
            .running_in(self.session_id, self.shell_id)
            .is_some_and(|shell| shell.role == PaneRole::Pi && shell.runtime_id == self.runtime_id)
    }
}

pub(super) fn log_socket_cleanup(session_id: SessionId, cleanup: SocketCleanup) {
    match cleanup {
        SocketCleanup::Removed => log::info!(
            "event=pi.bridge_socket_removed session_id={} reason=abandoned",
            session_id.get()
        ),
        SocketCleanup::NotASocket => log::warn!(
            "event=pi.bridge_socket_blocked session_id={} reason=not_a_socket",
            session_id.get()
        ),
        SocketCleanup::Absent | SocketCleanup::InUse => {}
    }
}

/// Startup reconciliation: removes the bridge socket of every Session whose writer lock no Pi
/// holds. Sessions whose Pi is still alive (an orphan of a crashed Axod) keep theirs. Failures
/// are logged and skipped; they must not keep Axod from starting.
pub(super) fn remove_abandoned_pi_bridge_sockets(database: &Connection) -> io::Result<()> {
    for (session_id, session_file, socket_path) in pi_bridge_sockets(database)? {
        match BridgeSocketPath::parse(socket_path)
            .and_then(|socket| socket.reconcile(&session_file))
        {
            Ok(cleanup) => log_socket_cleanup(session_id, cleanup),
            Err(error) => log::warn!(
                "event=pi.bridge_socket_reconcile_failed session_id={} error_kind={:?}",
                session_id.get(),
                error.kind()
            ),
        }
    }
    Ok(())
}

/// Connects one running Pi's bridge to the catalog while it is the pane's current process.
struct PiBridgeHost {
    manager: Weak<SessionManager>,
    binding: PiRuntimeBinding,
    session_uuid: String,
}

impl PiBridgeHost {
    fn log_context(&self) -> String {
        format!(
            "session_id={} shell_id={}",
            self.binding.session_id.get(),
            self.binding.shell_id.get()
        )
    }
}

impl worker::BridgeHost for PiBridgeHost {
    fn is_current(&self) -> bool {
        self.manager
            .upgrade()
            .is_some_and(|owner| owner.pi_runtime_is_current(self.binding))
    }

    fn bound(&self, pi_session_id: &str) -> io::Result<()> {
        let owner = self
            .manager
            .upgrade()
            .ok_or_else(|| io::Error::new(io::ErrorKind::Interrupted, "Axod is stopping"))?;
        owner.persist_pi_session_id(self.binding, &self.session_uuid, pi_session_id)?;
        owner.set_pi_connection(self.binding, true)
    }

    fn disconnected(&self) {
        if let Some(owner) = self.manager.upgrade() {
            let _ = owner.set_pi_connection(self.binding, false);
        }
    }

    fn resume_requested(&self, target_session_file: Option<&str>) {
        let context = self.log_context();
        let Some(target_session_file) = target_session_file else {
            log::warn!("event=session.pi_resume_rejected {context} reason=invalid_request");
            return;
        };
        let Some(owner) = self.manager.upgrade() else {
            return;
        };
        if let Err(error) = owner.resume_archived_pi_session(self.binding, target_session_file) {
            log::warn!(
                "event=session.pi_resume_rejected {context} error_kind={:?}",
                error.kind()
            );
        }
    }

    fn event(
        &self,
        pi_session_id: &str,
        stream_id: &str,
        sequence: u64,
        name: &str,
        data: Value,
    ) -> bool {
        let Some(owner) = self.manager.upgrade() else {
            return false;
        };
        if !matches!(owner.observe_pi_event(self.binding, name, &data), Ok(true)) {
            return false;
        }
        owner.publish_event(Event::PiEvent {
            session_id: self.binding.session_id,
            pi_session_id: pi_session_id.to_owned(),
            stream_id: stream_id.to_owned(),
            sequence,
            name: name.to_owned(),
            data,
        });
        true
    }
}

/// What a Pi event changes in the catalog, parsed from its name and payload once. Invalid
/// titles and emoji are dropped here, so the catalog only ever stores valid ones. Every Pi event
/// is still forwarded to clients as is; this is only the part axod acts on.
#[derive(Debug, Eq, PartialEq)]
pub(super) enum PiCatalogEvent<'a> {
    AgentStarted,
    AgentSettled,
    PromptStarted,
    PromptEnded,
    /// Pi named its session (`session.info`).
    Named {
        title: &'a str,
    },
    /// The Axo extension described the session; at least one field is set.
    Described {
        title: Option<&'a str>,
        emoji: Option<&'a str>,
    },
    /// Not a catalog change, or a payload with nothing valid in it.
    Ignored,
}

impl<'a> PiCatalogEvent<'a> {
    pub(super) fn parse(name: &str, data: &'a Value) -> Self {
        let field =
            |key: &str, valid: fn(&str) -> bool| data[key].as_str().filter(|value| valid(value));
        match name {
            "agent.start" => PiCatalogEvent::AgentStarted,
            "agent.settled" => PiCatalogEvent::AgentSettled,
            "ui.prompt.start" => PiCatalogEvent::PromptStarted,
            "ui.prompt.end" => PiCatalogEvent::PromptEnded,
            "session.info" => match field("name", valid_session_title) {
                Some(title) => PiCatalogEvent::Named { title },
                None => PiCatalogEvent::Ignored,
            },
            "axo.session.metadata" => {
                match (
                    field("title", valid_session_title),
                    field("emoji", valid_session_emoji),
                ) {
                    (None, None) => PiCatalogEvent::Ignored,
                    (title, emoji) => PiCatalogEvent::Described { title, emoji },
                }
            }
            _ => PiCatalogEvent::Ignored,
        }
    }
}

impl SessionManager {
    pub(super) fn start_pi_bridge_worker(self: &Arc<Self>, shell_id: ShellId) -> io::Result<()> {
        let (
            session_id,
            session_uuid,
            pane_id,
            initial_pwd,
            session_file,
            bridge_socket,
            bridge_token,
            process_id,
            runtime_id,
        ) = {
            let state = self.lock_state()?;
            let running = state
                .panes
                .running(shell_id)
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi pane is not running"))?;
            let StoredPiSession {
                session_uuid,
                session_file,
                ..
            } = open_pi_session(&state.database, running.session_id)?;
            let session_file = session_file.ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "Pi history path is missing")
            })?;
            (
                running.session_id,
                session_uuid,
                running.pane_id.clone().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "Pi pane ID is missing")
                })?,
                running.initial_pwd.clone(),
                session_file,
                running.pi_bridge_socket.clone().ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Pi bridge socket path is missing",
                    )
                })?,
                running.pi_bridge_token.clone().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "Pi bridge token is missing")
                })?,
                running.child.id(),
                running.runtime_id,
            )
        };
        let host = PiBridgeHost {
            manager: Arc::downgrade(self),
            binding: PiRuntimeBinding {
                session_id,
                shell_id,
                runtime_id,
            },
            session_uuid: session_uuid.clone(),
        };
        let config = worker::WorkerConfig {
            log_context: host.log_context(),
            session_uuid,
            pane_id,
            initial_pwd,
            session_file,
            bridge_socket,
            bridge_token,
            process_id,
        };
        let stop = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name(format!("axo-pi-bridge-{}", shell_id.get()))
            .spawn(move || worker::run(&host, &stop, &config))?;
        self.workers
            .lock()
            .map_err(|_| io::Error::other("session worker lock was poisoned"))?
            .push(worker);
        Ok(())
    }

    pub(super) fn start_pi_bridge_for_session(
        self: &Arc<Self>,
        session: &SessionRecord,
    ) -> io::Result<()> {
        if let Some(pi_shell) = session
            .shells
            .iter()
            .find(|shell| shell.role == PaneRole::Pi)
        {
            self.start_pi_bridge_worker(pi_shell.id)?;
        }
        Ok(())
    }

    pub(super) fn pi_runtime_is_current(&self, binding: PiRuntimeBinding) -> bool {
        self.state
            .lock()
            .map(|state| binding.is_current(&state))
            .unwrap_or(false)
    }

    pub(super) fn set_pi_connection(
        &self,
        binding: PiRuntimeBinding,
        connected: bool,
    ) -> io::Result<()> {
        let mut state = self.lock_state()?;
        if !binding.is_current(&state) {
            return Ok(());
        }
        let session_id = binding.session_id;
        let activity = state.pi_activity.entry(session_id).or_default();
        let changed = activity.connected != connected;
        activity.connected = connected;
        drop(state);
        if changed {
            self.publish_session_snapshot(session_id)?;
        }
        Ok(())
    }

    pub(super) fn observe_pi_event(
        &self,
        binding: PiRuntimeBinding,
        name: &str,
        data: &Value,
    ) -> io::Result<bool> {
        let session_id = binding.session_id;
        let changed = {
            let mut state = self.lock_state()?;
            if !binding.is_current(&state) {
                return Ok(false);
            }

            match PiCatalogEvent::parse(name, data) {
                PiCatalogEvent::AgentStarted => !std::mem::replace(
                    &mut state.pi_activity.entry(session_id).or_default().working,
                    true,
                ),
                PiCatalogEvent::AgentSettled => std::mem::replace(
                    &mut state.pi_activity.entry(session_id).or_default().working,
                    false,
                ),
                PiCatalogEvent::PromptStarted => {
                    let waits = &mut state.pi_activity.entry(session_id).or_default().ui_waits;
                    let previous = *waits;
                    *waits = waits.saturating_add(1);
                    *waits != previous
                }
                PiCatalogEvent::PromptEnded => {
                    let waits = &mut state.pi_activity.entry(session_id).or_default().ui_waits;
                    let previous = *waits;
                    *waits = waits.saturating_sub(1);
                    *waits != previous
                }
                PiCatalogEvent::Named { title } => {
                    describe_session(&state.database, session_id, Some(title), None)?
                }
                PiCatalogEvent::Described { title, emoji } => {
                    describe_session(&state.database, session_id, title, emoji)?
                }
                PiCatalogEvent::Ignored => false,
            }
        };
        if changed {
            self.publish_session_snapshot(session_id)?;
        }
        Ok(true)
    }

    pub(super) fn persist_pi_session_id(
        &self,
        binding: PiRuntimeBinding,
        session_uuid: &str,
        pi_session_id: &str,
    ) -> io::Result<()> {
        let state = self.lock_state()?;
        if !binding.is_current(&state) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi runtime was replaced",
            ));
        }
        bind_pi_session_id(
            &state.database,
            binding.session_id,
            session_uuid,
            pi_session_id,
        )
    }

    pub(super) fn request_session_focus(&self, session_id: SessionId) -> io::Result<()> {
        // Live catalog subscribers focus immediately. Listing clients get the same request for a
        // short window only, so a much later resync cannot replay a stale focus change.
        self.publish_event(Event::SessionFocus { session_id });
        *self
            .pending_resume_focus
            .lock()
            .map_err(|_| io::Error::other("pending resume focus lock was poisoned"))? =
            Some((session_id, Instant::now()));
        Ok(())
    }

    pub(super) fn take_pending_resume_focus(&self) -> io::Result<Option<SessionId>> {
        Ok(self
            .pending_resume_focus
            .lock()
            .map_err(|_| io::Error::other("pending resume focus lock was poisoned"))?
            .take()
            .filter(|(_, requested)| requested.elapsed() < PENDING_FOCUS_LIFETIME)
            .map(|(session_id, _)| session_id))
    }
}
