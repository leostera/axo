//! `relay_sync`: what the cloud acknowledged of each Session's transcript and metadata
//! (RFD0018), and whether an archived transcript now lives only in the cloud (RFD0027).

use std::io;

use axo_protocol::SessionId;
use rusqlite::{Connection, OptionalExtension, params};

use crate::rows::stored_session_id;

/// What the cloud acknowledged of one Session's transcript, and the metadata last sent to it with
/// its version (RFD0018, Upload). The cloud's answer to a handshake always wins over these.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredSyncState {
    pub session_id: SessionId,
    pub position: u64,
    pub chain: Option<String>,
    pub metadata_json: Option<String>,
    pub metadata_version: u64,
    /// The transcript was deleted here: the cloud holds it whole, at `position` and `chain`
    /// (RFD0027).
    pub in_cloud: bool,
}

pub fn load_sync_states(database: &Connection) -> io::Result<Vec<StoredSyncState>> {
    let mut statement = database
        .prepare(
            "SELECT session_id, position, chain, metadata_json, metadata_version, in_cloud FROM relay_sync",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map([], |row| {
            Ok(StoredSyncState {
                session_id: stored_session_id(row.get(0)?)?,
                position: stored_count(row.get(1)?)?,
                chain: row.get(2)?,
                metadata_json: row.get(3)?,
                metadata_version: stored_count(row.get(4)?)?,
                in_cloud: row.get(5)?,
            })
        })
        .map_err(io::Error::other)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(io::Error::other)
}

pub fn store_sync_cursor(
    database: &Connection,
    session_id: SessionId,
    position: u64,
    chain: &str,
) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO relay_sync (session_id, position, chain) VALUES (?1, ?2, ?3) \
             ON CONFLICT(session_id) DO UPDATE SET position = excluded.position, chain = excluded.chain",
            params![session_id.to_string(), count_to_store(position)?, chain],
        )
        .map(drop)
        .map_err(io::Error::other)
}

pub fn store_sync_metadata(
    database: &Connection,
    session_id: SessionId,
    metadata_json: &str,
    version: u64,
) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO relay_sync (session_id, metadata_json, metadata_version) VALUES (?1, ?2, ?3) \
             ON CONFLICT(session_id) DO UPDATE SET metadata_json = excluded.metadata_json, \
             metadata_version = excluded.metadata_version",
            params![session_id.to_string(), metadata_json, count_to_store(version)?],
        )
        .map(drop)
        .map_err(io::Error::other)
}

/// Records that an archived Session's transcript is in the cloud, before it is deleted here
/// (RFD0027). Only a Session still archived whose acknowledged cursor is `position` and `chain`
/// qualifies; returns whether it did.
pub fn mark_transcript_in_cloud(
    database: &Connection,
    session_id: SessionId,
    position: u64,
    chain: &str,
) -> io::Result<bool> {
    database
        .execute(
            "UPDATE relay_sync SET in_cloud = 1 WHERE session_id = ?1 AND position = ?2 \
             AND chain = ?3 AND position > 0 \
             AND EXISTS (SELECT 1 FROM sessions WHERE id = ?1 AND state = 'archived')",
            params![session_id.to_string(), count_to_store(position)?, chain],
        )
        .map(|changed| changed == 1)
        .map_err(io::Error::other)
}

/// A Session's transcript as the catalog knows it (RFD0027).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredTranscript {
    pub session_id: SessionId,
    pub pi_session_file: Option<String>,
    pub archived: bool,
    pub in_cloud: bool,
    /// What the cloud acknowledged: its record count and the chain there.
    pub position: u64,
    pub chain: Option<String>,
}

/// Which Session's transcript to look up.
#[derive(Clone, Copy, Debug)]
pub enum TranscriptOf<'a> {
    Session(SessionId),
    /// The Session whose Pi file this is.
    File(&'a str),
}

