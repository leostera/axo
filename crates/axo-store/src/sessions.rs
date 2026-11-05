//! Session rows: creating a Workspace Session with its panes, reading open and archived
//! Sessions, renaming, layouts, and archiving and reopening them.

use std::io;
use std::path::{Path, PathBuf};

use axo_pi::BridgeSocketPath;
use axo_protocol::rpc::ArchivedSessionRecord;
use axo_protocol::{Layout, PaneRole, SessionId, ShellId};
use rusqlite::{Connection, OptionalExtension, params};

use crate::pi::PiHistoryOwner;
use crate::rows::{
    expect_one_row, inserted_shell_id, not_found, stored_session_id, stored_shell_id,
    unix_timestamp,
};
use crate::shells::insert_terminal_shell;

/// An open session as stored, before its processes are restored.
#[derive(Debug)]
pub struct StoredSession {
    pub id: SessionId,
    pub initial_pwd: PathBuf,
    pub shell_ids: Vec<(ShellId, PaneRole, Option<String>)>,
}

pub fn read_open_sessions(database: &Connection) -> io::Result<Vec<StoredSession>> {
    let mut statement = database
        .prepare(
            "SELECT id, initial_pwd FROM sessions WHERE state = 'open' ORDER BY created_at, rowid",
        )
        .map_err(io::Error::other)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                stored_session_id(row.get::<_, String>(0)?)?,
                PathBuf::from(row.get::<_, String>(1)?),
            ))
        })
        .map_err(io::Error::other)?;
    let mut records = Vec::new();
    for row in rows {
        let (id, initial_pwd) = row.map_err(io::Error::other)?;
        let mut shell_statement = database.prepare(
            "SELECT id, role, pane_id FROM shells WHERE session_id = ?1 AND state = 'open' ORDER BY id",
        ).map_err(io::Error::other)?;
        let shell_ids = shell_statement
            .query_map(params![id.to_string()], |row| {
                let role: String = row.get(1)?;
                let role = match role.as_str() {
                    "pi" => PaneRole::Pi,
                    "terminal" => PaneRole::Terminal,
                    _ => return Err(rusqlite::Error::InvalidQuery),
                };
                Ok((stored_shell_id(row.get(0)?)?, role, row.get(2)?))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?;
        records.push(StoredSession {
            id,
            initial_pwd,
            shell_ids,
        });
    }
    Ok(records)
}

pub fn read_session_layout(database: &Connection, id: SessionId) -> io::Result<Option<Layout>> {
    let stored_layout = database
        .query_row(
            "SELECT layout_json FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.to_string()],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))?;
    Ok(stored_layout.and_then(|json| parse_stored_layout(id, &json)))
}

/// Parsing validates the layout's structure; a stored layout that fails is ignored.
pub fn parse_stored_layout(id: SessionId, json: &str) -> Option<Layout> {
    serde_json::from_str(json)
        .inspect_err(|error| {
            log::warn!(
                "event=session.layout_invalid session_id={} reason={error}",
                id
            );
        })
        .ok()
}

pub fn session_initial_pwd(database: &Connection, id: SessionId) -> io::Result<PathBuf> {
    database
        .query_row(
            "SELECT initial_pwd FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.to_string()],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))
}

pub fn archive_session(database: &mut Connection, id: SessionId, reason: &str) -> io::Result<()> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let archived_at = unix_timestamp();
    transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE session_id = ?3 AND state = 'open'",
            params![archived_at, reason, id.to_string()],
        )
        .map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![archived_at, reason, id.to_string()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "session was not open in the database",
        ));
    }
    transaction.commit().map_err(io::Error::other)
}

/// Records the receipt time of a completed user or assistant message for an open Session.
pub fn record_session_message(
    database: &Connection,
    id: SessionId,
    timestamp: i64,
) -> io::Result<bool> {
    let changed = database
        .execute(
            "UPDATE sessions SET last_message_at = MAX(COALESCE(last_message_at, 0), ?1) \
             WHERE id = ?2 AND state = 'open'",
            params![timestamp, id.to_string()],
        )
        .map_err(io::Error::other)?;
    Ok(changed == 1)
}

