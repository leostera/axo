//! Workspaces: creating, renaming and archiving them, and the Sessions that live in them.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::catalog::{remove_session_shells, session_metadata};
use super::pi_recovery::{PiLaunchRequest, spawn_new_pi};
use super::spawn::spawn_shell;
use super::{SessionManager, SessionState};
use crate::workspace_access::WorkspaceDirectoryAccess;
use axo_pi::BridgeSocketPath;
use axo_protocol::rpc;
use axo_protocol::{
    Event, PaneRole, SessionId, SessionRecord, WorkspaceRecord, WorkspaceState, is_uuid,
    new_uuid_v4,
};
use axo_store::Connection;
use axo_store::{
    InsertedWorkspaceSession, NewWorkspaceSession, abandon_workspace,
    archive_shell_and_prune_layout, insert_workspace, insert_workspace_session,
    next_session_ordinal, open_workspace_directories, open_workspace_directory,
    workspaces_without_open_sessions,
};
use axo_store::{archive_session, archive_workspace_records};
use axo_store::{list_open_workspaces, open_session_ids_in_workspace, rename_open_workspace};

/// How long a Workspace whose Session could not start waits before Axod tries again.
const WORKSPACE_SESSION_RETRY: Duration = Duration::from_secs(30);

fn copy_pi_transcript(source: &Path, destination: &Path, workspace: &Path) -> io::Result<()> {
    if !source.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Import path must be absolute",
        ));
    }
    let mut input = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(source)?;
    if !input.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Import source is not a regular file",
        ));
    }

    let mut reader = BufReader::new(&mut input);
    let mut header = String::new();
    if reader.read_line(&mut header)? == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Import source is empty",
        ));
    }
    let mut header: serde_json::Value = serde_json::from_str(header.trim_end()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Import source is not a Pi session",
        )
    })?;
    if header["type"] != "session"
        || header["id"].as_str().is_none_or(str::is_empty)
        || header["cwd"].as_str().is_none_or(str::is_empty)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Import source is not a Pi session",
        ));
    }

    header["cwd"] = serde_json::Value::String(workspace.to_string_lossy().into_owned());
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(destination)?;
    let result = (|| {
        output.write_all(header.to_string().as_bytes())?;
        output.write_all(b"\n")?;
        io::copy(&mut reader, &mut output)?;
        output.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(destination);
    }
    result
}

fn validate_workspace_name(name: &str) -> io::Result<()> {
    if name.is_empty()
        || name.len() > 80
        || name.trim() != name
        || name.chars().any(char::is_control)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Workspace name is invalid",
        ));
    }
    Ok(())
}

pub(super) fn create_workspace_session(
    state: &mut SessionState,
    attach_socket_path: &Path,
    pi_session_directory: &Path,
    workspace_id: &str,
    import_source: Option<&Path>,
) -> io::Result<SessionRecord> {
    let initial_pwd = open_workspace_directory(&state.database, workspace_id)?;
    let ordinal = next_session_ordinal(&state.database, workspace_id)?;
    let session_uuid = new_uuid_v4()?;
    let pane_id = new_uuid_v4()?;
    let pi_directory = pi_session_directory.join(workspace_id);
    fs::create_dir_all(&pi_directory)?;
    fs::set_permissions(&pi_directory, fs::Permissions::from_mode(0o700))?;
    let pi_session_file = pi_directory.join(format!("{session_uuid}.jsonl"));
    let bridge_socket = BridgeSocketPath::for_session(pi_session_directory, &session_uuid)?;
    if let Some(source) = import_source {
        copy_pi_transcript(source, &pi_session_file, &initial_pwd)?;
    }
    let session_name = format!("Session {ordinal}");
    let split_id = new_uuid_v4()?;
    let inserted = match insert_workspace_session(
        &mut state.database,
        &NewWorkspaceSession {
            workspace_id,
            initial_pwd: &initial_pwd,
            session_uuid: &session_uuid,
            name: &session_name,
            pi_session_file: &pi_session_file,
            bridge_socket: &bridge_socket,
            pane_id: &pane_id,
            split_id: &split_id,
        },
    ) {
        Ok(inserted) => inserted,
        Err(error) => {
            if import_source.is_some() {
                let _ = fs::remove_file(&pi_session_file);
            }
            return Err(error);
        }
    };
    let session_id = inserted.session_id;
    let request = PiLaunchRequest {
        agent_command: state.agent_command.clone(),
        session_id,
        initial_pwd: initial_pwd.clone(),
        session_file: pi_session_file.clone(),
        bridge_socket: bridge_socket.clone(),
        session_uuid: session_uuid.clone(),
        pane_id: pane_id.clone(),
        previous_token: None,
        size: state.pane_size(session_id, inserted.pi),
    };
    let running = match spawn_new_pi(&state.database, &request) {
        Ok(running) => running,
        Err(error) => {
            archive_session(&mut state.database, session_id, "pi_spawn_failed")?;
            if import_source.is_some() {
                let _ = fs::remove_file(&pi_session_file);
            }
            return Err(error);
        }
    };
    state.install_running(inserted.pi, running);
    start_companion_terminal(state, session_id, inserted, &initial_pwd)?;
    session_metadata(state, session_id, attach_socket_path)
}

