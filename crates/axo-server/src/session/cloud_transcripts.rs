//! Archived Sessions live in the cloud (RFD0027): once the cloud holds an archived Session's
//! transcript whole, it is deleted here, and reopening the Session fetches it back first.
//!
//! `relay_sync.in_cloud` says the cloud has it. It is set before the file is deleted, and
//! cleared only when the Session reopens with its transcript back in place, under the same lock
//! that reopens it. While it is set the uploader neither reads nor uploads the file, so a
//! missing or partial one never cuts the cloud's copy.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use axo_protocol::SessionId;
use axo_relay::peers::{Mirror, Place, restore_directory};

use super::SessionManager;

/// How long reopening waits for a transcript to come back from the cloud.
const RESTORE_TIMEOUT: Duration = Duration::from_secs(60);

impl SessionManager {
    /// Deletes an archived Session's transcript the cloud acknowledged whole, at `position` and
    /// `chain`, while the file was `length` bytes. Returns false, deleting nothing, if the
    /// Session reopened, has panes, changed, or is not at that cursor any more.
    pub(super) fn evict_transcript(
        &self,
        session_id: SessionId,
        position: u64,
        chain: &str,
        length: u64,
    ) -> io::Result<bool> {
        let state = self.lock_state()?;
        if state.panes.has_session(session_id) || state.reopening.contains(&session_id) {
            return Ok(false);
        }
        let id = session_id.to_string();
        let Some(transcript) = axo_store::load_transcript(&state.database, Some(&id), None)? else {
            return Ok(false);
        };
        let Some(file) = transcript.pi_session_file.map(PathBuf::from) else {
            return Ok(false);
        };
        if !transcript.archived || fs::metadata(&file)?.len() != length {
            return Ok(false);
        }
        // Recorded before anything is deleted: a crash in between leaves a file to delete again.
        if !axo_store::mark_transcript_in_cloud(&state.database, &id, position, chain)? {
            return Ok(false);
        }
        remove_if_present(&file)?;
        remove_if_present(&lock_file(&file))?;
        log::info!(
            "event=session.transcript_evicted session_id={session_id} records={position} bytes={length}"
        );
        Ok(true)
    }

    /// Puts an archived Session's transcript back from the cloud if it is there, checked against
    /// what the cloud acknowledged when it was deleted. `in_cloud` stays set until the reopen
    /// clears it (`reopened_with_transcript`).
    pub(super) fn restore_transcript(
        &self,
        session_id: Option<SessionId>,
        pi_session_file: Option<&str>,
    ) -> io::Result<()> {
        let id = session_id.map(|id| id.to_string());
        let transcript = {
            let state = self.lock_state()?;
            axo_store::load_transcript(&state.database, id.as_deref(), pi_session_file)?
        };
        let Some(transcript) = transcript.filter(|transcript| transcript.in_cloud) else {
            return Ok(());
        };
        let (Some(file), Some(chain)) = (
            transcript.pi_session_file.as_deref().map(PathBuf::from),
            transcript.chain.as_deref(),
        ) else {
            return Err(unavailable("its record is incomplete"));
        };
        let expected = Some((transcript.position, chain.to_owned()));
        // Deleted after a crash, or restored by a reopen that failed later: already in place.
        if file.exists() && axo_agent::pi::transcript_chain(&file)? == expected {
            return Ok(());
        }
        let place = Place::of(&self.host_id, &transcript.session_id)
            .ok_or_else(|| unavailable("its place is not valid"))?;
        let access = self.peer_access()?;
        log::info!(
            "event=session.transcript_restore session_id={} records={}",
            transcript.session_id,
            transcript.position
        );
        let staged = access
            .live
            .restore(place.clone(), transcript.position, RESTORE_TIMEOUT)
            .map_err(|error| unavailable(&error.to_string()))?;
        let mut staging = Mirror::new(restore_directory(&access.index));
        let outcome = if axo_agent::pi::transcript_chain(&staged)? == expected {
            if let Some(folder) = file.parent() {
                fs::create_dir_all(folder)?;
            }
            fs::rename(&staged, &file)
        } else {
            Err(unavailable("the cloud's copy is not the one deleted here"))
        };
        staging.forget(&place)?;
        outcome?;
        log::info!(
            "event=session.transcript_restored session_id={}",
            transcript.session_id
        );
        Ok(())
    }
}

/// Marks an archived Session as reopening for as long as it lives: its transcript is not deleted
/// meanwhile, even if the reopen found it on disk before taking the catalog lock.
pub(super) struct Reopening<'a> {
    manager: &'a SessionManager,
    session_id: SessionId,
}

impl<'a> Reopening<'a> {
    pub(super) fn begin(manager: &'a SessionManager, session_id: SessionId) -> io::Result<Self> {
        if !manager.lock_state()?.reopening.insert(session_id) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "the Session is already being reopened",
            ));
        }
        Ok(Self {
            manager,
            session_id,
        })
    }
}

impl Drop for Reopening<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.manager.lock_state() {
            state.reopening.remove(&self.session_id);
        }
    }
}

/// Called under the catalog lock as an archived Session reopens: its transcript must be here,
/// and from now on the uploader reads it again.
pub(super) fn reopened_with_transcript(
    database: &axo_store::Connection,
    session_id: SessionId,
) -> io::Result<()> {
    let id = session_id.to_string();
    let Some(transcript) = axo_store::load_transcript(database, Some(&id), None)? else {
        return Ok(());
    };
    if !transcript.in_cloud {
        return Ok(());
    }
    let on_disk = match transcript.pi_session_file.as_deref().map(Path::new) {
        Some(file) if file.exists() => axo_agent::pi::transcript_chain(file)?,
        _ => None,
    };
    if on_disk != transcript.chain.map(|chain| (transcript.position, chain)) {
        return Err(unavailable("it is not back on this Mac"));
    }
    axo_store::clear_transcript_in_cloud(database, &id)
}