pub fn write_session_layout(
    database: &Connection,
    id: SessionId,
    layout: &Layout,
) -> io::Result<()> {
    let layout_json = serde_json::to_string(layout).map_err(io::Error::other)?;
    let changed = database
        .execute(
            "UPDATE sessions SET layout_json = ?1 WHERE id = ?2 AND state = 'open'",
            params![layout_json, id.to_string()],
        )
        .map_err(io::Error::other)?;
    expect_one_row(changed, "session record is missing")
}

/// The user's name for a Session; Pi's title stays in `name`.
pub fn set_manual_session_name(database: &Connection, id: SessionId, name: &str) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE sessions SET manual_name = ?1 WHERE id = ?2 AND state = 'open'",
            params![name, id.to_string()],
        )
        .map_err(io::Error::other)?;
    expect_one_row(changed, "Session is not open")
}

/// Pi's title and emoji for a Session; `None` keeps the stored value. Returns whether an open
/// Session matched.
pub fn describe_session(
    database: &Connection,
    id: SessionId,
    title: Option<&str>,
    emoji: Option<&str>,
) -> io::Result<bool> {
    let changed = database
        .execute(
            "UPDATE sessions SET name = COALESCE(?1, name), emoji = COALESCE(?2, emoji) \
             WHERE id = ?3 AND state = 'open'",
            params![title, emoji, id.to_string()],
        )
        .map_err(io::Error::other)?;
    Ok(changed > 0)
}

/// Records which Pi session an open Session's transcript belongs to.
pub fn bind_pi_session_id(
    database: &Connection,
    id: SessionId,
    pi_session_id: &str,
) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE sessions SET pi_session_id = ? WHERE id = ? AND state = 'open'",
            params![pi_session_id, id.to_string()],
        )
        .map_err(io::Error::other)?;
    expect_one_row(changed, "Pi Session binding changed")
}

/// Sessions a person closed, most recently closed first, at most `limit`: what reopening a
/// closed Session offers. Sessions that ended any other way (their shell exited, Pi failed to
/// start, their Workspace was archived) are not offered.
pub fn recently_closed_sessions(
    database: &Connection,
    limit: usize,
) -> io::Result<Vec<PiHistoryOwner>> {
    let mut statement = database
        .prepare(
            "SELECT id, state, initial_pwd, workspace_id FROM sessions
             WHERE state = 'archived' AND termination_reason = 'explicit_close'
             ORDER BY archived_at DESC, created_at DESC, rowid DESC LIMIT ?1",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map(params![limit as i64], |row| {
            Ok(PiHistoryOwner {
                session_id: stored_session_id(row.get::<_, String>(0)?)?,
                lifecycle: row.get(1)?,
                initial_pwd: PathBuf::from(row.get::<_, String>(2)?),
                workspace_id: row.get(3)?,
            })
        })
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

pub fn archived_pi_pane_count(database: &Connection, id: SessionId) -> io::Result<i64> {
    database
        .query_row(
            "SELECT COUNT(*) FROM shells WHERE session_id = ?1 AND role = 'pi' AND state = 'archived'",
            params![id.to_string()],
            |row| row.get(0),
        )
        .map_err(io::Error::other)
}

