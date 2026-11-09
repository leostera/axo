//! What the kernel says about open Sessions' transcripts (RFD0037, `specs/sessions/upload-wakes.ts`):
//! a write to one, or a file created in the directory of one that does not exist yet, wakes the
//! uploader. One kqueue, in the uploader's `select!` through `AsyncFd`.
//!
//! The uploader registers before it reads, so a write after the read is always seen. While a
//! transcript does not exist its directory is watched instead, registered before the file is
//! tried, so a file created in between is seen either way. A transcript deleted, renamed over or
//! revoked is forgotten here and registered again, by path, on the turn its event wakes.

use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use tokio::io::Interest;
use tokio::io::unix::AsyncFd;

/// What a transcript's watch reports: written to or extended, or gone from its path.
const FILE_EVENTS: u32 = libc::NOTE_WRITE
    | libc::NOTE_EXTEND
    | libc::NOTE_DELETE
    | libc::NOTE_RENAME
    | libc::NOTE_REVOKE;
/// A transcript no longer at its path: registered again by path.
const GONE: u32 = libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;
/// Events read per `kevent` call.
const BATCH: usize = 32;

pub(super) struct TranscriptWatch {
    queue: AsyncFd<OwnedFd>,
    /// Each watched path (a transcript, or a directory standing in for one) and its descriptor,
    /// held open for its registration: closing it removes the registration.
    watched: Mutex<HashMap<PathBuf, OwnedFd>>,
}

impl TranscriptWatch {
    /// A new kqueue, registered with the runtime this is called in.
    pub(super) fn new() -> io::Result<Self> {
        // SAFETY: kqueue takes no arguments and returns a new descriptor or -1.
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `queue` is a new descriptor nothing else owns.
        let queue = unsafe { OwnedFd::from_raw_fd(queue) };
        set_close_on_exec(&queue)?;
        Ok(Self {
            // Readable only: a kqueue supports EVFILT_READ, and EVFILT_WRITE is EINVAL.
            // SAFETY: the OwnedFd is the kqueue, open for as long as the AsyncFd owns it.
            queue: unsafe { AsyncFd::register_with_interest(queue, Interest::READABLE) }?,
            watched: Mutex::new(HashMap::new()),
        })
    }

    /// Watches exactly these transcripts from now on: each one, or its directory while it does
    /// not exist. Call it before reading them.
    pub(super) fn watch<'a>(&self, transcripts: impl IntoIterator<Item = &'a Path>) {
        let mut watched = self.watched.lock().unwrap_or_else(|p| p.into_inner());
        let mut keep = HashSet::new();
        for transcript in transcripts {
            if watched.contains_key(transcript) {
                keep.insert(transcript.to_owned());
                continue;
            }
            let Some(directory) = transcript.parent() else {
                continue;
            };
            // The directory first: a file created after the try below still wakes the uploader.
            if !watched.contains_key(directory)
                && let Ok(descriptor) = self.register(directory, libc::NOTE_WRITE)
            {
                watched.insert(directory.to_owned(), descriptor);
            }
            match self.register(transcript, FILE_EVENTS) {
                Ok(descriptor) => {
                    watched.insert(transcript.to_owned(), descriptor);
                    keep.insert(transcript.to_owned());
                }
                Err(error) => {
                    if error.kind() != io::ErrorKind::NotFound {
                        log::warn!("event=sync.watch outcome=failed reason={error}");
                    }
                    keep.insert(directory.to_owned());
                }
            }
        }
        watched.retain(|path, _| keep.contains(path));
    }

    /// Waits until something watched changed, and takes what the kernel reported.
    pub(super) async fn changed(&self) -> io::Result<()> {
        loop {
            let mut ready = self.queue.readable().await?;
            let mut events = [empty_event(); BATCH];
            let none = libc::timespec {
                tv_sec: 0,
                tv_nsec: 0,
            };
            // SAFETY: `events` has room for BATCH events; a zero timeout never blocks.
            let count = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    events.as_mut_ptr(),
                    BATCH as libc::c_int,
                    &none,
                )
            };
            if count < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            let count = count as usize;
            if count < BATCH {
                // Drained: the next event makes the queue readable again.
                ready.clear_ready();
            }
            if count == 0 {
                continue;
            }
            self.forget_gone(&events[..count]);
            return Ok(());
        }
    }

    /// Drops the watches of transcripts that left their path; the next `watch` finds the new one.
    fn forget_gone(&self, events: &[libc::kevent]) {
        let gone: HashSet<usize> = events
            .iter()
            .filter(|event| event.fflags & GONE != 0)
            .map(|event| event.ident)
            .collect();
        if gone.is_empty() {
            return;
        }
        let mut watched = self.watched.lock().unwrap_or_else(|p| p.into_inner());
        watched.retain(|_, descriptor| !gone.contains(&(descriptor.as_raw_fd() as usize)));
    }

    /// Opens `path` for events only and registers it on the queue.
    fn register(&self, path: &Path, events: u32) -> io::Result<OwnedFd> {
        let name = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "a path with a NUL"))?;
        // SAFETY: `name` is NUL-terminated; O_EVTONLY opens for notifications only.
        let descriptor = unsafe { libc::open(name.as_ptr(), libc::O_EVTONLY | libc::O_CLOEXEC) };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a new descriptor nothing else owns.
        let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
        let change = libc::kevent {
            ident: descriptor.as_raw_fd() as usize,
            filter: libc::EVFILT_VNODE,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: events,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        // SAFETY: one change, no events out, and both descriptors are open.
        let result = unsafe {
            libc::kevent(
                self.queue.as_raw_fd(),
                &change,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        };
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(descriptor)
    }
}

