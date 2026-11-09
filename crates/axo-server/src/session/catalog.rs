//! The catalog lock and the records it serves: `SessionState`'s queries, `lock_state` and how a
//! Session and its panes are described to clients.

use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::agents::AgentState;
use super::events::ShellOutputSink;
use super::terminal::window_size;
use super::{RunningShell, SessionManager, SessionState};
use axo_panes::{Pane, RuntimeId, UnavailablePane};
use axo_protocol::{
    Availability, Layout, LayoutDirection, LayoutNode, PaneRole, SessionId, SessionRecord,
    SessionStatus, ShellId, ShellRecord, new_uuid_v4,
};
use axo_pty::WindowSize;
use axo_pty::process;
use axo_store::read_session_layout;
use axo_store::{StoredSessionRow, open_session_row};

impl SessionState {
    /// The size a pane should start at: its place in the Session's layout, or the whole terminal
    /// area for a pane the layout does not have yet (a new Session's only pane, or a split the
    /// client is about to place).
    pub(super) fn pane_size(&self, session_id: SessionId, shell_id: ShellId) -> WindowSize {
        let Some(viewport) = self.viewport else {
            return WindowSize::DEFAULT;
        };
        let placed = self.effective_layout(session_id).and_then(|layout| {
            viewport
                .grid_sizes(layout.root())
                .into_iter()
                .find(|(id, _)| *id == shell_id)
        });
        window_size(placed.map_or_else(|| viewport.full_grid(), |(_, grid)| grid))
    }

    /// The layout clients show: the stored one, or, like the client's `defaultLayout`, the
    /// open panes side by side in creation order.
    pub(super) fn effective_layout(&self, session_id: SessionId) -> Option<Layout> {
        if let Ok(Some(layout)) = read_session_layout(&self.database, session_id) {
            return Some(layout);
        }
        let mut shell_ids: Vec<_> = open_shell_ids(self, session_id).into_iter().collect();
        shell_ids.sort();
        let (first, rest) = shell_ids.split_first()?;
        let root = rest.iter().try_fold(
            LayoutNode::Pane { shell_id: *first },
            |layout, shell_id| -> io::Result<LayoutNode> {
                Ok(LayoutNode::Split {
                    id: new_uuid_v4()?,
                    direction: LayoutDirection::Right,
                    ratio: 0.5,
                    first: Box::new(layout),
                    second: Box::new(LayoutNode::Pane {
                        shell_id: *shell_id,
                    }),
                })
            },
        );
        root.ok().and_then(|root| Layout::try_from(root).ok())
    }

    /// Sizes the Session's panes that no client is attached to from the viewport. Attached
    /// panes are sized by their client, so the two never contend for one PTY.
    pub(super) fn fit_unattached_panes(&self, session_id: SessionId, layout: &Layout) {
        let Some(viewport) = self.viewport else {
            return;
        };
        for (shell_id, grid) in viewport.grid_sizes(layout.root()) {
            let Some(running) = self
                .panes
                .running_in(session_id, shell_id)
                .filter(|running| running.attachments == 0)
            else {
                continue;
            };
            let size = window_size(grid);
            match process::resize_if_changed(&running.master, &running.child, size) {
                Ok(true) => log::debug!(
                    "event=pane.fitted_to_viewport session_id={} shell_id={} rows={} columns={}",
                    session_id,
                    shell_id.get(),
                    size.rows(),
                    size.columns()
                ),
                Ok(false) => {}
                Err(error) => log::warn!(
                    "event=pane.fit_failed session_id={} shell_id={} error_kind={:?}",
                    session_id,
                    shell_id.get(),
                    error.kind()
                ),
            }
        }
    }

    /// A process enters the catalog, replacing whatever the pane held; returns a replaced
    /// process for the caller to stop.
    pub(super) fn install_running(
        &mut self,
        shell_id: ShellId,
        running: RunningShell,
    ) -> Option<RunningShell> {
        self.bind_output(shell_id, &running);
        match self.panes.insert_running(shell_id, running) {
            Some(Pane::Running(replaced)) => Some(replaced),
            Some(Pane::Unavailable(_)) | None => None,
        }
    }

