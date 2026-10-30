//! Terminal I/O: the attach socket and its connections, input, resize and the busy check.

use std::fs;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use std::thread;
use std::time::{Duration, Instant};

use super::SessionManager;
use axo_panes::RuntimeId;
use axo_protocol::rpc;
use axo_protocol::{GridSize, PaneRole, SessionId, ShellActivity, ShellId};
use axo_pty::process;
use axo_pty::{NextOutput, OutputSubscriber, TerminalOutput, WindowSize, attach};

const ATTACH_STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);

pub(super) const MAX_CONCURRENT_TERMINAL_ATTACHMENTS: usize = 256;

/// A client that cannot take its replay this fast is stalled; it can reattach.
const ATTACH_REPLAY_WRITE_TIMEOUT: Duration = Duration::from_secs(2);

/// Live writes tolerate a briefly busy UI; the backlog cap handles slower clients.
const ATTACH_LIVE_WRITE_TIMEOUT: Duration = Duration::from_secs(10);

const ATTACH_SEND_BUFFER_BYTES: libc::c_int = 256 * 1024;

pub(super) const TERMINAL_INPUT_WRITE_TIMEOUT: Duration = Duration::from_secs(5);

pub(super) struct AttachmentPermit(pub(super) Arc<AtomicUsize>);

impl AttachmentPermit {
    pub(super) fn try_acquire(active: Arc<AtomicUsize>) -> Option<Self> {
        let mut current = active.load(Ordering::Relaxed);
        loop {
            if current >= MAX_CONCURRENT_TERMINAL_ATTACHMENTS {
                return None;
            }
            match active.compare_exchange_weak(
                current,
                current + 1,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Some(Self(active)),
                Err(actual) => current = actual,
            }
        }
    }
}

impl Drop for AttachmentPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

pub(super) fn window_size(grid: GridSize) -> WindowSize {
    // A grid is at least 1x1 and fits u16, so this always succeeds.
    WindowSize::new(u32::from(grid.rows()), u32::from(grid.columns()))
        .unwrap_or(WindowSize::DEFAULT)
}

#[cfg(target_vendor = "apple")]
fn process_name(process_id: libc::pid_t) -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is writable for its full length; proc_name NUL-terminates within it.
    let length =
        unsafe { libc::proc_name(process_id, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if length <= 0 {
        return None;
    }
    let name = String::from_utf8_lossy(&buffer[..length as usize]).into_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(not(target_vendor = "apple"))]
fn process_name(_process_id: libc::pid_t) -> Option<String> {
    None
}

/// Waits until `descriptor` is readable or `timeout` passes. Errors count as readable so the
/// caller's own call reports them.
fn wait_until_readable(descriptor: RawFd, timeout: Duration) -> bool {
    let mut poll_descriptor = libc::pollfd {
        fd: descriptor,
        events: libc::POLLIN,
        revents: 0,
    };
    let timeout_millis = timeout.as_millis().clamp(1, libc::c_int::MAX as u128) as libc::c_int;
    // SAFETY: poll reads one initialized pollfd for the duration of the call.
    let ready = unsafe { libc::poll(&mut poll_descriptor, 1, timeout_millis) };
    ready != 0
}

pub(super) struct ShellAttachment {
    master: OwnedFd,
    output: Arc<TerminalOutput>,
    session_id: SessionId,
    pub(super) runtime_id: RuntimeId,
    first: bool,
}

/// Detaches the subscriber when the attachment worker exits for any reason.
struct OutputSubscription(pub(super) Arc<OutputSubscriber>);

impl Drop for OutputSubscription {
    fn drop(&mut self) {
        self.0.detach();
    }
}

pub(super) struct TerminalAttachmentLease<'a> {
    pub(super) manager: &'a SessionManager,
    pub(super) shell_id: ShellId,
    pub(super) runtime_id: RuntimeId,
}

impl Drop for TerminalAttachmentLease<'_> {
    fn drop(&mut self) {
        self.manager.mark_detached(self.shell_id, self.runtime_id);
    }
}

