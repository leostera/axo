//! Axod's SQLite catalog: the schema and its migrations, and every read and write that touches
//! only the database. Processes, files and settings parsing stay in `axo-server`, which owns the
//! connection and holds its catalog lock around these calls.

use std::collections::HashSet;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use axo_pi::BridgeSocketPath;
use axo_protocol::rpc::ArchivedSessionRecord;
use axo_protocol::{
    ConfigKey, Layout, PaneRole, SessionId, ShellId, Viewport, WorkspaceRecord, is_uuid,
    new_uuid_v4,
};
pub use rusqlite::Connection;
use rusqlite::{OptionalExtension, params};

pub const DATABASE_FILE: &str = "axo.db";

/// An open session as stored, before its processes are restored.
#[derive(Debug)]
pub struct StoredSession {
    pub id: SessionId,
    pub initial_pwd: PathBuf,
    pub shell_ids: Vec<(ShellId, PaneRole, Option<String>)>,
}

/// A setting's stored value; on first use, `default()` is stored and returned. Parsing it is the
/// caller's job.
pub fn load_or_create_setting(
    database: &Connection,
    key: ConfigKey,
    default: impl FnOnce() -> io::Result<String>,
) -> io::Result<String> {
    let key = config_metadata_key(key);
    let existing = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![key],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    if let Some(value) = existing {
        return Ok(value);
    }
    let value = default()?;
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)",
            params![key, value],
        )
        .map_err(io::Error::other)?;
    Ok(value)
}

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

pub fn load_or_create_host_id(database: &Connection) -> io::Result<String> {
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

/// This host's link to an Axo account, as stored. Each group of columns is set together (the
/// table enforces it); parsing the identifiers is the relay's job.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct StoredHostLink {
    pub account: Option<StoredAccountLink>,
    pub pending_redemption: Option<StoredPendingRedemption>,
}

/// The account this host is linked to, and the credential it connects with.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredAccountLink {
    pub account_id: String,
    pub credential_id: String,
}

/// A redemption that was started but not confirmed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredPendingRedemption {
    pub credential_id: String,
    pub host_generation: String,
}

pub fn load_host_link(database: &Connection) -> io::Result<StoredHostLink> {
    let row = database
        .query_row(
            "SELECT account_id, credential_id, pending_credential_id, pending_host_generation \
             FROM host_link WHERE singleton = 1",
            [],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .optional()
        .map_err(io::Error::other)?;
    let Some((account_id, credential_id, pending_credential_id, pending_host_generation)) = row
    else {
        return Ok(StoredHostLink::default());
    };
    Ok(StoredHostLink {
        account: account_id
            .zip(credential_id)
            .map(|(account_id, credential_id)| StoredAccountLink {
                account_id,
                credential_id,
            }),
        pending_redemption: pending_credential_id.zip(pending_host_generation).map(
            |(credential_id, host_generation)| StoredPendingRedemption {
                credential_id,
                host_generation,
            },
        ),
    })
}

pub fn store_host_link(database: &Connection, link: &StoredHostLink) -> io::Result<()> {
    let account = link.account.as_ref();
    let pending = link.pending_redemption.as_ref();
    let account_id = account.map(|account| &account.account_id);
    let credential_id = account.map(|account| &account.credential_id);
    let pending_credential_id = pending.map(|pending| &pending.credential_id);
    let pending_host_generation = pending.map(|pending| &pending.host_generation);
    database
        .execute(
            "INSERT INTO host_link \
             (singleton, account_id, credential_id, pending_credential_id, pending_host_generation) \
             VALUES (1, ?1, ?2, ?3, ?4) \
             ON CONFLICT(singleton) DO UPDATE SET account_id = excluded.account_id, \
             credential_id = excluded.credential_id, \
             pending_credential_id = excluded.pending_credential_id, \
             pending_host_generation = excluded.pending_host_generation",
            params![
                account_id,
                credential_id,
                pending_credential_id,
                pending_host_generation
            ],
        )
        .map(drop)
        .map_err(io::Error::other)
}

/// Opens (creating if needed) the catalog at `path`, migrated to the current schema and readable
/// only by its owner. Writes are durable once they return: WAL with `synchronous=FULL`.
pub fn open(path: &Path) -> io::Result<Connection> {
    let mut database = Connection::open(path).map_err(io::Error::other)?;
    database
        .busy_timeout(std::time::Duration::from_secs(3))
        .and_then(|()| database.pragma_update(None, "journal_mode", "WAL"))
        .and_then(|()| database.pragma_update(None, "synchronous", "FULL"))
        .and_then(|()| database.pragma_update(None, "foreign_keys", "ON"))
        .and_then(|()| back_up_before_uuid_rekey(&database, path))
        .and_then(|()| initialize_database(&mut database))
        .map_err(io::Error::other)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(database)
}

pub fn initialize_database(database: &mut Connection) -> rusqlite::Result<()> {
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
    // A catalog from before version 9 keys Sessions by integers; it is brought up to date in
    // that shape and then rekeyed by UUID (RFD0017).
    let integer_keyed = sessions_exist && old_version < 9;

    if sessions_exist && !shells_exist {
        transaction.execute_batch("ALTER TABLE sessions RENAME TO legacy_sessions;")?;
        create_integer_keyed_session_tables(&transaction)?;
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
    if integer_keyed {
        ensure_integer_keyed_session_columns(&transaction)?;
    }
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

    if integer_keyed {
        rekey_sessions_by_uuid(&transaction)?;
    }
    ensure_session_indexes(&transaction)?;

    transaction.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    transaction.commit()
}

/// The catalog's schema version (`PRAGMA user_version`). Version 9 keys Sessions by UUID.
pub const SCHEMA_VERSION: i64 = 9;

/// Where `open` keeps a copy of a catalog before rekeying it by UUID, next to the catalog.
pub fn pre_uuid_backup_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".pre-uuid");
    path.with_file_name(name)
}

