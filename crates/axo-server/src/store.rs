//! Axod's SQLite catalog: the schema and its migrations, and every read and write that touches
//! only the database. Process and filesystem work stays in `session`; callers hold the catalog
//! lock around these, since the connection lives in `SessionState`.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};

use axo_pi::{AgentCommand, BridgeSocketPath};
use axo_protocol::{Layout, PaneRole, SessionId, ShellId, Viewport, is_uuid, new_uuid_v4};
use rusqlite::{Connection, OptionalExtension, params};

use crate::session::ShellCommand;
use crate::workspace_access::WorkspaceDirectoryAccess;

/// The agent a new database starts with.
const DEFAULT_AGENT_COMMAND: &str = "pi";

pub(crate) const DATABASE_FILE: &str = "axo.db";

/// An open session as stored, before its processes are restored.
#[derive(Debug)]
pub(crate) struct StoredSession {
    pub(crate) id: SessionId,
    pub(crate) initial_pwd: PathBuf,
    pub(crate) shell_ids: Vec<(ShellId, PaneRole, Option<String>)>,
}

pub(crate) fn load_or_create_agent_command(database: &Connection) -> io::Result<AgentCommand> {
    database
        .execute(
            "INSERT OR IGNORE INTO daemon_metadata (key, value) VALUES ('agent_command', ?1)",
            params![DEFAULT_AGENT_COMMAND],
        )
        .map_err(io::Error::other)?;
    let source = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = 'agent_command'",
            [],
            |row| row.get::<_, String>(0),
        )
        .map_err(io::Error::other)?;
    AgentCommand::parse(&source).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("stored default agent command is invalid: {error}"),
        )
    })
}

pub(crate) fn load_or_create_shell_command(database: &Connection) -> io::Result<ShellCommand> {
    let existing = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = 'shell_command'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    let source = match existing {
        Some(source) => source,
        None => {
            let source = default_shell_command()?;
            database
                .execute(
                    "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1)",
                    params![source],
                )
                .map_err(io::Error::other)?;
            source
        }
    };
    ShellCommand::parse(&source).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("stored default shell command is invalid: {error}"),
        )
    })
}

pub(crate) fn default_shell_command() -> io::Result<String> {
    let configured = std::env::var_os("SHELL").map(PathBuf::from);
    let shell = configured
        .filter(|path| {
            path.is_absolute() && path.is_file() && axo_pty::command::is_executable(path)
        })
        .or_else(|| {
            super::current_user_login_shell()
                .ok()
                .filter(|path| path.is_file() && axo_pty::command::is_executable(path))
        })
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "could not determine an executable shell for the current user",
            )
        })?;
    shell.to_str().map(str::to_owned).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "the current user's shell path is not valid UTF-8",
        )
    })
}

pub(crate) fn load_or_create_host_id(database: &Connection) -> io::Result<String> {
    let existing = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = 'host_id'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    if let Some(host_id) = existing {
        if !is_uuid(&host_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "stored host identity is malformed",
            ));
        }
        return Ok(host_id);
    }

    let host_id = new_uuid_v4()?;
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES ('host_id', ?1)",
            params![host_id],
        )
        .map_err(io::Error::other)?;
    Ok(host_id)
}

pub(crate) fn initialize_database(database: &mut Connection) -> rusqlite::Result<()> {
    let old_version = database.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
    let sessions_exist = database.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions')",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    let shells_exist = database.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'shells')",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    let transaction = database.transaction()?;

    if sessions_exist && !shells_exist {
        transaction.execute_batch("ALTER TABLE sessions RENAME TO legacy_sessions;")?;
        create_tables(&transaction)?;
        transaction.execute_batch(
            "INSERT INTO sessions (id, initial_pwd, state, created_at, archived_at, termination_reason)
             SELECT id, initial_pwd, state, created_at, archived_at, termination_reason
             FROM legacy_sessions;
             INSERT INTO shells (id, session_id, initial_pwd, state, created_at, archived_at, termination_reason)
             SELECT id, id, initial_pwd, state, created_at, archived_at, termination_reason
             FROM legacy_sessions;
             DROP TABLE legacy_sessions;",
        )?;
    } else {
        create_tables(&transaction)?;
    }
    ensure_session_layout_column(&transaction)?;
    ensure_workspace_columns(&transaction)?;
    if old_version < 4 {
        transaction.execute(
            "UPDATE shells SET state = 'archived', archived_at = ?, termination_reason = 'workspace_clean_cutover' WHERE state = 'open'",
            params![unix_timestamp()],
        )?;
        transaction.execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?, termination_reason = 'workspace_clean_cutover' WHERE state = 'open'",
            params![unix_timestamp()],
        )?;
    }

    transaction.pragma_update(None, "user_version", 7)?;
    transaction.commit()
}