/// Maps why `attach_shell` failed to the attach protocol's rejection codes.
fn attach_rejection(error: &io::Error) -> attach::Rejection {
    match error.kind() {
        io::ErrorKind::NotFound => attach::Rejection::ShellNotOpen,
        io::ErrorKind::WouldBlock => attach::Rejection::DaemonBusy,
        _ => attach::Rejection::Other,
    }
}

/// Serves one attachment (see `axo_pty::attach` for the protocol): registers it with the shell,
/// subscribes to the shell's output, then streams replay and live output until either side ends.
pub(super) fn handle_attachment(
    mut stream: UnixStream,
    manager: Weak<SessionManager>,
    _permit: AttachmentPermit,
) {
    let started_at = Instant::now();
    // Accepted sockets can inherit nonblocking mode on macOS. Use bounded blocking I/O; any
    // failed write ends the attachment, so a partial write can never corrupt a live stream.
    if stream
        .set_nonblocking(false)
        .and_then(|()| stream.set_read_timeout(Some(Duration::from_millis(200))))
        .and_then(|()| stream.set_write_timeout(Some(ATTACH_REPLAY_WRITE_TIMEOUT)))
        .is_err()
    {
        log::warn!("event=session.attach_rejected reason=socket_setup");
        return;
    }
    attach::set_send_buffer(&stream, ATTACH_SEND_BUFFER_BYTES);
    let request = attach::read_request(&mut stream).and_then(|id| {
        ShellId::new(id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "shell ID must be positive"))
    });
    let id = match request {
        Ok(id) => id,
        Err(error) => {
            log::debug!(
                "event=session.attach_rejected reason=invalid_request error_kind={:?}",
                error.kind()
            );
            let _ = attach::write_rejection(&mut stream, attach_rejection(&error));
            return;
        }
    };
    let Some(manager) = manager.upgrade() else {
        return;
    };
    let attachment = match manager.attach_shell(id) {
        Ok(attachment) => attachment,
        Err(error) => {
            log::warn!(
                "event=session.attach_rejected shell_id={} error_kind={:?}",
                id.get(),
                error.kind()
            );
            if let Err(write_error) = attach::write_rejection(&mut stream, attach_rejection(&error))
            {
                log::debug!(
                    "event=session.attach_rejection_write_failed shell_id={} error_kind={:?}",
                    id.get(),
                    write_error.kind()
                );
            }
            return;
        }
    };
    let ShellAttachment {
        master,
        output,
        session_id,
        runtime_id,
        first,
    } = attachment;
    let _attachment_lease = TerminalAttachmentLease {
        manager: &manager,
        shell_id: id,
        runtime_id,
    };
    // Subscribe before replying: the replay plus queued chunks are then exactly the PTY stream.
    // The replay is a snapshot of the screen at the PTY's current size, which the client's
    // surface is created at too.
    let overflow_shutdown = stream.try_clone().ok().map(OwnedFd::from);
    let size = axo_pty::process::window_size(&master).ok();
    let (replay, subscriber) = output.subscribe(size, overflow_shutdown);
    let subscription = OutputSubscription(subscriber);
    drop(output);
    if first {
        manager.publish_shell_activity(session_id, id, ShellActivity::Attached);
    }

    let response = attach::write_acceptance(&mut stream, replay.len(), &master)
        .map_err(|(phase, error)| (phase.as_str(), error))
        .and_then(|()| stream.write_all(&replay).map_err(|error| ("replay", error)))
        .and_then(|()| {
            stream
                .set_write_timeout(Some(ATTACH_LIVE_WRITE_TIMEOUT))
                .map_err(|error| ("live_timeout", error))
        });
    drop(master);
    if let Err((phase, error)) = response {
        log::warn!(
            "event=session.attach_failed session_id={} shell_id={} phase={} replay_bytes={} elapsed_ms={} error_kind={:?}",
            session_id,
            id.get(),
            phase,
            replay.len(),
            started_at.elapsed().as_millis(),
            error.kind()
        );
        return;
    }
    log::info!(
        "event=session.attach_ready session_id={} shell_id={} replay_bytes={} elapsed_ms={}",
        session_id,
        id.get(),
        replay.len(),
        started_at.elapsed().as_millis()
    );
    drop(replay);

    let mut delivered = 0_u64;
    let reason = 'stream: loop {
        if manager.stop_workers.load(Ordering::Relaxed) {
            break "shutdown";
        }
        match subscription.0.next(ATTACH_STOP_POLL_INTERVAL) {
            NextOutput::Chunks(chunks) => {
                for chunk in chunks {
                    if stream.write_all(&chunk).is_err() {
                        break 'stream "client_write_failed";
                    }
                    delivered = delivered.saturating_add(chunk.len() as u64);
                }
            }
            NextOutput::Idle => {
                if attach::peer_closed(&mut stream) {
                    break "client_closed";
                }
            }
            NextOutput::Ended => break "shell_output_ended",
            NextOutput::Overflowed => break "client_overflowed",
            NextOutput::Detached => break "detached",
        }
    };
    let _ = stream.shutdown(std::net::Shutdown::Both);
    let level = if reason == "client_overflowed" {
        log::Level::Warn
    } else {
        log::Level::Info
    };
    log::log!(
        level,
        "event=session.attach_ended session_id={} shell_id={} reason={} bytes={} elapsed_ms={}",
        session_id,
        id.get(),
        reason,
        delivered,
        started_at.elapsed().as_millis()
    );
}

