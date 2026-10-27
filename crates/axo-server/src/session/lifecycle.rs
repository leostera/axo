//! Session and pane lifecycle: creating, closing, restoring and reaping, and the layout and
//! viewport they carry.

use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use super::catalog::{
    open_shell_ids, remove_session_shells, running_shell_record, session_metadata,
};
use super::spawn::spawn_shell;
use super::workspaces::create_workspace_session;
use super::{RunningShell, SessionManager, SessionState, stop_panes};
use axo_panes::{Pane, UnavailablePane};
use axo_protocol::rpc;
use axo_protocol::{
    Event, Layout, PaneRole, SessionId, SessionRecord, ShellActivity, ShellId, ShellRecord,
    Viewport, new_uuid_v4,
};
use axo_store::{
    archive_session, archive_shell, archive_shell_and_prune_layout, open_standalone_session_count,
    read_open_sessions, session_initial_pwd, store_viewport,
};
use axo_store::{
    insert_standalone_session, insert_terminal_shell, next_session_ordinal,
    open_session_workspace_id,
};
use axo_store::{open_session_ids_in_workspace, set_manual_session_name, write_session_layout};

const REAPER_INTERVAL: Duration = Duration::from_millis(100);

pub(super) fn valid_session_title(title: &str) -> bool {
    !title.is_empty()
        && title.trim() == title
        && title.encode_utf16().count() <= 80
        && !title.chars().any(char::is_control)
}

pub(super) fn valid_session_emoji(emoji: &str) -> bool {
    !emoji.is_empty()
        && emoji.chars().count() <= 16
        && emoji.trim() == emoji
        && !emoji.chars().any(char::is_whitespace)
        && !emoji.chars().any(char::is_control)
}

fn create_session(
    state: &mut SessionState,
    attach_socket_path: &Path,
) -> io::Result<SessionRecord> {
    let initial_pwd = state.initial_pwd.clone();
    let session_uuid = new_uuid_v4()?;
    let ordinal = next_session_ordinal(&state.database, None)?;
    let session_name = format!("Session {ordinal}");
    let id =
        insert_standalone_session(&state.database, &initial_pwd, &session_uuid, &session_name)?;

    if let Err(error) = create_shell(state, id, attach_socket_path) {
        archive_session(&mut state.database, id, "spawn_failed")?;
        return Err(error);
    }
    session_metadata(state, id, attach_socket_path)
}

fn create_shell(
    state: &mut SessionState,
    session_id: SessionId,
    attach_socket_path: &Path,
) -> io::Result<ShellRecord> {
    let initial_pwd = session_initial_pwd(&state.database, session_id)?;
    let shell_id = insert_terminal_shell(&state.database, session_id, &initial_pwd)?;

    let size = state.pane_size(session_id, shell_id);
    let running = match spawn_shell(&state.shell_command, session_id, &initial_pwd, size) {
        Ok(running) => running,
        Err(error) => {
            archive_shell(&state.database, shell_id, "spawn_failed")?;
            return Err(error);
        }
    };
    let metadata = running_shell_record(shell_id, &running, attach_socket_path);
    state.install_running(shell_id, running);
    Ok(metadata)
}

pub(super) fn close_session(
    state: &mut SessionState,
    id: SessionId,
    attach_socket_path: &Path,
    pi_session_directory: &Path,
) -> io::Result<(Option<SessionRecord>, Vec<RunningShell>)> {
    if open_shell_ids(state, id).is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "session is not open",
        ));
    }

    let workspace_id = open_session_workspace_id(&state.database, id)?;
    let replacement = if let Some(workspace_id) = workspace_id {
        let workspace_session_count =
            open_session_ids_in_workspace(&state.database, &workspace_id)?.len();
        (workspace_session_count == 1)
            .then(|| {
                create_workspace_session(
                    state,
                    attach_socket_path,
                    pi_session_directory,
                    &workspace_id,
                    None,
                )
            })
            .transpose()?
    } else if open_standalone_session_count(&state.database)? == 1 {
        // Workspace Sessions do not replace the standalone home Session.
        Some(create_session(state, attach_socket_path)?)
    } else {
        None
    };

    archive_session(&mut state.database, id, "explicit_close")?;
    state.pi_activity.remove(&id);
    state.queued_pi_prompts.remove(&id);
    let shells = remove_session_shells(state, id);
    Ok((replacement, shells))
}