pub(crate) fn create_tables(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspaces (
            workspace_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            directory_path TEXT NOT NULL,
            directory_bookmark TEXT,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            layout_json TEXT,
            workspace_id TEXT REFERENCES workspaces(workspace_id),
            session_uuid TEXT,
            name TEXT NOT NULL DEFAULT 'Session',
            manual_name TEXT,
            pi_session_file TEXT,
            pi_session_id TEXT,
            pi_bridge_socket_path TEXT
        );
        CREATE TABLE IF NOT EXISTS shells (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id),
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            role TEXT NOT NULL DEFAULT 'terminal' CHECK (role IN ('pi', 'terminal')),
            pane_id TEXT
        );
        CREATE INDEX IF NOT EXISTS shells_by_session_state
            ON shells(session_id, state, id);
        CREATE TABLE IF NOT EXISTS daemon_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );",
    )
}

pub(crate) fn open_standalone_session_count(database: &Connection) -> io::Result<i64> {
    database
        .query_row(
            "SELECT COUNT(*) FROM sessions WHERE workspace_id IS NULL AND state = 'open'",
            [],
            |row| row.get(0),
        )
        .map_err(io::Error::other)
}

pub(crate) fn read_open_sessions(database: &Connection) -> io::Result<Vec<StoredSession>> {
    let mut statement = database
        .prepare("SELECT id, initial_pwd FROM sessions WHERE state = 'open' ORDER BY id")
        .map_err(io::Error::other)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                stored_session_id(row.get(0)?)?,
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
            .query_map(params![id.get()], |row| {
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

pub(crate) fn read_session_layout(
    database: &Connection,
    id: SessionId,
) -> io::Result<Option<Layout>> {
    let stored_layout = database
        .query_row(
            "SELECT layout_json FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.get()],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))?;
    Ok(stored_layout.and_then(|json| parse_stored_layout(id, &json)))
}

/// Parsing validates the layout's structure; a stored layout that fails is ignored.
pub(crate) fn parse_stored_layout(id: SessionId, json: &str) -> Option<Layout> {
    serde_json::from_str(json)
        .inspect_err(|error| {
            log::warn!(
                "event=session.layout_invalid session_id={} reason={error}",
                id.get()
            );
        })
        .ok()
}

pub(crate) fn restore_workspace_accesses(
    database: &Connection,
) -> io::Result<HashMap<String, WorkspaceDirectoryAccess>> {
    let workspace_records = {
        let mut statement = database
            .prepare(
                "SELECT workspace_id, directory_path, directory_bookmark FROM workspaces \
                 WHERE state = 'open'",
            )
            .map_err(io::Error::other)?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };

    let mut accesses = HashMap::new();
    for (workspace_id, path, bookmark) in workspace_records {
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

pub(crate) fn ensure_workspace_columns(
    transaction: &rusqlite::Transaction<'_>,
) -> rusqlite::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspaces (
            workspace_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            directory_path TEXT NOT NULL,
            directory_bookmark TEXT,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER
        );",
    )?;
    for (table, column, definition) in [
        ("workspaces", "directory_bookmark", "TEXT"),
        (
            "sessions",
            "workspace_id",
            "TEXT REFERENCES workspaces(workspace_id)",
        ),
        ("sessions", "session_uuid", "TEXT"),
        ("sessions", "name", "TEXT NOT NULL DEFAULT 'Session'"),
        ("sessions", "manual_name", "TEXT"),
        ("sessions", "emoji", "TEXT"),
        ("sessions", "pi_session_file", "TEXT"),
        ("sessions", "pi_session_id", "TEXT"),
        ("sessions", "pi_bridge_socket_path", "TEXT"),
        (
            "shells",
            "role",
            "TEXT NOT NULL DEFAULT 'terminal' CHECK (role IN ('pi', 'terminal'))",
        ),
        ("shells", "pane_id", "TEXT"),
    ] {
        let columns = transaction
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?;
        if !columns.iter().any(|existing| existing == column) {
            transaction.execute(
                &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
                [],
            )?;
        }
    }
    transaction.execute_batch(
        "CREATE INDEX IF NOT EXISTS sessions_by_workspace_state ON sessions(workspace_id, state, id);",
    )?;
    Ok(())
}

pub(crate) fn ensure_pi_bridge_socket_paths(
    database: &Connection,
    pi_session_directory: &Path,
) -> io::Result<()> {
    let records = {
        let mut statement = database
            .prepare(
                "SELECT id, session_uuid, pi_bridge_socket_path FROM sessions
                 WHERE session_uuid IS NOT NULL",
            )
            .map_err(io::Error::other)?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };

    for (session_id, session_uuid, stored_path) in records {
        match stored_path {
            Some(path) => {
                BridgeSocketPath::parse(PathBuf::from(path)).map_err(|error| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("stored Pi bridge socket path for session {session_id} is invalid: {error}"),
                    )
                })?;
            }
            None => {
                let socket_path =
                    BridgeSocketPath::for_session(pi_session_directory, &session_uuid)?;
                let changed = database
                    .execute(
                        "UPDATE sessions SET pi_bridge_socket_path = ?1
                         WHERE id = ?2 AND pi_bridge_socket_path IS NULL",
                        params![socket_path.as_str(), session_id],
                    )
                    .map_err(io::Error::other)?;
                if changed != 1 {
                    return Err(io::Error::other(
                        "could not persist the Pi bridge socket address",
                    ));
                }
            }
        }
    }
    Ok(())
}

pub(crate) fn ensure_session_layout_column(
    transaction: &rusqlite::Transaction<'_>,
) -> rusqlite::Result<()> {
    let has_layout_column = {
        let mut statement = transaction.prepare("PRAGMA table_info(sessions)")?;
        let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
        columns
            .collect::<Result<Vec<_>, _>>()?
            .iter()
            .any(|column| column == "layout_json")
    };
    if !has_layout_column {
        transaction.execute("ALTER TABLE sessions ADD COLUMN layout_json TEXT", [])?;
    }
    Ok(())
}

pub(crate) fn session_initial_pwd(database: &Connection, id: SessionId) -> io::Result<PathBuf> {
    database
        .query_row(
            "SELECT initial_pwd FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.get()],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))
}

pub(crate) fn archive_shell(database: &Connection, id: ShellId, reason: &str) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![unix_timestamp(), reason, id.get()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "shell was not open in the database",
        ));
    }
    Ok(())
}

