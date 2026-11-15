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

const NATIVE_VIEWPORT_METADATA_KEY: &str = "client_viewport_native_v2";

pub fn load_viewport(database: &Connection) -> io::Result<Option<Viewport>> {
    let mut query = database
        .prepare(
            "SELECT key, value FROM daemon_metadata WHERE key IN (?1, ?2)
         ORDER BY CASE WHEN key = ?1 THEN 0 ELSE 1 END",
        )
        .map_err(io::Error::other)?;
    let rows = query
        .query_map(
            params![NATIVE_VIEWPORT_METADATA_KEY, VIEWPORT_METADATA_KEY],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .map_err(io::Error::other)?;
    for row in rows {
        let (key, value) = row.map_err(io::Error::other)?;
        match serde_json::from_str::<Viewport>(&value) {
            Ok(viewport) if key != NATIVE_VIEWPORT_METADATA_KEY || viewport.is_native() => {
                return Ok(Some(viewport));
            }
            _ => log::warn!("event=viewport.stored_invalid key={key}"),
        }
    }
    Ok(None)
}

pub fn store_viewport(database: &Connection, viewport: &Viewport) -> io::Result<()> {
    let legacy = serde_json::to_string(&viewport.legacy_projection()).map_err(io::Error::other)?;
    // Keep the strict legacy reader's key free of new fields. Both keys change atomically.
    let transaction = database.unchecked_transaction().map_err(io::Error::other)?;
    transaction
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![VIEWPORT_METADATA_KEY, legacy],
        )
        .map_err(io::Error::other)?;
    if viewport.is_native() {
        let value = serde_json::to_string(viewport).map_err(io::Error::other)?;
        transaction
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![NATIVE_VIEWPORT_METADATA_KEY, value],
            )
            .map_err(io::Error::other)?;
    } else {
        transaction
            .execute(
                "DELETE FROM daemon_metadata WHERE key = ?1",
                params![NATIVE_VIEWPORT_METADATA_KEY],
            )
            .map_err(io::Error::other)?;
    }
    transaction.commit().map_err(io::Error::other)?;
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
        ConfigKey::IdleMinutes => "sessions_idle_minutes",
        ConfigKey::IdleLimit => "sessions_idle_limit",
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
    fn native_viewports_preserve_the_legacy_key_and_legacy_reports_clear_native_state() {
        let database = database();
        let native = Viewport::from_native_metrics(
            axo_protocol::Size {
                width: 102.0,
                height: 100.0,
            },
            1.5,
            axo_protocol::PixelSize {
                width: 8,
                height: 18,
            },
            axo_protocol::Padding {
                top: 3,
                bottom: 3,
                left: 2,
                right: 2,
            },
            1.0,
            axo_protocol::ViewportOrigin::default(),
        )
        .unwrap();
        store_viewport(&database, &native).unwrap();
        assert_eq!(load_viewport(&database).unwrap(), Some(native));
        let raw: String = database
            .query_row(
                "SELECT value FROM daemon_metadata WHERE key = ?1",
                params![VIEWPORT_METADATA_KEY],
                |row| row.get(0),
            )
            .unwrap();
        let legacy: Viewport = serde_json::from_str(&raw).unwrap();
        assert_eq!(legacy, native.legacy_projection());
        assert!(
            serde_json::from_str::<serde_json::Value>(&raw)
                .unwrap()
                .get("rasterization")
                .is_none()
        );
        database
            .execute(
                "UPDATE daemon_metadata SET value = 'invalid' WHERE key = ?1",
                params![NATIVE_VIEWPORT_METADATA_KEY],
            )
            .unwrap();
        assert_eq!(
            load_viewport(&database).unwrap(),
            Some(legacy),
            "invalid native state degrades to legacy"
        );
        store_viewport(&database, &native).unwrap();
        store_viewport(&database, &legacy).unwrap();
        assert_eq!(load_viewport(&database).unwrap(), Some(legacy));
        let count: u32 = database
            .query_row(
                "SELECT count(*) FROM daemon_metadata WHERE key = ?1",
                params![NATIVE_VIEWPORT_METADATA_KEY],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0);
    }

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
