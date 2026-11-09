//! Agent-neutral catalog additions. The existing workspace/session tables remain authoritative;
//! backend thread IDs and displayed messages live here, rather than in Pi-specific columns.
use axo_protocol::SessionId;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::io;
use std::path::Path;

pub fn initialize(database: &Connection) -> io::Result<()> {
    database.execute_batch(
        "CREATE TABLE IF NOT EXISTS coding_agents (
            session_id TEXT PRIMARY KEY REFERENCES sessions(id),
            agent TEXT NOT NULL,
            thread_id TEXT
        );
        CREATE TABLE IF NOT EXISTS coding_messages (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            item_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
            text TEXT NOT NULL,
            created_at INTEGER NOT NULL,
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
    ).map_err(io::Error::other)
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
    database: &mut Connection,
    id: SessionId,
    workspace: &str,
    cwd: &Path,
    name: &str,
) -> io::Result<()> {
    let tx = database.transaction().map_err(io::Error::other)?;
    tx.execute(
        "INSERT INTO sessions(id, workspace_id, initial_pwd, name, state, created_at)
        VALUES (?1, ?2, ?3, ?4, 'open', ?5)",
        params![
            id.to_string(),
            workspace,
            cwd.to_string_lossy(),
            name,
            crate::unix_timestamp()
        ],
    )
    .map_err(io::Error::other)?;
    tx.execute(
        "INSERT INTO coding_agents(session_id, agent) VALUES (?1, 'codex')",
        params![id.to_string()],
    )
    .map_err(io::Error::other)?;
    tx.commit().map_err(io::Error::other)
}

pub fn thread_id(database: &Connection, id: SessionId) -> io::Result<Option<String>> {
    database
        .query_row(
            "SELECT thread_id FROM coding_agents WHERE session_id=?1 AND agent='codex'",
            params![id.to_string()],
            |r| r.get(0),
        )
        .map_err(io::Error::other)
}

pub fn set_thread_id(database: &Connection, id: SessionId, thread: &str) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE coding_agents SET thread_id=?2 WHERE session_id=?1",
            params![id.to_string(), thread],
        )
        .map_err(io::Error::other)?;
    crate::expect_one_row(changed, "coding agent session missing")
}

pub fn list_sessions(database: &Connection, archived: bool) -> io::Result<Vec<SessionId>> {
    let mut q = database.prepare("SELECT s.id FROM sessions s JOIN coding_agents c ON c.session_id=s.id
        WHERE s.state=?1 AND c.agent='codex' ORDER BY COALESCE(s.last_message_at,s.created_at) DESC, s.rowid DESC").map_err(io::Error::other)?;
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
    database
        .execute(
            "INSERT INTO coding_messages(session_id,item_id,role,text,created_at)
        VALUES (?1,?2,?3,?4,?5) ON CONFLICT(session_id,item_id) DO UPDATE SET text=excluded.text",
            params![id.to_string(), item_id, role, text, crate::unix_timestamp()],
        )
        .map_err(io::Error::other)?;
    crate::record_session_message(database, id, crate::unix_timestamp()).map(|_| ())
}

/// Read at most 200 messages, using a stable sequence cursor.
pub fn messages(database: &Connection, id: SessionId, after: i64) -> io::Result<Vec<Value>> {
    let mut q = database.prepare("SELECT sequence,role,text,created_at,item_id FROM coding_messages WHERE session_id=?1 AND sequence>?2 ORDER BY sequence LIMIT 200").map_err(io::Error::other)?;
    q.query_map(params![id.to_string(), after], |r| Ok(json!({"sequence":r.get::<_,i64>(0)?,"role":r.get::<_,String>(1)?,"text":r.get::<_,String>(2)?,"createdAt":r.get::<_,i64>(3)?,"itemId":r.get::<_,String>(4)?})))
        .map_err(io::Error::other)?.collect::<Result<Vec<_>,_>>().map_err(io::Error::other)
}

pub fn reopen(database: &Connection, id: SessionId) -> io::Result<()> {
    let changed = database.execute("UPDATE sessions SET state='open',archived_at=NULL,termination_reason=NULL
        WHERE id=?1 AND state='archived' AND id IN (SELECT session_id FROM coding_agents WHERE agent='codex')", params![id.to_string()]).map_err(io::Error::other)?;
    crate::expect_one_row(changed, "archived Codex session missing")
}

pub fn session_exists(database: &Connection, id: SessionId) -> io::Result<bool> {
    database.query_row("SELECT 1 FROM coding_agents c JOIN sessions s ON s.id=c.session_id WHERE c.session_id=?1 AND s.state='open'", params![id.to_string()], |_| Ok(true))
        .optional().map(|v| v.unwrap_or(false)).map_err(io::Error::other)
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
    let mut q = database.prepare("SELECT s.id,COALESCE(s.manual_name,s.name),s.emoji,s.workspace_id,w.name,s.created_at,s.last_message_at,s.state,s.initial_pwd
        FROM sessions s JOIN coding_agents c ON c.session_id=s.id LEFT JOIN workspaces w ON w.workspace_id=s.workspace_id
        WHERE c.agent='codex' ORDER BY s.rowid").map_err(io::Error::other)?;
    q.query_map([], |r| Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"emoji":r.get::<_,Option<String>>(2)?,
        "workspaceId":r.get::<_,Option<String>>(3)?,"workspaceName":r.get::<_,Option<String>>(4)?,"createdAt":r.get::<_,i64>(5)?,
        "lastMessageAt":r.get::<_,Option<i64>>(6)?,"archived":r.get::<_,String>(7)? == "archived","initialPwd":r.get::<_,String>(8)?})))
        .map_err(io::Error::other)?.collect::<Result<Vec<_>,_>>().map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_session_and_history_survive_archive_and_reopen_without_pi_columns() {
        let mut db = Connection::open_in_memory().unwrap();
        crate::initialize_database(&mut db).unwrap();
        initialize(&db).unwrap();
        let cwd = std::env::current_dir().unwrap();
        crate::insert_workspace(&db, "w", "Work", &cwd, None).unwrap();
        let id = SessionId::new_v4().unwrap();
        insert_session(&mut db, id, "w", &cwd, "Codex 1").unwrap();
        set_thread_id(&db, id, "thread-1").unwrap();
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