pub fn load_transcript(
    database: &Connection,
    of: TranscriptOf<'_>,
) -> io::Result<Option<StoredTranscript>> {
    let (session_id, pi_session_file) = match of {
        TranscriptOf::Session(id) => (Some(id.to_string()), None),
        TranscriptOf::File(file) => (None, Some(file)),
    };
    database
        .query_row(
            "SELECT s.id, s.pi_session_file, s.state = 'archived', \
             COALESCE(r.in_cloud, 0), COALESCE(r.position, 0), r.chain \
             FROM sessions s LEFT JOIN relay_sync r ON r.session_id = s.id \
             WHERE s.id = ?1 OR (?1 IS NULL AND s.pi_session_file = ?2) LIMIT 1",
            params![session_id, pi_session_file],
            |row| {
                Ok(StoredTranscript {
                    session_id: stored_session_id(row.get(0)?)?,
                    pi_session_file: row.get(1)?,
                    archived: row.get(2)?,
                    in_cloud: row.get(3)?,
                    position: stored_count(row.get(4)?)?,
                    chain: row.get(5)?,
                })
            },
        )
        .optional()
        .map_err(io::Error::other)
}

/// The transcript is back on disk, as the cloud holds it.
pub fn clear_transcript_in_cloud(database: &Connection, session_id: SessionId) -> io::Result<()> {
    database
        .execute(
            "UPDATE relay_sync SET in_cloud = 0 WHERE session_id = ?1",
            params![session_id.to_string()],
        )
        .map(drop)
        .map_err(io::Error::other)
}

/// A record count or version as stored: never negative unless the database is corrupt, and
/// reading one that is fails instead of reading as zero.
fn stored_count(value: i64) -> rusqlite::Result<u64> {
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(0, value))
}

/// A count to store: SQLite integers are signed.
fn count_to_store(value: u64) -> io::Result<i64> {
    i64::try_from(value)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "count is too large"))
}

/// Raises the handshake round and returns it: every handshake has a higher one than the last,
/// across sockets and restarts.
pub fn next_sync_round(database: &Connection) -> io::Result<u64> {
    database
        .query_row(
            "INSERT INTO daemon_metadata (key, value) VALUES ('relay_sync_round', '1') \
             ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) \
             RETURNING CAST(value AS INTEGER)",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map(|round| round.max(1) as u64)
        .map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::database;

    #[test]
    fn only_an_archived_session_at_its_acknowledged_cursor_is_marked_in_the_cloud() {
        let database = database();
        let id = SessionId::parse("8f8f8f8f-0000-4000-8000-000000000001").unwrap();
        database
            .execute(
                "INSERT INTO sessions (id, initial_pwd, state, created_at) VALUES (?1, '/tmp', 'open', 1)",
                params![id.to_string()],
            )
            .unwrap();
        store_sync_cursor(&database, id, 3, "chain-3").unwrap();
        assert!(
            !mark_transcript_in_cloud(&database, id, 3, "chain-3").unwrap(),
            "open"
        );
        database
            .execute(
                "UPDATE sessions SET state = 'archived' WHERE id = ?1",
                params![id.to_string()],
            )
            .unwrap();
        assert!(
            !mark_transcript_in_cloud(&database, id, 4, "chain-3").unwrap(),
            "not acknowledged"
        );
        assert!(
            !mark_transcript_in_cloud(&database, id, 3, "chain-x").unwrap(),
            "another chain"
        );
        assert!(mark_transcript_in_cloud(&database, id, 3, "chain-3").unwrap());
        assert!(load_sync_states(&database).unwrap()[0].in_cloud);
        clear_transcript_in_cloud(&database, id).unwrap();
        assert!(!load_sync_states(&database).unwrap()[0].in_cloud);
        let transcript = load_transcript(&database, TranscriptOf::Session(id))
            .unwrap()
            .unwrap();
        assert_eq!((transcript.session_id, transcript.position), (id, 3));
    }

    #[test]
    fn a_corrupt_cursor_fails_to_read_instead_of_reading_as_zero() {
        let database = database();
        database
            .execute(
                "INSERT INTO relay_sync (session_id, position, chain) VALUES ('8f8f8f8f-0000-4000-8000-000000000001', -1, 'c')",
                [],
            )
            .unwrap();
        assert!(load_sync_states(&database).is_err());
        database
            .execute(
                "UPDATE relay_sync SET position = 1, session_id = 'not-a-uuid'",
                [],
            )
            .unwrap();
        assert!(load_sync_states(&database).is_err());
    }
}