impl SessionManager {
    pub(super) fn start_attachment_listener(self: &Arc<Self>) -> io::Result<()> {
        let socket_path = &self.attach_socket_path;
        crate::SocketPath::parse(socket_path.clone())
            .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))?;
        crate::remove_stale_socket(socket_path)?;

        let listener = UnixListener::bind(socket_path)?;
        fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;

        let manager = Arc::downgrade(self);
        let active_attachments = Arc::new(AtomicUsize::new(0));
        let stop_workers = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name("axo-pty-attachments".into())
            .spawn(move || {
                while !stop_workers.load(Ordering::Relaxed) {
                    // Wake as soon as a client connects; the timeout only bounds the stop check.
                    if !wait_until_readable(listener.as_raw_fd(), ATTACH_STOP_POLL_INTERVAL) {
                        continue;
                    }
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            let Some(permit) =
                                AttachmentPermit::try_acquire(Arc::clone(&active_attachments))
                            else {
                                log::warn!("event=session.attach_rejected reason=capacity");
                                let _ = attach::write_rejection(&mut stream, attach::Rejection::DaemonBusy);
                                continue;
                            };
                            let mut rejection_stream = match stream.try_clone() {
                                Ok(stream) => stream,
                                Err(error) => {
                                    log::error!(
                                        "event=session.attach_worker_start_failed phase=clone_socket error_kind={:?}",
                                        error.kind()
                                    );
                                    let _ = attach::write_rejection(&mut stream, attach::Rejection::Other);
                                    continue;
                                }
                            };
                            let manager = manager.clone();
                            if let Err(error) = thread::Builder::new()
                                .name("axo-pty-attachment".into())
                                .spawn(move || handle_attachment(stream, manager, permit))
                            {
                                log::error!(
                                    "event=session.attach_worker_start_failed phase=spawn error_kind={:?}",
                                    error.kind()
                                );
                                let _ = attach::write_rejection(&mut rejection_stream, attach::Rejection::DaemonBusy);
                            }
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                        Err(_) => thread::sleep(Duration::from_millis(50)),
                    }
                }
            })?;
        self.workers
            .lock()
            .map_err(|_| io::Error::other("session worker lock was poisoned"))?
            .push(worker);
        Ok(())
    }

    pub(super) fn write_terminal_input(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        encoded_input: &str,
    ) -> io::Result<()> {
        let input = axo_protocol::base64::decode_terminal_input(encoded_input)?;
        if input.is_empty() || input.len() > 49_152 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal input must contain 1 to 49152 bytes",
            ));
        }
        let mut state = self.lock_state()?;
        let running = state
            .panes
            .running_in_mut(session_id, shell_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        if running.last_input_sequence == Some(sequence) {
            return Ok(());
        }
        let expected_sequence = running
            .last_input_sequence
            .map_or(Some(0), |last| last.checked_add(1))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "terminal input sequence exhausted",
                )
            })?;
        if sequence != expected_sequence {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal input sequence is out of order",
            ));
        }
        process::write_all(
            running.master.as_raw_fd(),
            &input,
            TERMINAL_INPUT_WRITE_TIMEOUT,
        )?;
        running.last_input_sequence = Some(sequence);
        if running.role == PaneRole::Pi {
            // A person is talking to this Pi: any chain of agent prompts ends here.
            state.prompt_provenance.reset(session_id);
        }
        Ok(())
    }

    /// Presses one key in the Session's Pi pane, as a person at the Mac would: Escape stops a reply
    /// or declines a question, Enter accepts one. A Pi still starting has nothing to stop or
    /// answer, so the key is not queued like a prompt.
    pub(super) fn press_pi_key(
        &self,
        session_id: SessionId,
        key: axo_relay::PiKey,
    ) -> io::Result<()> {
        let mut state = self.lock_state()?;
        let pi_shell = state
            .panes
            .in_session(session_id)
            .find_map(|(id, pane)| match pane {
                axo_panes::Pane::Running(shell) if shell.role == PaneRole::Pi => Some(id),
                _ => None,
            })
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi is not running"))?;
        let running = state
            .panes
            .running_in_mut(session_id, pi_shell)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi is not running"))?;
        let bytes: &[u8] = match key {
            axo_relay::PiKey::Escape => b"\x1b",
            axo_relay::PiKey::Enter => b"\r",
        };
        log::info!(
            "event=session.pi_key_pressed session_id={} key={key:?}",
            session_id
        );
        process::write_all(
            running.master.as_raw_fd(),
            bytes,
            TERMINAL_INPUT_WRITE_TIMEOUT,
        )
    }

    /// Types `text` into a pane as a keyboard would, outside its input sequence: for agents
    /// driving panes (RFD0015). Control characters act as keys.
    pub(super) fn write_terminal_text(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        text: &str,
    ) -> io::Result<()> {
        if text.is_empty() || text.len() > 49_152 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal text must contain 1 to 49152 bytes",
            ));
        }
        let state = self.lock_state()?;
        let running = state
            .panes
            .running_in(session_id, shell_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        log::info!(
            "event=terminal.write session_id={} shell_id={} bytes={}",
            session_id,
            shell_id.get(),
            text.len()
        );
        process::write_all(
            running.master.as_raw_fd(),
            text.as_bytes(),
            TERMINAL_INPUT_WRITE_TIMEOUT,
        )
    }

    /// The last `lines` lines of a pane's screen and scrollback as plain text, and whether
    /// earlier lines were left out.
    pub(super) fn terminal_screen(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        lines: usize,
    ) -> io::Result<rpc::TerminalScreen> {
        let output = {
            let state = self.lock_state()?;
            let running = state
                .panes
                .running_in(session_id, shell_id)
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
            Arc::clone(&running.output)
        };
        let text = output.screen_text();
        let (text, truncated) = last_lines(&text, lines);
        Ok(rpc::TerminalScreen {
            text: text.to_owned(),
            truncated,
        })
    }

    pub(super) fn resize_terminal(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        size: WindowSize,
    ) -> io::Result<()> {
        let state = self.lock_state()?;
        let running = state
            .panes
            .running_in(session_id, shell_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        process::resize(&running.master, &running.child, size)
    }

    pub(super) fn shell_busy(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> io::Result<rpc::ShellBusy> {
        let state = self.lock_state()?;
        let running = state
            .panes
            .running_in(session_id, shell_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        if running.role == PaneRole::Pi {
            let working = state
                .pi_activity
                .get(&session_id)
                .is_some_and(|activity| activity.working);
            return Ok(rpc::ShellBusy {
                busy: working,
                foreground_process: None,
            });
        }
        // SAFETY: the PTY master descriptor stays open while the shell is running.
        let foreground = unsafe { libc::tcgetpgrp(running.master.as_raw_fd()) };
        if foreground == -1 {
            return Err(io::Error::last_os_error());
        }
        let shell_process = running.child.id() as libc::pid_t;
        if foreground == shell_process {
            return Ok(rpc::ShellBusy {
                busy: false,
                foreground_process: None,
            });
        }
        Ok(rpc::ShellBusy {
            busy: true,
            foreground_process: process_name(foreground),
        })
    }

    /// Registers one more attachment and hands out a PTY descriptor for input, resizing, and
    /// termios/foreground queries. Output comes from `TerminalOutput`, never from this descriptor.
    pub(super) fn attach_shell(&self, id: ShellId) -> io::Result<ShellAttachment> {
        let mut state = self.lock_state()?;
        let running = state
            .panes
            .running_mut(id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        // SAFETY: fcntl duplicates the live PTY master; the result is owned below.
        let fd = unsafe { libc::fcntl(running.master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd == -1 {
            return Err(io::Error::last_os_error());
        }
        running.attachments += 1;
        Ok(ShellAttachment {
            // SAFETY: fcntl returned a new, owned descriptor.
            master: unsafe { OwnedFd::from_raw_fd(fd) },
            output: Arc::clone(&running.output),
            session_id: running.session_id,
            runtime_id: running.runtime_id,
            first: running.attachments == 1,
        })
    }

    pub(super) fn mark_detached(&self, id: ShellId, runtime_id: RuntimeId) {
        let session_id = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            let Some(running) = state.panes.running_mut(id) else {
                return;
            };
            if running.runtime_id != runtime_id {
                return;
            }
            running.attachments = running.attachments.saturating_sub(1);
            if running.attachments > 0 {
                return;
            }
            running.session_id
        };
        self.publish_shell_activity(session_id, id, ShellActivity::Detached);
    }
}

/// The last `count` lines of `text`, and whether any came before them.
fn last_lines(text: &str, count: usize) -> (&str, bool) {
    if count == 0 {
        return ("", !text.is_empty());
    }
    match text.rmatch_indices('\n').nth(count - 1) {
        Some((index, _)) => (&text[index + 1..], true),
        None => (text, false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::session::test_support::*;

    use std::io::Write;

    use std::os::unix::net::UnixStream;

    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::thread::{self};
    use std::time::{Duration, Instant};

    /// After a relaunch the app attaches to a Pi that set its modes long ago and has since written
    /// far more output than any byte history keeps. The replay must still restore them.
    #[test]
    fn a_late_attachment_restores_a_long_running_full_screen_program() {
        use std::io::Read;

        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        manager.stop_workers.store(false, Ordering::Relaxed);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let output = Arc::clone(
            &manager
                .lock_state()
                .unwrap()
                .panes
                .running(shell_id)
                .unwrap()
                .output,
        );
        output.record(b"\x1b[?1049h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[2J");
        let frame = b"\x1b[H\x1b[2Kworking...\r\n".repeat(1024);
        for _ in 0..(2 * axo_pty::output::MAX_TERMINAL_REPLAY_BYTES / frame.len()) {
            output.record(&frame);
        }
        output.record(b"\x1b[H\x1b[2KLATE ATTACH FRAME");

        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        writeln!(client, "{}", shell_id.get()).unwrap();
        let permit = AttachmentPermit::try_acquire(Arc::new(AtomicUsize::new(0))).unwrap();
        let weak = Arc::downgrade(manager);
        let worker = thread::spawn(move || handle_attachment(server, weak, permit));

        let mut length = [0_u8; 8];
        client.read_exact(&mut length).unwrap();
        let length = u64::from_be_bytes(length);
        assert!(
            length > 0 && length < 1024 * 1024,
            "replay of {length} bytes"
        );
        // The one-byte message that carries the PTY descriptor; the descriptor is discarded.
        let mut descriptor_message = [0_u8; 1];
        client.read_exact(&mut descriptor_message).unwrap();
        let mut replay = vec![0_u8; length as usize];
        client.read_exact(&mut replay).unwrap();
        let replay = String::from_utf8_lossy(&replay);
        for mode in [
            "\x1b[?1049h",
            "\x1b[?1000h",
            "\x1b[?1003h",
            "\x1b[?1006h",
            "\x1b[?2004h",
        ] {
            assert!(replay.contains(mode), "replay must restore {mode:?}");
        }
        assert!(replay.contains("LATE ATTACH FRAME"));

        manager.stop_workers.store(true, Ordering::Relaxed);
        drop(client);
        worker.join().unwrap();
    }

    #[test]
    fn a_stalled_client_is_released_without_blocking_the_shell() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        manager.stop_workers.store(false, Ordering::Relaxed);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let output = Arc::clone(
            &manager
                .lock_state()
                .unwrap()
                .panes
                .running(shell_id)
                .unwrap()
                .output,
        );
        let (mut client, server) = UnixStream::pair().unwrap();
        writeln!(client, "{}", shell_id.get()).unwrap();
        let permit = AttachmentPermit::try_acquire(Arc::new(AtomicUsize::new(0))).unwrap();
        let weak = Arc::downgrade(manager);
        let (done, completed) = mpsc::channel();
        let worker = thread::spawn(move || {
            handle_attachment(server, weak, permit);
            done.send(()).unwrap();
        });
        // Intentionally never read. Output keeps flowing (recording never blocks) until the
        // client's backlog overflows and Axod disconnects it.
        let chunk = vec![b'x'; 64 * 1024];
        let deadline = Instant::now() + Duration::from_secs(10);
        while completed.try_recv().is_err() {
            assert!(
                Instant::now() < deadline,
                "stalled client was never released"
            );
            output.record(&chunk);
        }
        worker.join().unwrap();
        assert_eq!(output.subscriber_count(), 0);
        assert_eq!(
            manager
                .lock_state()
                .unwrap()
                .panes
                .running(shell_id)
                .unwrap()
                .attachments,
            0
        );
        drop(client);
    }

    #[test]
    fn terminal_attachment_permits_are_bounded_and_released() {
        let active = Arc::new(AtomicUsize::new(0));
        let mut permits = Vec::new();
        for _ in 0..MAX_CONCURRENT_TERMINAL_ATTACHMENTS {
            match AttachmentPermit::try_acquire(Arc::clone(&active)) {
                Some(permit) => permits.push(permit),
                None => panic!("attachment capacity should be available"),
            }
        }
        assert!(AttachmentPermit::try_acquire(Arc::clone(&active)).is_none());
        assert_eq!(
            active.load(Ordering::Relaxed),
            MAX_CONCURRENT_TERMINAL_ATTACHMENTS
        );

        drop(permits);
        assert_eq!(active.load(Ordering::Relaxed), 0);
        assert!(AttachmentPermit::try_acquire(active).is_some());
    }

    /// A manager whose shells are `cat` writing everything they are typed to a file.
    fn pi_shell(session: &axo_protocol::SessionRecord) -> ShellId {
        session
            .shells
            .iter()
            .find(|shell| shell.role == PaneRole::Pi)
            .unwrap()
            .id
    }

    fn manager_recording_input(
        directory: &std::path::Path,
    ) -> (Arc<SessionManager>, std::path::PathBuf) {
        // The Pi pane records what it is typed; the terminal pane beside it discards its input.
        let log = directory.join("typed.log");
        let agent = directory.join("recording-agent");
        std::fs::write(
            &agent,
            format!("#!/bin/sh\nexec /bin/cat > {}\n", log.display()),
        )
        .unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o700)).unwrap();
        let shell = directory.join("silent-shell");
        std::fs::write(&shell, "#!/bin/sh\nexec /bin/cat > /dev/null\n").unwrap();
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut database =
            axo_store::Connection::open(directory.join(axo_store::DATABASE_FILE)).unwrap();
        axo_store::initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1), ('agent_command', ?2)",
                rusqlite::params![shell.to_string_lossy(), agent.to_string_lossy()],
            )
            .unwrap();
        drop(database);
        (SessionManager::open(directory).unwrap(), log)
    }

    /// Stands in for pi-axo's bridge listener: serves one connection at a time and closes any
    /// other while it does (as pi-axo does), proves the pane's identity, and accepts every
    /// command, reporting each action it was sent.
    fn fake_pi_bridge(
        manager: &SessionManager,
        session: &axo_protocol::SessionRecord,
    ) -> mpsc::Receiver<serde_json::Value> {
        use std::io::{BufRead, BufReader};
        let (socket, identity) = {
            let state = manager.lock_state().unwrap();
            let running = state.panes.running(pi_shell(session)).unwrap();
            let identity = serde_json::json!({
                "axoSessionId": session.id,
                "axoPaneId": running.pane_id,
                "piSessionId": axo_protocol::new_uuid_v4().unwrap(),
                "sessionFile": session.pi_session_file,
                "cwd": running.initial_pwd,
                "processId": running.child.id(),
            });
            (running.pi_bridge_socket.clone().unwrap(), identity)
        };
        let listener = std::os::unix::net::UnixListener::bind(socket.as_path()).unwrap();
        let (actions, received) = mpsc::channel();
        let serving = Arc::new(std::sync::atomic::AtomicBool::new(false));
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                if serving.swap(true, Ordering::SeqCst) {
                    drop(stream);
                    continue;
                }
                let identity = identity.clone();
                let actions = actions.clone();
                let serving = Arc::clone(&serving);
                thread::spawn(move || {
                    let _served = ServingGuard(serving);
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut writer = stream;
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    for record in [
                        serde_json::json!({ "type": "authenticated", "protocolVersion": 1 }),
                        serde_json::json!({ "type": "hello", "protocolVersion": 1, "identity": identity }),
                    ] {
                        let _ = writeln!(writer, "{record}");
                    }
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            return;
                        }
                        let command: serde_json::Value = serde_json::from_str(&line).unwrap();
                        let answer = serde_json::json!({
                            "type": "commandResult",
                            "requestId": command["requestId"],
                            "result": { "accepted": true },
                        });
                        let _ = writeln!(writer, "{answer}");
                        let _ = actions.send(command["action"].clone());
                    }
                });
            }
        });
        received
    }

    /// Marks the fake bridge free again when its one connection ends.
    struct ServingGuard(Arc<std::sync::atomic::AtomicBool>);

    impl Drop for ServingGuard {
        fn drop(&mut self) {
            self.0.store(false, Ordering::SeqCst);
        }
    }

    #[test]
    fn a_prompt_reaches_pi_over_its_bridge_once_pi_is_up() {
        use crate::session::prompts::{MAX_PI_PROMPT_BYTES, PromptError};
        let directory = std::path::PathBuf::from("/tmp").join(format!(
            "axo-prompt-{}",
            axo_protocol::new_uuid_v4().unwrap()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let (manager, log) = manager_recording_input(&directory);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = pi_shell(&session);

        // No Pi in the Session: nothing to prompt.
        manager
            .lock_state()
            .unwrap()
            .panes
            .running_mut(shell_id)
            .unwrap()
            .role = PaneRole::Terminal;
        let refused = manager.prompt_pi(session.id, "hello").unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::NotFound);

        manager
            .lock_state()
            .unwrap()
            .panes
            .running_mut(shell_id)
            .unwrap()
            .role = PaneRole::Pi;
        for bad in ["", "   \n", &"x".repeat(MAX_PI_PROMPT_BYTES + 1)] {
            let error = manager.prompt_pi(session.id, bad).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        }
        // Pi is still starting (its bridge has not bound): the prompt waits.
        manager
            .prompt_pi(session.id, "fix the build\nthen run tests")
            .unwrap();
        assert_eq!(
            manager.lock_state().unwrap().queued_pi_prompts[&session.id].len(),
            1
        );

        // Pi comes up: the worker binds, and what waited is sent.
        let actions = fake_pi_bridge(&manager, &session);
        assert_eq!(
            actions.recv_timeout(Duration::from_secs(15)).unwrap(),
            serde_json::json!({ "kind": "send", "text": "fix the build\nthen run tests", "delivery": "steer" })
        );
        assert!(
            !manager
                .lock_state()
                .unwrap()
                .queued_pi_prompts
                .contains_key(&session.id)
        );

        // Once Pi is up, a prompt is sent at once.
        let accepted = manager
            .prompt_session(&rpc::PromptSession {
                session_id: session.id,
                text: "and again".to_owned(),
                delivery: rpc::PromptDelivery::Turn,
                from_session_id: None,
            })
            .unwrap();
        assert_eq!((accepted.depth, accepted.queued), (0, false));
        assert_eq!(
            actions.recv_timeout(Duration::from_secs(5)).unwrap(),
            serde_json::json!({ "kind": "send", "text": "and again" })
        );

        // An agent prompting itself climbs one level per prompt and stops at the limit.
        let to_self = |text: &str| {
            manager.prompt_session(&rpc::PromptSession {
                session_id: session.id,
                text: text.to_owned(),
                delivery: rpc::PromptDelivery::FollowUp,
                from_session_id: Some(session.id),
            })
        };
        for depth in 1..=crate::session::prompts::MAX_PROMPT_DEPTH {
            assert_eq!(to_self("again").unwrap().depth, depth);
        }
        let sent = actions.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(
            sent["text"],
            format!(
                "[From Axo Session {} {:?}]\n\nagain",
                session.id, session.name
            ),
            "an agent's prompt names its sender"
        );
        assert_eq!(sent["delivery"], "followUp");
        assert!(matches!(to_self("again"), Err(PromptError::ChainTooDeep)));
        // A person typing into the pane ends the chain.
        let typed = axo_protocol::base64::encode(b"x\r");
        manager
            .write_terminal_input(session.id, shell_id, 0, &typed)
            .unwrap();
        assert_eq!(to_self("again").unwrap().depth, 1);
        assert_eq!(to_self("again").unwrap().depth, 2);
        // Ten prompts to itself a minute, then no more.
        assert!(matches!(to_self("again"), Err(PromptError::RateLimited)));

        // Nothing was typed into the pane except what the person typed.
        let deadline = Instant::now() + Duration::from_secs(5);
        while std::fs::read_to_string(&log).unwrap_or_default().is_empty()
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(std::fs::read_to_string(&log).unwrap_or_default(), "x\n");
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_remote_key_press_reaches_only_the_pi_pane() {
        let directory = std::path::PathBuf::from("/tmp")
            .join(format!("axo-key-{}", axo_protocol::new_uuid_v4().unwrap()));
        std::fs::create_dir_all(&directory).unwrap();
        let (manager, log) = manager_recording_input(&directory);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = pi_shell(&session);

        manager
            .lock_state()
            .unwrap()
            .panes
            .running_mut(shell_id)
            .unwrap()
            .role = PaneRole::Terminal;
        let refused = manager
            .press_pi_key(session.id, axo_relay::PiKey::Escape)
            .unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::NotFound);

        manager
            .lock_state()
            .unwrap()
            .panes
            .running_mut(shell_id)
            .unwrap()
            .role = PaneRole::Pi;
        manager
            .press_pi_key(session.id, axo_relay::PiKey::Escape)
            .unwrap();
        manager
            .press_pi_key(session.id, axo_relay::PiKey::Enter)
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        let typed = loop {
            let typed = std::fs::read_to_string(&log).unwrap_or_default();
            if typed.ends_with('\n') || Instant::now() > deadline {
                break typed;
            }
            thread::sleep(Duration::from_millis(50));
        };
        // Escape as itself; Enter as a carriage return (the terminal makes it a newline for `cat`).
        assert_eq!(typed, "\u{1b}\n");
        let _ = std::fs::remove_dir_all(&directory);
    }
}
