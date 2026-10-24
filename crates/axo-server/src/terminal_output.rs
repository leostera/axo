//! Axod is the single, permanent reader of every PTY it owns.
//!
//! Each shell gets one pump thread from the moment it is spawned until its PTY reaches end of
//! file. The pump records replay history, publishes `terminal.output` events, and fans raw bytes
//! out to every attached client. A shell therefore never blocks on a full PTY buffer because no
//! client is attached, and any number of clients (Mac windows, the web relay, the CLI) can watch
//! the same shell.
//!
//! Invariants:
//! - Only the pump reads the PTY master. Attached clients receive the master descriptor for
//!   input, resizing, and termios/foreground queries only.
//! - The pump never blocks on a client. Each subscriber has a bounded backlog; a subscriber that
//!   falls `MAX_SUBSCRIBER_BACKLOG_BYTES` behind is disconnected and must reattach (replay).
//! - Subscribing is atomic with respect to recording: a subscriber's replay plus its live chunks
//!   are exactly the PTY stream, with no gap and no duplicate.

use std::collections::VecDeque;
use std::fmt;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

use crate::session::{SessionId, ShellId};

pub(crate) const MAX_TERMINAL_OUTPUT_HISTORY_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const MAX_SUBSCRIBER_BACKLOG_BYTES: usize = 8 * 1024 * 1024;
const READ_BUFFER_BYTES: usize = 64 * 1024;
/// How often an idle pump rechecks whether its shell was removed from the catalog. Shell exit is
/// observed immediately as end of file; this only bounds descriptor retention after a close.
const STOP_POLL_INTERVAL_MILLIS: libc::c_int = 250;

/// The complete VT stream since the shell started, or nothing once it outgrew the cap. A
/// truncated stream could start mid-sequence or miss mode changes, so it is never replayed.
#[derive(Debug)]
pub(crate) struct TerminalOutputHistory {
    bytes: Vec<u8>,
    complete: bool,
}

impl TerminalOutputHistory {
    pub(crate) fn new() -> Self {
        Self {
            bytes: Vec::new(),
            complete: true,
        }
    }

    pub(crate) fn record(&mut self, output: &[u8]) {
        if !self.complete {
            return;
        }
        if self.bytes.len().saturating_add(output.len()) > MAX_TERMINAL_OUTPUT_HISTORY_BYTES {
            self.bytes = Vec::new();
            self.complete = false;
            return;
        }
        self.bytes.extend_from_slice(output);
    }

    pub(crate) fn replay(&self) -> &[u8] {
        if self.complete { &self.bytes } else { &[] }
    }
}

/// Where a shell's output is published once the catalog knows its identity.
pub(crate) trait TerminalOutputSink: Send + Sync {
    fn publish_terminal_output(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        output: &[u8],
    );
}

struct OutputBinding {
    session_id: SessionId,
    shell_id: ShellId,
    sink: Arc<dyn TerminalOutputSink>,
}

/// Shared between a shell's pump, its `RunningShell`, and its attachments.
pub(crate) struct TerminalOutput {
    state: Mutex<OutputState>,
    binding: OnceLock<OutputBinding>,
    stopped: AtomicBool,
}

struct OutputState {
    history: TerminalOutputHistory,
    ended: bool,
    subscribers: Vec<Arc<OutputSubscriber>>,
}

impl fmt::Debug for TerminalOutput {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = self.lock();
        formatter
            .debug_struct("TerminalOutput")
            .field("history_bytes", &state.history.replay().len())
            .field("ended", &state.ended)
            .field("subscribers", &state.subscribers.len())
            .finish()
    }
}

impl TerminalOutput {
    fn new() -> Self {
        Self {
            state: Mutex::new(OutputState {
                history: TerminalOutputHistory::new(),
                ended: false,
                subscribers: Vec::new(),
            }),
            binding: OnceLock::new(),
            stopped: AtomicBool::new(false),
        }
    }

    /// Starts draining `master` immediately. Output before `bind` is recorded for replay but not
    /// published, because the shell's catalog identity does not exist yet.
    pub(crate) fn start(master: &OwnedFd) -> io::Result<Arc<Self>> {
        // SAFETY: fcntl duplicates a live descriptor; the result is owned below.
        let duplicate = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if duplicate == -1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fcntl returned a new descriptor owned by the pump.
        let reader = unsafe { OwnedFd::from_raw_fd(duplicate) };
        let output = Arc::new(Self::new());
        let pump = Arc::clone(&output);
        thread::Builder::new()
            .name("axo-pty-output".into())
            .spawn(move || pump.run(reader))?;
        Ok(output)
    }

