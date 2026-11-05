//! Session sync (RFD0018, Upload; modelled in `specs/session-sync.ts`).
//!
//! Once paired, Axod uploads every Session's Pi transcript, open or archived, whether or not a
//! client is watching. On every connect it sends `axo.host.sync`, a manifest of every Session
//! with what it holds locally, and the cloud answers with what it holds. Axod classifies each
//! Session, finds the common prefix of a diverged one with `chainAt` and cuts the cloud back to
//! it with `truncate`, then appends the lines the cloud is missing, a batch at a time, moving
//! its cursor only when the cloud acknowledges a commit. New lines in open Sessions go ahead of
//! backfill. Any failure (a gap, a conflict, a timeout) starts the handshake again, and its
//! answer says what the cloud holds.
//!
//! An archived Session the cloud acknowledged whole is deleted here (RFD0027). From then on its
//! manifest row has no upload, which leaves the cloud's copy as it is, until reopening it
//! restores the file.
//!
//! This runs on its own thread and reaches the cloud through `RelayChannel`.

mod local_file;
mod metadata;
mod uploader;

#[cfg(test)]
mod test_support;

pub use metadata::{SessionMetadata, StoredSyncState, SyncSession, WorkspaceState};

use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use local_file::LocalFile;
use uploader::Uploader;

use crate::host::RelayHost;
use crate::outbound::RelayChannel;

/// Wakes the uploader early: a Session changed, or the socket reconnected.
#[derive(Clone, Default)]
pub struct SyncWaker(Arc<(Mutex<bool>, Condvar)>);

impl SyncWaker {
    pub fn wake(&self) {
        let (flag, condvar) = &*self.0;
        if let Ok(mut woken) = flag.lock() {
            *woken = true;
            condvar.notify_all();
        }
    }

    fn wait(&self, timeout: Duration) {
        let (flag, condvar) = &*self.0;
        if let Ok(woken) = flag.lock() {
            let (mut woken, _) = condvar
                .wait_timeout_while(woken, timeout, |woken| !*woken)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *woken = false;
        }
    }
}

/// The uploader thread.
pub struct SyncWorker {
    thread: Option<JoinHandle<()>>,
}

impl SyncWorker {
    pub fn start(
        host: Arc<dyn RelayHost>,
        channel: Arc<RelayChannel>,
        waker: SyncWaker,
        stop: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        let thread = thread::Builder::new()
            .name("axo-cloud-sync".to_owned())
            .spawn(move || {
                let mut uploader = Uploader::new(host, channel);
                while !stop.load(Ordering::Relaxed) {
                    let delay = uploader.turn();
                    if !delay.is_zero() {
                        waker.wait(delay);
                    }
                }
            })?;
        Ok(Self {
            thread: Some(thread),
        })
    }

    pub fn join(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// How many records a Pi transcript has and the chain at the last, if every line of it is a
/// whole record (RFD0027: a restored transcript must be the one that was deleted).
pub fn transcript_chain(path: &std::path::Path) -> io::Result<Option<(u64, String)>> {
    let mut file = LocalFile::new(Some(path.to_owned()));
    file.refresh()?;
    if file.whole_length()?.is_none() {
        return Ok(None);
    }
    let count = file.count();
    Ok(file
        .transcript
        .as_ref()
        .and_then(|transcript| transcript.chain_at(count))
        .map(|chain| (count, chain.to_owned())))
}

fn unix_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.char_indices().all(|(index, c)| match index {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pi3::Transcript;
    use crate::sync::test_support::{HEADER, temp_file};

    #[test]
    fn a_transcript_has_a_chain_only_when_every_line_is_a_whole_record() {
        let whole = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\",\"parentId\":null}}\n{{\"id\":\"b\",\"parentId\":\"a\"}}\n"
        ));
        let mut expected = Transcript::start(HEADER);
        expected.push(r#"{"id":"a","parentId":null}"#);
        expected.push(r#"{"id":"b","parentId":"a"}"#);
        assert_eq!(
            transcript_chain(&whole).unwrap(),
            Some((2, expected.chain().to_owned()))
        );
        let partial = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\",\"parentId\":null}}\n{{\"id\""
        ));
        assert_eq!(
            transcript_chain(&partial).unwrap(),
            None,
            "a partial last line"
        );
        let refused = temp_file(&format!("{HEADER}\nnot a record\n"));
        assert_eq!(
            transcript_chain(&refused).unwrap(),
            None,
            "a line that is not a record"
        );
        for path in [whole, partial, refused] {
            std::fs::remove_file(path).unwrap();
        }
    }
}