/// Starts the terminal pane beside a new Session's Pi. If its shell cannot start, the Session
/// keeps only its Pi pane rather than failing.
fn start_companion_terminal(
    state: &mut SessionState,
    session_id: SessionId,
    inserted: InsertedWorkspaceSession,
    initial_pwd: &Path,
) -> io::Result<()> {
    let size = state.pane_size(session_id, inserted.terminal);
    match spawn_shell(&state.shell_command, session_id, initial_pwd, size) {
        Ok(running) => {
            // A pane inserted just now holds no process to replace.
            let _ = state.install_running(inserted.terminal, running);
        }
        Err(error) => {
            log::warn!(
                "event=session.companion_terminal_failed session_id={} reason={error}",
                session_id.get()
            );
            archive_shell_and_prune_layout(
                &mut state.database,
                inserted.terminal,
                session_id,
                "spawn_failed",
                &HashSet::from([inserted.pi]),
            )?;
        }
    }
    Ok(())
}

/// Reopens access to every open Workspace's directory. A Workspace whose directory is gone is
/// logged and skipped; it must not keep Axod from starting.
pub(super) fn restore_workspace_accesses(
    database: &Connection,
) -> io::Result<HashMap<String, WorkspaceDirectoryAccess>> {
    let mut accesses = HashMap::new();
    for (workspace_id, path, bookmark) in open_workspace_directories(database)? {
        match WorkspaceDirectoryAccess::open(Path::new(&path), bookmark.as_deref()) {
            Ok(access) => {
                accesses.insert(workspace_id, access);
            }
            Err(_) => {
                log::warn!(
                    "event=workspace.access_restore_failed workspace_id={} reason=directory_unavailable",
                    workspace_id
                );
            }
        }
    }
    Ok(accesses)
}

impl SessionManager {
    pub(super) fn list_workspaces(&self) -> io::Result<Vec<WorkspaceRecord>> {
        list_open_workspaces(&self.lock_state()?.database)
    }