    #[cfg(test)]
    pub(crate) fn detached_for_tests() -> Arc<Self> {
        Arc::new(Self::new())
    }

    /// Attaches catalog identity; later output is published as `terminal.output`. Idempotent.
    pub(crate) fn bind(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sink: Arc<dyn TerminalOutputSink>,
    ) {
        let _ = self.binding.set(OutputBinding {
            session_id,
            shell_id,
            sink,
        });
    }

    /// Stops the pump within `STOP_POLL_INTERVAL_MILLIS` and releases its descriptor. Attached
    /// clients drain what was already queued and then see end of file.
    pub(crate) fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
    }

    /// Registers a subscriber and returns the replay it must write first. `overflow_shutdown`,
    /// when given, is shut down if the subscriber overflows, so a writer blocked on a stalled
    /// client wakes up.
    pub(crate) fn subscribe(
        &self,
        overflow_shutdown: Option<OwnedFd>,
    ) -> (Vec<u8>, Arc<OutputSubscriber>) {
        let mut state = self.lock();
        let subscriber = Arc::new(OutputSubscriber::new(overflow_shutdown, state.ended));
        if !state.ended {
            state.subscribers.push(Arc::clone(&subscriber));
        }
        (state.history.replay().to_vec(), subscriber)
    }

    #[cfg(test)]
    pub(crate) fn subscriber_count(&self) -> usize {
        self.lock().subscribers.len()
    }

    /// Records one chunk and fans it out. Exposed for tests; the pump is the only production caller.
    pub(crate) fn record(&self, output: &[u8]) {
        let chunk: Arc<[u8]> = Arc::from(output);
        let mut state = self.lock();
        state.history.record(output);
        state
            .subscribers
            .retain(|subscriber| subscriber.push(&chunk));
    }

    fn end(&self) {
        let mut state = self.lock();
        state.ended = true;
        for subscriber in state.subscribers.drain(..) {
            subscriber.end();
        }
    }

    fn lock(&self) -> MutexGuard<'_, OutputState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn run(&self, reader: OwnedFd) {
        let fd = reader.as_raw_fd();
        let mut buffer = vec![0_u8; READ_BUFFER_BYTES];
        let mut sequence = 0_u64;
        let mut total = 0_u64;
        let reason = loop {
            if self.stopped.load(Ordering::Relaxed) {
                break "stopped";
            }
            match wait_readable(fd, STOP_POLL_INTERVAL_MILLIS) {
                Ok(false) => continue,
                Ok(true) => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break "poll_failed",
            }
            // SAFETY: buffer is writable for its length and fd is owned by this pump.
            let count = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
            if count > 0 {
                let output = &buffer[..count as usize];
                total = total.saturating_add(output.len() as u64);
                self.record(output);
                if let Some(binding) = self.binding.get() {
                    binding.sink.publish_terminal_output(
                        binding.session_id,
                        binding.shell_id,
                        sequence,
                        output,
                    );
                    sequence = sequence.saturating_add(1);
                }
                continue;
            }
            if count == 0 {
                break "eof";
            }
            let error = io::Error::last_os_error();
            match error.kind() {
                // Another holder may have set O_NONBLOCK on the shared file description.
                io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock => continue,
                // macOS reports a hung-up PTY master as EIO once every slave is closed.
                _ if error.raw_os_error() == Some(libc::EIO) => break "eof",
                _ => break "read_failed",
            }
        };
        self.end();
        drop(reader);
        if let Some(binding) = self.binding.get() {
            log::debug!(
                "event=terminal.output_ended session_id={} shell_id={} reason={} bytes={}",
                binding.session_id.0,
                binding.shell_id.0,
                reason,
                total
            );
        }
    }
}

fn wait_readable(fd: RawFd, timeout_millis: libc::c_int) -> io::Result<bool> {
    let mut descriptor = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: descriptor points to one initialized pollfd for a live descriptor.
    let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_millis) };
    match ready {
        -1 => Err(io::Error::last_os_error()),
        0 => Ok(false),
        // POLLHUP/POLLERR also mean "read now": read reports EOF or the error.
        _ => Ok(true),
    }
}

/// One attachment's view of a shell's output.
pub(crate) struct OutputSubscriber {
    queue: Mutex<SubscriberQueue>,
    ready: Condvar,
    overflow_shutdown: Option<OwnedFd>,
}

