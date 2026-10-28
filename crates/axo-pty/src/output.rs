//! Axod is the single, permanent reader of every PTY it owns.
//!
//! Each shell gets one pump thread from the moment it is spawned until its PTY reaches end of
//! file. The pump feeds every byte into the shell's headless terminal (its `TerminalScreen`),
//! publishes `terminal.output` events, and fans raw bytes out to every attached client. A shell therefore never blocks on a full PTY buffer because no
//! client is attached, and any number of clients (Mac windows, the web relay, the CLI) can watch
//! the same shell.
//!
//! Invariants:
//! - Only the pump reads the PTY master. Attached clients receive the master descriptor for
//!   input, resizing, and termios/foreground queries only.
//! - The pump never blocks on a client. Each subscriber has a bounded backlog; a subscriber that
//!   falls `MAX_SUBSCRIBER_BACKLOG_BYTES` behind is disconnected and must reattach (replay).
//! - Subscribing is atomic with respect to recording: a terminal that parses a subscriber's
//!   replay and then its live chunks reaches exactly the state of one that parsed the whole PTY
//!   stream, with no gap and no duplicate.

use std::collections::VecDeque;
use std::fmt;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

use crate::process::{self, WindowSize};

/// The largest replay an attachment announces; see `TerminalScreen::replay`.
pub const MAX_TERMINAL_REPLAY_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_SUBSCRIBER_BACKLOG_BYTES: usize = 8 * 1024 * 1024;
/// History each PTY's headless terminal keeps, in libghostty-vt page memory. A replay of it is
/// usually far smaller; `TerminalScreen::replay` sheds history if one would still be too large.
const SCREEN_SCROLLBACK_MAX_BYTES: usize = 4 * 1024 * 1024;
const READ_BUFFER_BYTES: usize = 64 * 1024;
/// How often an idle pump rechecks whether its shell was removed from the catalog. Shell exit is
/// observed immediately as end of file; this only bounds descriptor retention after a close.
const STOP_POLL_INTERVAL_MILLIS: libc::c_int = 250;

/// The screen a PTY's program has drawn, kept by a headless terminal fed every byte it writes.
///
/// Attaching clients receive a snapshot of this screen instead of the PTY's byte history, so a
/// new client sees what an always-attached terminal would show, however long the program has
/// run: the modes it set once at startup (alternate screen, mouse reporting, bracketed paste,
/// keyboard protocol), its current contents and scrollback, and its cursor. A full-screen
/// program such as Pi would otherwise come back blank and ignore the mouse until it repaints.
struct TerminalScreen {
    /// `None` only if libghostty-vt could not create a terminal; replays are then empty.
    terminal: Option<axo_vt::Terminal>,
    scrollback_max_bytes: usize,
}

impl TerminalScreen {
    fn new(size: WindowSize) -> Self {
        let terminal = axo_vt::Terminal::new(grid_size(size), SCREEN_SCROLLBACK_MAX_BYTES)
            .inspect_err(|error| log::error!("event=terminal.screen_unavailable error={error}"))
            .ok();
        Self {
            terminal,
            scrollback_max_bytes: SCREEN_SCROLLBACK_MAX_BYTES,
        }
    }

    fn write(&mut self, output: &[u8]) {
        if let Some(terminal) = &mut self.terminal {
            terminal.write(output);
        }
    }

    /// Follows the PTY's size, which clients also change directly through their descriptor.
    fn resize(&mut self, size: WindowSize) {
        let Some(terminal) = &mut self.terminal else {
            return;
        };
        if let Some(size) = axo_vt::GridSize::new(size.columns(), size.rows())
            && let Err(error) = terminal.resize(size)
        {
            log::warn!("event=terminal.screen_resize_failed error={error}");
        }
    }

    /// VT bytes that rebuild this screen in a fresh terminal of the same size, then resume any
    /// escape sequence the program is midway through, so its next bytes continue seamlessly.
    /// A replay larger than `MAX_TERMINAL_REPLAY_BYTES` sheds the oldest history until it fits.
    fn replay(&mut self) -> Vec<u8> {
        self.replay_within(MAX_TERMINAL_REPLAY_BYTES)
    }