/// Copies a catalog that is about to be rekeyed by UUID, once: an existing copy is kept.
fn back_up_before_uuid_rekey(database: &Connection, path: &Path) -> rusqlite::Result<()> {
    let version: i64 = database.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    let has_sessions: bool = database.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions')",
        [],
        |row| row.get(0),
    )?;
    let backup = pre_uuid_backup_path(path);
    if version >= SCHEMA_VERSION || !has_sessions || backup.exists() {
        return Ok(());
    }
    database.execute("VACUUM INTO ?1", params![backup.to_string_lossy()])?;
    std::fs::set_permissions(&backup, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    log::info!(
        "event=catalog.backup reason=uuid_rekey path={}",
        backup.display()
    );
    Ok(())
}

/// Sessions and shells as they were before version 9, for catalogs older than shells.
fn create_integer_keyed_session_tables(
    transaction: &rusqlite::Transaction<'_>,
) -> rusqlite::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT
        );
        CREATE TABLE shells (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id),
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT
        );",
    )
}

/// Columns a pre-version-9 catalog may lack before it can be rekeyed.
fn ensure_integer_keyed_session_columns(
    transaction: &rusqlite::Transaction<'_>,
) -> rusqlite::Result<()> {
    add_missing_columns(transaction, &[("sessions", "session_uuid", "TEXT")])
}

