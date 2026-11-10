//! What the catalog records about each Session's Pi: its history file, bridge socket and
//! bridge credential.

use std::io;
use std::path::{Path, PathBuf};

use axo_agent::pi::BridgeSocketPath;
use axo_protocol::{SessionId, is_uuid};
use rusqlite::{Connection, OptionalExtension, params};

use crate::rows::{StoredLifecycle, stored_session_id};

pub fn ensure_pi_bridge_socket_paths(
    database: &Connection,
    pi_session_directory: &Path,
) -> io::Result<()> {
    let records = {
        let mut statement = database
            .prepare(
                "SELECT id, pi_bridge_socket_path FROM sessions WHERE pi_session_file IS NOT NULL",
            )
            .map_err(io::Error::other)?;
        statement
            .query_map([], |row| {
                Ok((
                    stored_session_id(row.get::<_, String>(0)?)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };

    for (session_id, stored_path) in records {
        match stored_path {
            Some(path) => {
                BridgeSocketPath::parse(PathBuf::from(path)).map_err(|error| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("stored Pi bridge socket path for session {session_id} is invalid: {error}"),
                    )
                })?;
            }
            None => {
                let socket_path =
                    BridgeSocketPath::for_session(pi_session_directory, &session_id.to_string())?;
                let changed = database
                    .execute(
                        "UPDATE sessions SET pi_bridge_socket_path = ?1
                         WHERE id = ?2 AND pi_bridge_socket_path IS NULL",
                        params![socket_path.as_str(), session_id.to_string()],
                    )
                    .map_err(io::Error::other)?;
                if changed != 1 {
                    return Err(io::Error::other(
                        "could not persist the Pi bridge socket address",
                    ));
                }
            }
        }
    }
    Ok(())
}

/// Points every Session whose Pi transcript is under `from` at the same file under `to`, after
/// the folder was moved (RFD0022). Returns how many Sessions moved.
pub fn relocate_pi_session_files(
    database: &Connection,
    from: &Path,
    to: &Path,
) -> io::Result<usize> {
    let (Some(from), Some(to)) = (from.to_str(), to.to_str()) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "transcript folders must be UTF-8",
        ));
    };
    let prefix = format!("{from}/");
    database
        .execute(
            "UPDATE sessions SET pi_session_file = ?2 || substr(pi_session_file, length(?1) + 1)
             WHERE substr(pi_session_file, 1, length(?3)) = ?3",
            params![from, to, prefix],
        )
        .map_err(io::Error::other)
}

pub fn pi_bridge_token_key(session_id: SessionId) -> String {
    format!("pi_bridge_token:{session_id}")
}

pub fn load_pi_bridge_token(
    database: &Connection,
    session_id: SessionId,
) -> io::Result<Option<String>> {
    let token = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![pi_bridge_token_key(session_id)],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    if token.as_ref().is_some_and(|token| !is_uuid(token)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi bridge credential is invalid",
        ));
    }
    Ok(token)
}

pub fn store_pi_bridge_token(
    database: &Connection,
    session_id: SessionId,
    token: &str,
) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![pi_bridge_token_key(session_id), token],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

pub fn pi_process_key(session_id: SessionId) -> String {
    format!("pi_process:{session_id}")
}

/// The Pi process axod last started for a Session, as `pid:started` (RFD0041): a later axod
/// kills it if it still holds the transcript, and only if it is that same process.
pub fn load_pi_process(database: &Connection, session_id: SessionId) -> io::Result<Option<String>> {
    database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![pi_process_key(session_id)],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)
}

/// Records the Session's Pi process, or forgets it with `None`.
pub fn store_pi_process(
    database: &Connection,
    session_id: SessionId,
    process: Option<&str>,
) -> io::Result<()> {
    match process {
        Some(process) => database.execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![pi_process_key(session_id), process],
        ),
        None => database.execute(
            "DELETE FROM daemon_metadata WHERE key = ?1",
            params![pi_process_key(session_id)],
        ),
    }
    .map_err(io::Error::other)?;
    Ok(())
}

/// A Session whose Pi transcript is a given history file.
#[derive(Debug)]
pub struct PiHistoryOwner {
    pub session_id: SessionId,
    pub lifecycle: StoredLifecycle,
    pub initial_pwd: PathBuf,
}

