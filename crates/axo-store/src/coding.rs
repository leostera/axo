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
        CREATE INDEX IF NOT EXISTS coding_messages_by_session ON coding_messages(session_id, sequence);"
    ).map_err(io::Error::other)
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