    fn replay_within(&mut self, max_bytes: usize) -> Vec<u8> {
        let Some(terminal) = &mut self.terminal else {
            return Vec::new();
        };
        loop {
            match terminal.snapshot() {
                Ok(replay) if replay.len() <= max_bytes => return replay,
                Ok(replay) if self.scrollback_max_bytes > 0 => {
                    self.scrollback_max_bytes /= 2;
                    log::info!(
                        "event=terminal.screen_history_shed replay_bytes={} scrollback_max_bytes={}",
                        replay.len(),
                        self.scrollback_max_bytes
                    );
                    if let Err(error) = terminal.set_scrollback_max_bytes(self.scrollback_max_bytes)
                    {
                        log::warn!("event=terminal.screen_replay_failed error={error}");
                        return Vec::new();
                    }
                }
                Ok(replay) => {
                    log::warn!(
                        "event=terminal.screen_replay_too_large replay_bytes={}",
                        replay.len()
                    );
                    return Vec::new();
                }
                Err(error) => {
                    log::warn!("event=terminal.screen_replay_failed error={error}");
                    return Vec::new();
                }
            }
        }
    }
}

/// A PTY reports 0x0 until someone sizes it; the emulator needs a real grid.
fn grid_size(size: WindowSize) -> axo_vt::GridSize {
    axo_vt::GridSize::new(size.columns(), size.rows()).unwrap_or_else(|| {
        let default = WindowSize::DEFAULT;
        axo_vt::GridSize::new(default.columns(), default.rows()).expect("the default is sized")
    })
}

/// Where a shell's output is published once its owner knows its identity.
pub trait TerminalOutputSink: Send + Sync {
    /// `sequence` counts published chunks from zero.
    fn publish_terminal_output(&self, sequence: u64, output: &[u8]);
}

struct OutputBinding {
    /// Identifies the PTY in logs, e.g. `session_id=1 shell_id=2`.
    label: String,
    sink: Arc<dyn TerminalOutputSink>,
}

/// Shared between a shell's pump, its `RunningShell`, and its attachments.
pub struct TerminalOutput {
    state: Mutex<OutputState>,
    binding: OnceLock<OutputBinding>,
    stopped: AtomicBool,
}

struct OutputState {
    screen: TerminalScreen,
    ended: bool,
    subscribers: Vec<Arc<OutputSubscriber>>,
}

impl fmt::Debug for TerminalOutput {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = self.lock();
        formatter
            .debug_struct("TerminalOutput")
            .field("screen", &state.screen.terminal.as_ref().map(|t| t.size()))
            .field("ended", &state.ended)
            .field("subscribers", &state.subscribers.len())
            .finish()
    }
}

impl TerminalOutput {
    fn new(size: WindowSize) -> Self {
        Self {
            state: Mutex::new(OutputState {
                screen: TerminalScreen::new(size),
                ended: false,
                subscribers: Vec::new(),
            }),
            binding: OnceLock::new(),
            stopped: AtomicBool::new(false),
        }
    }

    /// Starts draining `master` immediately. Output before `bind` is recorded for replay but not
    /// published, because the shell's catalog identity does not exist yet.
    pub fn start(master: &OwnedFd) -> io::Result<Arc<Self>> {
        // SAFETY: fcntl duplicates a live descriptor; the result is owned below.
        let duplicate = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if duplicate == -1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fcntl returned a new descriptor owned by the pump.
        let reader = unsafe { OwnedFd::from_raw_fd(duplicate) };
        let size = process::window_size(&reader).unwrap_or(WindowSize::DEFAULT);
        let output = Arc::new(Self::new(size));
        let pump = Arc::clone(&output);
        thread::Builder::new()
            .name("axo-pty-output".into())
            .spawn(move || pump.run(reader))?;
        Ok(output)
    }

    /// An output with no pump, fed by `record`; for tests in dependent crates.
    #[doc(hidden)]
    pub fn detached_for_tests() -> Arc<Self> {
        Arc::new(Self::new(WindowSize::DEFAULT))
    }

    /// Attaches the owner's identity; later output is published to `sink`. Idempotent.
    pub fn bind(&self, label: String, sink: Arc<dyn TerminalOutputSink>) {
        let _ = self.binding.set(OutputBinding { label, sink });
    }