fn close_shell(
    state: &mut SessionState,
    session_id: SessionId,
    shell_id: ShellId,
    attach_socket_path: &Path,
    pi_session_directory: &Path,
) -> io::Result<(rpc::ShellClosed, Vec<RunningShell>)> {
    let Some(pane) = state.panes.get(shell_id) else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "shell is not open"));
    };
    if pane.session_id() != session_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "shell does not belong to this session",
        ));
    }
    let role = match pane {
        Pane::Running(shell) => shell.role,
        Pane::Unavailable(_) => PaneRole::Pi,
    };

    let sibling_count = open_shell_ids(state, session_id).len();
    if sibling_count == 1 || role == PaneRole::Pi {
        let (replacement, shells) =
            close_session(state, session_id, attach_socket_path, pi_session_directory)?;
        return Ok((
            rpc::ShellClosed {
                archived_shell_id: shell_id,
                archived_session_id: Some(session_id),
                replacement,
            },
            shells,
        ));
    }

    let remaining_shell_ids = open_shell_ids(state, session_id)
        .into_iter()
        .filter(|candidate_id| *candidate_id != shell_id)
        .collect();
    archive_shell_and_prune_layout(
        &mut state.database,
        shell_id,
        session_id,
        "explicit_close",
        &remaining_shell_ids,
    )?;
    let shell = state.panes.remove(shell_id).into_iter().collect();
    Ok((
        rpc::ShellClosed {
            archived_shell_id: shell_id,
            archived_session_id: None,
            replacement: None,
        },
        shell,
    ))
}

/// Stops its panes when dropped; see `stop_panes`.
struct StopOnDrop(pub(super) Vec<RunningShell>);

impl Drop for StopOnDrop {
    fn drop(&mut self) {
        stop_panes(std::mem::take(&mut self.0));
    }
}

impl SessionManager {
    pub(super) fn create_session_and_publish(&self) -> io::Result<SessionRecord> {
        let session = self.create_session()?;
        self.publish_event(Event::snapshot(session.clone()));
        Ok(session)
    }

    /// Returns the replacement session created when the last one closes.
    pub(super) fn close_session_and_publish(
        self: &Arc<Self>,
        session_id: SessionId,
    ) -> io::Result<Option<SessionRecord>> {
        let replacement = self.close_session(session_id)?;
        self.publish_session_removed(session_id);
        if let Some(session) = &replacement {
            self.publish_event(Event::snapshot(session.clone()));
        }
        Ok(replacement)
    }

    pub(super) fn create_shell_and_publish(
        &self,
        session_id: SessionId,
    ) -> io::Result<ShellRecord> {
        let shell = self.create_shell(session_id)?;
        self.publish_session_snapshot(session_id)?;
        self.publish_shell_activity(session_id, shell.id, ShellActivity::Started);
        Ok(shell)
    }