/// Rekeys Sessions by UUID (RFD0017), in the caller's transaction. A Session that already has a
/// `session_uuid` keeps it as its ID, so its Pi transcript, bridge socket and token still match;
/// one without gets a new random UUID. Shells follow their Session; shell IDs do not change.
fn rekey_sessions_by_uuid(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    let missing = {
        let mut statement =
            transaction.prepare("SELECT id FROM sessions WHERE session_uuid IS NULL")?;
        statement
            .query_map([], |row| row.get::<_, i64>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for id in &missing {
        let uuid = SessionId::new_v4()
            .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
        transaction.execute(
            "UPDATE sessions SET session_uuid = ?1 WHERE id = ?2",
            params![uuid.to_string(), id],
        )?;
    }
    let invalid: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM sessions WHERE session_uuid NOT GLOB
         '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'",
        [],
        |row| row.get(0),
    )?;
    if invalid > 0 {
        return Err(rusqlite::Error::ToSqlConversionFailure(
            format!("{invalid} Session UUIDs are not canonical lowercase UUIDs").into(),
        ));
    }
    let count = |table: &str| -> rusqlite::Result<i64> {
        transaction.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
            row.get(0)
        })
    };
    let (sessions, shells) = (count("sessions")?, count("shells")?);
    let shell_sequence: i64 = transaction
        .query_row(
            "SELECT seq FROM sqlite_sequence WHERE name = 'shells'",
            [],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(0);

    // The new tables reference each other by their final names only after the renames, which
    // rewrite references; the old tables go first so nothing points at them.
    transaction.execute_batch(&format!(
        "CREATE TABLE sessions_v9 ({SESSIONS_V9_COLUMNS});
         CREATE TABLE shells_v9 ({SHELLS_V9_COLUMNS_REFERENCING_V9});
         INSERT INTO sessions_v9 (id, initial_pwd, state, created_at, archived_at, termination_reason,
                layout_json, workspace_id, name, manual_name, last_message_at, pi_session_file,
                pi_session_id, pi_bridge_socket_path, emoji)
             SELECT session_uuid, initial_pwd, state, created_at, archived_at, termination_reason,
                layout_json, workspace_id, name, manual_name, last_message_at, pi_session_file,
                pi_session_id, pi_bridge_socket_path, emoji
             FROM sessions ORDER BY id;
         INSERT INTO shells_v9 (id, session_id, initial_pwd, state, created_at, archived_at,
                termination_reason, role, pane_id)
             SELECT h.id, s.session_uuid, h.initial_pwd, h.state, h.created_at, h.archived_at,
                h.termination_reason, h.role, h.pane_id
             FROM shells h JOIN sessions s ON s.id = h.session_id;"
    ))?;
    if count("sessions_v9")? != sessions || count("shells_v9")? != shells {
        return Err(rusqlite::Error::ToSqlConversionFailure(
            "rekeying Sessions by UUID would lose rows".into(),
        ));
    }
    transaction.execute_batch(
        "DROP TABLE shells;
         DROP TABLE sessions;
         ALTER TABLE sessions_v9 RENAME TO sessions;
         ALTER TABLE shells_v9 RENAME TO shells;",
    )?;
    // Shell IDs are never reused, including ones whose rows are gone.
    transaction.execute(
        "UPDATE sqlite_sequence SET seq = MAX(seq, ?1) WHERE name = 'shells'",
        params![shell_sequence],
    )?;
    log::info!(
        "event=catalog.rekeyed_by_uuid sessions={sessions} shells={shells} new_uuids={}",
        missing.len()
    );
    Ok(())
}

/// Session IDs carry no order, so ties in time go to the row inserted later: `rowid`, which the
/// rekey preserves by copying Sessions in their old integer order. It only breaks ties.
const SESSIONS_V9_COLUMNS: &str = "
            id TEXT PRIMARY KEY NOT NULL,
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            layout_json TEXT,
            workspace_id TEXT REFERENCES workspaces(workspace_id),
            name TEXT NOT NULL DEFAULT 'Session',
            manual_name TEXT,
            last_message_at INTEGER,
            pi_session_file TEXT,
            pi_session_id TEXT,
            pi_bridge_socket_path TEXT,
            emoji TEXT";

const SHELLS_V9_COLUMNS_REFERENCING_V9: &str = "
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions_v9(id),
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            role TEXT NOT NULL DEFAULT 'terminal' CHECK (role IN ('pi', 'terminal')),
            pane_id TEXT";

fn ensure_session_indexes(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute_batch(
        "CREATE INDEX IF NOT EXISTS shells_by_session_state ON shells(session_id, state, id);
         CREATE INDEX IF NOT EXISTS sessions_by_workspace_state ON sessions(workspace_id, state, created_at);",
    )
}

pub fn create_tables(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
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
            id TEXT PRIMARY KEY NOT NULL,
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            layout_json TEXT,
            workspace_id TEXT REFERENCES workspaces(workspace_id),
            name TEXT NOT NULL DEFAULT 'Session',
            manual_name TEXT,
            last_message_at INTEGER,
            pi_session_file TEXT,
            pi_session_id TEXT,
            pi_bridge_socket_path TEXT,
            emoji TEXT
        );
        CREATE TABLE IF NOT EXISTS shells (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            role TEXT NOT NULL DEFAULT 'terminal' CHECK (role IN ('pi', 'terminal')),
            pane_id TEXT
        );
        CREATE TABLE IF NOT EXISTS daemon_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS host_link (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            account_id TEXT,
            credential_id TEXT,
            pending_credential_id TEXT,
            pending_host_generation TEXT,
            CHECK ((account_id IS NULL) = (credential_id IS NULL)),
            CHECK ((pending_credential_id IS NULL) = (pending_host_generation IS NULL))
        );",
    )
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

