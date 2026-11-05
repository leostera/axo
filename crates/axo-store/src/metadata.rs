//! `daemon_metadata`: the key-value table behind settings, the host identity and the last
//! client viewport.

use std::io;

use axo_protocol::{ConfigKey, Viewport, is_uuid, new_uuid_v4};
use rusqlite::{Connection, OptionalExtension, params};

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

/// What the last Axod to stop left for the next one (see `axo-server`'s `stop_notice`).
pub const DAEMON_STOP_METADATA_KEY: &str = "daemon_stop";

/// Replaces the record of how the last Axod stopped.
pub fn store_daemon_stop(database: &Connection, value: &str) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![DAEMON_STOP_METADATA_KEY, value],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

/// Reads and removes the record of how the last Axod stopped, so it is acted on once.
pub fn take_daemon_stop(database: &Connection) -> io::Result<Option<String>> {
    let value = database
        .query_row(
            "DELETE FROM daemon_metadata WHERE key = ?1 RETURNING value",
            params![DAEMON_STOP_METADATA_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    Ok(value)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::database;

    #[test]
    fn the_daemon_stop_record_is_taken_once() {
        let database = database();
        assert_eq!(take_daemon_stop(&database).unwrap(), None);
        store_daemon_stop(&database, "first").unwrap();
        store_daemon_stop(&database, "second").unwrap();
        assert_eq!(
            take_daemon_stop(&database).unwrap().as_deref(),
            Some("second")
        );
        assert_eq!(take_daemon_stop(&database).unwrap(), None);
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
}
