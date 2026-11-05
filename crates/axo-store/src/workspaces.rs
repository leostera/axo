//! Workspace rows, including the Home Workspace every Session falls back to.

use std::io;
use std::path::{Path, PathBuf};

use axo_protocol::{SessionId, WorkspaceRecord, new_uuid_v4};
use rusqlite::{Connection, OptionalExtension, params};

use crate::rows::{expect_one_row, not_found, stored_session_id, unix_timestamp};

/// Every open Workspace's ID, directory and security-scoped bookmark, for restoring access at
/// startup.
pub fn open_workspace_directories(
    database: &Connection,
) -> io::Result<Vec<(String, String, Option<String>)>> {
    let mut statement = database
        .prepare(
            "SELECT workspace_id, directory_path, directory_bookmark FROM workspaces \
             WHERE state = 'open'",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

pub fn archive_workspace_records(
    database: &mut Connection,
    workspace_id: &str,
) -> io::Result<Vec<SessionId>> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let session_ids = {
        let mut statement = transaction
            .prepare("SELECT id FROM sessions WHERE workspace_id = ?1 AND state = 'open'")
            .map_err(io::Error::other)?;
        statement
            .query_map(params![workspace_id], |row| row.get::<_, String>(0))
            .map_err(io::Error::other)?
            .map(|id| id.and_then(stored_session_id))
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };
    let archived_at = unix_timestamp();
    transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = 'workspace_archived'
             WHERE state = 'open' AND session_id IN (
                 SELECT id FROM sessions WHERE workspace_id = ?2 AND state = 'open'
             )",
            params![archived_at, workspace_id],
        )
        .map_err(io::Error::other)?;
    transaction
        .execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?1, termination_reason = 'workspace_archived'
             WHERE workspace_id = ?2 AND state = 'open'",
            params![archived_at, workspace_id],
        )
        .map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE workspaces SET state = 'archived', archived_at = ?1
             WHERE workspace_id = ?2 AND state = 'open'",
            params![archived_at, workspace_id],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Workspace is not open",
        ));
    }
    transaction.commit().map_err(io::Error::other)?;
    Ok(session_ids)
}

