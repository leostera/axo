//! Fixtures shared by the module tests: an in-memory catalog and raw row inserts.

use std::io;

use axo_protocol::SessionId;
use rusqlite::{Connection, params};

use crate::schema::initialize_database;

pub(crate) fn database() -> Connection {
    let mut database = Connection::open_in_memory().unwrap();
    initialize_database(&mut database).unwrap();
    database
}

pub(crate) fn insert_session(database: &Connection, state: &str) -> SessionId {
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

pub(crate) fn insert_workspace_row(database: &Connection, id: &str, name: &str, state: &str) {
    database
        .execute(
            "INSERT INTO workspaces (workspace_id, name, directory_path, state, created_at)
             VALUES (?1, ?2, ?3, ?4, 0)",
            params![id, name, format!("/work/{name}"), state],
        )
        .unwrap();
}

pub(crate) fn kind<T: std::fmt::Debug>(result: io::Result<T>) -> io::ErrorKind {
    result.unwrap_err().kind()
}

pub(crate) fn lifecycle(database: &Connection, table: &str, column: &str, id: &str) -> String {
    database
        .query_row(
            &format!("SELECT state FROM {table} WHERE {column} = ?1"),
            params![id],
            |row| row.get(0),
        )
        .unwrap()
}