fn empty_event() -> libc::kevent {
    libc::kevent {
        ident: 0,
        filter: 0,
        flags: 0,
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    }
}

fn set_close_on_exec(descriptor: &OwnedFd) -> io::Result<()> {
    // SAFETY: only this descriptor's flags change.
    if unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn directory(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "axo-watch-{name}-{}-{:?}",
            std::process::id(),
            std::time::Instant::now()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    async fn changes_within(watch: &TranscriptWatch, within: Duration) -> bool {
        tokio::time::timeout(within, watch.changed()).await.is_ok()
    }

    #[tokio::test]
    async fn a_write_to_a_watched_transcript_is_a_change_and_nothing_else_is() {
        let transcript = directory("write").join("t.jsonl");
        std::fs::write(&transcript, "a\n").unwrap();
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        assert!(!changes_within(&watch, Duration::from_millis(100)).await);
        std::fs::OpenOptions::new()
            .append(true)
            .open(&transcript)
            .and_then(|mut file| std::io::Write::write_all(&mut file, b"b\n"))
            .unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
        assert!(!changes_within(&watch, Duration::from_millis(100)).await);
    }

    #[tokio::test]
    async fn creating_a_transcript_that_did_not_exist_is_a_change() {
        let transcript = directory("create").join("t.jsonl");
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        std::fs::write(&transcript, "a\n").unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
        // Watched itself from the next turn on, not its directory.
        watch.watch([transcript.as_path()]);
        std::fs::write(transcript.with_file_name("other"), "x").unwrap();
        assert!(!changes_within(&watch, Duration::from_millis(100)).await);
    }

    #[tokio::test]
    async fn a_transcript_replaced_at_its_path_is_watched_again() {
        let transcript = directory("replace").join("t.jsonl");
        std::fs::write(&transcript, "a\n").unwrap();
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        let replacement = transcript.with_extension("new");
        std::fs::write(&replacement, "a\n").unwrap();
        std::fs::rename(&replacement, &transcript).unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
        watch.watch([transcript.as_path()]);
        std::fs::write(&transcript, "a\nb\n").unwrap();
        assert!(changes_within(&watch, Duration::from_secs(1)).await);
    }

    #[tokio::test]
    async fn a_transcript_no_longer_open_is_no_longer_watched() {
        let transcript = directory("forget").join("t.jsonl");
        std::fs::write(&transcript, "a\n").unwrap();
        let watch = TranscriptWatch::new().unwrap();
        watch.watch([transcript.as_path()]);
        watch.watch([]);
        std::fs::write(&transcript, "a\nb\n").unwrap();
        assert!(!changes_within(&watch, Duration::from_millis(100)).await);
    }
}
