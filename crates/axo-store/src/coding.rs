//! Windows conversation presentation and durable commands. Session folders, agent kinds and
//! conversation identities use the shared catalog; only messages and controls need adjunct tables.
use axo_protocol::SessionId;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::io;
use std::path::Path;

pub fn initialize(database: &Connection) -> io::Result<()> {
    database.execute_batch(
        "CREATE TABLE IF NOT EXISTS coding_messages (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            item_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
            text TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            command_id TEXT,
            UNIQUE(session_id, item_id)
        );
        CREATE INDEX IF NOT EXISTS coding_messages_by_session ON coding_messages(session_id, sequence);
        CREATE TABLE IF NOT EXISTS coding_commands (
            session_id TEXT NOT NULL REFERENCES sessions(id),
            command_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('pending','submitted')),
            PRIMARY KEY(session_id,command_id)
        );
        CREATE TABLE IF NOT EXISTS coding_preferences (session_id TEXT PRIMARY KEY REFERENCES sessions(id), value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS coding_outbox (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            command_id TEXT NOT NULL,
            payload TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'queued',
            error TEXT,
            UNIQUE(session_id, command_id)
        );"
    ).map_err(io::Error::other)?;
    let has_receipt: bool = database.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info('coding_messages') WHERE name='command_id')",
        [], |row| row.get(0),
    ).map_err(io::Error::other)?;
    if !has_receipt {
        database
            .execute_batch("ALTER TABLE coding_messages ADD COLUMN command_id TEXT")
            .map_err(io::Error::other)?;
    }
    database
        .execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS coding_message_command
        ON coding_messages(session_id,command_id) WHERE command_id IS NOT NULL",
        )
        .map_err(io::Error::other)?;
    Ok(())
}

pub fn preferences(db: &Connection, id: SessionId) -> io::Result<Value> {
    let text: Option<String> = db
        .query_row(
            "SELECT value FROM coding_preferences WHERE session_id=?1",
            [id.to_string()],
            |r| r.get(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    text.map(|s| serde_json::from_str(&s).map_err(io::Error::other))
        .unwrap_or_else(|| Ok(json!({})))
}
pub fn terminal_ids(db: &Connection, id: SessionId) -> io::Result<Vec<axo_protocol::ShellId>> {
    let mut q = db
        .prepare("SELECT id FROM shells WHERE session_id=?1 AND state='open' ORDER BY id LIMIT 16")
        .map_err(io::Error::other)?;
    q.query_map([id.to_string()], |r| crate::stored_shell_id(r.get(0)?))
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}
pub fn save_preferences(db: &Connection, id: SessionId, value: &Value) -> io::Result<()> {
    db.execute("INSERT INTO coding_preferences(session_id,value) VALUES (?1,?2) ON CONFLICT(session_id) DO UPDATE SET value=excluded.value", params![id.to_string(), value.to_string()]).map_err(io::Error::other)?;
    Ok(())
}
pub fn enqueue(
    db: &Connection,
    id: SessionId,
    command: &str,
    payload: &Value,
    priority: bool,
) -> io::Result<()> {
    let count: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM coding_outbox WHERE session_id=?1 AND state='queued'",
            [id.to_string()],
            |r| r.get(0),
        )
        .map_err(io::Error::other)?;
    if count >= 32 {
        return Err(io::Error::other(
            "The session already has 32 queued messages",
        ));
    }
    db.execute(
        "INSERT INTO coding_outbox(session_id,command_id,payload,priority) VALUES (?1,?2,?3,?4)",
        params![id.to_string(), command, payload.to_string(), priority],
    )
    .map_err(io::Error::other)?;
    Ok(())
}
pub fn queued(db: &Connection, id: SessionId) -> io::Result<Vec<Value>> {
    let mut q = db.prepare("SELECT command_id,payload,state,error FROM coding_outbox WHERE session_id=?1 AND state NOT IN ('delivered','cancelled') ORDER BY priority DESC,sequence").map_err(io::Error::other)?;
    let rows = q
        .query_map([id.to_string()], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
            ))
        })
        .map_err(io::Error::other)?;
    rows.map(|row| { let (command,payload,state,error) = row.map_err(io::Error::other)?; Ok(json!({"commandId":command,"prompt":serde_json::from_str::<Value>(&payload)?,"state":state,"error":error})) }).collect()
}
pub fn outbox_state(
    db: &Connection,
    id: SessionId,
    command: &str,
    state: &str,
    error: Option<&str>,
) -> io::Result<()> {
    let changed = db
        .execute(
            "UPDATE coding_outbox SET state=?3,error=?4 WHERE session_id=?1 AND command_id=?2",
            params![id.to_string(), command, state, error],
        )
        .map_err(io::Error::other)?;
    crate::expect_one_row(changed, "Queued message missing")
}