    /// A recovered Pi process takes over its unavailable pane, if `recovery` still holds the
    /// pane's reservation; otherwise it is handed back for the caller to stop.
    #[expect(
        clippy::result_large_err,
        reason = "the refused process is handed back by value so the caller stops it"
    )]
    pub(super) fn commit_recovery(
        &mut self,
        session_id: SessionId,
        shell_id: ShellId,
        recovery: RuntimeId,
        running: RunningShell,
    ) -> Result<(), RunningShell> {
        if self.shutting_down || !self.panes.is_recovering(session_id, shell_id, recovery) {
            return Err(running);
        }
        self.bind_output(shell_id, &running);
        self.panes
            .commit_recovery(session_id, shell_id, recovery, running)
    }

    /// Every way a process enters the catalog goes through here: binding its output stream to
    /// its pane identity starts `terminal.output` events, and its exit wakes the reaper.
    pub(super) fn bind_output(&self, shell_id: ShellId, running: &RunningShell) {
        let reaper = Arc::clone(&self.reaper);
        running.child.exit().on_exit(move || reaper.wake());
        let session_id = running.session_id;
        running.output.bind(
            format!("session_id={} shell_id={}", session_id, shell_id.get()),
            Arc::new(ShellOutputSink {
                events: self.events.clone(),
                session_id,
                shell_id,
            }),
        );
    }
}

/// How long the catalog lock may be waited for or held before it is reported.
const CATALOG_LOCK_REPORT_THRESHOLD: Duration = Duration::from_millis(50);

/// The catalog lock, held. Reports holds longer than `CATALOG_LOCK_REPORT_THRESHOLD` with the
/// source location that took the lock, so a slow request in `ipc.slow_request` can be traced to
/// whoever made it wait. Source locations are bounded; nothing user-controlled is logged.
pub(super) struct CatalogGuard<'a> {
    guard: std::sync::MutexGuard<'a, SessionState>,
    caller: &'static std::panic::Location<'static>,
    acquired: Instant,
    /// Told when a guard that was written through is released.
    changes: &'a StateChanges,
    written: bool,
}

/// Says when the Session state changed, for threads waiting for something in it (a Pi to exit,
/// or to start) instead of looking again on a timer (RFD0037). Each release of the state's
/// lock after a write raises the version. A waiter reads the version, then checks the state,
/// then waits for a newer version: a change between the two is never missed.
#[derive(Default)]
pub(super) struct StateChanges {
    version: std::sync::Mutex<u64>,
    changed: std::sync::Condvar,
}

impl StateChanges {
    fn changed(&self) {
        *self.version.lock().unwrap_or_else(|p| p.into_inner()) += 1;
        self.changed.notify_all();
    }

    pub(super) fn version(&self) -> u64 {
        *self.version.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Waits for a version after `seen`, or `deadline`; false at the deadline.
    pub(super) fn wait_after(&self, seen: u64, deadline: Instant) -> bool {
        let mut version = self.version.lock().unwrap_or_else(|p| p.into_inner());
        while *version == seen {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            version = self
                .changed
                .wait_timeout(version, deadline - now)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
        true
    }
}

impl std::ops::Deref for CatalogGuard<'_> {
    type Target = SessionState;

    fn deref(&self) -> &SessionState {
        &self.guard
    }
}

impl std::ops::DerefMut for CatalogGuard<'_> {
    fn deref_mut(&mut self) -> &mut SessionState {
        self.written = true;
        &mut self.guard
    }
}

impl Drop for CatalogGuard<'_> {
    fn drop(&mut self) {
        if self.written {
            self.changes.changed();
        }
        let held = self.acquired.elapsed();
        if held >= CATALOG_LOCK_REPORT_THRESHOLD {
            log::warn!(
                "event=catalog.lock_held_long caller={}:{} held_ms={}",
                self.caller.file(),
                self.caller.line(),
                held.as_millis()
            );
        }
    }
}

pub(super) fn open_shell_ids(state: &SessionState, session_id: SessionId) -> HashSet<ShellId> {
    state.panes.shell_ids_in(session_id)
}

pub(super) fn remove_session_shells(
    state: &mut SessionState,
    session_id: SessionId,
) -> Vec<RunningShell> {
    state.panes.remove_session(session_id)
}

