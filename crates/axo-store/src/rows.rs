//! Values every table shares: parsed IDs and lifecycle states, timestamps, and the
//! "exactly one row changed" check that turns a missed write into `NotFound`.

use std::io;

use axo_protocol::{SessionId, ShellId};
use rusqlite::Connection;

/// The `state` column of a Session or shell row. Parsed when read, so a corrupt or
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

pub(crate) fn not_found(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, message)
}

/// Fails with `NotFound(message)` unless exactly one row changed.
pub(crate) fn expect_one_row(changed: usize, message: &'static str) -> io::Result<()> {
    if changed == 1 {
        Ok(())
    } else {
        Err(not_found(message))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

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
}