pub fn insert_session(
    database: &Connection,
    id: SessionId,
    cwd: &Path,
    name: &str,
    manual_name: Option<&axo_protocol::rpc::SessionName>,
) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO sessions(id, initial_pwd, name, manual_name, agent, state, created_at)
         VALUES (?1, ?2, ?3, ?4, 'codex', 'open', ?5)",
            params![
                id.to_string(),
                cwd.to_string_lossy(),
                name,
                manual_name.map(|name| name.as_str()),
                crate::unix_timestamp()
            ],
        )
        .map(|_| ())
        .map_err(io::Error::other)
}

pub fn thread_id(database: &Connection, id: SessionId) -> io::Result<Option<String>> {
    database
        .query_row(
            "SELECT agent_conversation FROM sessions WHERE id=?1 AND agent='codex'",
            params![id.to_string()],
            |r| r.get(0),
        )
        .map_err(io::Error::other)
}

pub fn set_thread_id(database: &Connection, id: SessionId, thread: &str) -> io::Result<()> {
    crate::bind_agent_conversation(database, id, thread)
}

pub fn list_sessions(database: &Connection, archived: bool) -> io::Result<Vec<SessionId>> {
    let mut q = database.prepare("SELECT id FROM sessions
        WHERE state=?1 AND agent='codex' ORDER BY COALESCE(last_message_at,created_at) DESC, rowid DESC").map_err(io::Error::other)?;
    q.query_map(params![if archived { "archived" } else { "open" }], |r| {
        crate::stored_session_id(r.get(0)?)
    })
    .map_err(io::Error::other)?
    .collect::<Result<Vec<_>, _>>()
    .map_err(io::Error::other)
}

pub fn save_message(
    database: &Connection,
    id: SessionId,
    item_id: &str,
    role: &str,
    text: &str,
) -> io::Result<()> {
    save_message_with_command(database, id, item_id, role, text, None).map(|_| ())
}

/// Records an immutable client-command association on first insertion only. Duplicate native
/// notifications update text but must not consume or steal the next prompt's receipt.
pub fn save_message_with_command(
    database: &Connection,
    id: SessionId,
    item_id: &str,
    role: &str,
    text: &str,
    command_id: Option<&str>,
) -> io::Result<bool> {
    if role != "user" && command_id.is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Only user messages carry prompt receipts",
        ));
    }
    let existed: bool = database
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM coding_messages WHERE session_id=?1 AND item_id=?2)",
            params![id.to_string(), item_id],
            |row| row.get(0),
        )
        .map_err(io::Error::other)?;
    database.execute(
        "INSERT INTO coding_messages(session_id,item_id,role,text,created_at,command_id)
         VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(session_id,item_id) DO UPDATE SET text=excluded.text",
        params![id.to_string(), item_id, role, text, crate::unix_timestamp(), if existed { None } else { command_id }],
    ).map_err(io::Error::other)?;
    crate::record_session_message(database, id, crate::unix_timestamp())?;
    Ok(!existed)
}

/// Read at most 200 messages, using a stable sequence cursor.
pub fn messages(database: &Connection, id: SessionId, after: i64) -> io::Result<Vec<Value>> {
    let mut q = database.prepare("SELECT sequence,role,text,created_at,item_id,command_id FROM coding_messages WHERE session_id=?1 AND sequence>?2 ORDER BY sequence LIMIT 200").map_err(io::Error::other)?;
    q.query_map(params![id.to_string(), after], |r| Ok(json!({"sequence":r.get::<_,i64>(0)?,"role":r.get::<_,String>(1)?,"text":r.get::<_,String>(2)?,"createdAt":r.get::<_,i64>(3)?,"itemId":r.get::<_,String>(4)?,"commandId":r.get::<_,Option<String>>(5)?})))
        .map_err(io::Error::other)?.collect::<Result<Vec<_>,_>>().map_err(io::Error::other)
}

pub fn reopen(database: &Connection, id: SessionId) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE sessions SET state='open',archived_at=NULL,termination_reason=NULL
        WHERE id=?1 AND state='archived' AND agent='codex'",
            params![id.to_string()],
        )
        .map_err(io::Error::other)?;
    crate::expect_one_row(changed, "archived Codex session missing")
}

pub fn session_exists(database: &Connection, id: SessionId) -> io::Result<bool> {
    database
        .query_row(
            "SELECT 1 FROM sessions WHERE id=?1 AND state='open' AND agent='codex'",
            params![id.to_string()],
            |_| Ok(true),
        )
        .optional()
        .map(|v| v.unwrap_or(false))
        .map_err(io::Error::other)
}