pub(crate) fn archive_shell_and_prune_layout(
    database: &mut Connection,
    shell_id: ShellId,
    session_id: SessionId,
    reason: &str,
    remaining_shell_ids: &HashSet<ShellId>,
) -> io::Result<()> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![unix_timestamp(), reason, shell_id.get()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "shell was not open in the database",
        ));
    }

    if let Some(layout) = read_session_layout(&transaction, session_id)? {
        let pruned_layout = layout.pruned_to(remaining_shell_ids);
        let layout_json = pruned_layout
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(io::Error::other)?;
        transaction
            .execute(
                "UPDATE sessions SET layout_json = ?1 WHERE id = ?2 AND state = 'open'",
                params![layout_json, session_id.get()],
            )
            .map_err(io::Error::other)?;
    }

    transaction.commit().map_err(io::Error::other)
}

pub(crate) fn archive_workspace_records(
    database: &mut Connection,
    workspace_id: &str,
) -> io::Result<Vec<SessionId>> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let session_ids = {
        let mut statement = transaction
            .prepare("SELECT id FROM sessions WHERE workspace_id = ?1 AND state = 'open'")
            .map_err(io::Error::other)?;
        statement
            .query_map(params![workspace_id], |row| row.get::<_, i64>(0))
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

pub(crate) fn archive_session(
    database: &mut Connection,
    id: SessionId,
    reason: &str,
) -> io::Result<()> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let archived_at = unix_timestamp();
    transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE session_id = ?3 AND state = 'open'",
            params![archived_at, reason, id.get()],
        )
        .map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![archived_at, reason, id.get()],
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

