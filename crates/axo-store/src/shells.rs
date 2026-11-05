//! Shell (pane) rows: inserting terminals and archiving a single pane.

use std::collections::HashSet;
use std::io;
use std::path::Path;

use axo_protocol::{SessionId, ShellId};
use rusqlite::{Connection, params};

use crate::rows::{inserted_shell_id, unix_timestamp};
use crate::sessions::read_session_layout;

pub fn archive_shell(database: &Connection, id: ShellId, reason: &str) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![unix_timestamp(), reason, id.get()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "shell was not open in the database",
        ));
    }
    Ok(())
}

pub fn archive_shell_and_prune_layout(
    database: &mut Connection,
    shell_id: ShellId,
    session_id: SessionId,
    reason: &str,
    remaining_shell_ids: &HashSet<ShellId>,
) -> io::Result<()> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![unix_timestamp(), reason, shell_id.get()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "shell was not open in the database",
        ));
    }

    if let Some(layout) = read_session_layout(&transaction, session_id)? {
        let pruned_layout = layout.pruned_to(remaining_shell_ids);
        let layout_json = pruned_layout
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(io::Error::other)?;
        transaction
            .execute(
                "UPDATE sessions SET layout_json = ?1 WHERE id = ?2 AND state = 'open'",
                params![layout_json, session_id.to_string()],
            )
            .map_err(io::Error::other)?;
    }

    transaction.commit().map_err(io::Error::other)
}

pub fn insert_terminal_shell(
    database: &Connection,
    session_id: SessionId,
    initial_pwd: &Path,
) -> io::Result<ShellId> {
    database
        .execute(
            "INSERT INTO shells (session_id, initial_pwd, state, created_at) VALUES (?1, ?2, 'open', ?3)",
            params![session_id.to_string(), initial_pwd.to_string_lossy(), unix_timestamp()],
        )
        .map_err(io::Error::other)?;
    inserted_shell_id(database)
}