/// A durable receipt is reserved before talking to Codex, so retrying an unconfirmed
/// network command can never silently start the same work twice.
pub fn command_state(
    database: &Connection,
    id: SessionId,
    command: &str,
) -> io::Result<Option<String>> {
    database
        .query_row(
            "SELECT state FROM coding_commands WHERE session_id=?1 AND command_id=?2",
            params![id.to_string(), command],
            |r| r.get(0),
        )
        .optional()
        .map_err(io::Error::other)
}
pub fn reserve_command(database: &Connection, id: SessionId, command: &str) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO coding_commands(session_id,command_id,state) VALUES (?1,?2,'pending')",
            params![id.to_string(), command],
        )
        .map(|_| ())
        .map_err(io::Error::other)
}
pub fn submit_command(database: &Connection, id: SessionId, command: &str) -> io::Result<()> {
    database
        .execute(
            "UPDATE coding_commands SET state='submitted' WHERE session_id=?1 AND command_id=?2",
            params![id.to_string(), command],
        )
        .map(|_| ())
        .map_err(io::Error::other)
}

/// Includes archived sessions for the relay uploader; never mixes Pi-owned sessions.
pub fn catalog(database: &Connection) -> io::Result<Vec<Value>> {
    let mut q = database.prepare("SELECT id,COALESCE(manual_name,name),emoji,created_at,last_message_at,state,initial_pwd
        FROM sessions WHERE agent='codex' ORDER BY rowid").map_err(io::Error::other)?;
    q.query_map([], |r| Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"emoji":r.get::<_,Option<String>>(2)?,
        "createdAt":r.get::<_,i64>(3)?,"lastMessageAt":r.get::<_,Option<i64>>(4)?,
        "archived":r.get::<_,String>(5)? == "archived","folder":r.get::<_,String>(6)?})))
        .map_err(io::Error::other)?.collect::<Result<Vec<_>,_>>().map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_receipts_survive_updates_and_legacy_catalog_upgrade() {
        let mut db = Connection::open_in_memory().unwrap();
        crate::initialize_database(&mut db).unwrap();
        db.execute_batch(
            "CREATE TABLE coding_messages (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
            item_id TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
            created_at INTEGER NOT NULL, UNIQUE(session_id,item_id))",
        )
        .unwrap();
        initialize(&db).unwrap();
        initialize(&db).unwrap();
        let id = SessionId::new_v4().unwrap();
        insert_session(
            &db,
            id,
            &std::env::current_dir().unwrap(),
            "Receipt fixture",
            None,
        )
        .unwrap();
        assert!(
            save_message_with_command(&db, id, "u1", "user", "same", Some("command-1")).unwrap()
        );
        assert!(
            !save_message_with_command(&db, id, "u1", "user", "same", Some("command-2")).unwrap()
        );
        assert!(
            save_message_with_command(&db, id, "u2", "user", "same", Some("command-2")).unwrap()
        );
        let rows = messages(&db, id, 0).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["commandId"], "command-1");
        assert_eq!(rows[1]["commandId"], "command-2");
        assert!(
            !save_message_with_command(&db, id, "u1", "user", "same", Some("command-2")).unwrap()
        );
        assert_eq!(messages(&db, id, 0).unwrap()[0]["commandId"], "command-1");
        assert!(
            save_message_with_command(&db, id, "u3", "user", "same", Some("command-2")).is_err()
        );
    }
    #[test]
    fn codex_session_and_history_survive_archive_and_reopen_without_pi_columns() {
        let mut db = Connection::open_in_memory().unwrap();
        crate::initialize_database(&mut db).unwrap();
        initialize(&db).unwrap();
        let cwd = std::env::current_dir().unwrap();
        let id = SessionId::new_v4().unwrap();
        insert_session(&db, id, &cwd, "Codex 1", None).unwrap();
        assert_eq!(
            crate::open_session_agent(&db, id).unwrap(),
            (axo_agent::AgentKind::Codex, None)
        );
        set_thread_id(&db, id, "thread-1").unwrap();
        assert!(
            set_thread_id(&db, id, "another-thread").is_err(),
            "A Session cannot change conversation identity"
        );
        assert_eq!(
            catalog(&db).unwrap()[0]["folder"],
            cwd.to_string_lossy().as_ref()
        );
        save_message(&db, id, "m1", "user", "hello").unwrap();
        save_message(&db, id, "m1", "user", "hello again").unwrap();
        assert_eq!(messages(&db, id, 0).unwrap().len(), 1);
        assert_eq!(messages(&db, id, 0).unwrap()[0]["text"], "hello again");
        crate::archive_session(&mut db, id, "user_closed").unwrap();
        assert!(list_sessions(&db, false).unwrap().is_empty());
        reopen(&db, id).unwrap();
        assert_eq!(thread_id(&db, id).unwrap().as_deref(), Some("thread-1"));
        assert_eq!(list_sessions(&db, false).unwrap(), vec![id]);
    }
}
