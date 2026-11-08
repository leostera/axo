//! A pane's input side, apart from the Session state (RFD0034, step 8).
//!
//! Writing to a PTY blocks while the program in it isn't reading and its input queue is full,
//! with no limit: the master is a blocking descriptor shared with every attached client, and
//! `poll` on a macOS PTY says writable when a write would still block. So input is written
//! outside the Session state's lock, one write at a time per pane. A pane that takes no input
//! holds up only its own writers, and they give up after a time; closing the pane ends the
//! stuck write (the PTY hangs up).

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use axo_pty::process;

/// Where a pane's input goes: its own copy of the PTY master, and whose turn it is to write.
#[derive(Debug)]
pub(super) struct TerminalInput {
    master: OwnedFd,
    state: Mutex<InputState>,
    turn_over: Condvar,
}

#[derive(Debug, Default)]
struct InputState {
    /// A write is under way; others wait for it.
    writing: bool,
    /// The last of the person's inputs written, by its sequence number.
    last_sequence: Option<u64>,
}

impl TerminalInput {
    pub(super) fn new(master: &OwnedFd) -> io::Result<Self> {
        // SAFETY: fcntl duplicates a live descriptor; the result is owned below.
        let fd = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            // SAFETY: fcntl returned a new descriptor nothing else owns.
            master: unsafe { OwnedFd::from_raw_fd(fd) },
            state: Mutex::default(),
            turn_over: Condvar::new(),
        })
    }

    /// Writes the person's input number `sequence`. The same number again is taken as already
    /// written (a client retrying); any other but the next is refused.
    pub(super) fn write_sequenced(
        &self,
        sequence: u64,
        bytes: &[u8],
        timeout: Duration,
    ) -> io::Result<()> {
        let state = self.wait_for_turn(timeout)?;
        if state.last_sequence == Some(sequence) {
            return Ok(());
        }
        let expected = state
            .last_sequence
            .map_or(Some(0), |last| last.checked_add(1))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "terminal input sequence exhausted",
                )
            })?;
        if sequence != expected {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal input sequence is out of order",
            ));
        }
        self.write_in_turn(state, bytes, timeout, Some(sequence))
    }

    /// Writes keys or text outside the person's sequence: an agent typing, a remote key press.
    pub(super) fn write(&self, bytes: &[u8], timeout: Duration) -> io::Result<()> {
        let state = self.wait_for_turn(timeout)?;
        self.write_in_turn(state, bytes, timeout, None)
    }

    fn lock(&self) -> MutexGuard<'_, InputState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Waits until no other write is under way, for at most `timeout`.
    fn wait_for_turn(&self, timeout: Duration) -> io::Result<MutexGuard<'_, InputState>> {
        let deadline = Instant::now() + timeout;
        let mut state = self.lock();
        while state.writing {
            let now = Instant::now();
            if now >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "the pane is not taking input",
                ));
            }
            state = self
                .turn_over
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
        Ok(state)
    }

    /// Writes with the turn taken, the lock released meanwhile, and hands the turn on.
    fn write_in_turn(
        &self,
        mut state: MutexGuard<'_, InputState>,
        bytes: &[u8],
        timeout: Duration,
        sequence: Option<u64>,
    ) -> io::Result<()> {
        state.writing = true;
        drop(state);
        let turn = Turn(self);
        let written = process::write_all(self.master.as_raw_fd(), bytes, timeout);
        if written.is_ok()
            && let Some(sequence) = sequence
        {
            self.lock().last_sequence = Some(sequence);
        }
        drop(turn);
        written
    }
}

/// Hands the turn on when the write ends, even by a panic.
struct Turn<'a>(&'a TerminalInput);

impl Drop for Turn<'_> {
    fn drop(&mut self) {
        self.0.lock().writing = false;
        self.0.turn_over.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::OwnedFd;
    use std::sync::Arc;

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut fds = [0; 2];
        // SAFETY: pipe fills two new descriptors on success.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // SAFETY: both descriptors are new and owned here.
        unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
    }

    fn read_all(reader: &OwnedFd) -> Vec<u8> {
        let mut buffer = [0_u8; 1024];
        // SAFETY: buffer is writable for its length.
        let read = unsafe { libc::read(reader.as_raw_fd(), buffer.as_mut_ptr().cast(), 1024) };
        buffer[..read.max(0) as usize].to_vec()
    }

    const WAIT: Duration = Duration::from_secs(1);

    #[test]
    fn the_persons_inputs_are_written_once_and_in_order() {
        let (reader, writer) = pipe();
        let input = TerminalInput::new(&writer).unwrap();
        input.write_sequenced(0, b"a", WAIT).unwrap();
        input.write_sequenced(0, b"a", WAIT).unwrap();
        let skipped = input.write_sequenced(2, b"c", WAIT).unwrap_err();
        assert_eq!(skipped.kind(), io::ErrorKind::InvalidInput);
        input.write_sequenced(1, b"b", WAIT).unwrap();
        input.write(b"!", WAIT).unwrap();
        assert_eq!(read_all(&reader), b"ab!");
    }

    #[test]
    fn a_write_that_fails_is_not_counted_and_hands_the_turn_on() {
        let (reader, writer) = pipe();
        let input = TerminalInput::new(&writer).unwrap();
        // With no reader the write fails (Rust's runtime ignores SIGPIPE, so it is EPIPE).
        drop(reader);
        drop(writer);
        assert!(input.write_sequenced(0, b"a", WAIT).is_err());
        assert!(
            input.write_sequenced(0, b"a", WAIT).is_err(),
            "not taken as written"
        );
    }

    #[test]
    fn a_writer_waits_for_the_turn_and_gives_up_after_its_time() {
        let (reader, writer) = pipe();
        let input = Arc::new(TerminalInput::new(&writer).unwrap());
        // Hold the turn as a stuck write would.
        input.lock().writing = true;
        let started = Instant::now();
        let refused = input.write(b"x", Duration::from_millis(100)).unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() >= Duration::from_millis(100));

        let waiting = Arc::clone(&input);
        let writer_thread = std::thread::spawn(move || waiting.write(b"y", WAIT));
        std::thread::sleep(Duration::from_millis(50));
        drop(Turn(&input));
        writer_thread.join().unwrap().unwrap();
        assert_eq!(read_all(&reader), b"y");
    }
}
