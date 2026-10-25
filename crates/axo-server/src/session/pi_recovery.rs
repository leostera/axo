//! Launching and recovering Pi: restart of an unavailable pane, startup recovery and `/resume`
//! of an archived Session, all through one reservation (`PiRecoveryLease`).

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::catalog::session_metadata;
use super::lifecycle::close_session;
use super::pi_bridge::{PiRuntimeBinding, log_socket_cleanup};
use super::spawn::{spawn_shell, terminal_environment};
use super::{RunningShell, SessionManager, SessionState, stop_panes};
use crate::panes::{RecoveryRefused, RuntimeId, UnavailablePane};
use crate::workspace_access::WorkspaceDirectoryAccess;
use axo_pi::takeover::{self, TakeoverPolicy, TakeoverTarget, VerifiedProcessId};
use axo_pi::{AgentCommand, BridgeSocketPath, PiLaunch, PiProcess, WriterLock};
use axo_protocol::{Event, PaneRole, SessionId, SessionRecord, ShellId, new_uuid_v4};
use axo_pty::WindowSize;
use axo_pty::process::PtyProcess;
use axo_store::Connection;
use axo_store::{
    PiHistoryOwner, archived_pi_pane_count, pi_history_owners, reopen_archived_session,
    workspace_directory,
};
use axo_store::{
    StoredLifecycle, archive_shell_and_prune_layout, load_pi_bridge_token, read_open_sessions,
    store_pi_bridge_token,
};
use axo_store::{StoredPiSession, open_pi_session};

/// The longest transcript path Pi may ask to resume; the extension enforces the same bound.
const MAX_RESUME_PATH_BYTES: usize = 4096;

// A reservation keeps the unavailable pane in the catalog while recovery waits
// outside its mutex. Close/removal/shutdown invalidates it; failures release it.
pub(super) struct PiRecoveryLease<'a> {
    pub(super) manager: &'a SessionManager,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
    pub(super) recovery_id: RuntimeId,
}

impl PiRecoveryLease<'_> {
    fn is_current(&self, state: &SessionState) -> bool {
        !state.shutting_down
            && state
                .panes
                .is_recovering(self.session_id, self.shell_id, self.recovery_id)
    }

    pub(super) fn ensure_current(&self) -> io::Result<()> {
        let state = self.manager.lock_state()?;
        self.check_state(&state)
    }

    fn check_state(&self, state: &SessionState) -> io::Result<()> {
        if self.is_current(state) {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Pi recovery was cancelled",
            ))
        }
    }

    fn signal_current(&self, process_id: VerifiedProcessId, signal: libc::c_int) -> io::Result<()> {
        let state = self.manager.lock_state()?;
        self.check_state(&state)?;
        // Only these short syscalls run under the catalog mutex. Cancellation
        // and signal dispatch are ordered, with no socket/child waits here.
        takeover::signal_verified_process(process_id, signal)
    }
}

impl Drop for PiRecoveryLease<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.manager.state.lock() {
            state
                .panes
                .release_recovery(self.shell_id, self.recovery_id);
        }
    }
}

// Owned launch inputs: waiting/exec must not borrow the catalog or its database.
pub(super) struct PiLaunchRequest {
    pub(super) agent_command: AgentCommand,
    pub(super) session_id: SessionId,
    pub(super) initial_pwd: PathBuf,
    pub(super) session_file: PathBuf,
    pub(super) bridge_socket: BridgeSocketPath,
    pub(super) session_uuid: String,
    pub(super) pane_id: String,
    pub(super) previous_token: Option<String>,
    /// The PTY size Pi starts with.
    pub(super) size: WindowSize,
}

// New Session admission never takes over an existing writer. Recovery has a
// separate reservation/commit path, so no takeover wait can hide under its lock.
/// Starts Pi for a pane with no previous process (`request.previous_token` is ignored).
pub(super) fn spawn_new_pi(
    database: &Connection,
    request: &PiLaunchRequest,
) -> io::Result<RunningShell> {
    let lock = WriterLock::acquire(&request.session_file)?;
    let bridge_token = new_uuid_v4()?;
    store_pi_bridge_token(database, &request.session_uuid, &bridge_token)?;
    spawn_pi(request, lock, bridge_token)
}

