//! The bridge to each Pi: its worker, the events Pi reports, and the Session state they update.

use std::io;
use std::sync::{Arc, Weak};
use std::thread;
use std::time::{Duration, Instant};

use super::lifecycle::{valid_session_emoji, valid_session_title};
use super::{SessionManager, SessionState};
use axo_panes::RuntimeId;
use axo_pi::{BridgeSocketPath, SocketCleanup, worker};
use axo_protocol::{Event, PaneRole, SessionId, SessionRecord, ShellId};
use axo_store::Connection;
use axo_store::{StoredPiSession, open_pi_session, pi_bridge_sockets};
use axo_store::{bind_pi_session_id, describe_session, record_session_message, unix_timestamp};
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
            session_id
        ),
        SocketCleanup::NotASocket => log::warn!(
            "event=pi.bridge_socket_blocked session_id={} reason=not_a_socket",
            session_id
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
                session_id,
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
}

impl PiBridgeHost {
    fn log_context(&self) -> String {
        format!(
            "session_id={} shell_id={}",
            self.binding.session_id,
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
        owner.persist_pi_session_id(self.binding, pi_session_id)?;
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
        if name == "session.import.requested" {
            let Some(source_path) = data["sourcePath"]
                .as_str()
                .filter(|path| !path.is_empty() && path.len() <= 4096 && !path.contains('\0'))
            else {
                log::warn!(
                    "event=session.pi_import_rejected {} reason=invalid_path",
                    self.log_context()
                );
                return true;
            };
            if let Err(error) = owner.import_pi_session(self.binding, source_path) {
                log::warn!(
                    "event=session.pi_import_rejected {} error_kind={:?}",
                    self.log_context(),
                    error.kind()
                );
            }
            return true;
        }
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
    /// A user message started, before Pi emits `agent.start` for its run.
    UserMessageStarted,
    /// A user or assistant message was completed.
    MessageEnded,
    /// Pi reported its current activity when the bridge connected or reconnected.
    ActivitySnapshot {
        working: bool,
    },
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
            "message.start" if data["message"]["role"].as_str() == Some("user") => {
                PiCatalogEvent::UserMessageStarted
            }
            "message.end"
                if matches!(data["message"]["role"].as_str(), Some("user" | "assistant")) =>
            {
                PiCatalogEvent::MessageEnded
            }
            "activity.snapshot" => data["working"]
                .as_bool()
                .map(|working| PiCatalogEvent::ActivitySnapshot { working })
                .unwrap_or(PiCatalogEvent::Ignored),
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
            pane_id,
            initial_pwd,
            session_file,
            bridge_socket,
            bridge_token,
            process_id,
            runtime_id,
            commands,
        ) = {
            let mut state = self.lock_state()?;
            let not_running = || io::Error::new(io::ErrorKind::NotFound, "Pi pane is not running");
            let session_id = state
                .panes
                .running(shell_id)
                .ok_or_else(not_running)?
                .session_id;
            let StoredPiSession { session_file, .. } =
                open_pi_session(&state.database, session_id)?;
            let session_file = session_file.ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "Pi history path is missing")
            })?;
            let running = state.panes.running_mut(shell_id).ok_or_else(not_running)?;
            let (command_sender, commands) = worker::command_channel();
            running.pi_commands = Some(command_sender);
            (
                running.session_id,
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
                commands,
            )
        };
        let host = PiBridgeHost {
            manager: Arc::downgrade(self),
            binding: PiRuntimeBinding {
                session_id,
                shell_id,
                runtime_id,
            },
        };
        let config = worker::WorkerConfig {
            log_context: host.log_context(),
            session_uuid: session_id.to_string(),
            pane_id,
            initial_pwd,
            session_file,
            bridge_socket,
            bridge_token,
            process_id,
            commands,
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
        if connected {
            // Pi has finished starting: it can take what was sent to it meanwhile.
            self.flush_queued_pi_prompts(session_id)?;
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
                PiCatalogEvent::UserMessageStarted => !std::mem::replace(
                    &mut state.pi_activity.entry(session_id).or_default().working,
                    true,
                ),
                PiCatalogEvent::MessageEnded => {
                    record_session_message(&state.database, session_id, unix_timestamp())?
                }
                PiCatalogEvent::ActivitySnapshot { working } => {
                    let activity = state.pi_activity.entry(session_id).or_default();
                    let changed = activity.working != working;
                    activity.working = working;
                    changed
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
        pi_session_id: &str,
    ) -> io::Result<()> {
        let state = self.lock_state()?;
        if !binding.is_current(&state) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi runtime was replaced",
            ));
        }
        bind_pi_session_id(&state.database, binding.session_id, pi_session_id)
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