pub(super) fn session_metadata(
    state: &SessionState,
    agents: &AgentState,
    id: SessionId,
    attach_socket_path: &Path,
) -> io::Result<SessionRecord> {
    let StoredSessionRow {
        initial_pwd,
        workspace_id,
        workspace_name,
        name,
        manual_name,
        emoji,
        pi_session_file,
        pi_session_id,
        last_message_at,
        created_at,
        layout,
    } = open_session_row(&state.database, id)?;
    let mut shells: Vec<_> = state
        .panes
        .in_session(id)
        .map(|(shell_id, pane)| match pane {
            Pane::Running(running) => running_shell_record(shell_id, running, attach_socket_path),
            Pane::Unavailable(shell) => {
                let mut record = unavailable_pi_shell_record(shell_id, shell, attach_socket_path);
                if agents.dormant.contains(&shell_id) {
                    record.availability = Availability::Dormant;
                }
                record
            }
        })
        .collect();
    shells.sort_by_key(|shell| shell.id.get());
    let status = if shells
        .iter()
        .any(|shell| matches!(shell.availability, Availability::Unavailable { .. }))
    {
        SessionStatus::Unavailable
    } else if shells
        .iter()
        .any(|shell| shell.availability == Availability::Dormant)
    {
        // Idle, and ready for a prompt, which starts its Pi.
        SessionStatus::Ready
    } else if shells.iter().any(|shell| shell.role == PaneRole::Pi) {
        agents
            .activity
            .get(&id)
            .map_or(SessionStatus::Starting, |activity| activity.status())
    } else {
        SessionStatus::Ready
    };
    let last_message_at = last_message_at.or_else(|| {
        pi_session_file
            .as_deref()
            .and_then(file_modification_timestamp)
    });
    Ok(SessionRecord {
        id,
        pi_session_file,
        pi_session_id,
        workspace_id,
        workspace_name,
        name,
        manual_name,
        emoji,
        last_message_at,
        created_at,
        status,
        initial_pwd,
        shells,
        layout,
        pi: agents
            .controls
            .get(&id)
            .and_then(|controls| controls.runtime().cloned()),
    })
}

fn file_modification_timestamp(path: &Path) -> Option<i64> {
    std::fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs()
        .try_into()
        .ok()
}

pub(super) fn running_shell_record(
    id: ShellId,
    running: &RunningShell,
    attach_socket_path: &Path,
) -> ShellRecord {
    ShellRecord {
        id,
        pane_id: running.pane_id.clone(),
        role: running.role,
        process_id: running.child.id(),
        initial_pwd: running.initial_pwd.clone(),
        pty_device: running.slave_device.clone(),
        attach_socket_path: attach_socket_path.to_path_buf(),
        availability: Availability::Available,
    }
}

/// Shown on a Pi pane whose process could not be recovered.
const UNRECOVERABLE_PI_REASON: &str =
    "Axo could not recover this Pi session. Its conversation history is preserved.";

fn unavailable_pi_shell_record(
    id: ShellId,
    shell: &UnavailablePane,
    attach_socket_path: &Path,
) -> ShellRecord {
    ShellRecord {
        id,
        pane_id: shell.pane_id.clone(),
        role: PaneRole::Pi,
        process_id: 0,
        initial_pwd: shell.initial_pwd.clone(),
        pty_device: String::new(),
        attach_socket_path: attach_socket_path.to_path_buf(),
        availability: Availability::Unavailable {
            reason: UNRECOVERABLE_PI_REASON.to_owned(),
        },
    }
}

impl SessionManager {
    pub(super) fn list_sessions(&self) -> io::Result<Vec<SessionRecord>> {
        let state = self.lock_state()?;
        let agents = self.lock_agents();
        let mut sessions = state
            .panes
            .session_ids()
            .into_iter()
            .map(|id| session_metadata(&state, &agents, id, &self.attach_socket_path))
            .collect::<io::Result<Vec<_>>>()?;
        sessions.sort_by_key(|session| (session.created_at, session.id));
        Ok(sessions)
    }

    /// Open Sessions as `list_sessions` reports them, and archived ones from the store.
    pub(super) fn session_catalog(&self) -> io::Result<axo_protocol::rpc::SessionCatalog> {
        let sessions = self.list_sessions()?;
        let archived = axo_store::read_archived_sessions(&self.lock_state()?.database)?;
        Ok(axo_protocol::rpc::SessionCatalog { sessions, archived })
    }

