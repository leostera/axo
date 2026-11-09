//! The transcript writer lock: Pi's proof of life.
//!
//! Every Pi holds an exclusive `flock` on its Session's `<transcript>.jsonl.lock`, inherited at
//! launch and kept even if Axod crashes. Holding the lock therefore proves no Pi for the Session
//! is alive; only `acquire` can produce a `WriterLock`.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::FromRawFd;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::interrupt::Interrupt;

#[derive(Debug)]
pub struct WriterLock(OwnedFd);

/// How long a just-released lock may still be held by a child forked before the release, until
/// that child execs. Generous: exec waits on the loader, which is slow on a loaded machine.
const FORK_EXEC_WINDOW: Duration = Duration::from_millis(250);
const FORK_EXEC_POLL: Duration = Duration::from_millis(5);
/// How often a lock whose holder is unknown is tried again.
const UNKNOWN_HOLDER_RETRY: Duration = Duration::from_millis(100);

/// A kqueue that turns readable when a process exits: any process, not only a child.
struct ProcessExit(OwnedFd);

impl ProcessExit {
    /// `None` when `pid` has already exited.
    fn watch(pid: u32) -> io::Result<Option<Self>> {
        // SAFETY: kqueue returns a new descriptor, owned at once.
        let queue = unsafe { libc::kqueue() };
        if queue == -1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `queue` was just created and is owned only here.
        let queue = unsafe { OwnedFd::from_raw_fd(queue) };
        axo_pty::process::set_cloexec(queue.as_raw_fd())?;
        let change = libc::kevent {
            ident: pid as libc::uintptr_t,
            filter: libc::EVFILT_PROC,
            flags: libc::EV_ADD | libc::EV_ONESHOT,
            fflags: libc::NOTE_EXIT,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        // SAFETY: one initialized change and no event list; returns at once.
        let result = unsafe {
            libc::kevent(
                queue.as_raw_fd(),
                &change,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        };
        if result == -1 {
            let error = io::Error::last_os_error();
            return match error.raw_os_error() {
                Some(libc::ESRCH) => Ok(None),
                _ => Err(error),
            };
        }
        Ok(Some(Self(queue)))
    }

    fn as_raw_fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }
}

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

    /// Like `acquire`, but rides out a holder that is only a process forked mid-launch.
    ///
    /// A child forked by any thread holds a copy of every descriptor until it execs, and `flock`
    /// belongs to the shared open file description. So for a moment after Axod releases a lock
    /// (a probe, a failed launch), it still looks held. Taking that for a live Pi would send a
    /// shutdown request to a Pi that does not exist. `WouldBlock` after `FORK_EXEC_WINDOW`.
    pub fn acquire_settled(session_file: &Path, interrupt: &Interrupt<'_>) -> io::Result<Self> {
        match Self::poll(
            session_file,
            FORK_EXEC_WINDOW,
            FORK_EXEC_POLL,
            None,
            interrupt,
        ) {
            Err(error) if error.kind() == io::ErrorKind::TimedOut => Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "Pi transcript is already owned by a writer",
            )),
            settled => settled,
        }
    }

    /// Retries `acquire` until `timeout`, then fails with `TimedOut`. Nothing says when a lock
    /// is released, so with an unknown holder this tries again every `UNKNOWN_HOLDER_RETRY`.
    pub fn wait(
        session_file: &Path,
        timeout: Duration,
        interrupt: &Interrupt<'_>,
    ) -> io::Result<Self> {
        Self::poll(session_file, timeout, UNKNOWN_HOLDER_RETRY, None, interrupt)
    }

    /// Like `wait`, for a lock held by the process `holder`: tries again the moment it exits.
    /// A lock still held after that (a child it left holding it) is retried as with `wait`.
    pub fn wait_for_holder(
        session_file: &Path,
        holder: u32,
        timeout: Duration,
        interrupt: &Interrupt<'_>,
    ) -> io::Result<Self> {
        Self::poll(
            session_file,
            timeout,
            UNKNOWN_HOLDER_RETRY,
            Some(holder),
            interrupt,
        )
    }

    fn poll(
        session_file: &Path,
        timeout: Duration,
        interval: Duration,
        holder: Option<u32>,
        interrupt: &Interrupt<'_>,
    ) -> io::Result<Self> {
        let deadline = Instant::now() + timeout;
        let mut exit = match holder {
            Some(holder) => ProcessExit::watch(holder)?,
            None => None,
        };
        loop {
            interrupt.check()?;
            match Self::acquire(session_file) {
                Ok(lock) => return Ok(lock),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "Pi did not release its transcript lock",
                        ));
                    }
                    // While the holder lives, only its exit (or the deadline) is worth waking
                    // for; after it, or without one, try again after `interval`.
                    let next = match &exit {
                        Some(_) => deadline,
                        None => deadline.min(Instant::now() + interval),
                    };
                    let watching: Vec<_> = exit
                        .iter()
                        .map(|exit| (exit.as_raw_fd(), libc::POLLIN))
                        .collect();
                    match interrupt.wait(&watching, Some(next), "the next try") {
                        Ok(_) => exit = None,
                        Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
                        Err(error) => return Err(error),
                    }
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
    use std::thread;

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
    fn a_lock_copied_into_a_child_that_has_not_exec_ed_yet_is_ridden_out() {
        let directory = crate::test_directory();
        let session_file = directory.join("session.jsonl");
        let lock = WriterLock::acquire(&session_file).unwrap();
        let child = crate::PausedBeforeExec::fork();
        drop(lock);
        assert_eq!(
            WriterLock::acquire(&session_file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock,
            "the forked child holds the lock until it execs"
        );
        let spawning = thread::spawn(move || {
            thread::sleep(Duration::from_millis(20));
            child.exec()
        });
        WriterLock::acquire_settled(&session_file, &Interrupt::never()).unwrap();
        assert!(spawning.join().unwrap().success());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn a_lock_held_past_the_fork_window_is_owned_by_a_writer() {
        let directory = crate::test_directory();
        let session_file = directory.join("session.jsonl");
        let _writer = WriterLock::acquire(&session_file).unwrap();
        let started = Instant::now();
        assert_eq!(
            WriterLock::acquire_settled(&session_file, &Interrupt::never())
                .unwrap_err()
                .kind(),
            io::ErrorKind::WouldBlock
        );
        assert!(started.elapsed() >= FORK_EXEC_WINDOW);
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
