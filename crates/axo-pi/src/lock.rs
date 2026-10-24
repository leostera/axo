//! The transcript writer lock: Pi's proof of life.
//!
//! Every Pi holds an exclusive `flock` on its Session's `<transcript>.jsonl.lock`, inherited at
//! launch and kept even if Axod crashes. Holding the lock therefore proves no Pi for the Session
//! is alive; only `acquire` can produce a `WriterLock`.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

#[derive(Debug)]
pub struct WriterLock(OwnedFd);

fn lock_path(session_file: &Path) -> PathBuf {
    session_file.with_extension("jsonl.lock")
}

impl WriterLock {
    /// Takes the lock without waiting, creating the lock file if needed. Fails with
    /// `WouldBlock` while a Pi (or another holder) has it.
    pub fn acquire(session_file: &Path) -> io::Result<Self> {
        let lock_path = lock_path(session_file);
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(lock_path)?;
        if !lock.metadata()?.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi writer lock is not a regular file",
            ));
        }
        // SAFETY: lock is a valid file descriptor and flock only changes its advisory lock.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == -1 {
            let error = io::Error::last_os_error();
            return Err(if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
                io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "Pi transcript is already owned by a writer",
                )
            } else {
                error
            });
        }
        Ok(Self(OwnedFd::from(lock)))
    }

    /// Retries `acquire` until `timeout`, then fails with `TimedOut`.
    pub fn wait(
        session_file: &Path,
        timeout: Duration,
        check_current: &impl Fn() -> io::Result<()>,
    ) -> io::Result<Self> {
        let deadline = Instant::now() + timeout;
        loop {
            check_current()?;
            match Self::acquire(session_file) {
                Ok(lock) => return Ok(lock),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "Pi did not release its transcript lock",
                        ));
                    }
                    thread::sleep(Duration::from_millis(100));
                }
                Err(error) => return Err(error),
            }
        }
    }

    /// Takes an existing lock file's lock without creating one: `None` when there is no lock
    /// file (no Pi can hold it), `WouldBlock` while it is held.
    pub(crate) fn acquire_existing(session_file: &Path) -> io::Result<Option<Self>> {
        let lock = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(lock_path(session_file))
        {
            Ok(lock) => lock,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        flock_exclusive(&lock)?;
        Ok(Some(Self(OwnedFd::from(lock))))
    }

    /// Whether some process holds the lock. Never creates the lock file.
    pub fn is_held(session_file: &Path) -> io::Result<bool> {
        match Self::acquire_existing(session_file) {
            Ok(_) => Ok(false),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(true),
            Err(error) => Err(error),
        }
    }
}

fn flock_exclusive(lock: &File) -> io::Result<()> {
    // SAFETY: lock is a valid file descriptor and flock only changes its advisory lock.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    Err(if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
        io::Error::new(
            io::ErrorKind::WouldBlock,
            "Pi transcript is already owned by a writer",
        )
    } else {
        error
    })
}

impl AsRawFd for WriterLock {
    fn as_raw_fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn liveness_follows_the_writer_lock_without_creating_it() {
        let directory = crate::test_directory();
        let session_file = directory.join("session.jsonl");
        assert!(!WriterLock::is_held(&session_file).unwrap());
        assert!(
            !lock_path(&session_file).exists(),
            "probing must not create the lock file"
        );

        let writer = WriterLock::acquire(&session_file).unwrap();
        assert!(WriterLock::is_held(&session_file).unwrap());
        assert_eq!(
            WriterLock::acquire(&session_file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        drop(writer);
        // A process forked concurrently (by another test) holds a copy of every descriptor
        // until it execs, and flock belongs to the shared open file description; allow for it.
        let deadline = Instant::now() + Duration::from_secs(2);
        while WriterLock::is_held(&session_file).unwrap() {
            assert!(
                Instant::now() < deadline,
                "the lock stayed held after its holder dropped it"
            );
            thread::sleep(Duration::from_millis(10));
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn writer_lock_rejects_a_symlink_without_touching_its_target() {
        let directory = crate::test_directory();
        let session_file = directory.join("session.jsonl");
        let target = directory.join("not-a-lock");
        fs::write(&target, b"untouched lock target\n").unwrap();
        std::os::unix::fs::symlink(&target, lock_path(&session_file)).unwrap();
        assert!(WriterLock::acquire(&session_file).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"untouched lock target\n");
        fs::remove_dir_all(directory).unwrap();
    }
}
