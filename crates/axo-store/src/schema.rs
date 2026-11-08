//! Opening the catalog and its current schema. `open` is the only way the daemon gets a
//! connection: WAL, `synchronous=FULL`, foreign keys on, owner-only file, migrated to
//! [`SCHEMA_VERSION`].

use std::io;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use rusqlite::{Connection, params};

use crate::migrations::{
    back_up_before_uuid_rekey, create_integer_keyed_session_tables,
    ensure_integer_keyed_session_columns, ensure_session_layout_column, ensure_workspace_columns,
    rekey_sessions_by_uuid,
};
use crate::rows::unix_timestamp;

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
    #[cfg(unix)]
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
        CREATE TABLE IF NOT EXISTS relay_sync (
            session_id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            chain TEXT,
            metadata_json TEXT,
            metadata_version INTEGER NOT NULL DEFAULT 0,
            in_cloud INTEGER NOT NULL DEFAULT 0
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DATABASE_FILE;
    use crate::metadata::load_or_create_host_id;
    use axo_protocol::new_uuid_v4;

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
        #[cfg(unix)]
        {
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        let host = load_or_create_host_id(&database).unwrap();
        drop(database);

        // Reopening migrates nothing away and keeps what was stored.
        let database = open(&path).unwrap();
        assert_eq!(load_or_create_host_id(&database).unwrap(), host);
        drop(database);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