pub(crate) fn pi_bridge_token_key(session_uuid: &str) -> String {
    format!("pi_bridge_token:{session_uuid}")
}

pub(crate) fn load_pi_bridge_token(
    database: &Connection,
    session_uuid: &str,
) -> io::Result<Option<String>> {
    let token = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![pi_bridge_token_key(session_uuid)],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    if token.as_ref().is_some_and(|token| !is_uuid(token)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi bridge credential is invalid",
        ));
    }
    Ok(token)
}

pub(crate) fn store_pi_bridge_token(
    database: &Connection,
    session_uuid: &str,
    token: &str,
) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![pi_bridge_token_key(session_uuid), token],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

/// Where the latest client's viewport is kept across restarts, so restored panes start at
/// the size they will be shown at.
pub(crate) const VIEWPORT_METADATA_KEY: &str = "client_viewport";

pub(crate) fn load_viewport(database: &Connection) -> io::Result<Option<Viewport>> {
    let stored: Option<String> = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![VIEWPORT_METADATA_KEY],
            |row| row.get(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    Ok(
        stored.and_then(|stored| match serde_json::from_str(&stored) {
            Ok(viewport) => Some(viewport),
            Err(error) => {
                log::warn!("event=viewport.stored_invalid reason={error}");
                None
            }
        }),
    )
}

pub(crate) fn store_viewport(database: &Connection, viewport: &Viewport) -> io::Result<()> {
    let value = serde_json::to_string(viewport).map_err(io::Error::other)?;
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![VIEWPORT_METADATA_KEY, value],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

/// The `state` column of a Session, shell or Workspace row. Parsed when read, so a corrupt or
/// unknown state fails the query instead of being compared as a string downstream.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum StoredLifecycle {
    Open,
    Archived,
}

impl rusqlite::types::FromSql for StoredLifecycle {
    fn column_result(value: rusqlite::types::ValueRef<'_>) -> rusqlite::types::FromSqlResult<Self> {
        match value.as_str()? {
            "open" => Ok(StoredLifecycle::Open),
            "archived" => Ok(StoredLifecycle::Archived),
            other => Err(rusqlite::types::FromSqlError::Other(
                format!("unknown lifecycle state {other:?}").into(),
            )),
        }
    }
}

/// Catalog IDs come from `AUTOINCREMENT` columns, so a stored ID is positive unless the database
/// is corrupt; reading one that is not fails instead of producing an invalid ID.
pub(crate) fn stored_session_id(value: i64) -> rusqlite::Result<SessionId> {
    SessionId::new(value).ok_or(rusqlite::Error::IntegralValueOutOfRange(0, value))
}

pub(crate) fn stored_shell_id(value: i64) -> rusqlite::Result<ShellId> {
    ShellId::new(value).ok_or(rusqlite::Error::IntegralValueOutOfRange(0, value))
}

pub(crate) fn inserted_session_id(database: &Connection) -> io::Result<SessionId> {
    stored_session_id(database.last_insert_rowid()).map_err(io::Error::other)
}

pub(crate) fn inserted_shell_id(database: &Connection) -> io::Result<ShellId> {
    stored_shell_id(database.last_insert_rowid()).map_err(io::Error::other)
}

pub(crate) fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