pub fn ensure_workspace_columns(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
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
    let columns: &[(&str, &str, &str)] = &[
        ("workspaces", "directory_bookmark", "TEXT"),
        (
            "sessions",
            "workspace_id",
            "TEXT REFERENCES workspaces(workspace_id)",
        ),
        ("sessions", "name", "TEXT NOT NULL DEFAULT 'Session'"),
        ("sessions", "manual_name", "TEXT"),
        ("sessions", "last_message_at", "INTEGER"),
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
    ];
    add_missing_columns(transaction, columns)
}

fn add_missing_columns(
    transaction: &rusqlite::Transaction<'_>,
    columns: &[(&str, &str, &str)],
) -> rusqlite::Result<()> {
    for (table, column, definition) in columns {
        let existing = transaction
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?;
        if !existing.iter().any(|existing| existing == column) {
            transaction.execute(
                &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
                [],
            )?;
        }
    }
    Ok(())
}

pub fn ensure_pi_bridge_socket_paths(
    database: &Connection,
    pi_session_directory: &Path,
) -> io::Result<()> {
    let records = {
        let mut statement = database
            .prepare(
                "SELECT id, pi_bridge_socket_path FROM sessions WHERE pi_session_file IS NOT NULL",
            )
            .map_err(io::Error::other)?;
        statement
            .query_map([], |row| {
                Ok((
                    stored_session_id(row.get::<_, String>(0)?)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };

    for (session_id, stored_path) in records {
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
                    BridgeSocketPath::for_session(pi_session_directory, &session_id.to_string())?;
                let changed = database
                    .execute(
                        "UPDATE sessions SET pi_bridge_socket_path = ?1
                         WHERE id = ?2 AND pi_bridge_socket_path IS NULL",
                        params![socket_path.as_str(), session_id.to_string()],
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

pub fn ensure_session_layout_column(
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

pub fn archive_shell(database: &Connection, id: ShellId, reason: &str) -> io::Result<()> {
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

pub fn archive_shell_and_prune_layout(
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
                params![layout_json, session_id.to_string()],
            )
            .map_err(io::Error::other)?;
    }

    transaction.commit().map_err(io::Error::other)
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

pub fn pi_bridge_token_key(session_id: SessionId) -> String {
    format!("pi_bridge_token:{session_id}")
}

pub fn load_pi_bridge_token(
    database: &Connection,
    session_id: SessionId,
) -> io::Result<Option<String>> {
    let token = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![pi_bridge_token_key(session_id)],
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

pub fn store_pi_bridge_token(
    database: &Connection,
    session_id: SessionId,
    token: &str,
) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![pi_bridge_token_key(session_id), token],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

/// Where the latest client's viewport is kept across restarts, so restored panes start at
/// the size they will be shown at.
pub const VIEWPORT_METADATA_KEY: &str = "client_viewport";

pub fn load_viewport(database: &Connection) -> io::Result<Option<Viewport>> {
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

pub fn store_viewport(database: &Connection, viewport: &Viewport) -> io::Result<()> {
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
pub enum StoredLifecycle {
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

/// A stored Session ID is a canonical UUID unless the database is corrupt; reading one that is
/// not fails instead of producing an invalid ID.
pub fn stored_session_id(value: String) -> rusqlite::Result<SessionId> {
    SessionId::parse(&value).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Text,
            Box::new(axo_protocol::InvalidSessionId(value)),
        )
    })
}

/// Shell IDs come from an `AUTOINCREMENT` column, so a stored one is positive unless the
/// database is corrupt; reading one that is not fails instead of producing an invalid ID.
pub fn stored_shell_id(value: i64) -> rusqlite::Result<ShellId> {
    ShellId::new(value).ok_or(rusqlite::Error::IntegralValueOutOfRange(0, value))
}

pub fn inserted_shell_id(database: &Connection) -> io::Result<ShellId> {
    stored_shell_id(database.last_insert_rowid()).map_err(io::Error::other)
}

pub fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
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

fn not_found(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, message)
}

/// Fails with `NotFound(message)` unless exactly one row changed.
fn expect_one_row(changed: usize, message: &'static str) -> io::Result<()> {
    if changed == 1 {
        Ok(())
    } else {
        Err(not_found(message))
    }
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

/// Where a setting lives in `daemon_metadata`.
fn config_metadata_key(key: ConfigKey) -> &'static str {
    match key {
        ConfigKey::AgentCommand => "agent_command",
        ConfigKey::ShellCommand => "shell_command",
    }
}

pub fn store_config_value(database: &Connection, key: ConfigKey, value: &str) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![config_metadata_key(key), value],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

/// A Session whose Pi transcript is a given history file.
#[derive(Debug)]
pub struct PiHistoryOwner {
    pub session_id: SessionId,
    pub lifecycle: StoredLifecycle,
    pub initial_pwd: PathBuf,
    pub workspace_id: Option<String>,
}

/// Every Session, open or archived, whose Pi history is `session_file`. More than one means
/// the catalog is inconsistent; callers require exactly one.
pub fn pi_history_owners(
    database: &Connection,
    session_file: &str,
) -> io::Result<Vec<PiHistoryOwner>> {
    let mut statement = database
        .prepare(
            "SELECT id, state, initial_pwd, workspace_id FROM sessions WHERE pi_session_file = ?1",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map(params![session_file], |row| {
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

pub fn insert_terminal_shell(
    database: &Connection,
    session_id: SessionId,
    initial_pwd: &Path,
) -> io::Result<ShellId> {
    database
        .execute(
            "INSERT INTO shells (session_id, initial_pwd, state, created_at) VALUES (?1, ?2, 'open', ?3)",
            params![session_id.to_string(), initial_pwd.to_string_lossy(), unix_timestamp()],
        )
        .map_err(io::Error::other)?;
    inserted_shell_id(database)
}

/// What an open Session stores about its Pi.
pub struct StoredPiSession {
    pub session_file: Option<PathBuf>,
    pub bridge_socket_path: Option<String>,
    /// Whether Pi ever completed a message, and so wrote its history.
    pub has_messages: bool,
}

pub fn open_pi_session(database: &Connection, id: SessionId) -> io::Result<StoredPiSession> {
    database
        .query_row(
            "SELECT pi_session_file, pi_bridge_socket_path, last_message_at IS NOT NULL
             FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.to_string()],
            |row| {
                Ok(StoredPiSession {
                    session_file: row.get::<_, Option<String>>(0)?.map(PathBuf::from),
                    bridge_socket_path: row.get(1)?,
                    has_messages: row.get(2)?,
                })
            },
        )
        .map_err(io::Error::other)
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

/// Every Session that records a Pi bridge socket: its ID, history file and socket path.
pub fn pi_bridge_sockets(database: &Connection) -> io::Result<Vec<(SessionId, PathBuf, PathBuf)>> {
    let mut statement = database
        .prepare(
            "SELECT id, pi_session_file, pi_bridge_socket_path FROM sessions
             WHERE pi_session_file IS NOT NULL AND pi_bridge_socket_path IS NOT NULL",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map([], |row| {
            Ok((
                stored_session_id(row.get::<_, String>(0)?)?,
                PathBuf::from(row.get::<_, String>(1)?),
                PathBuf::from(row.get::<_, String>(2)?),
            ))
        })
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn database() -> Connection {
        let mut database = Connection::open_in_memory().unwrap();
        initialize_database(&mut database).unwrap();
        database
    }

    #[test]
    fn host_link_round_trips_and_its_column_pairs_stay_together() {
        let database = database();
        assert_eq!(
            load_host_link(&database).unwrap(),
            StoredHostLink::default()
        );
        let pending = StoredHostLink {
            account: None,
            pending_redemption: Some(StoredPendingRedemption {
                credential_id: "credential-1".into(),
                host_generation: "generation-1".into(),
            }),
        };
        store_host_link(&database, &pending).unwrap();
        assert_eq!(load_host_link(&database).unwrap(), pending);
        let linked = StoredHostLink {
            account: Some(StoredAccountLink {
                account_id: "account-1".into(),
                credential_id: "credential-1".into(),
            }),
            pending_redemption: None,
        };
        store_host_link(&database, &linked).unwrap();
        assert_eq!(load_host_link(&database).unwrap(), linked);
        store_host_link(&database, &StoredHostLink::default()).unwrap();
        assert_eq!(
            load_host_link(&database).unwrap(),
            StoredHostLink::default()
        );

        for half in [
            "INSERT OR REPLACE INTO host_link (singleton, account_id) VALUES (1, 'a')",
            "INSERT OR REPLACE INTO host_link (singleton, pending_credential_id) VALUES (1, 'c')",
        ] {
            assert!(database.execute(half, []).is_err(), "{half}");
        }
    }

    fn insert_session(database: &Connection, state: &str) -> SessionId {
        let id = SessionId::new_v4().unwrap();
        database
            .execute(
                "INSERT INTO sessions (id, initial_pwd, state, created_at, name, emoji)
                 VALUES (?1, '/', ?2, 0, 'Pi title', '🦀')",
                params![id.to_string(), state],
            )
            .unwrap();
        id
    }

    fn insert_workspace(database: &Connection, id: &str, name: &str, state: &str) {
        database
            .execute(
                "INSERT INTO workspaces (workspace_id, name, directory_path, state, created_at)
                 VALUES (?1, ?2, ?3, ?4, 0)",
                params![id, name, format!("/work/{name}"), state],
            )
            .unwrap();
    }

    fn kind<T: std::fmt::Debug>(result: io::Result<T>) -> io::ErrorKind {
        result.unwrap_err().kind()
    }

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
    fn workspaces_list_open_ones_by_name_and_rename_only_open_ones() {
        let database = database();
        let (zed, alpha, gone) = (
            new_uuid_v4().unwrap(),
            new_uuid_v4().unwrap(),
            new_uuid_v4().unwrap(),
        );
        insert_workspace(&database, &zed, "zed", "open");
        insert_workspace(&database, &alpha, "alpha", "open");
        insert_workspace(&database, &gone, "gone", "archived");
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

    fn lifecycle(database: &Connection, table: &str, column: &str, id: &str) -> String {
        database
            .query_row(
                &format!("SELECT state FROM {table} WHERE {column} = ?1"),
                params![id],
                |row| row.get(0),
            )
            .unwrap()
    }

    #[test]
    fn reopening_an_archived_session_reopens_its_shells_and_workspace_or_nothing() {
        let database = &mut database();
        let workspace = new_uuid_v4().unwrap();
        insert_workspace(database, &workspace, "w", "archived");
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
    fn every_session_owning_a_pi_history_is_reported() {
        let database = database();
        let first = insert_session(&database, "open");
        let second = insert_session(&database, "archived");
        for id in [first, second] {
            database
                .execute(
                    "UPDATE sessions SET pi_session_file = '/h.jsonl' WHERE id = ?1",
                    params![id.to_string()],
                )
                .unwrap();
        }
        let owners = pi_history_owners(&database, "/h.jsonl").unwrap();
        assert_eq!(owners.len(), 2, "callers must see the inconsistency");
        assert_eq!(owners[1].lifecycle, StoredLifecycle::Archived);
        assert!(
            pi_history_owners(&database, "/other.jsonl")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn stored_lifecycle_parses_known_states_and_rejects_others() {
        let database = Connection::open_in_memory().unwrap();
        let read = |state: &str| {
            database.query_row("SELECT ?1", params![state], |row| {
                row.get::<_, StoredLifecycle>(0)
            })
        };
        assert_eq!(read("open").unwrap(), StoredLifecycle::Open);
        assert_eq!(read("archived").unwrap(), StoredLifecycle::Archived);
        assert!(read("closed").is_err());
        assert!(read("").is_err());
    }

    #[test]
    fn archives_legacy_shell_sessions_during_workspace_cutover() {
        let mut database = Connection::open_in_memory().unwrap();
        database
            .execute_batch(
                "CREATE TABLE sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    initial_pwd TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER,
                    termination_reason TEXT
                );
                INSERT INTO sessions (id, initial_pwd, state, created_at)
                VALUES (7, '/tmp', 'open', 123);",
            )
            .unwrap();

        initialize_database(&mut database).unwrap();

        let session: (String, String, String) = database
            .query_row("SELECT id, initial_pwd, state FROM sessions", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .unwrap();
        let shell: (i64, String, String, String) = database
            .query_row(
                "SELECT id, session_id, initial_pwd, state FROM shells WHERE id = 7",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert!(SessionId::parse(&session.0).is_some(), "{}", session.0);
        assert_eq!((&*session.1, &*session.2), ("/tmp", "archived"));
        assert_eq!(
            shell,
            (7, session.0, "/tmp".to_owned(), "archived".to_owned())
        );
    }

    #[test]
    fn adds_layout_storage_to_existing_tab_databases() {
        let mut database = Connection::open_in_memory().unwrap();
        database
            .execute_batch(
                "CREATE TABLE sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    initial_pwd TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER,
                    termination_reason TEXT
                );
                CREATE TABLE shells (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    initial_pwd TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER,
                    termination_reason TEXT
                );
                INSERT INTO sessions (initial_pwd, state, created_at)
                VALUES ('/tmp', 'open', 123);
                INSERT INTO shells (session_id, initial_pwd, state, created_at)
                VALUES (1, '/tmp', 'open', 123);",
            )
            .unwrap();

        initialize_database(&mut database).unwrap();

        let layout: Option<String> = database
            .query_row("SELECT layout_json FROM sessions", [], |row| row.get(0))
            .unwrap();
        let schema_version: i64 = database
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(layout, None);
        assert_eq!(schema_version, SCHEMA_VERSION);
        let manual_name_column: i64 = database
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'manual_name'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(manual_name_column, 1);
        let bridge_socket_column: i64 = database
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'pi_bridge_socket_path'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(bridge_socket_column, 1);
        let session_state: String = database
            .query_row("SELECT state FROM sessions", [], |row| row.get(0))
            .unwrap();
        assert_eq!(session_state, "archived");
    }

    #[test]
    fn open_creates_an_owner_only_durable_catalog_and_reopens_it() {
        let directory = std::env::temp_dir().join(format!(
            "axo-store-open-{}-{}",
            std::process::id(),
            new_uuid_v4().unwrap()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(DATABASE_FILE);

        let database = open(&path).unwrap();
        let pragma = |name: &str| -> String {
            database
                .query_row(&format!("PRAGMA {name}"), [], |row| {
                    row.get::<_, rusqlite::types::Value>(0)
                })
                .map(|value| match value {
                    rusqlite::types::Value::Integer(number) => number.to_string(),
                    rusqlite::types::Value::Text(text) => text,
                    other => format!("{other:?}"),
                })
                .unwrap()
        };
        assert_eq!(pragma("journal_mode"), "wal");
        // FULL is also bundled SQLite's default, so this guards the build, not the pragma.
        assert_eq!(pragma("synchronous"), "2", "FULL");
        assert_eq!(pragma("foreign_keys"), "1");
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let host = load_or_create_host_id(&database).unwrap();
        drop(database);

        // Reopening migrates nothing away and keeps what was stored.
        let database = open(&path).unwrap();
        assert_eq!(load_or_create_host_id(&database).unwrap(), host);
        drop(database);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn new_sessions_are_numbered_within_their_workspace_and_open_with_pi_beside_a_terminal() {
        let database = &mut database();
        let workspace = new_uuid_v4().unwrap();
        super::insert_workspace(database, &workspace, "w", Path::new("/w"), None).unwrap();
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
        super::insert_workspace(database, &other, "A Project", Path::new("/p"), None).unwrap();
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
        super::insert_workspace(&database, &empty, "empty", Path::new("/e"), None).unwrap();
        super::insert_workspace(&database, &busy, "busy", Path::new("/b"), None).unwrap();
        super::insert_workspace(&database, &archived, "archived", Path::new("/a"), None).unwrap();
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

    #[test]
    fn a_stored_setting_replaces_the_previous_value() {
        let database = database();
        store_config_value(&database, ConfigKey::ShellCommand, "/bin/zsh").unwrap();
        store_config_value(&database, ConfigKey::ShellCommand, "/bin/bash").unwrap();
        let value: String = database
            .query_row(
                "SELECT value FROM daemon_metadata WHERE key = 'shell_command'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(value, "/bin/bash");
    }

    /// A version 8 catalog as Axo last wrote one: integer Session IDs, a `session_uuid` on
    /// Sessions launched with Pi.
    const VERSION_8_CATALOG: &str = "
        CREATE TABLE workspaces (
            workspace_id TEXT PRIMARY KEY, name TEXT NOT NULL, directory_path TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')), created_at INTEGER NOT NULL,
            archived_at INTEGER, directory_bookmark TEXT);
        CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            layout_json TEXT, workspace_id TEXT REFERENCES workspaces(workspace_id),
            session_uuid TEXT, name TEXT NOT NULL DEFAULT 'Session', pi_session_file TEXT,
            pi_session_id TEXT, emoji TEXT, manual_name TEXT, pi_bridge_socket_path TEXT,
            last_message_at INTEGER);
        CREATE TABLE shells (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id),
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            role TEXT NOT NULL DEFAULT 'terminal' CHECK (role IN ('pi', 'terminal')), pane_id TEXT);
        CREATE INDEX shells_by_session_state ON shells(session_id, state, id);
        CREATE INDEX sessions_by_workspace_state ON sessions(workspace_id, state, id);
        INSERT INTO workspaces VALUES ('w', 'W', '/w', 'open', 0, NULL, NULL);
        INSERT INTO sessions (id, initial_pwd, state, created_at, workspace_id, session_uuid, name,
                              pi_session_file, layout_json, manual_name)
            VALUES (3, '/w', 'open', 10, 'w', '0b8f4e2a-7c1d-4e6b-9a3f-5d2c8e1b7a49', 'Pi',
                    '/h.jsonl', '{\"kind\":\"leaf\"}', 'Mine');
        INSERT INTO sessions (id, initial_pwd, state, created_at, archived_at)
            VALUES (5, '/old', 'archived', 1, 2);
        INSERT INTO shells (id, session_id, initial_pwd, state, created_at, role)
            VALUES (40, 3, '/w', 'open', 10, 'pi');
        INSERT INTO shells (id, session_id, initial_pwd, state, created_at)
            VALUES (41, 5, '/old', 'archived', 1);
        INSERT INTO shells (id, session_id, initial_pwd, state, created_at)
            VALUES (60, 5, '/old', 'archived', 1);
        DELETE FROM shells WHERE id = 60;
        PRAGMA user_version = 8;";

    #[test]
    fn a_version_8_catalog_is_rekeyed_by_uuid_keeping_existing_uuids_and_shell_ids() {
        let mut database = Connection::open_in_memory().unwrap();
        database.pragma_update(None, "foreign_keys", "ON").unwrap();
        database.execute_batch(VERSION_8_CATALOG).unwrap();

        initialize_database(&mut database).unwrap();

        let rows: Vec<(String, String, Option<String>, Option<String>)> = database
            .prepare("SELECT id, initial_pwd, manual_name, layout_json FROM sessions ORDER BY created_at DESC")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0].0, "0b8f4e2a-7c1d-4e6b-9a3f-5d2c8e1b7a49",
            "its UUID is kept"
        );
        assert_eq!(rows[0].2.as_deref(), Some("Mine"));
        assert_eq!(rows[0].3.as_deref(), Some("{\"kind\":\"leaf\"}"));
        assert!(
            SessionId::parse(&rows[1].0).is_some(),
            "a new UUID: {}",
            rows[1].0
        );
        let shells: Vec<(i64, String)> = database
            .prepare("SELECT id, session_id FROM shells ORDER BY id")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(shells, [(40, rows[0].0.clone()), (41, rows[1].0.clone())]);
        let columns: Vec<String> = database
            .prepare("SELECT name FROM pragma_table_info('sessions')")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(!columns.iter().any(|column| column == "session_uuid"));
        let version: i64 = database
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, SCHEMA_VERSION);
        let violations: i64 = database
            .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(violations, 0);

        // A deleted shell's ID is not handed out again.
        let open = SessionId::parse(&rows[0].0).unwrap();
        let next = insert_terminal_shell(&database, open, Path::new("/w")).unwrap();
        assert_eq!(next.get(), 61);
        assert_eq!(read_open_sessions(&database).unwrap()[0].id, open);

        // Running it again changes nothing.
        initialize_database(&mut database).unwrap();
        let again: String = database
            .query_row("SELECT id FROM sessions WHERE created_at = 10", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(again, rows[0].0);
    }

    #[test]
    fn open_backs_up_a_catalog_before_rekeying_it_by_uuid() {
        let directory = std::env::temp_dir().join(format!(
            "axo-store-backup-{}-{}",
            std::process::id(),
            new_uuid_v4().unwrap()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join(DATABASE_FILE);
        Connection::open(&path)
            .unwrap()
            .execute_batch(VERSION_8_CATALOG)
            .unwrap();

        drop(open(&path).unwrap());
        let backup = pre_uuid_backup_path(&path);
        let old = Connection::open(&backup).unwrap();
        let (version, id): (i64, i64) = (
            old.query_row("PRAGMA user_version", [], |row| row.get(0))
                .unwrap(),
            old.query_row("SELECT MAX(id) FROM sessions", [], |row| row.get(0))
                .unwrap(),
        );
        assert_eq!((version, id), (8, 5));
        assert_eq!(
            std::fs::metadata(&backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(old);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