fn unavailable(reason: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::NotFound,
        format!("This Session's transcript is in the cloud and could not be fetched: {reason}"),
    )
}

fn lock_file(file: &Path) -> PathBuf {
    let mut name = file.as_os_str().to_owned();
    name.push(".lock");
    PathBuf::from(name)
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::test_support::LifecycleFixture;
    use rusqlite::params;

    const LINES: &str = "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"cwd\":\"/tmp\"}\n\
        {\"id\":\"a\",\"parentId\":null}\n{\"id\":\"b\",\"parentId\":\"a\"}\n";

    /// An archived Session whose transcript the cloud acknowledged whole.
    fn archived(fixture: &LifecycleFixture) -> (SessionId, PathBuf, String) {
        let session_id = SessionId::new_v4().unwrap();
        let file = fixture.directory.join(format!("{session_id}.jsonl"));
        fs::write(&file, LINES).unwrap();
        fs::write(lock_file(&file), b"").unwrap();
        let (count, chain) = axo_agent::pi::transcript_chain(&file).unwrap().unwrap();
        assert_eq!(count, 2);
        let state = fixture.manager.lock_state().unwrap();
        state
            .database
            .execute(
                "INSERT INTO sessions (id, initial_pwd, state, created_at, pi_session_file) \
                 VALUES (?1, '/tmp', 'archived', 1, ?2)",
                params![session_id.to_string(), file.to_string_lossy()],
            )
            .unwrap();
        axo_store::store_sync_cursor(&state.database, &session_id.to_string(), 2, &chain).unwrap();
        (session_id, file, chain)
    }

    fn in_cloud(fixture: &LifecycleFixture, session_id: SessionId) -> bool {
        let state = fixture.manager.lock_state().unwrap();
        axo_store::load_transcript(&state.database, Some(&session_id.to_string()), None)
            .unwrap()
            .unwrap()
            .in_cloud
    }

    #[test]
    fn a_transcript_is_deleted_only_as_the_cloud_acknowledged_it_and_recorded_first() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let (session_id, file, chain) = archived(&fixture);
        let length = fs::metadata(&file).unwrap().len();

        assert!(
            !manager
                .evict_transcript(session_id, 2, &chain, length + 1)
                .unwrap(),
            "changed since"
        );
        assert!(
            !manager
                .evict_transcript(session_id, 3, &chain, length)
                .unwrap(),
            "not acknowledged"
        );
        assert!(
            !manager
                .evict_transcript(session_id, 2, "other", length)
                .unwrap(),
            "another chain"
        );
        assert!(file.exists() && !in_cloud(&fixture, session_id));

        assert!(
            manager
                .evict_transcript(session_id, 2, &chain, length)
                .unwrap()
        );
        assert!(!file.exists() && !lock_file(&file).exists());
        assert!(in_cloud(&fixture, session_id));
    }

    #[test]
    fn an_open_session_keeps_its_transcript() {
        let fixture = LifecycleFixture::new();
        let (session_id, file, chain) = archived(&fixture);
        fixture
            .manager
            .lock_state()
            .unwrap()
            .database
            .execute(
                "UPDATE sessions SET state = 'open' WHERE id = ?1",
                params![session_id.to_string()],
            )
            .unwrap();
        let length = fs::metadata(&file).unwrap().len();
        assert!(
            !fixture
                .manager
                .evict_transcript(session_id, 2, &chain, length)
                .unwrap()
        );
        assert!(file.exists());
    }

    #[test]
    fn a_session_reopens_only_with_the_transcript_the_cloud_acknowledged_back_in_place() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let (session_id, file, chain) = archived(&fixture);
        let length = fs::metadata(&file).unwrap().len();
        assert!(
            manager
                .evict_transcript(session_id, 2, &chain, length)
                .unwrap()
        );
        let reopen =
            || reopened_with_transcript(&manager.lock_state().unwrap().database, session_id);

        assert_eq!(
            reopen().unwrap_err().kind(),
            io::ErrorKind::NotFound,
            "not back"
        );
        fs::write(&file, &LINES[..LINES.len() - 10]).unwrap();
        assert_eq!(
            reopen().unwrap_err().kind(),
            io::ErrorKind::NotFound,
            "only part of it"
        );
        assert!(in_cloud(&fixture, session_id));

        // A crash between recording and deleting leaves the file: nothing needs fetching.
        fs::write(&file, LINES).unwrap();
        manager.restore_transcript(Some(session_id), None).unwrap();
        reopen().unwrap();
        assert!(!in_cloud(&fixture, session_id));
    }

    #[test]
    fn a_transcript_that_cannot_be_fetched_fails_the_reopen_and_changes_nothing() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let (session_id, file, chain) = archived(&fixture);
        let length = fs::metadata(&file).unwrap().len();
        assert!(
            manager
                .evict_transcript(session_id, 2, &chain, length)
                .unwrap()
        );
        // This Mac does not follow the account here: there is nothing to fetch it through.
        assert!(manager.restore_transcript(Some(session_id), None).is_err());
        assert!(!file.exists() && in_cloud(&fixture, session_id));
    }
}