/// Open Workspaces, Home first and the rest by name.
pub fn list_open_workspaces(database: &Connection) -> io::Result<Vec<WorkspaceRecord>> {
    let mut statement = database
        .prepare(
            "SELECT workspace_id, name, directory_path, \
                 workspace_id IS (SELECT value FROM daemon_metadata WHERE key = ?1) \
             FROM workspaces WHERE state = 'open' ORDER BY 4 DESC, name, workspace_id",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map(params![HOME_WORKSPACE_METADATA_KEY], |row| {
            Ok(WorkspaceRecord {
                workspace_id: row.get(0)?,
                name: row.get(1)?,
                directory_path: row.get(2)?,
                state: None,
                home: row.get(3)?,
            })
        })
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

/// Renames an open Workspace and returns its directory.
pub fn rename_open_workspace(
    database: &Connection,
    workspace_id: &str,
    name: &str,
) -> io::Result<String> {
    let changed = database
        .execute(
            "UPDATE workspaces SET name = ?1 WHERE workspace_id = ?2 AND state = 'open'",
            params![name, workspace_id],
        )
        .map_err(io::Error::other)?;
    expect_one_row(changed, "Workspace is not open")?;
    database
        .query_row(
            "SELECT directory_path FROM workspaces WHERE workspace_id = ?1",
            params![workspace_id],
            |row| row.get(0),
        )
        .map_err(io::Error::other)
}

pub fn open_session_ids_in_workspace(
    database: &Connection,
    workspace_id: &str,
) -> io::Result<Vec<SessionId>> {
    let mut statement = database
        .prepare("SELECT id FROM sessions WHERE workspace_id = ?1 AND state = 'open'")
        .map_err(io::Error::other)?;
    statement
        .query_map(params![workspace_id], |row| row.get::<_, String>(0))
        .map_err(io::Error::other)?
        .map(|id| id.and_then(stored_session_id))
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

/// A Workspace's directory and security-scoped bookmark, whether or not it is open.
pub fn workspace_directory(
    database: &Connection,
    workspace_id: &str,
) -> io::Result<(String, Option<String>)> {
    database
        .query_row(
            "SELECT directory_path, directory_bookmark FROM workspaces WHERE workspace_id = ?1",
            params![workspace_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(io::Error::other)
}

/// The working directory of an open Workspace.
pub fn open_workspace_directory(database: &Connection, workspace_id: &str) -> io::Result<PathBuf> {
    database
        .query_row(
            "SELECT directory_path FROM workspaces WHERE workspace_id = ? AND state = 'open'",
            params![workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .map(PathBuf::from)
        .ok_or_else(|| not_found("Workspace is not open"))
}

pub fn insert_workspace(
    database: &Connection,
    workspace_id: &str,
    name: &str,
    directory: &Path,
    bookmark: Option<&str>,
) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO workspaces (workspace_id, name, directory_path, directory_bookmark, state, created_at) \
             VALUES (?, ?, ?, ?, 'open', ?)",
            params![workspace_id, name, directory.to_string_lossy(), bookmark, unix_timestamp()],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

const HOME_WORKSPACE_METADATA_KEY: &str = "home_workspace_id";

const HOME_WORKSPACE_NAME: &str = "Home";

/// The Home Workspace's ID, creating it at `directory` on first use (and reopening it if it was
/// ever archived). Open Sessions outside any Workspace, from before Home existed, move into it.
pub fn ensure_home_workspace(database: &mut Connection, directory: &Path) -> io::Result<String> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let existing: Option<String> = transaction
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![HOME_WORKSPACE_METADATA_KEY],
            |row| row.get(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    let workspace_id = match existing {
        Some(workspace_id) => {
            transaction
                .execute(
                    "UPDATE workspaces SET state = 'open', archived_at = NULL WHERE workspace_id = ?1",
                    params![workspace_id],
                )
                .map_err(io::Error::other)?;
            workspace_id
        }
        None => {
            let workspace_id = new_uuid_v4()?;
            insert_workspace(
                &transaction,
                &workspace_id,
                HOME_WORKSPACE_NAME,
                directory,
                None,
            )?;
            transaction
                .execute(
                    "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)",
                    params![HOME_WORKSPACE_METADATA_KEY, workspace_id],
                )
                .map_err(io::Error::other)?;
            workspace_id
        }
    };
    transaction
        .execute(
            "UPDATE sessions SET workspace_id = ?1 WHERE workspace_id IS NULL AND state = 'open'",
            params![workspace_id],
        )
        .map_err(io::Error::other)?;
    transaction.commit().map_err(io::Error::other)?;
    Ok(workspace_id)
}

/// Archives a Workspace whose first Session could not be created.
pub fn abandon_workspace(database: &Connection, workspace_id: &str) -> io::Result<()> {
    database
        .execute(
            "UPDATE workspaces SET state = 'archived', archived_at = ? WHERE workspace_id = ?",
            params![unix_timestamp(), workspace_id],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

/// Open Workspaces with no open Session, which startup gives one.
pub fn workspaces_without_open_sessions(database: &Connection) -> io::Result<Vec<String>> {
    let mut statement = database
        .prepare(
            "SELECT w.workspace_id FROM workspaces w WHERE w.state = 'open' \
             AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.workspace_id = w.workspace_id \
             AND s.state = 'open') ORDER BY w.workspace_id",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::open_session_workspace_id;
    use crate::test_support::{database, insert_session, insert_workspace_row, kind};

    #[test]
    fn workspaces_list_open_ones_by_name_and_rename_only_open_ones() {
        let database = database();
        let (zed, alpha, gone) = (
            new_uuid_v4().unwrap(),
            new_uuid_v4().unwrap(),
            new_uuid_v4().unwrap(),
        );
        insert_workspace_row(&database, &zed, "zed", "open");
        insert_workspace_row(&database, &alpha, "alpha", "open");
        insert_workspace_row(&database, &gone, "gone", "archived");
        let names: Vec<_> = list_open_workspaces(&database)
            .unwrap()
            .into_iter()
            .map(|workspace| workspace.name)
            .collect();
        assert_eq!(names, ["alpha", "zed"]);

        assert_eq!(
            rename_open_workspace(&database, &zed, "omega").unwrap(),
            "/work/zed"
        );
        assert_eq!(
            kind(rename_open_workspace(&database, &gone, "back")),
            io::ErrorKind::NotFound
        );
        let session = insert_session(&database, "open");
        database
            .execute(
                "UPDATE sessions SET workspace_id = ?1 WHERE id = ?2",
                params![zed, session.to_string()],
            )
            .unwrap();
        assert_eq!(
            open_session_ids_in_workspace(&database, &zed).unwrap(),
            [session]
        );
        assert!(
            open_session_ids_in_workspace(&database, &alpha)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn the_home_workspace_is_created_once_reopened_and_adopts_standalone_sessions() {
        let database = &mut database();
        let standalone = insert_session(database, "open");
        let closed = insert_session(database, "archived");

        let home = ensure_home_workspace(database, Path::new("/Users/me")).unwrap();
        assert_eq!(
            open_workspace_directory(database, &home).unwrap(),
            Path::new("/Users/me")
        );
        let other = new_uuid_v4().unwrap();
        // "A Project" sorts before "Home" by name, yet Home is listed first.
        insert_workspace(database, &other, "A Project", Path::new("/p"), None).unwrap();
        let listed: Vec<_> = list_open_workspaces(database)
            .unwrap()
            .into_iter()
            .map(|workspace| (workspace.name, workspace.home))
            .collect();
        assert_eq!(
            listed,
            [("Home".to_owned(), true), ("A Project".to_owned(), false)]
        );
        assert_eq!(
            open_session_workspace_id(database, standalone).unwrap(),
            Some(home.clone())
        );
        let closed_workspace: Option<String> = database
            .query_row(
                "SELECT workspace_id FROM sessions WHERE id = ?1",
                params![closed.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            closed_workspace, None,
            "archived Sessions stay where they were"
        );

        abandon_workspace(database, &home).unwrap();
        assert_eq!(
            ensure_home_workspace(database, Path::new("/elsewhere")).unwrap(),
            home
        );
        assert_eq!(
            open_workspace_directory(database, &home).unwrap(),
            Path::new("/Users/me"),
            "an archived Home is reopened where it was"
        );
    }

    #[test]
    fn startup_finds_open_workspaces_without_an_open_session() {
        let database = database();
        let (empty, busy, archived) = (
            new_uuid_v4().unwrap(),
            new_uuid_v4().unwrap(),
            new_uuid_v4().unwrap(),
        );
        insert_workspace(&database, &empty, "empty", Path::new("/e"), None).unwrap();
        insert_workspace(&database, &busy, "busy", Path::new("/b"), None).unwrap();
        insert_workspace(&database, &archived, "archived", Path::new("/a"), None).unwrap();
        abandon_workspace(&database, &archived).unwrap();
        let session = insert_session(&database, "open");
        database
            .execute(
                "UPDATE sessions SET workspace_id = ?1 WHERE id = ?2",
                params![busy, session.to_string()],
            )
            .unwrap();
        assert_eq!(
            workspaces_without_open_sessions(&database).unwrap(),
            [empty]
        );
        assert_eq!(
            kind(open_workspace_directory(&database, &archived)),
            io::ErrorKind::NotFound
        );
    }
}