fn spawn_pi(
    request: &PiLaunchRequest,
    lock: WriterLock,
    bridge_token: String,
) -> io::Result<RunningShell> {
    let home = crate::current_user_home_directory()?;
    let environment = terminal_environment();
    let PiProcess {
        pty:
            PtyProcess {
                child,
                master,
                device: slave_device,
                output,
            },
        writer_lock,
        socket_cleanup,
    } = axo_pi::spawn(
        &request.launch(&home, &environment),
        lock,
        &bridge_token,
        request.size,
    )?;
    log_socket_cleanup(request.session_id, socket_cleanup);
    Ok(RunningShell {
        runtime_id: RuntimeId::new(),
        session_id: request.session_id,
        role: PaneRole::Pi,
        pane_id: Some(request.pane_id.clone()),
        initial_pwd: request.initial_pwd.clone(),
        child,
        wait_error_reported: false,
        master,
        slave_device,
        attachments: 0,
        output,
        last_input_sequence: None,
        _writer_lock: Some(writer_lock),
        pi_bridge_socket: Some(request.bridge_socket.clone()),
        pi_bridge_token: Some(bridge_token),
    })
}

impl PiLaunchRequest {
    fn launch<'a>(
        &'a self,
        home: &'a Path,
        environment: &'a [(&'static str, PathBuf)],
    ) -> PiLaunch<'a> {
        PiLaunch {
            agent_command: &self.agent_command,
            initial_pwd: &self.initial_pwd,
            session_file: &self.session_file,
            bridge_socket: &self.bridge_socket,
            session_uuid: &self.session_uuid,
            pane_id: &self.pane_id,
            home,
            environment,
        }
    }

    fn takeover_target(&self) -> TakeoverTarget<'_> {
        TakeoverTarget {
            session_id: self.session_id,
            initial_pwd: &self.initial_pwd,
            session_file: &self.session_file,
            bridge_socket: &self.bridge_socket,
            session_uuid: &self.session_uuid,
            pane_id: &self.pane_id,
            previous_token: self.previous_token.as_deref(),
        }
    }
}

/// The RPC error for a recovery that could not be reserved.
fn recovery_refused(refused: RecoveryRefused) -> io::Error {
    match refused {
        RecoveryRefused::NotUnavailable => io::Error::new(
            io::ErrorKind::NotFound,
            "the requested Pi pane is not unavailable",
        ),
        RecoveryRefused::AlreadyRecovering => io::Error::new(
            io::ErrorKind::WouldBlock,
            "Pi recovery is already in progress",
        ),
    }
}

impl SessionManager {
    pub(super) fn recover_pi_shells(self: &Arc<Self>, panes: Vec<(SessionId, ShellId)>) {
        for (session_id, shell_id) in panes {
            if let Err(error) = self.restart_unavailable_pi(
                session_id,
                shell_id,
                TakeoverPolicy::PreserveExistingProcess,
            ) {
                log::warn!(
                    "event=session.pi_restore_unavailable session_id={} shell_id={} error_kind={:?}",
                    session_id.get(),
                    shell_id.get(),
                    error.kind()
                );
            }
        }
    }

