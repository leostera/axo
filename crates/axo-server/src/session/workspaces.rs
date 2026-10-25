//! Workspaces: creating, renaming and archiving them, and the Sessions that live in them.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;

use super::catalog::{remove_session_shells, session_metadata};
use super::pi_recovery::{PiLaunchRequest, spawn_new_pi};
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
    NewWorkspaceSession, abandon_workspace, insert_workspace, insert_workspace_session,
    next_session_ordinal, open_workspace_directories, open_workspace_directory,
    workspaces_without_open_sessions,
};
use axo_store::{archive_session, archive_workspace_records};
use axo_store::{list_open_workspaces, open_session_ids_in_workspace, rename_open_workspace};

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
) -> io::Result<SessionRecord> {
    let initial_pwd = open_workspace_directory(&state.database, workspace_id)?;
    let ordinal = next_session_ordinal(&state.database, Some(workspace_id))?;
    let session_uuid = new_uuid_v4()?;
    let pane_id = new_uuid_v4()?;
    let pi_directory = pi_session_directory.join(workspace_id);
    fs::create_dir_all(&pi_directory)?;
    fs::set_permissions(&pi_directory, fs::Permissions::from_mode(0o700))?;
    let pi_session_file = pi_directory.join(format!("{session_uuid}.jsonl"));
    let bridge_socket = BridgeSocketPath::for_session(pi_session_directory, &session_uuid)?;
    let session_name = format!("Session {ordinal}");
    let (session_id, pane) = insert_workspace_session(
        &mut state.database,
        &NewWorkspaceSession {
            workspace_id,
            initial_pwd: &initial_pwd,
            session_uuid: &session_uuid,
            name: &session_name,
            pi_session_file: &pi_session_file,
            bridge_socket: &bridge_socket,
            pane_id: &pane_id,
        },
    )?;
    let request = PiLaunchRequest {
        agent_command: state.agent_command.clone(),
        session_id,
        initial_pwd: initial_pwd.clone(),
        session_file: pi_session_file.clone(),
        bridge_socket: bridge_socket.clone(),
        session_uuid: session_uuid.clone(),
        pane_id: pane_id.clone(),
        previous_token: None,
        size: state.pane_size(session_id, pane),
    };
    let running = match spawn_new_pi(&state.database, &request) {
        Ok(running) => running,
        Err(error) => {
            archive_session(&mut state.database, session_id, "pi_spawn_failed")?;
            return Err(error);
        }
    };
    state.install_running(pane, running);
    session_metadata(state, session_id, attach_socket_path)
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

    pub(super) fn ensure_open_workspace_sessions(self: &Arc<Self>) -> io::Result<()> {
        let sessions = {
            let mut state = self.lock_state()?;
            let workspace_ids = workspaces_without_open_sessions(&state.database)?;
            workspace_ids
                .iter()
                .map(|workspace_id| {
                    create_workspace_session(
                        &mut state,
                        &self.attach_socket_path,
                        &self.pi_session_directory,
                        workspace_id,
                    )
                })
                .collect::<io::Result<Vec<_>>>()?
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
}

#[cfg(test)]
mod tests {

    use crate::session::test_support::*;

    use axo_protocol::new_uuid_v4;

    use axo_store::unix_timestamp;
    use rusqlite::params;

    use std::fs;

    use std::path::PathBuf;

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
        assert!(manager.list_workspaces().unwrap().is_empty());
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
