//! Creating Sessions: where each starts (RFD0038), and importing a Pi transcript as one.

use std::collections::HashSet;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::agents::AgentState;
use super::catalog::session_metadata;
use super::pi_recovery::{PiLaunchRequest, spawn_new_pi};
use super::spawn::spawn_shell;
use super::transcripts::PiDirectories;
use super::{SessionManager, SessionState};
use axo_agent::pi::BridgeSocketPath;
use axo_protocol::rpc;
use axo_protocol::{Event, PaneRole, SessionId, SessionRecord, new_uuid_v4};
use axo_store::{
    InsertedSession, NewSession, archive_session, archive_shell_and_prune_layout,
    insert_new_session, next_session_ordinal, open_session_row,
};

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

/// Creates a Session in `folder` (canonical, an existing directory) with Pi beside a terminal,
/// and starts both. Its transcript is `<sessions>/<hostId>/<sessionId>.jsonl` (RFD0038).
pub(super) fn create_session(
    state: &mut SessionState,
    attach_socket_path: &Path,
    pi_directories: &PiDirectories,
    folder: &Path,
    import_source: Option<&Path>,
) -> io::Result<SessionRecord> {
    let initial_pwd = folder.to_path_buf();
    let ordinal = next_session_ordinal(&state.database, folder)?;
    let session_id = SessionId::new_v4()?;
    let session_uuid = session_id.to_string();
    let pane_id = new_uuid_v4()?;
    let pi_session_file = pi_directories
        .transcripts
        .join(format!("{session_uuid}.jsonl"));
    let bridge_socket = BridgeSocketPath::for_session(&pi_directories.bridges, &session_uuid)?;
    if let Some(source) = import_source {
        copy_pi_transcript(source, &pi_session_file, &initial_pwd)?;
    }
    let session_name = format!("Session {ordinal}");
    let split_id = new_uuid_v4()?;
    let inserted = match insert_new_session(
        &mut state.database,
        &NewSession {
            session_id,
            folder: &initial_pwd,
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
    // A new Session: the agents know nothing of it yet.
    session_metadata(
        state,
        &AgentState::default(),
        session_id,
        attach_socket_path,
    )
}

/// Starts the terminal pane beside a new Session's Pi. If its shell cannot start, the Session
/// keeps only its Pi pane rather than failing.
fn start_companion_terminal(
    state: &mut SessionState,
    session_id: SessionId,
    inserted: InsertedSession,
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
                session_id
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

impl SessionManager {
    /// Where a new Session starts: `folder`, the folder of the open Session `like`, or the home
    /// directory. Canonical, so Sessions in one folder share one path.
    fn new_session_folder(&self, request: &rpc::CreateSession) -> io::Result<PathBuf> {
        let folder = match (&request.folder, request.like) {
            (Some(_), Some(_)) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "a new Session takes a folder or another Session's, not both",
                ));
            }
            (Some(folder), None) if !folder.is_absolute() => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "a Session's folder must be an absolute path",
                ));
            }
            (Some(folder), None) => folder.clone(),
            (None, Some(like)) => {
                let state = self.lock_state()?;
                if !state.panes.has_session(like) {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        "that Session is not open",
                    ));
                }
                open_session_row(&state.database, like)?.folder
            }
            (None, None) => self.home.clone(),
        };
        let folder = folder.canonicalize()?;
        if !folder.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a Session's folder must be a directory",
            ));
        }
        Ok(folder)
    }

    /// Creates a Session with Pi beside a terminal, starts Pi's bridge and publishes it.
    pub(super) fn create_session(
        self: &Arc<Self>,
        request: rpc::CreateSession,
    ) -> io::Result<SessionRecord> {
        let folder = self.new_session_folder(&request)?;
        let session = create_session(
            &mut *self.lock_state()?,
            &self.attach_socket_path,
            &self.pi_directories,
            &folder,
            None,
        )?;
        self.start_pi_bridge_for_session(&session)?;
        self.publish_event(Event::snapshot(session.clone()));
        Ok(session)
    }

    /// Imports a Pi transcript as a new Session in the folder of the Session that asked.
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
            let folder = open_session_row(&state.database, binding.session_id)?.folder;
            let session = create_session(
                &mut state,
                &self.attach_socket_path,
                &self.pi_directories,
                &folder,
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
    use axo_protocol::rpc;
    use axo_store::unix_timestamp;
    use rusqlite::params;
    use std::fs;
    use std::path::Path;

    #[test]
    fn imported_pi_transcript_is_copied_without_mutating_the_source_and_follows_symlinks() {
        let directory = test_directory("axo-import");
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
    fn a_new_session_starts_in_a_folder_beside_another_or_at_home_and_nothing_replaces_it() {
        let directory = test_directory("axocr");
        fs::create_dir_all(directory.join("project")).unwrap();
        let manager = open_with_silent_shell(&directory);
        assert!(
            manager.list_sessions().unwrap().is_empty(),
            "nothing is opened for you"
        );
        let project = directory.join("project").canonicalize().unwrap();

        let first = manager
            .create_session(rpc::CreateSession {
                folder: Some(directory.join("project")),
                like: None,
            })
            .unwrap();
        assert_eq!(first.folder, project);
        assert!(
            first
                .shells
                .iter()
                .all(|shell| shell.initial_pwd == project)
        );
        assert_eq!(
            first.pi_session_file.as_deref().and_then(Path::parent),
            Some(manager.pi_directories.transcripts.as_path()),
            "a transcript is under its Mac's folder, by the Session's id"
        );
        let beside = manager
            .create_session(rpc::CreateSession {
                folder: None,
                like: Some(first.id),
            })
            .unwrap();
        assert_eq!(beside.folder, project);
        assert_eq!(beside.name, "Session 2", "numbered within its folder");
        let home = manager
            .create_session(rpc::CreateSession::default())
            .unwrap();
        assert_eq!(home.folder, manager.home);

        for refused in [
            rpc::CreateSession {
                folder: Some("relative".into()),
                like: None,
            },
            rpc::CreateSession {
                folder: Some(directory.join("missing")),
                like: None,
            },
            rpc::CreateSession {
                folder: Some(project.clone()),
                like: Some(first.id),
            },
        ] {
            assert!(manager.create_session(refused).is_err());
        }

        for session in [&first, &beside, &home] {
            manager.close_session_and_publish(session.id).unwrap();
        }
        assert!(
            manager.list_sessions().unwrap().is_empty(),
            "closing the last Session leaves none"
        );
        manager.shutdown();
        drop(manager);
        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn a_manual_session_name_is_kept_apart_from_pis() {
        let directory = test_directory("axor");
        fs::create_dir_all(&directory).unwrap();
        let manager = open_with_silent_shell(&directory);
        let session_id = sid(702);
        let history = directory.join("pi-session.jsonl");
        fs::write(&history, b"canonical Pi history").unwrap();
        manager
            .lock_state()
            .unwrap()
            .database
            .execute(
                "INSERT INTO sessions (id, initial_pwd, state, created_at, name, pi_session_file)
                 VALUES (?1, '/tmp', 'open', ?2, 'Pi conversation title', ?3)",
                params![
                    session_id.to_string(),
                    unix_timestamp(),
                    history.to_string_lossy(),
                ],
            )
            .unwrap();

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
        assert_eq!(fs::read(&history).unwrap(), b"canonical Pi history");

        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }
}