/// Reopens an archived Session, the shells that closed with it and (if it has one) its
/// Workspace, all or nothing. Shells closed earlier on their own stay closed; `archive_session`
/// stamps a Session and its last shells with the same time and reason. Fails with `AlreadyExists` if the Session is no longer archived, `NotFound` if its Workspace
/// row is gone.
pub fn reopen_archived_session(
    database: &mut Connection,
    id: SessionId,
    workspace_id: Option<&str>,
) -> io::Result<()> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    if let Some(workspace_id) = workspace_id {
        let workspace_exists: bool = transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM workspaces WHERE workspace_id = ?1)",
                params![workspace_id],
                |row| row.get(0),
            )
            .map_err(io::Error::other)?;
        if !workspace_exists {
            return Err(not_found("archived Session's Workspace is missing"));
        }
        transaction
            .execute(
                "UPDATE workspaces SET state = 'open', archived_at = NULL WHERE workspace_id = ?1",
                params![workspace_id],
            )
            .map_err(io::Error::other)?;
    }
    // Before the Session row loses the time and reason that identify its last shells.
    transaction
        .execute(
            "UPDATE shells SET state = 'open', archived_at = NULL, termination_reason = NULL
             WHERE session_id = ?1 AND state = 'archived'
               AND archived_at IS (SELECT archived_at FROM sessions WHERE id = ?1)
               AND termination_reason IS (SELECT termination_reason FROM sessions WHERE id = ?1)",
            params![id.to_string()],
        )
        .map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE sessions SET state = 'open', archived_at = NULL, termination_reason = NULL
             WHERE id = ?1 AND state = 'archived'",
            params![id.to_string()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "Session changed while it was being resumed",
        ));
    }
    transaction.commit().map_err(io::Error::other)
}

/// The number in a new Session's default name ("Session N"): one more than the open Sessions
/// in its Workspace, or the standalone ones.
pub fn next_session_ordinal(database: &Connection, workspace_id: &str) -> io::Result<i64> {
    database
        .query_row(
            "SELECT COUNT(*) + 1 FROM sessions WHERE workspace_id = ? AND state = 'open'",
            params![workspace_id],
            |row| row.get(0),
        )
        .map_err(io::Error::other)
}

/// A Workspace Session about to be created, with its Pi pane and a terminal pane.
pub struct NewWorkspaceSession<'a> {
    pub session_id: SessionId,
    pub workspace_id: &'a str,
    pub initial_pwd: &'a Path,
    pub name: &'a str,
    pub pi_session_file: &'a Path,
    pub bridge_socket: &'a BridgeSocketPath,
    pub pane_id: &'a str,
    /// The UUID of the split between the Pi and terminal panes.
    pub split_id: &'a str,
}

/// The panes a new Workspace Session starts with.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InsertedWorkspaceSession {
    pub session_id: SessionId,
    pub pi: ShellId,
    pub terminal: ShellId,
}

/// Inserts a Workspace Session with Pi on the left and a terminal on the right, in one
/// transaction, so a failure never leaves an open Session without its panes.
pub fn insert_workspace_session(
    database: &mut Connection,
    new: &NewWorkspaceSession<'_>,
) -> io::Result<InsertedWorkspaceSession> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    transaction
        .execute(
            "INSERT INTO sessions
                (id, initial_pwd, state, created_at, workspace_id, name, pi_session_file, pi_bridge_socket_path)
             VALUES (?, ?, 'open', ?, ?, ?, ?, ?)",
            params![
                new.session_id.to_string(),
                new.initial_pwd.to_string_lossy(),
                unix_timestamp(),
                new.workspace_id,
                new.name,
                new.pi_session_file.to_string_lossy(),
                new.bridge_socket.as_str(),
            ],
        )
        .map_err(io::Error::other)?;
    let session_id = new.session_id;
    transaction
        .execute(
            "INSERT INTO shells (session_id, initial_pwd, state, created_at, role, pane_id)
             VALUES (?, ?, 'open', ?, 'pi', ?)",
            params![
                session_id.to_string(),
                new.initial_pwd.to_string_lossy(),
                unix_timestamp(),
                new.pane_id
            ],
        )
        .map_err(io::Error::other)?;
    let pi = inserted_shell_id(&transaction)?;
    let terminal = insert_terminal_shell(&transaction, session_id, new.initial_pwd)?;
    let layout = Layout::side_by_side(pi, terminal, new.split_id.to_owned())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    write_session_layout(&transaction, session_id, &layout)?;
    transaction.commit().map_err(io::Error::other)?;
    Ok(InsertedWorkspaceSession {
        session_id,
        pi,
        terminal,
    })
}