    /// Every RPC, attach and event path goes through this one lock, so holding it across slow
    /// work (spawning, SQLite, signalling) stalls every client. Long waits and long holds are
    /// logged with the caller's source location; see `CatalogGuard`.
    #[track_caller]
    pub(super) fn lock_state(&self) -> io::Result<CatalogGuard<'_>> {
        let caller = std::panic::Location::caller();
        debug_assert!(
            !super::agents::holding(),
            "the Session state is locked before the agents' state, never after: {caller}"
        );
        let requested = Instant::now();
        let guard = self
            .state
            .lock()
            .map_err(|_| io::Error::other("session state lock was poisoned"))?;
        let acquired = Instant::now();
        let waited = acquired - requested;
        if waited >= CATALOG_LOCK_REPORT_THRESHOLD {
            log::warn!(
                "event=catalog.lock_wait_long caller={}:{} waited_ms={}",
                caller.file(),
                caller.line(),
                waited.as_millis()
            );
        }
        Ok(CatalogGuard {
            guard,
            caller,
            acquired,
            changes: &self.state_changes,
            written: false,
        })
    }

    /// Waits until `found` finds something in the Session state, or `deadline`: it looks once,
    /// then again after each change. `None` at the deadline.
    pub(super) fn wait_for_state<T>(
        &self,
        deadline: Instant,
        mut found: impl FnMut(&SessionState) -> Option<T>,
    ) -> io::Result<Option<T>> {
        loop {
            let seen = self.state_changes.version();
            let state = self.lock_state()?;
            let looked = found(&state);
            drop(state);
            if let Some(found) = looked {
                return Ok(Some(found));
            }
            if !self.state_changes.wait_after(seen, deadline) {
                return Ok(None);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::session::test_support::*;

    use axo_protocol::new_uuid_v4;

    use rusqlite::params;

    #[test]
    fn a_wait_for_the_state_looks_again_only_when_the_state_changes() {
        let fixture = LifecycleFixture::new();
        let manager = Arc::clone(&fixture.manager);
        let looked = std::sync::atomic::AtomicUsize::new(0);
        let writer = {
            let manager = Arc::clone(&manager);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(300));
                // Reading changes nothing; writing does.
                drop(manager.lock_state().unwrap());
                std::thread::sleep(Duration::from_millis(100));
                manager.lock_state().unwrap().reopening.clear();
            })
        };
        let started = Instant::now();
        let found = manager
            .wait_for_state(started + Duration::from_secs(5), |_| {
                let count = looked.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                (count > 1).then_some(count)
            })
            .unwrap();
        writer.join().unwrap();
        assert_eq!(
            found,
            Some(2),
            "it looked once, then once more after the write"
        );
        assert!(started.elapsed() >= Duration::from_millis(400));
        assert!(started.elapsed() < Duration::from_secs(2));
        // Nothing found by the deadline.
        let deadline = Instant::now() + Duration::from_millis(100);
        assert_eq!(
            manager.wait_for_state(deadline, |_| None::<()>).unwrap(),
            None
        );
    }

    #[test]
    fn session_metadata_reads_emoji_workspace_name_and_ignores_a_corrupt_layout() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.create_session_and_publish().unwrap();
        let workspace_id = new_uuid_v4().unwrap();
        {
            let state = manager.lock_state().unwrap();
            state
                .database
                .execute(
                    "INSERT INTO workspaces (workspace_id, name, directory_path, state, created_at)
                     VALUES (?1, 'Axo', '/tmp', 'open', 0)",
                    params![workspace_id],
                )
                .unwrap();
            state
                .database
                .execute(
                    "UPDATE sessions SET emoji = '🦀', workspace_id = ?1, layout_json = '{\"not\": 1}'
                     WHERE id = ?2",
                    params![workspace_id, session.id.to_string()],
                )
                .unwrap();
            let record = session_metadata(
                &state,
                &manager.lock_agents(),
                session.id,
                &manager.attach_socket_path,
            )
            .unwrap();
            assert_eq!(record.emoji.as_deref(), Some("🦀"));
            assert_eq!(record.workspace_id.as_deref(), Some(workspace_id.as_str()));
            assert_eq!(record.workspace_name.as_deref(), Some("Axo"));
            assert_eq!(record.layout, None, "a corrupt stored layout is ignored");
            assert_eq!(record.shells.len(), 2, "Pi and its terminal");

            // A Session whose Workspace is gone is inconsistent, not Workspace-less.
            state
                .database
                .execute(
                    "UPDATE workspaces SET state = 'archived' WHERE workspace_id = ?1",
                    params![workspace_id],
                )
                .unwrap();
            assert!(
                session_metadata(
                    &state,
                    &manager.lock_agents(),
                    session.id,
                    &manager.attach_socket_path
                )
                .is_err()
            );
        }
    }
}