struct SubscriberQueue {
    chunks: VecDeque<Arc<[u8]>>,
    bytes: usize,
    status: SubscriberStatus,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SubscriberStatus {
    Live,
    Ended,
    Overflowed,
    Detached,
}

#[derive(Debug)]
pub(crate) enum NextOutput {
    Chunks(Vec<Arc<[u8]>>),
    /// Nothing arrived within the timeout; the caller should check its peer and wait again.
    Idle,
    /// The shell's PTY reached end of file and every queued chunk was delivered.
    Ended,
    /// The subscriber fell too far behind and must reattach to resynchronize.
    Overflowed,
    Detached,
}

impl OutputSubscriber {
    fn new(overflow_shutdown: Option<OwnedFd>, ended: bool) -> Self {
        Self {
            queue: Mutex::new(SubscriberQueue {
                chunks: VecDeque::new(),
                bytes: 0,
                status: if ended {
                    SubscriberStatus::Ended
                } else {
                    SubscriberStatus::Live
                },
            }),
            ready: Condvar::new(),
            overflow_shutdown,
        }
    }

    fn lock(&self) -> MutexGuard<'_, SubscriberQueue> {
        self.queue
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Returns false once this subscriber should be dropped from the fan-out list.
    fn push(&self, chunk: &Arc<[u8]>) -> bool {
        let mut queue = self.lock();
        if queue.status != SubscriberStatus::Live {
            return false;
        }
        if queue.bytes.saturating_add(chunk.len()) > MAX_SUBSCRIBER_BACKLOG_BYTES {
            queue.status = SubscriberStatus::Overflowed;
            queue.chunks.clear();
            queue.bytes = 0;
            drop(queue);
            if let Some(socket) = &self.overflow_shutdown {
                // SAFETY: shutdown only changes the state of this live socket.
                unsafe { libc::shutdown(socket.as_raw_fd(), libc::SHUT_RDWR) };
            }
            self.ready.notify_all();
            return false;
        }
        queue.bytes += chunk.len();
        queue.chunks.push_back(Arc::clone(chunk));
        drop(queue);
        self.ready.notify_all();
        true
    }

    fn end(&self) {
        let mut queue = self.lock();
        if queue.status == SubscriberStatus::Live {
            queue.status = SubscriberStatus::Ended;
        }
        drop(queue);
        self.ready.notify_all();
    }

    /// Stops delivery; the hub drops this subscriber on its next chunk.
    pub(crate) fn detach(&self) {
        let mut queue = self.lock();
        queue.status = SubscriberStatus::Detached;
        queue.chunks.clear();
        queue.bytes = 0;
        drop(queue);
        self.ready.notify_all();
    }