    pub(super) fn restart_unavailable_pi(
        self: &Arc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
        takeover_policy: TakeoverPolicy,
    ) -> io::Result<SessionRecord> {
        let (request, recovery) = {
            let mut state = self.lock_state()?;
            if state.shutting_down {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Axod is shutting down",
                ));
            }
            let unavailable = state
                .panes
                .unavailable(shell_id)
                .filter(|shell| shell.session_id == session_id)
                .ok_or_else(|| recovery_refused(RecoveryRefused::NotUnavailable))?;
            if unavailable.is_recovering() {
                return Err(recovery_refused(RecoveryRefused::AlreadyRecovering));
            }
            let pane_id = unavailable.pane_id.clone().ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "Pi pane ID is missing")
            })?;
            let initial_pwd = unavailable.initial_pwd.clone();
            let StoredPiSession {
                session_uuid,
                session_file,
                bridge_socket_path,
            } = open_pi_session(&state.database, session_id)?;
            let session_file = session_file.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Pi Session is missing its persisted history path",
                )
            })?;
            let bridge_socket =
                BridgeSocketPath::parse(PathBuf::from(bridge_socket_path.ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Pi Session is missing its persisted bridge socket path",
                    )
                })?))?;
            if pi_history_owners(&state.database, &session_file.to_string_lossy())?.len() != 1 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Pi history has ambiguous Session ownership",
                ));
            }
            let request = PiLaunchRequest {
                agent_command: state.agent_command.clone(),
                session_id,
                initial_pwd,
                session_file,
                bridge_socket,
                previous_token: load_pi_bridge_token(&state.database, &session_uuid)?,
                session_uuid,
                pane_id,
                size: state.pane_size(session_id, shell_id),
            };
            // Reserved last, so no failure above leaves a reservation behind.
            let recovery_id = state
                .panes
                .begin_recovery(session_id, shell_id)
                .map_err(recovery_refused)?;
            let recovery = PiRecoveryLease {
                manager: self,
                session_id,
                shell_id,
                recovery_id,
            };
            (request, recovery)
        };

        let check_current = || recovery.ensure_current();
        let history =
            axo_pi::ensure_existing_history(&request.session_file, &self.pi_session_directory)?;
        let lock = takeover::take_over(
            request.takeover_target(),
            takeover_policy,
            &|| recovery.ensure_current(),
            &|process_id, signal| recovery.signal_current(process_id, signal),
        )?;
        if axo_pi::ensure_existing_history(&request.session_file, &self.pi_session_directory)?
            != history
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi history changed while recovery was waiting",
            ));
        }
        let bridge_token = new_uuid_v4()?;
        {
            let state = self.lock_state()?;
            if !recovery.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi recovery was cancelled",
                ));
            }
            // Rotate only while owning the original exclusive transcript lock.
            store_pi_bridge_token(&state.database, &request.session_uuid, &bridge_token)?;
        }
        check_current()?;
        let pending = spawn_pi(&request, lock, bridge_token)?;
        let session = self.commit_pi_recovery(&recovery, pending)?;
        self.start_pi_bridge_worker(shell_id)?;
        self.publish_session_snapshot(session_id)?;
        Ok(session)
    }

    pub(super) fn commit_pi_recovery(
        &self,
        recovery: &PiRecoveryLease<'_>,
        running: RunningShell,
    ) -> io::Result<SessionRecord> {
        let PiRecoveryLease {
            session_id,
            shell_id,
            recovery_id,
            ..
        } = *recovery;
        let committed = match self.lock_state() {
            Ok(mut state) => {
                // Only this reservation may replace the unavailable pane, never a concurrent
                // newer launch; metadata is built after installing the process.
                match state.commit_recovery(session_id, shell_id, recovery_id, running) {
                    Ok(()) => {
                        state.pi_activity.remove(&session_id);
                        Ok(session_metadata(
                            &state,
                            session_id,
                            &self.attach_socket_path,
                        ))
                    }
                    Err(cancelled) => Err((
                        cancelled,
                        io::Error::new(io::ErrorKind::Interrupted, "Pi recovery was cancelled"),
                    )),
                }
            }
            Err(error) => Err((running, error)),
        };
        match committed {
            Ok(metadata) => metadata,
            Err((cancelled, error)) => {
                // A close/shutdown may win during exec. Clean up outside the catalog lock and
                // keep the writer lock until the child exits.
                stop_panes(vec![cancelled]);
                Err(error)
            }
        }
    }

    pub(super) fn resume_archived_pi_session(
        self: &Arc<Self>,
        requester: PiRuntimeBinding,
        requested_session_file: &str,
    ) -> io::Result<SessionId> {
        if requested_session_file.is_empty()
            || requested_session_file.len() > MAX_RESUME_PATH_BYTES
            || requested_session_file.contains('\0')
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi session path is invalid",
            ));
        }
        let session_file = PathBuf::from(requested_session_file);
        let canonical_directory = fs::canonicalize(&self.pi_session_directory)?;
        let canonical_file = fs::canonicalize(&session_file)?;
        if !canonical_file.starts_with(&canonical_directory)
            || !fs::metadata(&canonical_file)?.is_file()
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Pi session is not an Axo-owned history file",
            ));
        }

        let PiHistoryOwner {
            session_id,
            lifecycle,
            initial_pwd,
            workspace_id,
        } = {
            let state = self.lock_state()?;
            if !requester.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Pi resume request came from a stale pane",
                ));
            }
            let owners = pi_history_owners(&state.database, requested_session_file)?;
            let Ok([record]) = <[_; 1]>::try_from(owners) else {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "no unique Axo Session owns this Pi history",
                ));
            };
            record
        };

        if lifecycle == StoredLifecycle::Open {
            return self.complete_pi_resume(requester, session_id);
        }
        let workspace_access = if let Some(workspace_id) = &workspace_id {
            let (directory_path, bookmark) =
                workspace_directory(&self.lock_state()?.database, workspace_id)?;
            let access =
                WorkspaceDirectoryAccess::open(Path::new(&directory_path), bookmark.as_deref())?;
            if !initial_pwd.starts_with(access.path()) {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Session working directory is outside its Workspace",
                ));
            }
            Some((workspace_id.clone(), access))
        } else {
            if !initial_pwd.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "the Session's working directory is unavailable",
                ));
            }
            None
        };

        if archived_pi_pane_count(&self.lock_state()?.database, session_id)? != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "archived Session does not have exactly one Pi pane",
            ));
        }

        let pi_shells = {
            let mut state = self.lock_state()?;
            if state.shutting_down || !requester.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi resume request is no longer current",
                ));
            }
            if state.panes.has_session(session_id) {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "archived Session still has live Axo process state",
                ));
            }

            reopen_archived_session(&mut state.database, session_id, workspace_id.as_deref())?;
            if let Some((workspace_id, access)) = workspace_access {
                self.workspace_access
                    .lock()
                    .map_err(|_| io::Error::other("Workspace access lock was poisoned"))?
                    .insert(workspace_id, access);
            }

            let record = read_open_sessions(&state.database)?
                .into_iter()
                .find(|record| record.id == session_id)
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "resumed Session record is missing")
                })?;
            let mut remaining_shell_ids: HashSet<_> = record
                .shell_ids
                .iter()
                .map(|(shell_id, _, _)| *shell_id)
                .collect();
            let mut pi_shells = Vec::new();
            for (shell_id, role, pane_id) in record.shell_ids {
                match role {
                    PaneRole::Terminal => {
                        let size = state.pane_size(session_id, shell_id);
                        match spawn_shell(
                            &state.shell_command,
                            session_id,
                            &record.initial_pwd,
                            size,
                        ) {
                            Ok(shell) => {
                                state.install_running(shell_id, shell);
                            }
                            Err(error) => {
                                log::warn!(
                                    "event=session.terminal_restore_unavailable session_id={} shell_id={} error_kind={:?}",
                                    session_id.get(),
                                    shell_id.get(),
                                    error.kind()
                                );
                                remaining_shell_ids.remove(&shell_id);
                                archive_shell_and_prune_layout(
                                    &mut state.database,
                                    shell_id,
                                    session_id,
                                    "resume_spawn_failed",
                                    &remaining_shell_ids,
                                )?;
                            }
                        }
                    }
                    PaneRole::Pi => {
                        // The Session had no live panes (checked above).
                        let _ = state.panes.insert_unavailable(
                            shell_id,
                            UnavailablePane::new(session_id, pane_id, record.initial_pwd.clone()),
                        );
                        pi_shells.push((session_id, shell_id));
                    }
                }
            }
            pi_shells
        };

        self.recover_pi_shells(pi_shells);
        self.complete_pi_resume(requester, session_id)
    }

    pub(super) fn complete_pi_resume(
        self: &Arc<Self>,
        requester: PiRuntimeBinding,
        target_session_id: SessionId,
    ) -> io::Result<SessionId> {
        let requester_session_id = requester.session_id;
        let (replacement, shells) = {
            let mut state = self.lock_state()?;
            if state.shutting_down || !requester.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "requesting Pi runtime is no longer current",
                ));
            }
            // Target readiness and requester archival are one catalog transition.
            // A concurrent target close/recovery cannot slip between these checks.
            let target = session_metadata(&state, target_session_id, &self.attach_socket_path)?;
            if !target
                .shells
                .iter()
                .any(|shell| shell.role == PaneRole::Pi && shell.is_available())
            {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "resumed Pi pane is not available",
                ));
            }
            if requester_session_id != target_session_id {
                close_session(
                    &mut state,
                    requester_session_id,
                    &self.attach_socket_path,
                    &self.pi_session_directory,
                )?
            } else {
                (None, Vec::new())
            }
        };

        if requester_session_id != target_session_id {
            self.terminate_shells_in_background(shells);
            if let Some(session) = &replacement {
                self.start_pi_bridge_for_session(session)?;
            }
            self.publish_session_removed(requester_session_id);
            if let Some(replacement) = replacement {
                self.publish_event(Event::snapshot(replacement.clone()));
            }
        }

        self.request_session_focus(target_session_id)?;
        self.publish_session_snapshot(target_session_id)?;
        log::info!(
            "event=session.pi_resume_completed session_id={}",
            target_session_id.get()
        );
        Ok(target_session_id)
    }
}
