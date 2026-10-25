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
        let (request, recovery, grace) = {
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
            (request, recovery, state.takeover_grace)
        };

        let check_current = || recovery.ensure_current();
        let history =
            axo_pi::ensure_existing_history(&request.session_file, &self.pi_session_directory)?;
        let lock = takeover::take_over(
            request.takeover_target(),
            takeover_policy,
            grace,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::panes::RuntimeId;
    use crate::session::{pi_bridge::*, test_support::*};
    use axo_pi::bridge;
    use axo_pi::takeover::{TakeoverGrace, TakeoverPolicy};
    use axo_pi::{AgentCommand, BridgeSocketPath, WriterLock};
    use axo_protocol::rpc;
    use axo_protocol::{
        Availability, Layout, LayoutDirection, LayoutNode, PaneRole, SessionStatus, new_uuid_v4,
    };
    use axo_pty::WindowSize;
    use axo_pty::process;
    use axo_store::Connection;
    use axo_store::{DATABASE_FILE, load_pi_bridge_token, store_pi_bridge_token};
    use axo_store::{initialize_database, unix_timestamp};
    use rusqlite::params;
    use serde_json::{Value, json};
    use std::fs;
    use std::fs::OpenOptions;
    use std::io;
    use std::io::BufReader;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::os::unix::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use std::thread::{self};
    use std::time::{Duration, Instant};

    #[test]
    fn stalled_pi_recovery_keeps_catalog_and_sibling_ptys_responsive() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        let (worker, _bridge) = fixture.begin_recovery(TakeoverPolicy::PreserveExistingProcess);
        let start = Instant::now();
        assert!(
            manager.state.try_lock().is_ok(),
            "recovery held the shared catalog lock during authentication"
        );
        let home = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id != fixture.session_id)
            .unwrap();
        manager.rename_session(home.id, "Still responsive").unwrap();
        let attachment = manager.attach_shell(home.shells[0].id).unwrap();
        manager.mark_detached(home.shells[0].id, attachment.runtime_id);
        let error = manager
            .restart_unavailable_pi(
                fixture.session_id,
                fixture.shell_id,
                TakeoverPolicy::ExplicitUserRestart,
            )
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(start.elapsed() < Duration::from_secs(1));
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        let state = manager.lock_state().unwrap();
        assert!(
            !state
                .panes
                .unavailable(fixture.shell_id)
                .unwrap()
                .is_recovering()
        );
        assert_eq!(
            load_pi_bridge_token(&state.database, &fixture.session_uuid)
                .unwrap()
                .as_deref(),
            Some(fixture.token.as_str())
        );
        drop(state);
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn closing_a_pi_pane_cancels_pending_takeover_without_escalating() {
        for policy in [
            TakeoverPolicy::PreserveExistingProcess,
            TakeoverPolicy::ExplicitUserRestart,
        ] {
            let fixture = PiRecoveryFixture::new();
            let lock = WriterLock::acquire(&fixture.file).unwrap();
            let mut command = Command::new("/bin/sleep");
            command.arg("60");
            // SAFETY: isolated test child creates its own process group.
            unsafe {
                command.pre_exec(|| {
                    if libc::setsid() == -1 {
                        Err(io::Error::last_os_error())
                    } else {
                        Ok(())
                    }
                });
            }
            let mut old_pi = ChildProcessGuard(command.spawn().unwrap());
            let (worker, mut bridge) = fixture.begin_recovery(policy);
            fixture.accept_shutdown(&mut bridge, old_pi.0.id());
            let start = Instant::now();
            fixture
                .lifecycle
                .manager
                .close_session(fixture.session_id)
                .unwrap();
            assert_eq!(
                worker.join().unwrap().unwrap_err().kind(),
                io::ErrorKind::Interrupted
            );
            assert!(start.elapsed() < Duration::from_secs(1));
            assert!(
                old_pi.0.try_wait().unwrap().is_none(),
                "cancelled recovery signalled the old process"
            );
            let state = fixture.lifecycle.manager.lock_state().unwrap();
            assert!(!state.panes.running(fixture.shell_id).is_some());
            assert!(!state.panes.unavailable(fixture.shell_id).is_some());
            let lifecycle: String = state
                .database
                .query_row(
                    "SELECT state FROM sessions WHERE id = ?1",
                    params![fixture.session_id.get()],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(lifecycle, "archived");
            drop(state);
            drop(lock);
            fixture.assert_preserved();
        }
    }

    #[test]
    fn shutdown_fences_pending_pi_recovery_and_future_restarts() {
        let fixture = PiRecoveryFixture::new();
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        let (worker, _bridge) = fixture.begin_recovery(TakeoverPolicy::PreserveExistingProcess);
        let start = Instant::now();
        fixture.lifecycle.manager.shutdown();
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(
            fixture
                .lifecycle
                .manager
                .lock_state()
                .unwrap()
                .panes
                .running_is_empty()
        );
        assert_eq!(
            fixture
                .lifecycle
                .manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::ExplicitUserRestart
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn failed_pi_exec_releases_recovery_reservation_and_original_writer_lock() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let original_command = manager.lock_state().unwrap().agent_command.clone();
        let broken_executable = fixture.lifecycle.directory.join("broken-pi");
        fs::write(
            &broken_executable,
            "#!/nonexistent/axo-fixture-interpreter\n",
        )
        .unwrap();
        fs::set_permissions(&broken_executable, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(broken_executable.to_str().unwrap()).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::PreserveExistingProcess
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert!(
            !manager
                .lock_state()
                .unwrap()
                .panes
                .unavailable(fixture.shell_id)
                .unwrap()
                .is_recovering()
        );
        // Concurrent forked fixture children may briefly hold CLOEXEC copies
        // until exec. Bound the wait rather than requiring instantaneous release.
        drop(WriterLock::wait(&fixture.file, Duration::from_secs(1), &|| Ok(())).unwrap());
        manager.lock_state().unwrap().agent_command = original_command;
        let recovered = manager
            .restart_unavailable_pi(
                fixture.session_id,
                fixture.shell_id,
                TakeoverPolicy::PreserveExistingProcess,
            )
            .unwrap();
        assert!(
            recovered
                .shells
                .iter()
                .any(|shell| shell.id == fixture.shell_id && shell.is_available())
        );
        assert_eq!(
            WriterLock::acquire(&fixture.file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        fixture.assert_preserved();
    }

    #[test]
    fn cancelled_pi_launch_is_cleaned_up_instead_of_resurrecting_the_pane() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let (recovery_id, pending) = {
            let mut state = manager.lock_state().unwrap();
            let recovery_id = state
                .panes
                .begin_recovery(fixture.session_id, fixture.shell_id)
                .unwrap();
            let pending = spawn_new_pi(
                &state.database,
                &PiLaunchRequest {
                    agent_command: state.agent_command.clone(),
                    session_id: fixture.session_id,
                    initial_pwd: fixture.lifecycle.directory.clone(),
                    session_file: fixture.file.clone(),
                    bridge_socket: fixture.socket.clone(),
                    session_uuid: fixture.session_uuid.clone(),
                    pane_id: fixture.pane_id.clone(),
                    previous_token: None,
                    size: WindowSize::DEFAULT,
                },
            )
            .unwrap();
            (recovery_id, pending)
        };
        let recovery = PiRecoveryLease {
            manager,
            session_id: fixture.session_id,
            shell_id: fixture.shell_id,
            recovery_id,
        };
        manager.close_session(fixture.session_id).unwrap();
        assert_eq!(
            manager
                .commit_pi_recovery(&recovery, pending)
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );
        assert!(
            !manager
                .lock_state()
                .unwrap()
                .panes
                .running(fixture.shell_id)
                .is_some()
        );
        // Both parent and child lock copies must be released by cleanup. Other
        // concurrent fixture forks can retain CLOEXEC copies briefly until exec.
        drop(WriterLock::wait(&fixture.file, Duration::from_secs(1), &|| Ok(())).unwrap());
        fixture.assert_preserved();
    }

    #[test]
    fn pi_recovery_rejects_missing_and_ambiguously_owned_history() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        fs::remove_file(&fixture.file).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::PreserveExistingProcess
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert!(!fixture.file.exists());
        assert!(!fixture.file.with_extension("jsonl.lock").exists());
        fs::write(&fixture.file, b"original history\n").unwrap();
        manager.lock_state().unwrap().database.execute(
            "INSERT INTO sessions (initial_pwd, state, created_at, session_uuid, pi_session_file) VALUES ('/tmp', 'archived', ?1, ?2, ?3)",
            params![unix_timestamp(), new_uuid_v4().unwrap(), fixture.file.to_string_lossy()],
        ).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::ExplicitUserRestart
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert!(!fixture.file.with_extension("jsonl.lock").exists());
        fixture.assert_preserved();
    }

    #[test]
    fn pi_recovery_rejects_history_replaced_during_takeover() {
        let fixture = PiRecoveryFixture::new();
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        let (worker, mut bridge) = fixture.begin_recovery(TakeoverPolicy::PreserveExistingProcess);
        // The unavailable writer's identity must never turn into a different
        // history merely because the path was reused while takeover waited.
        let original = fixture.file.with_extension("saved.jsonl");
        fs::rename(&fixture.file, &original).unwrap();
        fs::write(&fixture.file, b"replacement history\n").unwrap();
        fixture.accept_shutdown(&mut bridge, 2);
        drop(lock);
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(fs::read(&fixture.file).unwrap(), b"replacement history\n");
        assert_eq!(fs::read(&original).unwrap(), b"original history\n");
        let state = fixture.lifecycle.manager.lock_state().unwrap();
        assert!(!state.panes.running(fixture.shell_id).is_some());
        assert!(
            !state
                .panes
                .unavailable(fixture.shell_id)
                .unwrap()
                .is_recovering()
        );
        assert_eq!(
            load_pi_bridge_token(&state.database, &fixture.session_uuid)
                .unwrap()
                .as_deref(),
            Some(fixture.token.as_str())
        );
    }

    #[test]
    fn pi_recovery_rejects_symlinked_and_outside_history_without_touching_it() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let original = fixture.file.with_extension("original.jsonl");
        fs::rename(&fixture.file, &original).unwrap();
        std::os::unix::fs::symlink(&original, &fixture.file).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::PreserveExistingProcess
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(fs::read(&original).unwrap(), b"original history\n");
        assert!(!fixture.file.with_extension("jsonl.lock").exists());
        fs::remove_file(&fixture.file).unwrap();
        fs::rename(&original, &fixture.file).unwrap();
        let outside = fixture.lifecycle.directory.join("outside.jsonl");
        fs::write(&outside, b"not an owned Pi history\n").unwrap();
        manager
            .lock_state()
            .unwrap()
            .database
            .execute(
                "UPDATE sessions SET pi_session_file = ?1 WHERE id = ?2",
                params![outside.to_string_lossy(), fixture.session_id.get()],
            )
            .unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::ExplicitUserRestart
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(fs::read(&outside).unwrap(), b"not an owned Pi history\n");
        assert!(!outside.with_extension("jsonl.lock").exists());
        fixture.assert_preserved();
    }

    #[test]
    fn resume_handoff_preserves_requester_when_target_or_runtime_is_unavailable() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let home = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id != fixture.session_id)
            .unwrap();
        let requester = {
            let mut state = manager.lock_state().unwrap();
            let shell = state.panes.running_mut(home.shells[0].id).unwrap();
            shell.role = PaneRole::Pi;
            PiRuntimeBinding {
                session_id: home.id,
                shell_id: home.shells[0].id,
                runtime_id: shell.runtime_id,
            }
        };
        assert_eq!(
            manager
                .complete_pi_resume(requester, fixture.session_id)
                .unwrap_err()
                .kind(),
            io::ErrorKind::WouldBlock
        );
        manager.close_session(fixture.session_id).unwrap();
        assert!(
            manager
                .complete_pi_resume(requester, fixture.session_id)
                .is_err()
        );
        let stale = PiRuntimeBinding {
            runtime_id: RuntimeId::new(),
            ..requester
        };
        assert_eq!(
            manager
                .complete_pi_resume(stale, home.id)
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );
        assert!(manager.pi_runtime_is_current(requester));
        assert!(
            manager
                .list_sessions()
                .unwrap()
                .iter()
                .any(|session| session.id == home.id)
        );
        assert_eq!(manager.take_pending_resume_focus().unwrap(), None);
        fixture.assert_preserved();
    }

    #[test]
    fn stale_recovery_lease_cannot_release_a_newer_reservation() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let old_id = RuntimeId::new();
        let old = PiRecoveryLease {
            manager,
            session_id: fixture.session_id,
            shell_id: fixture.shell_id,
            recovery_id: old_id,
        };
        let new_id = manager
            .lock_state()
            .unwrap()
            .panes
            .begin_recovery(fixture.session_id, fixture.shell_id)
            .unwrap();
        assert_eq!(
            old.ensure_current().unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
        drop(old);
        assert!(manager.lock_state().unwrap().panes.is_recovering(
            fixture.session_id,
            fixture.shell_id,
            new_id
        ));
    }

    #[test]
    fn pi_writer_lock_is_inherited_only_by_its_pi_child() {
        let fixture = LifecycleFixture::new();
        let fake_pi = fixture.directory.join("fake-pi");
        fs::write(&fake_pi, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&fake_pi, fs::Permissions::from_mode(0o700)).unwrap();
        let agent = AgentCommand::parse(fake_pi.to_str().unwrap()).unwrap();
        let session_uuid = new_uuid_v4().unwrap();
        let pane_id = new_uuid_v4().unwrap();
        let file = fixture
            .manager
            .pi_session_directory
            .join(format!("{session_uuid}.jsonl"));
        fs::write(&file, b"preserved history").unwrap();
        let socket =
            BridgeSocketPath::for_session(&fixture.manager.pi_session_directory, &session_uuid)
                .unwrap();
        let mut pi = {
            let state = fixture.manager.lock_state().unwrap();
            spawn_new_pi(
                &state.database,
                &PiLaunchRequest {
                    agent_command: agent.clone(),
                    session_id: sid(900),
                    initial_pwd: fixture.directory.clone(),
                    session_file: file.clone(),
                    bridge_socket: socket.clone(),
                    session_uuid: session_uuid.clone(),
                    pane_id: pane_id.clone(),
                    previous_token: None,
                    size: WindowSize::DEFAULT,
                },
            )
            .unwrap()
        };
        // Guard the owned fixture child even if an assertion below fails.
        let lock = pi._writer_lock.take().unwrap();
        let mut child = RunningShellGuard(pi);
        // SAFETY: lock is a live descriptor owned by this fixture.
        assert_ne!(
            unsafe { libc::fcntl(lock.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        let mut unrelated =
            ChildProcessGuard(Command::new("/bin/sleep").arg("60").spawn().unwrap());
        drop(lock);
        assert_eq!(
            WriterLock::acquire(&file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        process::stop(&mut child.0.child, process::SHELL_STOP_GRACE);
        // Concurrent forked fixture children may briefly hold CLOEXEC copies until exec.
        let recovered = WriterLock::wait(&file, Duration::from_secs(1), &|| Ok(())).unwrap();
        assert!(unrelated.0.try_wait().unwrap().is_none());
        assert_eq!(fs::read(&file).unwrap(), b"preserved history");
        drop(recovered);
    }

    #[test]
    fn automatic_pi_restart_preserves_busy_pi_and_explicit_restart_preserves_history() {
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", new_uuid_v4().unwrap()));
        let server_directory = directory.join("server");
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory).unwrap();

        let session_id = sid(701);
        let shell_id = shid(801);
        let session_uuid = new_uuid_v4().unwrap();
        let pane_id = new_uuid_v4().unwrap();
        let session_file = pi_session_directory.join(format!("{session_uuid}.jsonl"));
        fs::write(&session_file, b"preserved Pi transcript\n").unwrap();
        let lock_path = session_file.with_extension("jsonl.lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)
            .unwrap();
        // SAFETY: lock is a live file descriptor opened by this isolated test.
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        // Make the locked open-file description survive exec so the fixture Pi owns the lock.
        let lock_fd = lock.as_raw_fd();
        let mut old_pi_command = Command::new("/bin/sh");
        old_pi_command.args(["-c", "trap '' TERM; exec /bin/sleep 60"]);
        // SAFETY: the child-only hook clears close-on-exec on the fixture lock descriptor.
        unsafe {
            old_pi_command.pre_exec(move || {
                if libc::setsid() == -1 {
                    return Err(io::Error::last_os_error());
                }
                if libc::fcntl(lock_fd, libc::F_SETFD, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut old_pi = ChildProcessGuard(old_pi_command.spawn().unwrap());
        let old_pi_process_id = old_pi.0.id();
        drop(lock);

        let mut database = Connection::open(server_directory.join(DATABASE_FILE)).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO sessions
                    (id, initial_pwd, state, created_at, layout_json, session_uuid, name, pi_session_file)
                 VALUES (?1, '/tmp', 'open', ?2, ?3, ?4, 'Recovery fixture', ?5)",
                params![
                    session_id.get(),
                    unix_timestamp(),
                    serde_json::to_string(&Layout::single(shell_id)).unwrap(),
                    session_uuid,
                    session_file.to_string_lossy(),
                ],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO shells (id, session_id, initial_pwd, state, created_at, role, pane_id)
                 VALUES (?1, ?2, '/tmp', 'open', ?3, 'pi', ?4)",
                params![shell_id.get(), session_id.get(), unix_timestamp(), pane_id],
            )
            .unwrap();
        let bridge_token = new_uuid_v4().unwrap();
        store_pi_bridge_token(&database, &session_uuid, &bridge_token).unwrap();
        drop(database);

        let bridge_socket =
            BridgeSocketPath::for_session(&pi_session_directory, &session_uuid).unwrap();
        drop(UnixListener::bind(bridge_socket.as_path()).unwrap());

        let manager = open_with_silent_shell(&server_directory);
        // The old Pi ignores SIGTERM; escalation is what is tested, not the production waits.
        manager.lock_state().unwrap().takeover_grace = TakeoverGrace {
            before_terminate: Duration::from_millis(100),
            before_kill: Duration::from_millis(100),
        };
        let stored_bridge_socket: String = manager
            .lock_state()
            .unwrap()
            .database
            .query_row(
                "SELECT pi_bridge_socket_path FROM sessions WHERE id = ?1",
                params![session_id.get()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(Path::new(&stored_bridge_socket), bridge_socket.as_path());
        let sessions = manager.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session_id);
        assert!(matches!(sessions[0].status, SessionStatus::Unavailable));
        assert_eq!(sessions[0].layout, Some(Layout::single(shell_id)));
        assert_eq!(sessions[0].shells.len(), 1);
        assert_eq!(sessions[0].shells[0].id, shell_id);
        assert!(!sessions[0].shells[0].is_available());
        assert_eq!(sessions[0].shells[0].process_id, 0);
        assert!(matches!(
            sessions[0].shells[0].availability,
            Availability::Unavailable { .. }
        ));
        manager
            .set_layout(session_id, Layout::single(shell_id))
            .unwrap();
        assert!(
            manager
                .restart_unavailable_pi(
                    session_id,
                    shell_id,
                    TakeoverPolicy::PreserveExistingProcess,
                )
                .is_err()
        );
        assert!(old_pi.0.try_wait().unwrap().is_none());

        let restart_error = manager
            .restart_unavailable_pi(session_id, shell_id, TakeoverPolicy::ExplicitUserRestart)
            .unwrap_err();
        assert_eq!(restart_error.kind(), io::ErrorKind::PermissionDenied);
        assert!(old_pi.0.try_wait().unwrap().is_none());
        assert!(!manager.list_sessions().unwrap()[0].shells[0].is_available());

        manager.restore_open_sessions().unwrap();
        assert_eq!(manager.list_sessions().unwrap().len(), 1);
        assert!(!manager.list_sessions().unwrap()[0].shells[0].is_available());

        fs::remove_file(bridge_socket.as_path()).unwrap();
        let listener = UnixListener::bind(bridge_socket.as_path()).unwrap();
        let handshake_session_file = session_file.to_string_lossy().into_owned();
        let handshake_session_uuid = session_uuid.clone();
        let handshake_pane_id = pane_id.clone();
        let handshake_bridge_token = bridge_token.clone();
        let bridge_server = thread::spawn(move || {
            for (expected_action, result_reason) in
                [("shutdownIfIdle", "busy"), ("shutdown", "stale")]
            {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let authentication = bridge::read_record::<Value>(&mut reader).unwrap();
                assert_eq!(authentication["token"], handshake_bridge_token);
                bridge::write_record(
                    reader.get_mut(),
                    &json!({ "type": "authenticated", "protocolVersion": 1 }),
                )
                .unwrap();
                bridge::write_record(
                    reader.get_mut(),
                    &json!({
                        "type": "hello",
                        "protocolVersion": 1,
                        "identity": {
                            "axoSessionId": handshake_session_uuid,
                            "axoPaneId": handshake_pane_id,
                            "piSessionId": "pi-takeover",
                            "sessionFile": handshake_session_file,
                            "cwd": "/tmp",
                            "processId": old_pi_process_id
                        }
                    }),
                )
                .unwrap();
                let shutdown = bridge::read_record::<Value>(&mut reader).unwrap();
                assert_eq!(shutdown["action"]["kind"], expected_action);
                bridge::write_record(
                    reader.get_mut(),
                    &json!({
                        "type": "commandResult",
                        "requestId": shutdown["requestId"],
                        "result": { "accepted": false, "reason": result_reason }
                    }),
                )
                .unwrap();
            }
        });

        let fake_pi = directory.join("fake-pi");
        fs::write(&fake_pi, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&fake_pi, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(fake_pi.to_str().unwrap()).unwrap();

        let automatic_error = manager
            .restart_unavailable_pi(
                session_id,
                shell_id,
                TakeoverPolicy::PreserveExistingProcess,
            )
            .unwrap_err();
        assert_eq!(automatic_error.kind(), io::ErrorKind::WouldBlock);
        assert!(old_pi.0.try_wait().unwrap().is_none());
        assert!(!manager.list_sessions().unwrap()[0].shells[0].is_available());

        let restarted = manager
            .restart_unavailable_pi(session_id, shell_id, TakeoverPolicy::ExplicitUserRestart)
            .unwrap();
        bridge_server.join().unwrap();
        assert_eq!(restarted.id, session_id);
        assert_eq!(restarted.shells.len(), 1);
        assert_eq!(restarted.shells[0].id, shell_id);
        assert!(restarted.shells[0].is_available());
        assert!(restarted.shells[0].process_id > 0);
        assert!(manager.list_sessions().unwrap()[0].shells[0].is_available());
        assert!(old_pi.0.try_wait().unwrap().is_some());
        let terminal_shell = manager.create_shell(session_id).unwrap();
        manager
            .set_layout(
                session_id,
                Layout::try_from(LayoutNode::Split {
                    id: new_uuid_v4().unwrap(),
                    direction: LayoutDirection::Right,
                    ratio: 0.5,
                    first: Box::new(LayoutNode::Pane { shell_id }),
                    second: Box::new(LayoutNode::Pane {
                        shell_id: terminal_shell.id,
                    }),
                })
                .unwrap(),
            )
            .unwrap();
        assert_eq!(
            fs::read(&session_file).unwrap(),
            b"preserved Pi transcript\n"
        );

        {
            let mut state = manager.lock_state().unwrap();
            state
                .panes
                .running_mut(shell_id)
                .unwrap()
                .child
                .kill()
                .unwrap();
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            manager.reap_exited_sessions().unwrap();
            let sessions = manager.list_sessions().unwrap();
            if sessions.len() == 1
                && sessions[0]
                    .shells
                    .iter()
                    .any(|shell| shell.id == shell_id && !shell.is_available())
            {
                break;
            }
            assert!(Instant::now() < deadline, "Pi exit was not reconciled");
            thread::sleep(Duration::from_millis(10));
        }
        let sessions = manager.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session_id);
        assert_eq!(
            sessions[0].pi_session_file.as_deref(),
            Some(session_file.as_path())
        );
        assert_eq!(sessions[0].shells.len(), 2);
        assert!(
            !sessions[0]
                .shells
                .iter()
                .find(|shell| shell.id == shell_id)
                .unwrap()
                .is_available()
        );
        assert!(
            sessions[0]
                .shells
                .iter()
                .find(|shell| shell.id == terminal_shell.id)
                .unwrap()
                .is_available()
        );
        assert_eq!(
            fs::read(&session_file).unwrap(),
            b"preserved Pi transcript\n"
        );
        {
            let state = manager.lock_state().unwrap();
            let session_state: (String, Option<String>) = state
                .database
                .query_row(
                    "SELECT state, termination_reason FROM sessions WHERE id = ?1",
                    params![session_id.get()],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap();
            assert_eq!(session_state, ("open".to_owned(), None));
        }
        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn pi_resume_reopens_archived_axo_session_without_replacing_history() {
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", new_uuid_v4().unwrap()));
        let server_directory = directory.join("server");
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory).unwrap();
        let database_path = server_directory.join(DATABASE_FILE);
        let session_id = sid(901);
        let shell_id = shid(902);
        let session_uuid = new_uuid_v4().unwrap();
        let pane_id = new_uuid_v4().unwrap();
        let workspace_id = new_uuid_v4().unwrap();
        let workspace_root = PathBuf::from("/tmp").canonicalize().unwrap();
        let workspace_root_string = workspace_root.to_string_lossy().into_owned();
        let session_file = pi_session_directory.join(format!("{session_uuid}.jsonl"));
        let history = b"archived Pi conversation must remain canonical\n";
        fs::write(&session_file, history).unwrap();

        let mut database = Connection::open(&database_path).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO workspaces (workspace_id, name, directory_path, state, created_at, archived_at)
                 VALUES (?1, 'Archived Workspace', ?2, 'archived', ?3, ?4)",
                params![
                    workspace_id,
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp()
                ],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO sessions
                    (id, initial_pwd, state, created_at, archived_at, termination_reason,
                     layout_json, workspace_id, session_uuid, pi_session_file, pi_session_id)
                 VALUES (?1, ?2, 'archived', ?3, ?4, 'pi_exited', ?5, ?6, ?7, ?8, 'pi-session-archived')",
                params![
                    session_id.get(),
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp(),
                    serde_json::to_string(&Layout::single(shell_id)).unwrap(),
                    workspace_id,
                    session_uuid,
                    session_file.to_string_lossy(),
                ],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO shells
                    (id, session_id, initial_pwd, state, created_at, archived_at, termination_reason, role, pane_id)
                 VALUES (?1, ?2, ?3, 'archived', ?4, ?5, 'pi_exited', 'pi', ?6)",
                params![
                    shell_id.get(),
                    session_id.get(),
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp(),
                    pane_id
                ],
            )
            .unwrap();
        drop(database);

        let manager = open_with_silent_shell(&server_directory);
        let fake_pi = directory.join("fake-pi");
        fs::write(&fake_pi, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&fake_pi, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(fake_pi.to_str().unwrap()).unwrap();
        let active_workspace = manager
            .create_workspace(rpc::CreateWorkspace {
                name: "Active Workspace".to_owned(),
                directory_path: PathBuf::from("/tmp").canonicalize().unwrap(),
                directory_bookmark: None,
            })
            .unwrap();
        let requester_session_id = active_workspace.session.id;
        let requester_shell_id = active_workspace.session.shells[0].id;
        let requester = PiRuntimeBinding {
            session_id: requester_session_id,
            shell_id: requester_shell_id,
            runtime_id: manager
                .lock_state()
                .unwrap()
                .panes
                .running(requester_shell_id)
                .unwrap()
                .runtime_id,
        };
        let unrelated_history = directory.join("unowned.jsonl");
        fs::write(&unrelated_history, b"not an Axo transcript").unwrap();
        let rejected = manager
            .resume_archived_pi_session(requester, unrelated_history.to_str().unwrap())
            .unwrap_err();
        assert_eq!(rejected.kind(), io::ErrorKind::PermissionDenied);

        assert_eq!(
            manager
                .resume_archived_pi_session(requester, session_file.to_str().unwrap())
                .unwrap(),
            session_id
        );
        assert_eq!(
            manager.take_pending_resume_focus().unwrap(),
            Some(session_id)
        );
        assert_eq!(manager.take_pending_resume_focus().unwrap(), None);
        let resumed = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id == session_id)
            .unwrap();
        assert_eq!(
            resumed.pi_session_file.as_deref(),
            Some(session_file.as_path())
        );
        assert_eq!(resumed.workspace_id.as_deref(), Some(workspace_id.as_str()));
        assert_eq!(resumed.shells.len(), 1);
        assert_eq!(resumed.shells[0].id, shell_id);
        assert!(resumed.shells[0].is_available());
        assert_eq!(fs::read(&session_file).unwrap(), history);
        assert!(
            manager
                .list_sessions()
                .unwrap()
                .iter()
                .all(|session| session.id != requester_session_id)
        );
        let requester_state: (String, Option<String>) = manager
            .lock_state()
            .unwrap()
            .database
            .query_row(
                "SELECT state, termination_reason FROM sessions WHERE id = ?1",
                params![requester_session_id.get()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            requester_state,
            ("archived".to_owned(), Some("explicit_close".to_owned()))
        );
        let workspace_state: String = manager
            .lock_state()
            .unwrap()
            .database
            .query_row(
                "SELECT state FROM workspaces WHERE workspace_id = ?1",
                params![workspace_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(workspace_state, "open");

        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }
}