#[cfg(test)]
mod tests {
    use super::*;

    use crate::session::{catalog::*, settings::*, spawn::*, terminal::*, test_support::*};

    use axo_pi::WriterLock;

    use axo_protocol::{PaneRole, SessionStatus, new_uuid_v4};
    use axo_pty::WindowSize;
    use axo_pty::process;
    use axo_store::Connection;
    use axo_store::initialize_database;
    use axo_store::{load_pi_bridge_token, store_pi_bridge_token};
    use rusqlite::params;
    use serde_json::{Value, json};
    use std::fs;

    use std::io::{self};

    #[test]
    fn pi_catalog_events_keep_only_valid_titles_and_emoji() {
        let parse = |name: &str, data: Value| format!("{:?}", PiCatalogEvent::parse(name, &data));
        assert_eq!(parse("agent.start", json!({})), "AgentStarted");
        assert_eq!(parse("ui.prompt.end", json!(null)), "PromptEnded");
        assert_eq!(
            parse("message.start", json!({"message": {"role": "user"}})),
            "UserMessageStarted"
        );
        assert_eq!(
            parse("message.start", json!({"message": {"role": "assistant"}})),
            "Ignored"
        );
        assert_eq!(
            parse("message.end", json!({"message": {"role": "user"}})),
            "MessageEnded"
        );
        assert_eq!(
            parse("message.end", json!({"message": {"role": "assistant"}})),
            "MessageEnded"
        );
        assert_eq!(
            parse("message.end", json!({"message": {"role": "toolResult"}})),
            "Ignored"
        );
        assert_eq!(
            parse("session.info", json!({ "name": "Fix the build" })),
            r#"Named { title: "Fix the build" }"#
        );
        assert_eq!(parse("session.info", json!({ "name": "" })), "Ignored");
        assert_eq!(parse("session.info", json!({ "name": 7 })), "Ignored");
        assert_eq!(
            parse(
                "axo.session.metadata",
                json!({ "title": "", "emoji": "🔧" })
            ),
            r#"Described { title: None, emoji: Some("🔧") }"#
        );
        assert_eq!(
            parse(
                "axo.session.metadata",
                json!({ "title": "", "emoji": "not an emoji" })
            ),
            "Ignored"
        );
        assert_eq!(
            parse("activity.snapshot", json!({ "working": true })),
            "ActivitySnapshot { working: true }"
        );
        assert_eq!(
            parse("activity.snapshot", json!({ "working": false })),
            "ActivitySnapshot { working: false }"
        );
        assert_eq!(parse("activity.snapshot", json!({})), "Ignored");
        assert_eq!(parse("message.delta", json!({ "name": "x" })), "Ignored");
    }

