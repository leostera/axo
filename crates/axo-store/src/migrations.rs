//! Bringing older catalogs up to the current schema: columns added since the first release,
//! the Workspace cutover (version 4), and rekeying Sessions by UUID (version 9, RFD0017).

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use axo_protocol::SessionId;
use rusqlite::{Connection, OptionalExtension, params};

use crate::schema::SCHEMA_VERSION;

/// Where `open` keeps a copy of a catalog before rekeying it by UUID, next to the catalog.
pub fn pre_uuid_backup_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".pre-uuid");
    path.with_file_name(name)
}

/// Copies a catalog that is about to be rekeyed by UUID, once: an existing copy is kept.
pub(crate) fn back_up_before_uuid_rekey(
    database: &Connection,
    path: &Path,
) -> rusqlite::Result<()> {
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
    #[cfg(unix)]
    std::fs::set_permissions(&backup, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    log::info!(
        "event=catalog.backup reason=uuid_rekey path={}",
        backup.display()
    );
    Ok(())
}

/// Sessions and shells as they were before version 9, for catalogs older than shells.
pub(crate) fn create_integer_keyed_session_tables(
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
pub(crate) fn ensure_integer_keyed_session_columns(
    transaction: &rusqlite::Transaction<'_>,
) -> rusqlite::Result<()> {
    add_missing_columns(transaction, &[("sessions", "session_uuid", "TEXT")])
}

/// Rekeys Sessions by UUID (RFD0017), in the caller's transaction. A Session that already has a
/// `session_uuid` keeps it as its ID, so its Pi transcript, bridge socket and token still match;
/// one without gets a new random UUID. Shells follow their Session; shell IDs do not change.
pub(crate) fn rekey_sessions_by_uuid(
    transaction: &rusqlite::Transaction<'_>,
) -> rusqlite::Result<()> {
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
        ("relay_sync", "in_cloud", "INTEGER NOT NULL DEFAULT 0"),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DATABASE_FILE;
    use crate::schema::{initialize_database, open};
    use crate::sessions::read_open_sessions;
    use crate::shells::insert_terminal_shell;
    use axo_protocol::new_uuid_v4;

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
        #[cfg(unix)]
        assert_eq!(
            std::fs::metadata(&backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(old);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
