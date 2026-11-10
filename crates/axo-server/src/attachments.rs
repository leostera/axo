//! The attach socket (see `axo_pty::attach` for the protocol): a client names a pane, gets a copy
//! of its PTY master for input and resizing, then the screen's replay and its live output until
//! either side ends. Each attachment is a task; the short blocking writes of the handshake run on
//! the blocking pool.

use std::fs;
use std::io::{self, Write};
use std::os::fd::OwnedFd;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use axo_protocol::{SessionId, ShellId};
use axo_pty::{NextOutput, OutputSubscriber, TerminalOutput, attach};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

use crate::core::Core;
use crate::session::panes::RuntimeId;

const MAX_CONCURRENT_TERMINAL_ATTACHMENTS: usize = 256;
/// A client that cannot take its replay this fast is stalled; it can reattach.
const ATTACH_REPLAY_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// Live writes tolerate a briefly busy UI; the backlog cap handles slower clients.
const ATTACH_LIVE_WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const ATTACH_SEND_BUFFER_BYTES: libc::c_int = 256 * 1024;

/// One more attachment to a pane, as its Session hands it out.
pub(crate) struct Attached {
    pub(crate) master: OwnedFd,
    pub(crate) output: Arc<TerminalOutput>,
    pub(crate) session_id: SessionId,
    pub(crate) runtime_id: RuntimeId,
}

/// Binds the attach socket and serves it on the runtime until axod stops.
pub(crate) fn listen(core: &Arc<Core>, stop: axo_ipc::Stop) -> io::Result<()> {
    let path = &core.attach_socket_path;
    crate::SocketPath::parse(path.clone())
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))?;
    crate::remove_stale_socket(path)?;
    let listener = std::os::unix::net::UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let listener = UnixListener::from_std(listener)?;
    let core = Arc::downgrade(core);
    tokio::spawn(async move {
        let active = Arc::new(AtomicUsize::new(0));
        loop {
            let accepted = tokio::select! {
                () = stop.stopped() => return,
                accepted = listener.accept() => accepted,
            };
            let Ok((stream, _)) = accepted else {
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            };
            let Some(core) = core.upgrade() else { return };
            if active.fetch_add(1, Ordering::AcqRel) >= MAX_CONCURRENT_TERMINAL_ATTACHMENTS {
                active.fetch_sub(1, Ordering::AcqRel);
                log::warn!("event=session.attach_rejected reason=capacity");
                reject_in_background(stream, attach::Rejection::DaemonBusy);
                continue;
            }
            let active = Arc::clone(&active);
            tokio::spawn(async move {
                serve(core, stream).await;
                active.fetch_sub(1, Ordering::AcqRel);
            });
        }
    });
    Ok(())
}

pub(crate) fn remove_socket(path: &Path) {
    let _ = fs::remove_file(path);
}

fn reject_in_background(stream: UnixStream, rejection: attach::Rejection) {
    tokio::task::spawn_blocking(move || {
        if let Ok(stream) = stream.into_std() {
            let _ = blocking(&stream, ATTACH_REPLAY_WRITE_TIMEOUT)
                .and_then(|mut stream| attach::write_rejection(&mut stream, rejection));
        }
    });
}

/// The stream, set to bounded blocking I/O. Accepted sockets can inherit nonblocking mode on
/// macOS; any failed write ends the attachment, so a partial write never corrupts a stream.
fn blocking(
    stream: &std::os::unix::net::UnixStream,
    write_timeout: Duration,
) -> io::Result<std::os::unix::net::UnixStream> {
    let stream = stream.try_clone()?;
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_millis(200)))?;
    stream.set_write_timeout(Some(write_timeout))?;
    Ok(stream)
}

/// Maps why attaching failed to the attach protocol's rejection codes.
fn rejection(error: &io::Error) -> attach::Rejection {
    match error.kind() {
        io::ErrorKind::NotFound => attach::Rejection::ShellNotOpen,
        io::ErrorKind::WouldBlock => attach::Rejection::DaemonBusy,
        _ => attach::Rejection::Other,
    }
}

/// Finds the pane `shell_id` and registers one more attachment with it: one of this Mac's
/// Sessions, or a remote pane.
async fn attach_to(core: &Core, shell_id: ShellId) -> io::Result<Attached> {
    if let Some(attached) = core.peers.with_pane(None, shell_id, |session_id, running| {
        let master = running.duplicate_master()?;
        running.attachments += 1;
        Ok::<_, io::Error>(Attached {
            master,
            output: Arc::clone(&running.output),
            session_id,
            runtime_id: running.runtime_id,
        })
    }) {
        return attached;
    }
    crate::sessions::owner_of(core, None, shell_id)?
        .with(move |session| session.attach(shell_id))
        .await?
}

async fn detach_from(core: &Core, shell_id: ShellId, runtime_id: RuntimeId) {
    let peer = core.peers.with_pane(None, shell_id, |_, running| {
        if running.runtime_id == runtime_id {
            running.attachments = running.attachments.saturating_sub(1);
        }
    });
    if peer.is_some() {
        return;
    }
    if let Ok(owner) = crate::sessions::owner_of(core, None, shell_id) {
        let _ = owner
            .with(move |session| session.detached(shell_id, runtime_id))
            .await;
    }
}