    /// Takes every queued chunk, waiting up to `timeout` for the first one.
    pub(crate) fn next(&self, timeout: Duration) -> NextOutput {
        let mut queue = self.lock();
        if queue.chunks.is_empty() && queue.status == SubscriberStatus::Live {
            queue = self
                .ready
                .wait_timeout_while(queue, timeout, |queue| {
                    queue.chunks.is_empty() && queue.status == SubscriberStatus::Live
                })
                .map(|(queue, _)| queue)
                .unwrap_or_else(|poisoned| poisoned.into_inner().0);
        }
        match queue.status {
            SubscriberStatus::Overflowed => return NextOutput::Overflowed,
            SubscriberStatus::Detached => return NextOutput::Detached,
            SubscriberStatus::Live | SubscriberStatus::Ended => {}
        }
        if !queue.chunks.is_empty() {
            queue.bytes = 0;
            return NextOutput::Chunks(queue.chunks.drain(..).collect());
        }
        if queue.status == SubscriberStatus::Ended {
            NextOutput::Ended
        } else {
            NextOutput::Idle
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU64;
    use std::time::Instant;

    #[test]
    fn history_replays_only_complete_streams() {
        let mut history = TerminalOutputHistory::new();
        history.record(b"hello");
        assert_eq!(history.replay(), b"hello");
        history.record(&vec![b'x'; MAX_TERMINAL_OUTPUT_HISTORY_BYTES]);
        assert!(history.replay().is_empty());
        history.record(b"later");
        assert!(history.replay().is_empty());
    }

    #[test]
    fn subscribers_get_replay_then_exactly_the_live_stream() {
        let output = TerminalOutput::detached_for_tests();
        output.record(b"before ");
        let (replay, subscriber) = output.subscribe(None);
        output.record(b"after");
        assert_eq!(replay, b"before ");
        let NextOutput::Chunks(chunks) = subscriber.next(Duration::from_millis(10)) else {
            panic!("expected live output");
        };
        assert_eq!(chunks.concat(), b"after");
        assert!(matches!(
            subscriber.next(Duration::from_millis(1)),
            NextOutput::Idle
        ));
    }

    #[test]
    fn every_subscriber_sees_the_same_stream() {
        let output = TerminalOutput::detached_for_tests();
        let subscribers: Vec<_> = (0..8).map(|_| output.subscribe(None).1).collect();
        output.record(b"one");
        output.record(b"two");
        for subscriber in &subscribers {
            let NextOutput::Chunks(chunks) = subscriber.next(Duration::from_millis(10)) else {
                panic!("expected output");
            };
            assert_eq!(chunks.concat(), b"onetwo");
        }
    }

    #[test]
    fn a_stalled_subscriber_is_disconnected_without_slowing_others() {
        let output = TerminalOutput::detached_for_tests();
        let (_, stalled) = output.subscribe(None);
        let (_, active) = output.subscribe(None);
        let chunk = vec![b'x'; 64 * 1024];
        let started = Instant::now();
        for _ in 0..(MAX_SUBSCRIBER_BACKLOG_BYTES / chunk.len() + 1) {
            output.record(&chunk);
            let _ = active.next(Duration::ZERO);
        }
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(matches!(
            stalled.next(Duration::ZERO),
            NextOutput::Overflowed
        ));
        assert_eq!(output.subscriber_count(), 1);
    }

    #[test]
    fn ended_output_drains_queued_chunks_before_reporting_end() {
        let output = TerminalOutput::detached_for_tests();
        let (_, subscriber) = output.subscribe(None);
        output.record(b"last words");
        output.end();
        let NextOutput::Chunks(chunks) = subscriber.next(Duration::ZERO) else {
            panic!("expected queued output");
        };
        assert_eq!(chunks.concat(), b"last words");
        assert!(matches!(subscriber.next(Duration::ZERO), NextOutput::Ended));
        let (_, late) = output.subscribe(None);
        assert!(matches!(late.next(Duration::ZERO), NextOutput::Ended));
    }

    struct CountingSink(AtomicU64);

    impl TerminalOutputSink for CountingSink {
        fn publish_terminal_output(&self, _: SessionId, _: ShellId, _: u64, output: &[u8]) {
            self.0.fetch_add(output.len() as u64, Ordering::Relaxed);
        }
    }

    #[test]
    fn the_pump_drains_a_pty_with_no_attachment_and_ends_on_hangup() {
        let mut master: RawFd = -1;
        let mut slave: RawFd = -1;
        // SAFETY: openpty initializes both descriptors on success.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0);
        // SAFETY: openpty returned owned descriptors.
        let master = unsafe { OwnedFd::from_raw_fd(master) };
        // SAFETY: openpty returned owned descriptors.
        let slave = unsafe { OwnedFd::from_raw_fd(slave) };
        let output = TerminalOutput::start(&master).unwrap();
        let sink = Arc::new(CountingSink(AtomicU64::new(0)));
        output.bind(SessionId(1), ShellId(2), sink.clone());
        let (_, subscriber) = output.subscribe(None);

        // Far more than a PTY buffer holds: this blocks forever unless something drains it.
        let payload = vec![b'y'; 1024 * 1024];
        let mut written = 0;
        while written < payload.len() {
            // SAFETY: payload is readable for the remaining length; slave is open.
            let count = unsafe {
                libc::write(
                    slave.as_raw_fd(),
                    payload[written..].as_ptr().cast(),
                    payload.len() - written,
                )
            };
            assert!(count > 0, "{}", io::Error::last_os_error());
            written += count as usize;
        }
        drop(slave);

        let mut received = 0;
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            assert!(Instant::now() < deadline, "pump did not end");
            match subscriber.next(Duration::from_millis(100)) {
                NextOutput::Chunks(chunks) => {
                    received += chunks.iter().map(|c| c.len()).sum::<usize>()
                }
                NextOutput::Ended => break,
                NextOutput::Idle => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        // The PTY line discipline may expand bytes (no ONLCR here), so compare at least.
        assert!(received >= payload.len());
        assert!(sink.0.load(Ordering::Relaxed) >= payload.len() as u64);
        drop(master);
    }
}
