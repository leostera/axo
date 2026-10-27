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

use super::{SessionManager, SessionState};
use axo_panes::RuntimeId;
use axo_protocol::rpc;
use axo_protocol::{GridSize, PaneRole, SessionId, ShellActivity, ShellId};
use axo_pty::process;
use axo_pty::{NextOutput, OutputSubscriber, TerminalOutput, WindowSize, attach};

/// Most prompt text one remote prompt carries.
const MAX_PI_PROMPT_BYTES: usize = 16_000;
/// Prompts that may wait for one starting Pi; more is a client sending blind.
const MAX_QUEUED_PI_PROMPTS: usize = 8;

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
            session_id.get(),
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
        session_id.get(),
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
        session_id.get(),
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
        Ok(())
    }

    /// Types a prompt into the Session's Pi pane and submits it. The text goes in as a bracketed
    /// paste, so newlines and control characters in it stay text instead of acting as keys; only
    /// the final carriage return submits. This does not use the pane's input sequence: that
    /// belongs to the one client typing into the pane.
    /// Types `text` into the Session's Pi as one bracketed paste and a submit.
    ///
    /// Pi ignores a submit until its startup has finished ("Startup is still in progress"): the
    /// words stay in its editor and nothing is sent. Its bridge binds only after that point, so a
    /// prompt for a Pi whose bridge has not bound yet waits here and is typed by
    /// `flush_queued_pi_prompts` when it does. This is what a chat's first message meets.
    pub(super) fn prompt_pi(&self, session_id: SessionId, text: &str) -> io::Result<()> {
        if text.trim().is_empty() || text.len() > MAX_PI_PROMPT_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a prompt must contain 1 to 16000 bytes of text",
            ));
        }
        // A pasted escape could close the paste early and run the rest as keystrokes.
        let text: String = text.chars().filter(|&c| c != '\u{1b}').collect();
        let mut state = self.lock_state()?;
        let pi_shell = state
            .panes
            .in_session(session_id)
            .find_map(|(id, pane)| match pane {
                axo_panes::Pane::Running(shell) if shell.role == PaneRole::Pi => Some(id),
                _ => None,
            })
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi is not running"))?;
        let ready = state.pi_activity.get(&session_id).is_some_and(|activity| activity.connected);
        if !ready {
            let queue = state.queued_pi_prompts.entry(session_id).or_default();
            if queue.len() >= MAX_QUEUED_PI_PROMPTS {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "Pi is still starting and already has prompts waiting",
                ));
            }
            log::info!(
                "event=session.pi_prompt_queued session_id={} queued={}",
                session_id.get(),
                queue.len() + 1
            );
            queue.push(text);
            return Ok(());
        }
        type_pi_prompt(&mut state, session_id, pi_shell, &text)
    }

    /// Presses one key in the Session's Pi pane, as a person at the Mac would: Escape stops a reply
    /// or declines a question, Enter accepts one. A Pi still starting has nothing to stop or
    /// answer, so the key is not queued like a prompt.
    pub(super) fn press_pi_key(&self, session_id: SessionId, key: axo_relay::PiKey) -> io::Result<()> {
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
            session_id.get()
        );
        process::write_all(running.master.as_raw_fd(), bytes, TERMINAL_INPUT_WRITE_TIMEOUT)
    }

    /// Types the prompts that waited for the Session's Pi to finish starting, oldest first.
    pub(super) fn flush_queued_pi_prompts(&self, session_id: SessionId) -> io::Result<()> {
        let mut state = self.lock_state()?;
        let Some(queue) = state.queued_pi_prompts.remove(&session_id) else {
            return Ok(());
        };
        let Some(pi_shell) = state.panes.in_session(session_id).find_map(|(id, pane)| match pane {
            axo_panes::Pane::Running(shell) if shell.role == PaneRole::Pi => Some(id),
            _ => None,
        }) else {
            return Ok(());
        };
        log::info!(
            "event=session.pi_prompts_flushed session_id={} count={}",
            session_id.get(),
            queue.len()
        );
        for text in &queue {
            type_pi_prompt(&mut state, session_id, pi_shell, text)?;
        }
        Ok(())
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

fn type_pi_prompt(
    state: &mut SessionState,
    session_id: SessionId,
    pi_shell: ShellId,
    text: &str,
) -> io::Result<()> {
    let running = state
        .panes
        .running_in_mut(session_id, pi_shell)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi is not running"))?;
    let input = format!("\u{1b}[200~{text}\u{1b}[201~\r");
    process::write_all(
        running.master.as_raw_fd(),
        input.as_bytes(),
        TERMINAL_INPUT_WRITE_TIMEOUT,
    )
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
        session.shells.iter().find(|shell| shell.role == PaneRole::Pi).unwrap().id
    }

    fn manager_recording_input(directory: &std::path::Path) -> (Arc<SessionManager>, std::path::PathBuf) {
        // The Pi pane records what it is typed; the terminal pane beside it discards its input.
        let log = directory.join("typed.log");
        let agent = directory.join("recording-agent");
        std::fs::write(&agent, format!("#!/bin/sh\nexec /bin/cat > {}\n", log.display())).unwrap();
        std::fs::set_permissions(&agent, std::fs::Permissions::from_mode(0o700)).unwrap();
        let shell = directory.join("silent-shell");
        std::fs::write(&shell, "#!/bin/sh\nexec /bin/cat > /dev/null\n").unwrap();
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut database = axo_store::Connection::open(directory.join(axo_store::DATABASE_FILE)).unwrap();
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

    #[test]
    fn a_prompt_reaches_pi_as_one_bracketed_paste_and_a_submit() {
        let directory = std::path::PathBuf::from("/tmp").join(format!("axo-prompt-{}", axo_protocol::new_uuid_v4().unwrap()));
        std::fs::create_dir_all(&directory).unwrap();
        let (manager, log) = manager_recording_input(&directory);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = pi_shell(&session);

        // No Pi in the Session yet: nothing to prompt, and nothing is typed anywhere.
        manager.lock_state().unwrap().panes.running_mut(shell_id).unwrap().role = PaneRole::Terminal;
        let refused = manager.prompt_pi(session.id, "hello").unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::NotFound);

        manager.lock_state().unwrap().panes.running_mut(shell_id).unwrap().role = PaneRole::Pi;
        for bad in ["", "   \n", &"x".repeat(MAX_PI_PROMPT_BYTES + 1)] {
            let error = manager.prompt_pi(session.id, bad).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        }
        manager.prompt_pi(session.id, "fix the build\nthen run tests\u{1b}[201~evil").unwrap();
        // Pi is still starting (its bridge has not bound): the prompt waits instead of being
        // typed into an editor that ignores Enter.
        thread::sleep(Duration::from_millis(300));
        assert_eq!(std::fs::read_to_string(&log).unwrap_or_default(), "");
        assert_eq!(manager.lock_state().unwrap().queued_pi_prompts[&session.id].len(), 1);

        manager.lock_state().unwrap().pi_activity.entry(session.id).or_default().connected = true;
        manager.flush_queued_pi_prompts(session.id).unwrap();
        assert!(!manager.lock_state().unwrap().queued_pi_prompts.contains_key(&session.id));

        let deadline = Instant::now() + Duration::from_secs(15);
        let typed = loop {
            let typed = std::fs::read_to_string(&log).unwrap_or_default();
            if typed.contains("evil") || Instant::now() > deadline {
                break typed;
            }
            thread::sleep(Duration::from_millis(50));
        };
        // One paste around the whole text, a stray escape removed from inside it, then Enter
        // (the terminal turns it into a newline for `cat`).
        assert_eq!(typed, "\u{1b}[200~fix the build\nthen run tests[201~evil\u{1b}[201~\n");

        // Once Pi is up, a prompt is typed at once, after the ones that waited.
        manager.prompt_pi(session.id, "and again").unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        let typed = loop {
            let typed = std::fs::read_to_string(&log).unwrap_or_default();
            if typed.contains("again") || Instant::now() > deadline {
                break typed;
            }
            thread::sleep(Duration::from_millis(50));
        };
        assert!(typed.ends_with("\u{1b}[200~and again\u{1b}[201~\n"), "{typed:?}");
        let _ = std::fs::remove_dir_all(&directory);
    }
    #[test]
    fn a_remote_key_press_reaches_only_the_pi_pane() {
        let directory = std::path::PathBuf::from("/tmp").join(format!("axo-key-{}", axo_protocol::new_uuid_v4().unwrap()));
        std::fs::create_dir_all(&directory).unwrap();
        let (manager, log) = manager_recording_input(&directory);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = pi_shell(&session);

        manager.lock_state().unwrap().panes.running_mut(shell_id).unwrap().role = PaneRole::Terminal;
        let refused = manager.press_pi_key(session.id, axo_relay::PiKey::Escape).unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::NotFound);

        manager.lock_state().unwrap().panes.running_mut(shell_id).unwrap().role = PaneRole::Pi;
        manager.press_pi_key(session.id, axo_relay::PiKey::Escape).unwrap();
        manager.press_pi_key(session.id, axo_relay::PiKey::Enter).unwrap();
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