/// Every Session, open or archived, whose Pi history is `session_file`. More than one means
/// the catalog is inconsistent; callers require exactly one.
pub fn pi_history_owners(
    database: &Connection,
    session_file: &str,
) -> io::Result<Vec<PiHistoryOwner>> {
    let mut statement = database
        .prepare("SELECT id, state, initial_pwd FROM sessions WHERE pi_session_file = ?1")
        .map_err(io::Error::other)?;
    statement
        .query_map(params![session_file], |row| {
            Ok(PiHistoryOwner {
                session_id: stored_session_id(row.get::<_, String>(0)?)?,
                lifecycle: row.get(1)?,
                initial_pwd: PathBuf::from(row.get::<_, String>(2)?),
            })
        })
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

/// What an open Session stores about its Pi.
pub struct StoredPiSession {
    pub session_file: Option<PathBuf>,
    pub bridge_socket_path: Option<String>,
    /// Whether Pi ever completed a message, and so wrote its history.
    pub has_messages: bool,
}

pub fn open_pi_session(database: &Connection, id: SessionId) -> io::Result<StoredPiSession> {
    database
        .query_row(
            "SELECT pi_session_file, pi_bridge_socket_path, last_message_at IS NOT NULL
             FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.to_string()],
            |row| {
                Ok(StoredPiSession {
                    session_file: row.get::<_, Option<String>>(0)?.map(PathBuf::from),
                    bridge_socket_path: row.get(1)?,
                    has_messages: row.get(2)?,
                })
            },
        )
        .map_err(io::Error::other)
}

/// Every Session that records a Pi bridge socket: its ID, history file and socket path.
pub fn pi_bridge_sockets(database: &Connection) -> io::Result<Vec<(SessionId, PathBuf, PathBuf)>> {
    let mut statement = database
        .prepare(
            "SELECT id, pi_session_file, pi_bridge_socket_path FROM sessions
             WHERE pi_session_file IS NOT NULL AND pi_bridge_socket_path IS NOT NULL",
        )
        .map_err(io::Error::other)?;
    statement
        .query_map([], |row| {
            Ok((
                stored_session_id(row.get::<_, String>(0)?)?,
                PathBuf::from(row.get::<_, String>(1)?),
                PathBuf::from(row.get::<_, String>(2)?),
            ))
        })
        .map_err(io::Error::other)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{database, insert_session};

    #[test]
    fn a_pi_bridge_token_is_kept_per_session_and_replaced_whole() {
        let database = database();
        let (session, other) = (SessionId::from_u128(1), SessionId::from_u128(2));
        assert_eq!(load_pi_bridge_token(&database, session).unwrap(), None);
        let (first, second) = (
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
        );
        store_pi_bridge_token(&database, session, first).unwrap();
        store_pi_bridge_token(&database, session, second).unwrap();
        assert_eq!(
            load_pi_bridge_token(&database, session).unwrap().as_deref(),
            Some(second)
        );
        assert_eq!(load_pi_bridge_token(&database, other).unwrap(), None);
        store_pi_bridge_token(&database, other, "not a token").unwrap();
        assert_eq!(
            load_pi_bridge_token(&database, other).unwrap_err().kind(),
            io::ErrorKind::InvalidData,
            "a damaged credential is refused, not used"
        );
    }

    #[test]
    fn moved_transcripts_are_found_at_their_new_place() {
        let database = database();
        let paths = [
            "/axo/server/pi-sessions/w1/s1.jsonl",
            "/axo/server/pi-sessions/w10/s2.jsonl",
            "/elsewhere/s3.jsonl",
        ];
        let ids: Vec<_> = paths
            .iter()
            .map(|path| {
                let id = insert_session(&database, "open");
                database
                    .execute(
                        "UPDATE sessions SET pi_session_file = ?2 WHERE id = ?1",
                        params![id.to_string(), path],
                    )
                    .unwrap();
                id
            })
            .collect();
        let moved = relocate_pi_session_files(
            &database,
            Path::new("/axo/server/pi-sessions/w1"),
            Path::new("/axo/sessions/h/w1"),
        )
        .unwrap();
        assert_eq!(moved, 1, "w10 only starts like w1");
        let path = |id: &SessionId| -> String {
            database
                .query_row(
                    "SELECT pi_session_file FROM sessions WHERE id = ?1",
                    params![id.to_string()],
                    |row| row.get(0),
                )
                .unwrap()
        };
        assert_eq!(path(&ids[0]), "/axo/sessions/h/w1/s1.jsonl");
        assert_eq!(path(&ids[1]), paths[1]);
        assert_eq!(path(&ids[2]), paths[2]);
    }

    #[test]
    fn every_session_owning_a_pi_history_is_reported() {
        let database = database();
        let first = insert_session(&database, "open");
        let second = insert_session(&database, "archived");
        for id in [first, second] {
            database
                .execute(
                    "UPDATE sessions SET pi_session_file = '/h.jsonl' WHERE id = ?1",
                    params![id.to_string()],
                )
                .unwrap();
        }
        let owners = pi_history_owners(&database, "/h.jsonl").unwrap();
        assert_eq!(owners.len(), 2, "callers must see the inconsistency");
        assert_eq!(owners[1].lifecycle, StoredLifecycle::Archived);
        assert!(
            pi_history_owners(&database, "/other.jsonl")
                .unwrap()
                .is_empty()
        );
    }
}