pub fn open_session_workspace_id(
    database: &Connection,
    id: SessionId,
) -> io::Result<Option<String>> {
    database
        .query_row(
            "SELECT workspace_id FROM sessions WHERE id = ? AND state = 'open'",
            params![id.to_string()],
            |row| row.get(0),
        )
        .map_err(io::Error::other)
}

/// An open Session's stored fields, with its Workspace's name.
pub struct StoredSessionRow {
    pub initial_pwd: PathBuf,
    pub workspace_id: Option<String>,
    pub workspace_name: Option<String>,
    pub name: String,
    pub manual_name: Option<String>,
    pub emoji: Option<String>,
    pub pi_session_file: Option<PathBuf>,
    pub pi_session_id: Option<String>,
    pub last_message_at: Option<i64>,
    /// Unix seconds.
    pub created_at: i64,
    pub layout: Option<Layout>,
}

/// One cached query per Session: this runs for every listing and snapshot, under the catalog
/// lock. A Session pointing at a Workspace that is not open is an error, not Workspace-less.
pub fn open_session_row(database: &Connection, id: SessionId) -> io::Result<StoredSessionRow> {
    let (row, stored_layout) = database
        .prepare_cached(
            "SELECT s.initial_pwd, s.workspace_id, w.name, s.name, s.manual_name,
                    s.emoji, s.pi_session_file, s.pi_session_id, s.layout_json, s.last_message_at,
                    s.created_at
             FROM sessions s
             LEFT JOIN workspaces w ON w.workspace_id = s.workspace_id AND w.state = 'open'
             WHERE s.id = ?1 AND s.state = 'open'",
        )
        .and_then(|mut statement| {
            statement.query_row(params![id.to_string()], |row| {
                Ok((
                    StoredSessionRow {
                        initial_pwd: PathBuf::from(row.get::<_, String>(0)?),
                        workspace_id: row.get(1)?,
                        workspace_name: row.get(2)?,
                        name: row.get(3)?,
                        manual_name: row.get(4)?,
                        emoji: row.get(5)?,
                        pi_session_file: row.get::<_, Option<String>>(6)?.map(PathBuf::from),
                        pi_session_id: row.get(7)?,
                        last_message_at: row.get(9)?,
                        created_at: row.get(10)?,
                        layout: None,
                    },
                    row.get::<_, Option<String>>(8)?,
                ))
            })
        })
        .map_err(io::Error::other)?;
    if row.workspace_id.is_some() && row.workspace_name.is_none() {
        return Err(io::Error::other("Session's Workspace is not open"));
    }
    Ok(StoredSessionRow {
        layout: stored_layout.and_then(|json| parse_stored_layout(id, &json)),
        ..row
    })
}

/// The most archived Sessions `read_archived_sessions` returns.
pub const MAX_ARCHIVED_SESSIONS: usize = 1000;