    /// Stops the pump within `STOP_POLL_INTERVAL_MILLIS` and releases its descriptor. Attached
    /// clients drain what was already queued and then see end of file.
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
    }

    /// Registers a subscriber and returns the replay it must write first: a snapshot of the
    /// screen, taken at `size` when given (the PTY's size now; a client may have resized it
    /// since the last output). `overflow_shutdown`, when given, is shut down if the subscriber
    /// overflows, so a writer blocked on a stalled client wakes up.
    pub fn subscribe(
        &self,
        size: Option<WindowSize>,
        overflow_shutdown: Option<OwnedFd>,
    ) -> (Vec<u8>, Arc<OutputSubscriber>) {
        let mut state = self.lock();
        if let Some(size) = size {
            state.screen.resize(size);
        }
        let subscriber = Arc::new(OutputSubscriber::new(overflow_shutdown, state.ended));
        if !state.ended {
            state.subscribers.push(Arc::clone(&subscriber));
        }
        (state.screen.replay(), subscriber)
    }

    /// The screen and its scrollback as plain text; empty if the headless terminal is missing.
    pub fn screen_text(&self) -> String {
        let mut state = self.lock();
        let Some(terminal) = &mut state.screen.terminal else {
            return String::new();
        };
        terminal.plain_text().unwrap_or_else(|error| {
            log::warn!("event=terminal.screen_text_failed error={error}");
            String::new()
        })
    }

    /// How many clients are attached; for diagnostics and tests.
    pub fn subscriber_count(&self) -> usize {
        self.lock().subscribers.len()
    }

    /// Records one chunk and fans it out. Exposed for tests; the pump is the only production caller.
    pub fn record(&self, output: &[u8]) {
        self.record_at(None, output);
    }

    /// Records one chunk the program wrote while its PTY had `size`.
    fn record_at(&self, size: Option<WindowSize>, output: &[u8]) {
        let chunk: Arc<[u8]> = Arc::from(output);
        let mut state = self.lock();
        if let Some(size) = size {
            state.screen.resize(size);
        }
        state.screen.write(output);
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
                // Output after a resize is drawn for the new grid, so the screen must have it
                // first. One ioctl per chunk; clients resize through their own descriptor.
                self.record_at(process::window_size(&reader).ok(), output);
                if let Some(binding) = self.binding.get() {
                    binding.sink.publish_terminal_output(sequence, output);
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
                "event=terminal.output_ended {} reason={} bytes={}",
                binding.label,
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
pub struct OutputSubscriber {
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
pub enum NextOutput {
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
    pub fn detach(&self) {
        let mut queue = self.lock();
        queue.status = SubscriberStatus::Detached;
        queue.chunks.clear();
        queue.bytes = 0;
        drop(queue);
        self.ready.notify_all();
    }

    /// Takes every queued chunk, waiting up to `timeout` for the first one.
    pub fn next(&self, timeout: Duration) -> NextOutput {
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

    /// What a client terminal of `size` shows after parsing `stream`.
    fn parsed(size: WindowSize, stream: &[u8]) -> String {
        let mut terminal =
            axo_vt::Terminal::new(grid_size(size), SCREEN_SCROLLBACK_MAX_BYTES).unwrap();
        terminal.write(stream);
        String::from_utf8_lossy(&terminal.snapshot().unwrap()).into_owned()
    }

    fn contains(haystack: &[u8], needle: &str) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle.as_bytes())
    }

    fn live(subscriber: &OutputSubscriber) -> Vec<u8> {
        let NextOutput::Chunks(chunks) = subscriber.next(Duration::from_millis(10)) else {
            panic!("expected live output");
        };
        chunks.concat()
    }

    #[test]
    fn screen_text_is_plain() {
        let output = TerminalOutput::detached_for_tests();
        output.record(b"\x1b[31m$ cargo test\x1b[0m\r\nok\r\n");
        assert_eq!(output.screen_text(), "$ cargo test\nok");
    }

    #[test]
    fn subscribers_get_replay_then_exactly_the_live_stream() {
        let output = TerminalOutput::detached_for_tests();
        output.record(b"before \x1b[3");
        let (replay, subscriber) = output.subscribe(None, None);
        output.record(b"1mafter");
        let live = live(&subscriber);
        assert_eq!(live, b"1mafter", "live output is the raw PTY stream");
        assert!(matches!(
            subscriber.next(Duration::from_millis(1)),
            NextOutput::Idle
        ));
        // The replay ends inside the same escape sequence, so the live bytes complete it.
        let size = WindowSize::DEFAULT;
        assert_eq!(
            parsed(size, &[replay, live].concat()),
            parsed(size, b"before \x1b[31mafter")
        );
    }

    #[test]
    fn replay_restores_what_a_full_screen_program_set_up_long_ago() {
        let output = TerminalOutput::detached_for_tests();
        // Pi's fullscreen TUI sets its modes once at startup, then only redraws.
        output.record(b"\x1b[?1049h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[2J");
        // Far more redraw output than the old byte history kept.
        let frame = b"\x1b[H\x1b[2Kworking...\r\n".repeat(1024);
        for _ in 0..(2 * MAX_TERMINAL_REPLAY_BYTES / frame.len()) {
            output.record(&frame);
        }
        output.record(b"\x1b[H\x1b[2KPi transcript");
        let (replay, _subscriber) = output.subscribe(None, None);
        assert!(
            replay.len() < MAX_TERMINAL_REPLAY_BYTES / 64,
            "{} bytes",
            replay.len()
        );
        for mode in [
            "\x1b[?1049h",
            "\x1b[?1000h",
            "\x1b[?1003h",
            "\x1b[?1006h",
            "\x1b[?2004h",
        ] {
            assert!(contains(&replay, mode), "replay must restore {mode:?}");
        }
        assert!(contains(&replay, "Pi transcript"));
    }

    #[test]
    fn replay_is_taken_at_the_size_the_pty_has_now() {
        let output = TerminalOutput::detached_for_tests();
        output.record(&b"x".repeat(100));
        let wide = WindowSize::new(24, 120).unwrap();
        let (replay, _subscriber) = output.subscribe(Some(wide), None);
        assert!(
            contains(&replay, &"x".repeat(100)),
            "reflowed onto one 120-column row"
        );
        assert_eq!(parsed(wide, &replay), parsed(wide, &b"x".repeat(100)));
    }

    #[test]
    fn an_oversized_replay_sheds_history_instead_of_disappearing() {
        let mut screen = TerminalScreen::new(WindowSize::DEFAULT);
        for line in 0..5_000 {
            screen.write(format!("\x1b[31mhistory line {line}\r\n").as_bytes());
        }
        screen.write(b"\x1b[0mthe end");
        let max_bytes = 16 * 1024;
        let replay = screen.replay_within(max_bytes);
        assert!(
            !replay.is_empty() && replay.len() <= max_bytes,
            "{} bytes",
            replay.len()
        );
        assert!(contains(&replay, "the end"));
        assert!(
            !contains(&replay, "history line 0\r\n"),
            "the oldest history went first"
        );
        assert!(screen.scrollback_max_bytes < SCREEN_SCROLLBACK_MAX_BYTES);
    }

    #[test]
    fn every_subscriber_sees_the_same_stream() {
        let output = TerminalOutput::detached_for_tests();
        let subscribers: Vec<_> = (0..8).map(|_| output.subscribe(None, None).1).collect();
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
        let (_, stalled) = output.subscribe(None, None);
        let (_, active) = output.subscribe(None, None);
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
        let (_, subscriber) = output.subscribe(None, None);
        output.record(b"last words");
        output.end();
        let NextOutput::Chunks(chunks) = subscriber.next(Duration::ZERO) else {
            panic!("expected queued output");
        };
        assert_eq!(chunks.concat(), b"last words");
        assert!(matches!(subscriber.next(Duration::ZERO), NextOutput::Ended));
        let (_, late) = output.subscribe(None, None);
        assert!(matches!(late.next(Duration::ZERO), NextOutput::Ended));
    }

    struct CountingSink(AtomicU64);

    impl TerminalOutputSink for CountingSink {
        fn publish_terminal_output(&self, _: u64, output: &[u8]) {
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
        output.bind("test".to_owned(), sink.clone());
        let (_, subscriber) = output.subscribe(None, None);

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