    pub(super) fn rename_workspace(
        &self,
        workspace_id: &str,
        name: &str,
    ) -> io::Result<WorkspaceRecord> {
        if !is_uuid(workspace_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace ID is invalid",
            ));
        }
        validate_workspace_name(name)?;
        let (workspace, session_ids) = {
            let state = self.lock_state()?;
            let directory_path = rename_open_workspace(&state.database, workspace_id, name)?;
            let session_ids = open_session_ids_in_workspace(&state.database, workspace_id)?;
            (
                WorkspaceRecord {
                    workspace_id: workspace_id.to_owned(),
                    name: name.to_owned(),
                    directory_path,
                    state: None,
                    home: workspace_id == self.home_workspace_id,
                },
                session_ids,
            )
        };
        for session_id in session_ids {
            self.publish_session_snapshot(session_id)?;
        }
        self.publish_workspace_changed(workspace_id);
        Ok(workspace)
    }

    pub(super) fn archive_workspace(
        self: &Arc<Self>,
        workspace_id: &str,
    ) -> io::Result<Vec<SessionId>> {
        if !is_uuid(workspace_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace ID is invalid",
            ));
        }
        if workspace_id == self.home_workspace_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "The Home Workspace cannot be archived",
            ));
        }
        let (session_ids, shells) = {
            let mut state = self.lock_state()?;
            let session_ids = archive_workspace_records(&mut state.database, workspace_id)?;
            let mut shells = Vec::new();
            for session_id in &session_ids {
                state.pi_activity.remove(session_id);
                shells.extend(remove_session_shells(&mut state, *session_id));
            }
            (session_ids, shells)
        };
        self.terminate_shells_in_background(shells);
        match self.workspace_access.lock() {
            Ok(mut access) => {
                access.remove(workspace_id);
            }
            Err(_) => log::error!(
                "event=workspace.archive_access_release_failed workspace_id={workspace_id}"
            ),
        }
        for session_id in &session_ids {
            self.publish_session_removed(*session_id);
        }
        self.publish_workspace_changed(workspace_id);
        Ok(session_ids)
    }

    /// Gives every open Workspace without a Session a new one. A Workspace whose Session cannot
    /// start (Pi fails to launch) is logged and retried after `WORKSPACE_SESSION_RETRY`; it
    /// must not keep Axod from starting, nor be retried on every reaper tick.
    pub(super) fn ensure_open_workspace_sessions(self: &Arc<Self>) -> io::Result<()> {
        let sessions = {
            let mut state = self.lock_state()?;
            let mut failures = self
                .workspace_session_failures
                .lock()
                .map_err(|_| io::Error::other("Workspace session retry state is unavailable"))?;
            let mut sessions = Vec::new();
            for workspace_id in workspaces_without_open_sessions(&state.database)? {
                if failures
                    .get(&workspace_id)
                    .is_some_and(|failed| failed.elapsed() < WORKSPACE_SESSION_RETRY)
                {
                    continue;
                }
                match create_workspace_session(
                    &mut state,
                    &self.attach_socket_path,
                    &self.pi_session_directory,
                    &workspace_id,
                    None,
                ) {
                    Ok(session) => {
                        failures.remove(&workspace_id);
                        sessions.push(session);
                    }
                    Err(error) => {
                        log::error!(
                            "event=workspace.session_create_failed workspace_id={workspace_id} reason={error}"
                        );
                        failures.insert(workspace_id, Instant::now());
                    }
                }
            }
            sessions
        };

        for session in sessions {
            self.start_pi_bridge_for_session(&session)?;
            self.publish_event(Event::snapshot(session.clone()));
        }
        Ok(())
    }

    pub(super) fn create_workspace(
        self: &Arc<Self>,
        request: rpc::CreateWorkspace,
    ) -> io::Result<rpc::WorkspaceCreated> {
        validate_workspace_name(&request.name)?;
        if !request.directory_path.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace root must be an absolute path",
            ));
        }
        let directory_access = WorkspaceDirectoryAccess::open(
            &request.directory_path,
            request.directory_bookmark.as_deref(),
        )?;
        let directory = directory_access.path().to_path_buf();
        let workspace_id = new_uuid_v4()?;
        let mut state = self.lock_state()?;
        insert_workspace(
            &state.database,
            &workspace_id,
            &request.name,
            &directory,
            request.directory_bookmark.as_deref(),
        )?;
        let session = match create_workspace_session(
            &mut state,
            &self.attach_socket_path,
            &self.pi_session_directory,
            &workspace_id,
            None,
        ) {
            Ok(session) => session,
            Err(error) => {
                let _ = abandon_workspace(&state.database, &workspace_id);
                return Err(io::Error::other(error));
            }
        };
        let pi_shell_id = session
            .shells
            .iter()
            .find(|shell| shell.role == PaneRole::Pi)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Workspace Session has no Pi pane",
                )
            })?
            .id;
        drop(state);
        self.workspace_access
            .lock()
            .map_err(|_| io::Error::other("Workspace access registry is unavailable"))?
            .insert(workspace_id.clone(), directory_access);
        self.start_pi_bridge_worker(pi_shell_id)
            .map_err(io::Error::other)?;
        let workspace = WorkspaceRecord {
            workspace_id: workspace_id.clone(),
            name: request.name,
            directory_path: directory.to_string_lossy().into_owned(),
            state: Some(WorkspaceState::Open),
            home: false,
        };
        self.publish_event(Event::snapshot(session.clone()));
        self.publish_workspace_changed(&workspace_id);
        Ok(rpc::WorkspaceCreated { workspace, session })
    }

    pub(super) fn create_session_in_workspace(
        self: &Arc<Self>,
        workspace_id: &str,
    ) -> io::Result<SessionRecord> {
        if !is_uuid(workspace_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace ID is invalid",
            ));
        }
        let mut state = self.lock_state()?;
        let session = create_workspace_session(
            &mut state,
            &self.attach_socket_path,
            &self.pi_session_directory,
            workspace_id,
            None,
        )?;
        let pi_shell_id = session
            .shells
            .iter()
            .find(|shell| shell.role == PaneRole::Pi)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Workspace Session has no Pi pane",
                )
            })?
            .id;
        drop(state);
        self.start_pi_bridge_worker(pi_shell_id)?;
        self.publish_event(Event::snapshot(session.clone()));
        Ok(session)
    }

    pub(super) fn import_pi_session(
        self: &Arc<Self>,
        binding: super::pi_bridge::PiRuntimeBinding,
        source_path: &str,
    ) -> io::Result<SessionRecord> {
        let source = Path::new(source_path);
        if source_path.len() > 4096 || source_path.contains('\0') || !source.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Import path is invalid",
            ));
        }
        let (session, pi_shell_id) = {
            let mut state = self.lock_state()?;
            if !binding.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi Session is no longer current",
                ));
            }
            let current = session_metadata(&state, binding.session_id, &self.attach_socket_path)?;
            let workspace_id = current.workspace_id.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Import requires a Workspace Session",
                )
            })?;
            let session = create_workspace_session(
                &mut state,
                &self.attach_socket_path,
                &self.pi_session_directory,
                &workspace_id,
                Some(source),
            )?;
            let pi_shell_id = session
                .shells
                .iter()
                .find(|shell| shell.role == PaneRole::Pi)
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Imported Session has no Pi pane",
                    )
                })?
                .id;
            (session, pi_shell_id)
        };
        self.start_pi_bridge_worker(pi_shell_id)?;
        self.publish_event(Event::snapshot(session.clone()));
        self.publish_event(Event::SessionFocus {
            session_id: session.id,
        });
        Ok(session)
    }
}