async fn serve(core: Arc<Core>, stream: UnixStream) {
    let started_at = Instant::now();
    let Ok(stream) = stream.into_std() else {
        return;
    };
    // The request, read with bounded blocking I/O.
    let requested = tokio::task::spawn_blocking(move || {
        let mut handshake = blocking(&stream, ATTACH_REPLAY_WRITE_TIMEOUT)?;
        attach::set_send_buffer(&handshake, ATTACH_SEND_BUFFER_BYTES);
        let id = attach::read_request(&mut handshake).and_then(|id| {
            ShellId::new(id).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "shell ID must be positive")
            })
        });
        Ok::<_, io::Error>((handshake, id))
    })
    .await;
    let Ok(Ok((mut handshake, id))) = requested else {
        return;
    };
    let shell_id = match id {
        Ok(id) => id,
        Err(error) => {
            log::debug!(
                "event=session.attach_rejected reason=invalid_request error_kind={:?}",
                error.kind()
            );
            tokio::task::spawn_blocking(move || {
                let _ = attach::write_rejection(&mut handshake, rejection(&error));
            });
            return;
        }
    };
    let attached = match attach_to(&core, shell_id).await {
        Ok(attached) => attached,
        Err(error) => {
            log::warn!(
                "event=session.attach_rejected shell_id={} error_kind={:?}",
                shell_id.get(),
                error.kind()
            );
            tokio::task::spawn_blocking(move || {
                let _ = attach::write_rejection(&mut handshake, rejection(&error));
            });
            return;
        }
    };
    let Attached {
        master,
        output,
        session_id,
        runtime_id,
    } = attached;
    // Subscribe before replying: the replay plus queued chunks are then exactly the PTY stream.
    // The replay is a snapshot of the screen at the PTY's current size, which the client's
    // surface is created at too.
    let accepted = tokio::task::spawn_blocking(move || {
        let overflow_shutdown = handshake.try_clone().ok().map(OwnedFd::from);
        let size = axo_pty::process::window_size(&master).ok();
        let (replay, subscriber) = output.subscribe(size, overflow_shutdown);
        let written = attach::write_acceptance(&mut handshake, replay.len(), &master)
            .map_err(|(phase, error)| (phase.as_str(), error))
            .and_then(|()| {
                handshake
                    .write_all(&replay)
                    .map_err(|error| ("replay", error))
            });
        (handshake, subscriber, replay.len(), written)
    })
    .await;
    let Ok((handshake, subscriber, replay_bytes, written)) = accepted else {
        detach_from(&core, shell_id, runtime_id).await;
        return;
    };
    let subscription = Subscription(subscriber);
    if let Err((phase, error)) = written {
        log::warn!(
            "event=session.attach_failed session_id={session_id} shell_id={} phase={phase} replay_bytes={replay_bytes} elapsed_ms={} error_kind={:?}",
            shell_id.get(),
            started_at.elapsed().as_millis(),
            error.kind()
        );
        detach_from(&core, shell_id, runtime_id).await;
        return;
    }
    log::info!(
        "event=session.attach_ready session_id={session_id} shell_id={} replay_bytes={replay_bytes} elapsed_ms={}",
        shell_id.get(),
        started_at.elapsed().as_millis()
    );
    let (reason, delivered) = match handshake
        .set_nonblocking(true)
        .and_then(|()| UnixStream::from_std(handshake))
    {
        Ok(stream) => stream_output(stream, &subscription.0).await,
        Err(_) => ("socket_setup", 0),
    };
    drop(subscription);
    detach_from(&core, shell_id, runtime_id).await;
    let level = if reason == "client_overflowed" {
        log::Level::Warn
    } else {
        log::Level::Info
    };
    log::log!(
        level,
        "event=session.attach_ended session_id={session_id} shell_id={} reason={reason} bytes={delivered} elapsed_ms={}",
        shell_id.get(),
        started_at.elapsed().as_millis()
    );
}

/// Detaches the subscriber when the attachment ends for any reason.
struct Subscription(Arc<OutputSubscriber>);

impl Drop for Subscription {
    fn drop(&mut self) {
        self.0.detach();
    }
}

/// Writes the pane's output to the client until either ends. The client sends nothing after its
/// request (input goes to the PTY descriptor it was handed); what it does send is dropped, and
/// its hanging up ends the stream.
async fn stream_output(
    mut stream: UnixStream,
    subscriber: &OutputSubscriber,
) -> (&'static str, u64) {
    let mut delivered = 0_u64;
    let mut scratch = [0_u8; 4096];
    let reason = 'stream: loop {
        let next = tokio::select! {
            next = subscriber.next_async() => next,
            read = stream.read(&mut scratch) => match read {
                Ok(0) | Err(_) => break "client_closed",
                Ok(_) => continue,
            },
        };
        match next {
            NextOutput::Chunks(chunks) => {
                for chunk in chunks {
                    let written =
                        tokio::time::timeout(ATTACH_LIVE_WRITE_TIMEOUT, stream.write_all(&chunk))
                            .await;
                    if !matches!(written, Ok(Ok(()))) {
                        break 'stream "client_write_failed";
                    }
                    delivered = delivered.saturating_add(chunk.len() as u64);
                }
            }
            NextOutput::Idle => {}
            NextOutput::Ended => break "shell_output_ended",
            NextOutput::Overflowed => break "client_overflowed",
            NextOutput::Detached => break "detached",
        }
    };
    let _ = stream.shutdown().await;
    (reason, delivered)
}