    pub(super) fn close_shell_and_publish(
        self: &Arc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> io::Result<rpc::ShellClosed> {
        let closed = self.close_shell(session_id, shell_id)?;
        if closed.archived_session_id.is_some() {
            self.publish_session_removed(session_id);
            if let Some(replacement) = &closed.replacement {
                self.publish_event(Event::snapshot(replacement.clone()));
            }
        } else {
            self.publish_session_snapshot(session_id)?;
        }
        self.publish_shell_activity(session_id, shell_id, ShellActivity::Exited);
        Ok(closed)
    }

    pub(super) fn set_layout_and_publish(
        &self,
        session_id: SessionId,
        layout: Layout,
    ) -> io::Result<()> {
        self.set_layout(session_id, layout)?;
        self.publish_session_snapshot(session_id)
    }

    pub(super) fn restore_open_sessions(self: &Arc<Self>) -> io::Result<()> {
        let mut state = self.lock_state()?;
        if state.shutting_down {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Axod is shutting down",
            ));
        }
        let records = read_open_sessions(&state.database)?;
        let mut pi_shells = Vec::new();
        for record in records {
            if record.shell_ids.is_empty() {
                archive_session(&mut state.database, record.id, "missing_open_pane")?;
                continue;
            }
            for (shell_id, role, pane_id) in record.shell_ids {
                if state.panes.contains(shell_id) {
                    continue;
                }

                let running = match role {
                    PaneRole::Terminal => Some(spawn_shell(
                        &state.shell_command,
                        record.id,
                        &record.initial_pwd,
                        state.pane_size(record.id, shell_id),
                    )?),
                    PaneRole::Pi => {
                        // Not open (checked above), so this cannot be refused.
                        let _ = state.panes.insert_unavailable(
                            shell_id,
                            UnavailablePane::new(record.id, pane_id, record.initial_pwd.clone()),
                        );
                        pi_shells.push((record.id, shell_id));
                        None
                    }
                };
                if let Some(running) = running {
                    state.install_running(shell_id, running);
                }
            }
        }
        drop(state);
        self.recover_pi_shells(pi_shells);
        Ok(())
    }

    pub(super) fn start_reaper(self: &Arc<Self>) {
        let manager = Arc::downgrade(self);
        let stop_workers = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name("axo-session-reaper".into())
            .spawn(move || {
                while !stop_workers.load(Ordering::Relaxed) {
                    thread::sleep(REAPER_INTERVAL);
                    let Some(manager) = manager.upgrade() else {
                        break;
                    };
                    if let Err(error) = manager.reap_exited_sessions() {
                        log::error!("event=session.reap_failed reason={error}");
                    }
                }
            });
        if let Ok(worker) = worker
            && let Ok(mut workers) = self.workers.lock()
        {
            workers.push(worker);
        }
    }

    pub(super) fn create_session(&self) -> io::Result<SessionRecord> {
        let mut state = self.lock_state()?;
        create_session(&mut state, &self.attach_socket_path)
    }

    pub(super) fn ensure_home_session(&self) -> io::Result<Option<SessionRecord>> {
        let mut state = self.lock_state()?;
        if open_standalone_session_count(&state.database)? == 0 {
            create_session(&mut state, &self.attach_socket_path).map(Some)
        } else {
            Ok(None)
        }
    }

    pub(super) fn set_layout(&self, session_id: SessionId, layout: Layout) -> io::Result<()> {
        let shell_ids = layout.shell_ids().clone();
        let state = self.lock_state()?;
        let open_shell_ids = open_shell_ids(&state, session_id);
        if open_shell_ids.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "session is not open",
            ));
        }
        if shell_ids != open_shell_ids {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "layout does not match the session's open shells",
            ));
        }

        write_session_layout(&state.database, session_id, &layout)?;
        state.fit_unattached_panes(session_id, &layout);
        Ok(())
    }

    /// Records the latest client's viewport and sizes every pane no client is attached to.
    pub(super) fn set_viewport(&self, viewport: Viewport) -> io::Result<()> {
        let mut state = self.lock_state()?;
        if state.viewport == Some(viewport) {
            return Ok(());
        }
        store_viewport(&state.database, &viewport)?;
        state.viewport = Some(viewport);
        let session_ids = read_open_sessions(&state.database)?
            .into_iter()
            .map(|record| record.id);
        for session_id in session_ids {
            if let Some(layout) = state.effective_layout(session_id) {
                state.fit_unattached_panes(session_id, &layout);
            }
        }
        Ok(())
    }

    pub(super) fn create_shell(&self, session_id: SessionId) -> io::Result<ShellRecord> {
        let mut state = self.lock_state()?;
        create_shell(&mut state, session_id, &self.attach_socket_path)
    }

    pub(super) fn rename_session(
        &self,
        session_id: SessionId,
        name: &str,
    ) -> io::Result<SessionRecord> {
        if !valid_session_title(name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Session name must be between 1 and 80 characters",
            ));
        }
        let session = {
            let state = self.lock_state()?;
            set_manual_session_name(&state.database, session_id, name)?;
            session_metadata(&state, session_id, &self.attach_socket_path)?
        };
        self.publish_event(Event::snapshot(session.clone()));
        Ok(session)
    }

    pub(super) fn close_session(
        self: &Arc<Self>,
        id: SessionId,
    ) -> io::Result<Option<SessionRecord>> {
        let (replacement, shells_to_terminate) = {
            let mut state = self.lock_state()?;
            close_session(
                &mut state,
                id,
                &self.attach_socket_path,
                &self.pi_session_directory,
            )?
        };
        self.terminate_shells_in_background(shells_to_terminate);
        if let Some(session) = &replacement {
            self.start_pi_bridge_for_session(session)?;
        }
        Ok(replacement)
    }

    fn close_shell(
        self: &Arc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> io::Result<rpc::ShellClosed> {
        let (closed, shells_to_terminate) = {
            let mut state = self.lock_state()?;
            close_shell(
                &mut state,
                session_id,
                shell_id,
                &self.attach_socket_path,
                &self.pi_session_directory,
            )?
        };
        self.terminate_shells_in_background(shells_to_terminate);
        if let Some(session) = &closed.replacement {
            self.start_pi_bridge_for_session(session)?;
        }
        Ok(closed)
    }

    /// Stops `shells` on one background worker, so closing never waits for a grace period.
    pub(super) fn terminate_shells_in_background(&self, shells: Vec<RunningShell>) {
        if shells.is_empty() {
            return;
        }
        let process_ids = shells
            .iter()
            .map(|shell| shell.child.id().to_string())
            .collect::<Vec<_>>()
            .join(",");
        // The guard stops them even if spawning fails and drops the closure.
        let cleanup = StopOnDrop(shells);
        match thread::Builder::new()
            .name("axo-shell-cleanup".into())
            .spawn(move || drop(cleanup))
        {
            Ok(worker) => match self.workers.lock() {
                Ok(mut workers) => {
                    let (finished, running): (Vec<_>, Vec<_>) = std::mem::take(&mut *workers)
                        .into_iter()
                        .partition(JoinHandle::is_finished);
                    for finished in finished {
                        let _ = finished.join();
                    }
                    *workers = running;
                    workers.push(worker);
                }
                Err(_) => {
                    let _ = worker.join();
                }
            },
            Err(error) => {
                log::error!(
                    "event=session.shell_cleanup_start_failed pids={process_ids} reason={error}"
                );
            }
        }
    }

    pub(super) fn reap_exited_sessions(self: &Arc<Self>) -> io::Result<()> {
        let mut state = self.lock_state()?;
        let exited = state
            .panes
            .running_iter_mut()
            .filter_map(|(shell_id, running)| match running.child.try_wait() {
                Ok(Some(status)) => {
                    log::info!("event=session.child_exited session_id={} shell_id={} runtime_id={} pid={} status={status}",
                        running.session_id.get(), shell_id.get(), running.runtime_id, running.child.id());
                    Some((shell_id, running.session_id))
                }
                Ok(None) => None,
                Err(error) => {
                    if !running.wait_error_reported {
                        log::error!("event=session.child_wait_failed session_id={} shell_id={} runtime_id={} pid={} error_kind={:?}",
                            running.session_id.get(), shell_id.get(), running.runtime_id, running.child.id(), error.kind());
                        running.wait_error_reported = true;
                    }
                    // Do not guess that the child exited or signal a potentially
                    // reused PID. One uncertain child must not stop other reaping.
                    None
                }
            })
            .collect::<Vec<_>>();

        let exited_pi_shells: Vec<_> = exited
            .iter()
            .filter_map(|(shell_id, session_id)| {
                state
                    .panes
                    .running(*shell_id)
                    .is_some_and(|shell| shell.role == PaneRole::Pi)
                    .then_some((*shell_id, *session_id))
            })
            .collect();
        let exited_pi_shell_ids: HashSet<_> = exited_pi_shells
            .iter()
            .map(|(shell_id, _)| *shell_id)
            .collect();
        let exited_non_pi_shell_ids: HashSet<_> = exited
            .iter()
            .filter_map(|(shell_id, _)| {
                (!exited_pi_shell_ids.contains(shell_id)).then_some(*shell_id)
            })
            .collect();
        let mut changed_sessions = HashSet::new();
        let mut removed_sessions = HashSet::new();
        for (shell_id, session_id) in &exited_pi_shells {
            let exited = state.panes.process_exited(*shell_id, |shell| {
                UnavailablePane::new(
                    shell.session_id,
                    shell.pane_id.clone(),
                    shell.initial_pwd.clone(),
                )
            });
            if exited.is_some() {
                state.pi_activity.remove(session_id);
                // A prompt for the Pi that exited is not typed into whatever replaces it.
                state.queued_pi_prompts.remove(session_id);
                changed_sessions.insert(*session_id);
            }
        }
        for (shell_id, session_id) in &exited {
            if exited_pi_shell_ids.contains(shell_id) {
                continue;
            }
            let remaining_shell_ids: HashSet<_> = open_shell_ids(&state, *session_id)
                .into_iter()
                .filter(|candidate_id| !exited_non_pi_shell_ids.contains(candidate_id))
                .collect();
            archive_shell_and_prune_layout(
                &mut state.database,
                *shell_id,
                *session_id,
                "shell_exited",
                &remaining_shell_ids,
            )?;
            state.panes.remove(*shell_id);
            if remaining_shell_ids.is_empty() {
                if removed_sessions.insert(*session_id) {
                    archive_session(&mut state.database, *session_id, "shell_exited")?;
                    state.pi_activity.remove(session_id);
                    state.queued_pi_prompts.remove(session_id);
                }
            } else {
                changed_sessions.insert(*session_id);
            }
        }
        drop(state);

        for (shell_id, session_id) in exited {
            self.publish_shell_activity(session_id, shell_id, ShellActivity::Exited);
        }
        for session_id in removed_sessions {
            self.publish_session_removed(session_id);
        }
        for session_id in changed_sessions {
            self.publish_session_snapshot(session_id)?;
        }
        self.ensure_open_workspace_sessions()?;
        if let Some(session) = self.ensure_home_session()? {
            self.publish_event(Event::snapshot(session.clone()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{settings::*, test_support::*};
    use axo_panes::Pane;
    use axo_pi::bridge;

    use axo_pi::WriterLock;

    use axo_protocol::{Layout, LayoutDirection, LayoutNode, new_uuid_v4};
    use axo_pty::WindowSize;
    use axo_pty::process;

    use axo_store::load_viewport;

    use rusqlite::params;
    use serde_json::json;

    use std::os::fd::AsRawFd;

    use std::time::{Duration, Instant};

    #[test]
    fn session_restore_waits_outside_the_catalog_lock_and_isolates_pi_failure() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        manager.lock_state().unwrap().panes.remove(fixture.shell_id);
        let (worker, mut bridge) =
            fixture.observe_operation(|manager| manager.restore_open_sessions());
        assert!(
            catalog_lock_is_free(manager),
            "startup restoration held the shared catalog lock during takeover"
        );
        let home = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id != fixture.session_id)
            .unwrap();
        assert!(home.shells.iter().any(|shell| shell.is_available()));
        bridge::write_record(bridge.get_mut(), &json!({ "type": "protocolError" })).unwrap();
        worker.join().unwrap().unwrap();
        let sessions = manager.list_sessions().unwrap();
        let target = sessions
            .iter()
            .find(|session| session.id == fixture.session_id)
            .unwrap();
        assert!(!target.shells[0].is_available());
        assert!(sessions.iter().any(|session| session.id == home.id));
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn restoring_sessions_does_not_replace_an_existing_runtime() {
        let fixture = LifecycleFixture::new();
        let session = fixture.manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let runtime = fixture
            .manager
            .lock_state()
            .unwrap()
            .panes
            .running(shell_id)
            .unwrap()
            .runtime_id;
        fixture.manager.restore_open_sessions().unwrap();
        assert_eq!(
            fixture
                .manager
                .lock_state()
                .unwrap()
                .panes
                .running(shell_id)
                .unwrap()
                .runtime_id,
            runtime
        );
    }

    #[test]
    fn reaper_isolates_wait_errors_without_guessing_process_exit() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let uncertain = manager.create_session().unwrap();
        let exited = manager.create_session().unwrap();
        let uncertain_shell = uncertain.shells[0].id;
        let exited_shell = exited.shells[0].id;
        {
            let mut state = manager.lock_state().unwrap();
            let child = &mut state.panes.running_mut(uncertain_shell).unwrap().child;
            child.kill().unwrap();
            let mut status = 0;
            // SAFETY: this fixture owns the still-unreaped child. Reaping outside
            // Child deliberately simulates lost wait ownership (ECHILD).
            assert_eq!(
                unsafe { libc::waitpid(child.id() as libc::pid_t, &mut status, 0) },
                child.id() as libc::pid_t
            );
            let child = &mut state.panes.running_mut(exited_shell).unwrap().child;
            child.kill().unwrap();
            assert!(wait_for_shell_exit(child, Duration::from_secs(2)).unwrap());
        }
        manager.reap_exited_sessions().unwrap();
        manager.reap_exited_sessions().unwrap();
        let state = manager.lock_state().unwrap();
        assert!(
            state
                .panes
                .running(uncertain_shell)
                .unwrap()
                .wait_error_reported
        );
        assert!(!state.panes.running(exited_shell).is_some());
        let uncertain_state: String = state
            .database
            .query_row(
                "SELECT state FROM sessions WHERE id = ?",
                params![uncertain.id.get()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(uncertain_state, "open");
        let exited_state: String = state
            .database
            .query_row(
                "SELECT state FROM sessions WHERE id = ?",
                params![exited.id.get()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(exited_state, "archived");
    }

    #[test]
    fn closing_a_session_stops_every_pane_together_on_one_worker() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.create_session().unwrap();
        manager.create_shell(session.id).unwrap();
        manager.create_shell(session.id).unwrap();
        let process_ids: Vec<libc::pid_t> = {
            let state = manager.lock_state().unwrap();
            state
                .panes
                .in_session(session.id)
                .filter_map(|(_, pane)| match pane {
                    Pane::Running(running) => Some(running.child.id() as libc::pid_t),
                    Pane::Unavailable(_) => None,
                })
                .collect()
        };
        assert_eq!(process_ids.len(), 3);

        let started = Instant::now();
        manager.close_session(session.id).unwrap();
        assert!(
            started.elapsed() < process::SHELL_STOP_GRACE,
            "closing must not wait for its panes to stop"
        );
        assert_eq!(
            manager.workers.lock().unwrap().len(),
            1,
            "one cleanup worker per close, not one per pane"
        );
        let worker = manager.workers.lock().unwrap().pop().unwrap();
        worker.join().unwrap();
        assert!(
            started.elapsed() < process::SHELL_STOP_GRACE + process::KILL_WAIT,
            "panes are stopped together, not one grace after another"
        );
        for process_id in process_ids {
            // SAFETY: signal 0 only checks whether the process still exists.
            let alive = unsafe { libc::kill(process_id, 0) } == 0;
            assert!(
                !alive,
                "pane process {process_id} survived its Session's close"
            );
        }
    }

    #[test]
    fn creates_a_shell_attached_to_a_real_pty() {
        let home = crate::current_user_home_directory().unwrap();
        let shell = ShellCommand::parse("/bin/zsh").unwrap();
        let mut session = spawn_shell(&shell, sid(1), &home, WindowSize::DEFAULT).unwrap();
        assert!(session.slave_device.starts_with("/dev/"));
        // The child should receive only the slave as stdio, never the PTY master.
        // SAFETY: the test owns this open PTY master descriptor.
        let master_flags = unsafe { libc::fcntl(session.master.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(master_flags, -1);
        assert_ne!(master_flags & libc::FD_CLOEXEC, 0);

        let master = session.master.as_raw_fd();
        let (_, output) = session.output.subscribe(None, None);
        let command = b"printf 'AXO_PTY_READY\\n'\n";
        // SAFETY: command points to initialized bytes and master is an open PTY.
        let written = unsafe { libc::write(master, command.as_ptr().cast(), command.len()) };
        assert_eq!(written as usize, command.len());
        assert!(read_until(&output, b"AXO_PTY_READY", SHELL_OUTPUT_WAIT));
        process::stop(&mut session.child, process::SHELL_STOP_GRACE);
    }

    #[test]
    fn the_latest_viewport_sizes_unattached_panes_and_new_ones() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.list_sessions().unwrap().remove(0);
        let first = session.shells[0].id;
        assert_eq!(pty_size(manager, first), (24, 80));

        manager.set_viewport(test_viewport(1000.0)).unwrap();
        assert_eq!(pty_size(manager, first), (34, 124));

        // A new pane starts at the whole area until the client's layout places it.
        let second = manager.create_shell(session.id).unwrap().id;
        assert_eq!(pty_size(manager, second), (34, 124));
        let split = LayoutNode::Split {
            id: new_uuid_v4().unwrap(),
            direction: LayoutDirection::Right,
            ratio: 0.5,
            first: Box::new(LayoutNode::Pane { shell_id: first }),
            second: Box::new(LayoutNode::Pane { shell_id: second }),
        };
        manager
            .set_layout(session.id, Layout::try_from(split).unwrap())
            .unwrap();
        assert_eq!(pty_size(manager, first), (34, 61));
        assert_eq!(pty_size(manager, second), (34, 61));

        // An attached pane belongs to its client; the latest viewport resizes the rest.
        manager
            .lock_state()
            .unwrap()
            .panes
            .running_mut(first)
            .unwrap()
            .attachments = 1;
        manager.set_viewport(test_viewport(500.0)).unwrap();
        assert_eq!(pty_size(manager, first), (34, 61));
        assert_eq!(pty_size(manager, second), (34, 30));

        let state = manager.lock_state().unwrap();
        assert_eq!(
            load_viewport(&state.database).unwrap(),
            Some(test_viewport(500.0))
        );
    }
}