    #[test]
    fn startup_reconciliation_keeps_sockets_of_live_pis_only() {
        let directory = bridge_socket_directory();
        let database = Connection::open_in_memory().unwrap();
        database
            .execute_batch(
                "CREATE TABLE sessions (id TEXT PRIMARY KEY, pi_session_file TEXT, pi_bridge_socket_path TEXT);",
            )
            .unwrap();
        let live_file = directory.join("live.jsonl");
        let live_socket = directory.join("live.sock");
        let dead_file = directory.join("dead.jsonl");
        let dead_socket = directory.join("dead.sock");
        for (id, file, socket) in [(1, &live_file, &live_socket), (2, &dead_file, &dead_socket)] {
            abandoned_socket(socket);
            database
                .execute(
                    "INSERT INTO sessions VALUES (?1, ?2, ?3)",
                    params![
                        sid(id).to_string(),
                        file.to_string_lossy(),
                        socket.to_string_lossy()
                    ],
                )
                .unwrap();
        }
        let live_writer = WriterLock::acquire(&live_file).unwrap();

        remove_abandoned_pi_bridge_sockets(&database).unwrap();

        assert!(live_socket.exists(), "a live Pi keeps its socket");
        assert!(!dead_socket.exists());
        drop(live_writer);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn stale_runtime_callbacks_cannot_mutate_a_replacement_pi() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let old_runtime = manager
            .lock_state()
            .unwrap()
            .panes
            .running(shell_id)
            .unwrap()
            .runtime_id;
        let old_binding = PiRuntimeBinding {
            session_id: session.id,
            shell_id,
            runtime_id: old_runtime,
        };
        let old_attachment = TerminalAttachmentLease {
            manager,
            shell_id,
            runtime_id: old_runtime,
        };
        let mut replacement = spawn_shell(
            &ShellCommand::parse("/bin/sh").unwrap(),
            session.id,
            &fixture.directory,
            WindowSize::DEFAULT,
        )
        .unwrap();
        replacement.role = PaneRole::Pi;
        replacement.attachments = 1;
        let binding = PiRuntimeBinding {
            runtime_id: replacement.runtime_id,
            ..old_binding
        };
        let mut old = manager
            .lock_state()
            .unwrap()
            .install_running(shell_id, replacement)
            .unwrap();
        process::stop(&mut old.child, process::SHELL_STOP_GRACE);

        manager.set_pi_connection(binding, true).unwrap();
        assert!(
            manager
                .observe_pi_event(binding, "agent.start", &json!({}))
                .unwrap()
        );
        manager
            .persist_pi_session_id(binding, "replacement")
            .unwrap();
        // A stale attachment's release must not detach the replacement's clients.
        drop(old_attachment);
        manager.set_pi_connection(old_binding, false).unwrap();
        assert!(
            !manager
                .observe_pi_event(old_binding, "agent.settled", &json!({}))
                .unwrap()
        );
        assert!(
            !manager
                .observe_pi_event(
                    old_binding,
                    "session.info",
                    &json!({ "name": "stale title" }),
                )
                .unwrap()
        );
        assert!(
            manager
                .observe_pi_event(binding, "agent.settled", &json!({}))
                .unwrap()
        );
        assert!(
            manager
                .observe_pi_event(
                    binding,
                    "message.start",
                    &json!({ "message": { "role": "user" } }),
                )
                .unwrap()
        );
        assert_eq!(
            manager
                .persist_pi_session_id(old_binding, "old")
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert!(!manager.pi_runtime_is_current(old_binding));
        assert!(manager.pi_runtime_is_current(binding));
        let history = manager.pi_session_directory.join("resume.jsonl");
        fs::write(&history, b"unchanged transcript").unwrap();
        assert_eq!(
            manager
                .resume_archived_pi_session(old_binding, history.to_str().unwrap())
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );

        let state = manager.lock_state().unwrap();
        assert_eq!(state.panes.running(shell_id).unwrap().attachments, 1);
        assert!(state.pi_activity[&session.id].connected);
        assert!(state.pi_activity[&session.id].working);
        let updated = session_metadata(&state, session.id, &manager.attach_socket_path).unwrap();
        assert_eq!(updated.pi_session_id.as_deref(), Some("replacement"));
        assert_eq!(updated.name, session.name);
    }

    #[test]
    fn activity_snapshot_restores_working_state_after_bridge_reconnect() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let runtime_id = {
            let mut state = manager.lock_state().unwrap();
            let shell = state.panes.running_mut(shell_id).unwrap();
            shell.role = PaneRole::Pi;
            shell.runtime_id
        };
        let binding = PiRuntimeBinding {
            session_id: session.id,
            shell_id,
            runtime_id,
        };

        manager.set_pi_connection(binding, true).unwrap();
        assert!(
            manager
                .observe_pi_event(binding, "activity.snapshot", &json!({ "working": true }))
                .unwrap()
        );
        assert_eq!(
            manager.list_sessions().unwrap()[0].status,
            SessionStatus::Working
        );

        assert!(
            manager
                .observe_pi_event(binding, "activity.snapshot", &json!({ "working": false }))
                .unwrap()
        );
        assert_eq!(
            manager.list_sessions().unwrap()[0].status,
            SessionStatus::Ready
        );
    }

    #[test]
    fn pi_bridge_credential_is_persisted_per_session() {
        let mut database = Connection::open_in_memory().unwrap();
        initialize_database(&mut database).unwrap();
        let session_id = SessionId::new_v4().unwrap();
        let first_token = new_uuid_v4().unwrap();
        let second_token = new_uuid_v4().unwrap();

        assert_eq!(load_pi_bridge_token(&database, session_id).unwrap(), None);
        store_pi_bridge_token(&database, session_id, &first_token).unwrap();
        assert_eq!(
            load_pi_bridge_token(&database, session_id).unwrap(),
            Some(first_token)
        );
        store_pi_bridge_token(&database, session_id, &second_token).unwrap();
        assert_eq!(
            load_pi_bridge_token(&database, session_id).unwrap(),
            Some(second_token)
        );
    }
}