#[cfg(test)]
mod tests {

    use super::copy_pi_transcript;
    use crate::session::test_support::*;

    use axo_protocol::new_uuid_v4;

    use axo_store::unix_timestamp;
    use rusqlite::params;

    use std::fs;

    use std::path::{Path, PathBuf};

    #[test]
    fn imported_pi_transcript_is_copied_without_mutating_the_source_and_follows_symlinks() {
        let directory =
            PathBuf::from("/tmp").join(format!("axo-import-{}", new_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        let source = directory.join("source.jsonl");
        let destination = directory.join("owned-copy.jsonl");
        fs::write(
            &source,
            b"{\"type\":\"session\",\"version\":3,\"id\":\"source-id\",\"cwd\":\"/work\"}\n{\"type\":\"message\",\"id\":\"entry\"}\n",
        )
        .unwrap();

        copy_pi_transcript(&source, &destination, Path::new("/target-workspace")).unwrap();

        assert!(source.is_file());
        let lines = fs::read_to_string(&destination).unwrap();
        let mut lines = lines.lines();
        let header: serde_json::Value = serde_json::from_str(lines.next().unwrap()).unwrap();
        assert_eq!(header["id"], "source-id");
        assert_eq!(header["cwd"], "/target-workspace");
        assert_eq!(
            lines.next().unwrap(),
            "{\"type\":\"message\",\"id\":\"entry\"}"
        );

        let symlink = directory.join("linked.jsonl");
        std::os::unix::fs::symlink(&source, &symlink).unwrap();
        let linked_copy = directory.join("linked-copy.jsonl");
        copy_pi_transcript(&symlink, &linked_copy, Path::new("/target-workspace")).unwrap();
        assert!(linked_copy.is_file());
        assert!(
            !fs::symlink_metadata(&linked_copy)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn manual_session_rename_is_separate_and_workspace_archive_preserves_history() {
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", new_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        let manager = open_with_silent_shell(&directory);
        let workspace_id = new_uuid_v4().unwrap();
        let session_uuid = new_uuid_v4().unwrap();
        let session_id = sid(702);
        let history = directory.join("pi-session.jsonl");
        fs::write(&history, b"canonical Pi history").unwrap();
        {
            let state = manager.lock_state().unwrap();
            state
                .database
                .execute(
                    "INSERT INTO workspaces
                     (workspace_id, name, directory_path, state, created_at)
                     VALUES (?1, 'Original Workspace', '/tmp', 'open', ?2)",
                    params![workspace_id, unix_timestamp()],
                )
                .unwrap();
            state
                .database
                .execute(
                    "INSERT INTO sessions
                     (id, initial_pwd, state, created_at, workspace_id, session_uuid, name, pi_session_file)
                     VALUES (?1, '/tmp', 'open', ?2, ?3, ?4, 'Pi conversation title', ?5)",
                    params![
                        session_id.get(),
                        unix_timestamp(),
                        workspace_id,
                        session_uuid,
                        history.to_string_lossy(),
                    ],
                )
                .unwrap();
        }

        let renamed_session = manager.rename_session(session_id, "Sidebar label").unwrap();
        assert_eq!(renamed_session.name, "Pi conversation title");
        assert_eq!(
            renamed_session.manual_name.as_deref(),
            Some("Sidebar label")
        );
        assert_eq!(
            serde_json::to_value(&renamed_session).unwrap()["manualName"],
            "Sidebar label"
        );

        let renamed_workspace = manager
            .rename_workspace(&workspace_id, "Renamed Workspace")
            .unwrap();
        assert_eq!(renamed_workspace.name, "Renamed Workspace");
        let session_after_workspace_rename =
            manager.rename_session(session_id, "Sidebar label").unwrap();
        assert_eq!(
            session_after_workspace_rename.workspace_name.as_deref(),
            Some("Renamed Workspace")
        );

        let archived_sessions = manager.archive_workspace(&workspace_id).unwrap();
        assert_eq!(archived_sessions, vec![session_id]);
        let remaining: Vec<_> = manager
            .list_workspaces()
            .unwrap()
            .into_iter()
            .map(|workspace| workspace.workspace_id)
            .collect();
        assert_eq!(remaining, [manager.home_workspace_id.clone()]);
        let refused = manager
            .archive_workspace(&manager.home_workspace_id)
            .unwrap_err();
        assert_eq!(refused.kind(), std::io::ErrorKind::InvalidInput);
        assert_eq!(
            manager.list_workspaces().unwrap().len(),
            1,
            "Home stays open"
        );
        let state = manager.lock_state().unwrap();
        let archived_state: (String, String) = state
            .database
            .query_row(
                "SELECT state, termination_reason FROM sessions WHERE id = ?1",
                params![session_id.get()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            archived_state,
            ("archived".to_owned(), "workspace_archived".to_owned())
        );
        drop(state);
        assert_eq!(fs::read(&history).unwrap(), b"canonical Pi history");

        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }
}