/// Archived Sessions that had a Pi, most recently archived first, at most
/// [`MAX_ARCHIVED_SESSIONS`].
pub fn read_archived_sessions(database: &Connection) -> io::Result<Vec<ArchivedSessionRecord>> {
    let mut statement = database
        .prepare(
            "SELECT s.id, COALESCE(s.manual_name, s.name), s.emoji, s.workspace_id,
                    w.name, s.initial_pwd, s.pi_session_file, s.last_message_at, s.archived_at
             FROM sessions s
             LEFT JOIN workspaces w ON w.workspace_id = s.workspace_id
             WHERE s.state = 'archived' AND s.pi_session_file IS NOT NULL
             ORDER BY s.archived_at DESC, s.created_at DESC, s.rowid DESC
             LIMIT ?1",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map(params![MAX_ARCHIVED_SESSIONS as i64], |row| {
            Ok(ArchivedSessionRecord {
                id: stored_session_id(row.get::<_, String>(0)?)?,
                name: row.get(1)?,
                emoji: row.get(2)?,
                workspace_id: row.get(3)?,
                workspace_name: row.get(4)?,
                initial_pwd: PathBuf::from(row.get::<_, String>(5)?),
                pi_session_file: row.get::<_, Option<String>>(6)?.map(PathBuf::from),
                last_message_at: row.get(7)?,
                archived_at: row.get(8)?,
            })
        })
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pi::open_pi_session;
    use crate::test_support::{database, insert_session, insert_workspace_row, kind, lifecycle};
    use crate::workspaces::{insert_workspace, open_workspace_directory};
    use axo_protocol::new_uuid_v4;

    #[test]
    fn session_writes_apply_only_to_open_sessions() {
        let database = database();
        let open = insert_session(&database, "open");
        let archived = insert_session(&database, "archived");
        let layout = Layout::single(ShellId::new(1).unwrap());

        write_session_layout(&database, open, &layout).unwrap();
        assert_eq!(
            read_session_layout(&database, open).unwrap(),
            Some(layout.clone())
        );
        assert_eq!(
            kind(write_session_layout(&database, archived, &layout)),
            io::ErrorKind::NotFound
        );
        set_manual_session_name(&database, open, "Mine").unwrap();
        assert_eq!(
            kind(set_manual_session_name(&database, archived, "Mine")),
            io::ErrorKind::NotFound
        );
        assert!(!describe_session(&database, archived, Some("t"), None).unwrap());
    }

    #[test]
    fn last_message_timestamp_is_monotonic_and_only_updates_open_sessions() {
        let database = database();
        let open = insert_session(&database, "open");
        let archived = insert_session(&database, "archived");

        assert!(record_session_message(&database, open, 100).unwrap());
        assert!(record_session_message(&database, open, 90).unwrap());
        let timestamp: Option<i64> = database
            .query_row(
                "SELECT last_message_at FROM sessions WHERE id = ?1",
                params![open.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(timestamp, Some(100));
        assert!(!record_session_message(&database, archived, 200).unwrap());
    }

    #[test]
    fn describing_a_session_keeps_the_fields_pi_leaves_out() {
        let database = database();
        let id = insert_session(&database, "open");
        let read = |database: &Connection| -> (String, Option<String>) {
            database
                .query_row(
                    "SELECT name, emoji FROM sessions WHERE id = ?1",
                    params![id.to_string()],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap()
        };
        assert!(describe_session(&database, id, Some("Renamed"), None).unwrap());
        assert_eq!(read(&database), ("Renamed".into(), Some("🦀".into())));
        assert!(describe_session(&database, id, None, Some("🐙")).unwrap());
        assert_eq!(read(&database), ("Renamed".into(), Some("🐙".into())));
    }

    #[test]
    fn a_pi_session_id_binds_only_to_an_open_session() {
        let database = database();
        let open = insert_session(&database, "open");
        let archived = insert_session(&database, "archived");
        assert_eq!(
            kind(bind_pi_session_id(&database, archived, "pi-1")),
            io::ErrorKind::NotFound
        );
        bind_pi_session_id(&database, open, "pi-1").unwrap();
    }

    #[test]
    fn reopening_an_archived_session_reopens_its_shells_and_workspace_or_nothing() {
        let database = &mut database();
        let workspace = new_uuid_v4().unwrap();
        insert_workspace_row(database, &workspace, "w", "archived");
        let session = insert_session(database, "archived");
        database
            .execute(
                "UPDATE sessions SET archived_at = 9, termination_reason = 'explicit_close'
                 WHERE id = ?1",
                params![session.to_string()],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO shells (session_id, initial_pwd, state, created_at, role,
                                     archived_at, termination_reason)
                 VALUES (?1, '/', 'archived', 0, 'pi', 9, 'explicit_close')",
                params![session.to_string()],
            )
            .unwrap();
        let shell = inserted_shell_id(database).unwrap().get().to_string();
        // Closed on its own before the Session closed: stays closed.
        database
            .execute(
                "INSERT INTO shells (session_id, initial_pwd, state, created_at, role,
                                     archived_at, termination_reason)
                 VALUES (?1, '/', 'archived', 0, 'terminal', 9, 'pane_closed')",
                params![session.to_string()],
            )
            .unwrap();
        let closed_alone = inserted_shell_id(database).unwrap().get().to_string();
        let id = session.to_string();

        // A missing Workspace leaves everything archived.
        assert_eq!(
            kind(reopen_archived_session(
                database,
                session,
                Some("missing-workspace")
            )),
            io::ErrorKind::NotFound
        );
        assert_eq!(lifecycle(database, "sessions", "id", &id), "archived");
        assert_eq!(lifecycle(database, "shells", "id", &shell), "archived");

        reopen_archived_session(database, session, Some(&workspace)).unwrap();
        assert_eq!(lifecycle(database, "sessions", "id", &id), "open");
        assert_eq!(lifecycle(database, "shells", "id", &shell), "open");
        assert_eq!(
            lifecycle(database, "shells", "id", &closed_alone),
            "archived"
        );
        assert_eq!(
            lifecycle(database, "workspaces", "workspace_id", &workspace),
            "open"
        );
        assert_eq!(archived_pi_pane_count(database, session).unwrap(), 0);

        // A Session that is already open was changed by someone else.
        assert_eq!(
            kind(reopen_archived_session(database, session, None)),
            io::ErrorKind::AlreadyExists
        );
    }

    #[test]
    fn new_sessions_are_numbered_within_their_workspace_and_open_with_pi_beside_a_terminal() {
        let database = &mut database();
        let workspace = new_uuid_v4().unwrap();
        insert_workspace(database, &workspace, "w", Path::new("/w"), None).unwrap();
        assert_eq!(next_session_ordinal(database, &workspace).unwrap(), 1);

        let socket = BridgeSocketPath::parse(PathBuf::from("/tmp/axo-store-test.sock")).unwrap();
        let split = new_uuid_v4().unwrap();
        let inserted = insert_workspace_session(
            database,
            &NewWorkspaceSession {
                session_id: SessionId::new_v4().unwrap(),
                workspace_id: &workspace,
                initial_pwd: Path::new("/w"),
                name: "Session 1",
                pi_session_file: Path::new("/h.jsonl"),
                bridge_socket: &socket,
                pane_id: "pane",
                split_id: &split,
            },
        )
        .unwrap();
        let session = inserted.session_id;
        assert_eq!(next_session_ordinal(database, &workspace).unwrap(), 2);

        // The Workspace Session arrives whole: Pi on the left, a terminal on the right.
        let row = open_session_row(database, session).unwrap();
        assert_eq!(
            row.layout,
            Some(Layout::side_by_side(inserted.pi, inserted.terminal, split).unwrap())
        );
        assert_eq!(row.workspace_name.as_deref(), Some("w"));
        let session_record = read_open_sessions(database)
            .unwrap()
            .into_iter()
            .find(|record| record.id == session)
            .unwrap();
        assert_eq!(
            session_record
                .shell_ids
                .iter()
                .map(|(id, role, _)| (*id, *role))
                .collect::<Vec<_>>(),
            vec![
                (inserted.pi, PaneRole::Pi),
                (inserted.terminal, PaneRole::Terminal)
            ]
        );
        let pi = open_pi_session(database, session).unwrap();
        assert_eq!(pi.session_file.as_deref(), Some(Path::new("/h.jsonl")));
        assert_eq!(pi.bridge_socket_path.as_deref(), Some(socket.as_str()));
        assert_eq!(
            open_session_workspace_id(database, session).unwrap(),
            Some(workspace.clone())
        );
        assert_eq!(
            open_workspace_directory(database, &workspace).unwrap(),
            Path::new("/w")
        );
    }
}
