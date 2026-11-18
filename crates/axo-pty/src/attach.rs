//! Attach protocols v2/v3, both ends.
//!
//! The client writes its positive shell ID and newline (v2), or `3:<id>\n` (v3).
//! Axod answers with either `u64::MAX` and a one-byte rejection code, or:
//!
//! 1. the replay length as a big-endian `u64` (at most `MAX_TERMINAL_REPLAY_BYTES`),
//! 2. v3 only: snapshot rows and columns, each a positive big-endian `u16`,
//! 3. a one-byte message (`'1'`) carrying the PTY master descriptor (`SCM_RIGHTS`), then
//! 4. the replay followed by live output, as raw bytes, until the PTY reaches end of file.
//!
//! v3's captured grid permits initial replay parsing without guessing from a later
//! PTY size or GTK allocation. v2 remains byte-for-byte compatible with shipped clients.
//!
//! The descriptor is for input, resizing, and termios/foreground queries only; reading it would
//! steal output from Axod's pump. Closing the socket detaches. End of file means the shell exited
//! or the attachment fell too far behind; clients check the catalog to tell which.

use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use crate::output::MAX_TERMINAL_REPLAY_BYTES;

/// Sent in place of a replay length when the request is rejected.
pub const REJECTION_MARKER: u64 = u64::MAX;

/// Why an attachment was refused. The discriminants are the wire codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Rejection {
    ShellNotOpen = 2,
    Other = 3,
    DaemonBusy = 4,
    /// The caller may not type into that pane: it is neither the person nor in its Session.
    NotAllowed = 5,
}

impl Rejection {
    /// Unknown codes (including v1's retired `1`) are `Other`.
    pub fn from_code(code: u8) -> Rejection {
        match code {
            2 => Rejection::ShellNotOpen,
            4 => Rejection::DaemonBusy,
            5 => Rejection::NotAllowed,
            _ => Rejection::Other,
        }
    }
}

/// An open attachment, client side.
#[derive(Debug)]
pub struct Attachment {
    /// Carries the replay (`replay_bytes` long) and then live output.
    pub control: UnixStream,
    /// The shell's PTY master, for input and resizing only.
    pub pty: OwnedFd,
    pub replay_bytes: u64,
}

/// An attachment whose bounded initial replay has been read off the UI thread.
/// The renderer bootstraps at `size` before consuming live bytes from `control`.
#[derive(Debug)]
pub struct PreparedAttachment {
    attachment: Attachment,
    replay: Vec<u8>,
    size: crate::process::WindowSize,
}

impl PreparedAttachment {
    pub fn attachment(&self) -> &Attachment {
        &self.attachment
    }
    pub fn replay(&self) -> &[u8] {
        &self.replay
    }
    pub fn size(&self) -> crate::process::WindowSize {
        self.size
    }
}

impl Attachment {
    /// Consumes exactly the announced replay, at the server-captured grid. The
    /// PTY may already have a different size when another client resizes it.
    fn prepare_at(mut self, size: crate::process::WindowSize) -> io::Result<PreparedAttachment> {
        let length = usize::try_from(self.replay_bytes)
            .ok()
            .filter(|length| *length <= MAX_TERMINAL_REPLAY_BYTES)
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "oversized initial replay")
            })?;
        // Validate that the supplied descriptor is a sized PTY, not arbitrary input.
        let _current_size = crate::process::window_size(&self.pty)?;
        let mut replay = vec![0; length];
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut received = 0;
        while received < length {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "initial replay timed out",
                ));
            }
            stream_option_result(
                &self.control,
                self.control.set_read_timeout(Some(remaining)),
            )?;
            match self.control.read(&mut replay[received..]) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "initial replay truncated",
                    ));
                }
                Ok(count) => received += count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        clear_handshake_timeouts(&self.control)?;
        Ok(PreparedAttachment {
            attachment: self,
            replay,
            size,
        })
    }

    /// The kernel signals the foreground group. Never read the master or change
    /// its shared file-status flags, and never signal a guessed child PID.
    pub fn resize(&self, size: crate::process::WindowSize) -> io::Result<()> {
        if crate::process::window_size(&self.pty)? == size {
            return Ok(());
        }
        let dimensions = libc::winsize {
            ws_row: size.rows(),
            ws_col: size.columns(),
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: this attachment owns a live master; dimensions is initialized.
        if unsafe { libc::ioctl(self.pty.as_raw_fd(), libc::TIOCSWINSZ, &dimensions) } == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

// Server side.

const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);

const MAX_SHELL_ID_DIGITS: usize = 19;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttachVersion {
    V2,
    V3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AttachRequest {
    pub version: AttachVersion,
    pub shell_id: i64,
}

/// Legacy request reader retained for v2 clients/tests.
pub fn read_request(stream: &mut UnixStream) -> io::Result<i64> {
    let request = read_versioned_request(stream)?;
    if request.version != AttachVersion::V2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected v2 attachment request",
        ));
    }
    Ok(request.shell_id)
}

/// Reads a bounded positive shell ID (v2), or `3:<id>` (v3), within REQUEST_TIMEOUT.
pub fn read_versioned_request(stream: &mut UnixStream) -> io::Result<AttachRequest> {
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut request = Vec::with_capacity(MAX_SHELL_ID_DIGITS + 2);
    let mut byte = [0_u8; 1];
    loop {
        wait_for_request_data(stream.as_raw_fd(), deadline)?;
        match stream.read(&mut byte) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "attachment request ended before its newline",
                ));
            }
            Ok(_) if byte[0] == b'\n' && !request.is_empty() => break,
            Ok(_) if request.len() < MAX_SHELL_ID_DIGITS + 2 => {
                request.push(byte[0]);
            }
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "attachment request must contain one positive shell ID",
                ));
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        }
    }

    let text = std::str::from_utf8(&request)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "shell ID is not UTF-8"))?;
    let (version, text) = match text.strip_prefix("3:") {
        Some(id) => (AttachVersion::V3, id),
        None => (AttachVersion::V2, text),
    };
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid attachment version or shell ID",
        ));
    }
    let shell_id = text
        .parse::<i64>()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "shell ID is invalid"))?;
    if shell_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "shell ID must be positive",
        ));
    }
    Ok(AttachRequest { version, shell_id })
}

fn wait_for_request_data(file_descriptor: RawFd, deadline: Instant) -> io::Result<()> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "attachment request timed out",
            ));
        }
        let timeout_millis =
            remaining.as_millis().clamp(1, libc::c_int::MAX as u128) as libc::c_int;
        let mut descriptor = libc::pollfd {
            fd: file_descriptor,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: descriptor points to one initialized pollfd for an open socket.
        let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_millis) };
        if ready > 0 {
            return Ok(());
        }
        if ready == 0 {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "attachment request timed out",
            ));
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

pub fn set_send_buffer(stream: &UnixStream, bytes: libc::c_int) {
    // SAFETY: setsockopt borrows this live socket and an initialized integer.
    unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_SNDBUF,
            (&bytes as *const libc::c_int).cast(),
            std::mem::size_of_val(&bytes) as _,
        );
    }
}

/// Answers a request that cannot be served.
pub fn write_rejection(stream: &mut UnixStream, rejection: Rejection) -> io::Result<()> {
    stream.write_all(&REJECTION_MARKER.to_be_bytes())?;
    stream.write_all(&[rejection as u8])
}

/// Accepts a request: the replay length, then the PTY master in a one-byte `SCM_RIGHTS`
/// message. The caller streams the replay and live output next.
pub fn write_acceptance(
    stream: &mut UnixStream,
    replay_bytes: usize,
    master: &OwnedFd,
) -> Result<(), (AcceptPhase, io::Error)> {
    stream
        .write_all(&(replay_bytes as u64).to_be_bytes())
        .map_err(|error| (AcceptPhase::ReplayHeader, error))?;
    send_descriptor(stream.as_raw_fd(), master.as_raw_fd())
        .map_err(|error| (AcceptPhase::PtyDescriptor, error))
}

/// v3's captured grid is the same value passed to TerminalOutput::subscribe.
pub fn write_snapshot_acceptance(
    stream: &mut UnixStream,
    replay_bytes: usize,
    master: &OwnedFd,
    size: crate::process::WindowSize,
) -> Result<(), (AcceptPhase, io::Error)> {
    stream
        .write_all(&(replay_bytes as u64).to_be_bytes())
        .and_then(|()| stream.write_all(&size.rows().to_be_bytes()))
        .and_then(|()| stream.write_all(&size.columns().to_be_bytes()))
        .map_err(|error| (AcceptPhase::ReplayHeader, error))?;
    send_descriptor(stream.as_raw_fd(), master.as_raw_fd())
        .map_err(|error| (AcceptPhase::PtyDescriptor, error))
}

/// Which step of `write_acceptance` failed, for diagnostics.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AcceptPhase {
    ReplayHeader,
    PtyDescriptor,
}

impl AcceptPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            AcceptPhase::ReplayHeader => "replay_header",
            AcceptPhase::PtyDescriptor => "pty_descriptor",
        }
    }
}

fn send_descriptor(socket_fd: RawFd, descriptor: RawFd) -> io::Result<()> {
    let mut byte = b'1';
    let mut vector = libc::iovec {
        iov_base: (&mut byte as *mut u8).cast(),
        iov_len: 1,
    };
    let control_size = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) } as usize;
    let mut control = vec![0_usize; control_size.div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: zeroed msghdr is a valid starting point before its fields are initialized.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = control_size as _;

    // SAFETY: message points to valid iovec and control storage sized for one descriptor.
    let header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    if header.is_null() {
        return Err(io::Error::other(
            "could not allocate PTY descriptor message",
        ));
    }
    // SAFETY: header points into message's control buffer with enough SCM_RIGHTS capacity.
    unsafe {
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
        std::ptr::copy_nonoverlapping(
            &descriptor as *const RawFd as *const u8,
            libc::CMSG_DATA(header).cast(),
            std::mem::size_of::<RawFd>(),
        );
    }

    // SAFETY: sendmsg reads the initialized message and descriptor; both remain alive here.
    let sent = unsafe { libc::sendmsg(socket_fd, &message, 0) };
    if sent == -1 {
        return Err(io::Error::last_os_error());
    }
    if sent != 1 {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "short PTY descriptor message",
        ));
    }
    Ok(())
}

// Client side.

const RETRY_WINDOW: Duration = Duration::from_secs(10);

const RETRY_DELAY: Duration = Duration::from_millis(50);

/// Opens an attachment, retrying while the daemon is busy or restarting (up to `RETRY_WINDOW`).
pub fn connect(socket_path: &Path, shell_id: i64) -> io::Result<Attachment> {
    let deadline = Instant::now() + RETRY_WINDOW;
    loop {
        match open(socket_path, shell_id) {
            Ok(attachment) => return Ok(attachment),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::UnexpectedEof
                ) && Instant::now() < deadline =>
            {
                thread::sleep(RETRY_DELAY);
            }
            Err(error) => return Err(error),
        }
    }
}

/// Opens one attachment: request, header and PTY descriptor. Replay and live output follow on
/// `Attachment::control`.
pub fn open(socket_path: &Path, shell_id: i64) -> io::Result<Attachment> {
    match open_request(socket_path, shell_id, AttachVersion::V2)? {
        OpenedAttachment::Legacy(attachment) => Ok(attachment),
        OpenedAttachment::Snapshot { .. } => Err(io::Error::other("unexpected attachment version")),
    }
}

/// Opens v3 and reads its bounded replay off the UI thread. An old daemon's
/// refusal is explicit: never downgrade to an inferred grid or a new subprocess.
pub fn open_snapshot(socket_path: &Path, shell_id: i64) -> io::Result<PreparedAttachment> {
    let opened = open_request(socket_path, shell_id, AttachVersion::V3).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("snapshot attach v3 (requires updated axod): {error}"),
        )
    })?;
    match opened {
        OpenedAttachment::Snapshot { attachment, size } => attachment.prepare_at(size),
        OpenedAttachment::Legacy(_) => Err(io::Error::other("snapshot metadata is required")),
    }
}

enum OpenedAttachment {
    Legacy(Attachment),
    Snapshot {
        attachment: Attachment,
        size: crate::process::WindowSize,
    },
}

fn open_request(
    socket_path: &Path,
    shell_id: i64,
    version: AttachVersion,
) -> io::Result<OpenedAttachment> {
    if shell_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "shell ID must be positive",
        ));
    }
    let mut control = UnixStream::connect(socket_path)?;
    control.set_read_timeout(Some(Duration::from_secs(5)))?;
    control
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("set attachment write timeout: {error}"),
            )
        })?;
    match version {
        AttachVersion::V2 => writeln!(control, "{shell_id}")?,
        AttachVersion::V3 => writeln!(control, "3:{shell_id}")?,
    }
    let replay_bytes = receive_header(&mut control).map_err(|error| {
        io::Error::new(error.kind(), format!("read attachment header: {error}"))
    })?;
    let snapshot_size = if version == AttachVersion::V3 {
        let mut grid = [0; 4];
        read_exact_with_progress(&mut control, &mut grid, "snapshot grid")?;
        Some(
            crate::process::WindowSize::new(
                u16::from_be_bytes([grid[0], grid[1]]).into(),
                u16::from_be_bytes([grid[2], grid[3]]).into(),
            )
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid snapshot grid"))?,
        )
    } else {
        None
    };
    let pty = receive_pty_master(&control)
        .map_err(|error| io::Error::new(error.kind(), format!("receive PTY: {error}")))?;
    // The handshake deadline must not turn an idle live terminal into a read failure.
    clear_handshake_timeouts(&control)?;
    let attachment = Attachment {
        control,
        pty,
        replay_bytes,
    };
    Ok(match snapshot_size {
        Some(size) => OpenedAttachment::Snapshot { attachment, size },
        None => OpenedAttachment::Legacy(attachment),
    })
}

fn clear_handshake_timeouts(control: &UnixStream) -> io::Result<()> {
    let cleared = control
        .set_read_timeout(None)
        .and_then(|()| control.set_write_timeout(None));
    stream_option_result(control, cleared)
}

fn stream_option_result(_control: &UnixStream, cleared: io::Result<()>) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    if let Err(error) = &cleared {
        // Darwin refuses socket options after the peer disconnects, even with replay
        // still buffered. That stream can only drain to EOF; it cannot wait on a timeout.
        if error.raw_os_error() == Some(libc::EINVAL) {
            let mut descriptor = libc::pollfd {
                fd: _control.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: descriptor borrows this live socket for a nonblocking readiness check.
            if unsafe { libc::poll(&mut descriptor, 1, 0) } > 0
                && descriptor.revents & libc::POLLHUP != 0
            {
                return Ok(());
            }
        }
    }
    cleared
}

/// Returns the replay length; the replay itself follows the PTY descriptor on the stream.
fn receive_header(control: &mut UnixStream) -> io::Result<u64> {
    let mut length_bytes = [0_u8; size_of::<u64>()];
    read_exact_with_progress(control, &mut length_bytes, "history length")?;
    let length = u64::from_be_bytes(length_bytes);
    if length == REJECTION_MARKER {
        let mut code = [0_u8; 1];
        control.read_exact(&mut code)?;
        let (kind, message) = match Rejection::from_code(code[0]) {
            Rejection::ShellNotOpen => (io::ErrorKind::NotFound, "shell is no longer open"),
            Rejection::DaemonBusy => (
                io::ErrorKind::WouldBlock,
                "daemon is busy attaching terminals",
            ),
            Rejection::Other => (
                io::ErrorKind::Other,
                "daemon rejected the terminal attachment",
            ),
            Rejection::NotAllowed => (
                io::ErrorKind::PermissionDenied,
                "only the person or that Session's own processes attach to its panes",
            ),
        };
        return Err(io::Error::new(kind, message));
    }
    if length > MAX_TERMINAL_REPLAY_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon announced an oversized terminal replay",
        ));
    }
    Ok(length)
}

fn read_exact_with_progress(
    reader: &mut impl Read,
    buffer: &mut [u8],
    phase: &str,
) -> io::Result<()> {
    let mut received = 0;
    while received < buffer.len() {
        match reader.read(&mut buffer[received..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    format!(
                        "{phase}: received {received} of {} bytes before the connection closed",
                        buffer.len()
                    ),
                ));
            }
            Ok(count) => received += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                return Err(io::Error::new(
                    error.kind(),
                    format!(
                        "{phase}: received {received} of {} bytes: {error}",
                        buffer.len()
                    ),
                ));
            }
        }
    }
    Ok(())
}

fn receive_pty_master(control: &UnixStream) -> io::Result<OwnedFd> {
    // XNU unp_externalize installs every descriptor before recvmsg copies control
    // data to userspace; a one-fd receive buffer can lose unreported descriptors.
    // Match XNU's UIPC_MAX_CMSG_FD (512), also above Linux's SCM_MAX_FD (253).
    // Source: xnu/bsd/kern/uipc_usrreq.c. Accept one, but own/close every extra.
    receive_pty_master_with_capacity(control, 512)
}

fn receive_pty_master_with_capacity(
    control: &UnixStream,
    descriptor_capacity: u32,
) -> io::Result<OwnedFd> {
    let mut payload = [0_u8; 1];
    let mut vector = libc::iovec {
        iov_base: payload.as_mut_ptr().cast(),
        iov_len: payload.len(),
    };
    let control_size =
        unsafe { libc::CMSG_SPACE(descriptor_capacity * size_of::<libc::c_int>() as u32) } as usize;
    let mut ancillary = vec![0_usize; control_size.div_ceil(size_of::<usize>())];
    // SAFETY: zeroed msghdr is a valid starting point before its fields are initialized.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = ancillary.as_mut_ptr().cast();
    message.msg_controllen = control_size as _;

    // Linux must set CLOEXEC atomically: the renderer can coexist with spawning threads.
    #[cfg(target_os = "linux")]
    let flags = libc::MSG_CMSG_CLOEXEC;
    #[cfg(not(target_os = "linux"))]
    let flags = 0;
    let received = loop {
        message.msg_controllen = control_size as _;
        message.msg_flags = 0;
        // SAFETY: message borrows initialized payload and aligned ancillary storage.
        let received = unsafe { libc::recvmsg(control.as_raw_fd(), &mut message, flags) };
        if received >= 0 {
            break received;
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    };

    // Adopt *all* delivered descriptors before checking the payload/truncation. Even a
    // rejected packet transfers ownership; do not leak the unexpected descriptors.
    // Bound all declared control/header lengths by our actual receive buffer.
    message.msg_controllen = message.msg_controllen.min(control_size as _);
    // SAFETY: recvmsg just filled this live buffer and installed its descriptors;
    // no descriptor has yet been adopted or closed by another owner.
    let mut descriptors = unsafe { received_descriptors(&message) }?;
    if received != 1
        || payload[0] != b'1'
        || message.msg_flags & libc::MSG_CTRUNC != 0
        || descriptors.len() != 1
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon did not provide exactly one PTY descriptor",
        ));
    }
    let descriptor = descriptors.remove(0);
    #[cfg(not(target_os = "linux"))]
    {
        // Darwin has no MSG_CMSG_CLOEXEC. Never return an inheritable descriptor.
        // SAFETY: descriptor is owned and live until after this checked call.
        if unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(descriptor)
}

/// Own every delivered descriptor, even when another control entry is unexpected.
///
/// # Safety
/// `message` must borrow a live, initialized recvmsg receive buffer, with its extent
/// clamped to that allocation. Its SCM_RIGHTS numbers must be fresh kernel-delivered
/// descriptors, not already owned or closed elsewhere.
unsafe fn received_descriptors(message: &libc::msghdr) -> io::Result<Vec<OwnedFd>> {
    let mut descriptors = Vec::new();
    let mut only_rights = true;
    // SAFETY: message still borrows recvmsg's initialized ancillary storage.
    let mut header = unsafe { libc::CMSG_FIRSTHDR(message) };
    while !header.is_null() {
        // SAFETY: FIRSTHDR/NXTHDR only return headers within the clamped buffer.
        let entry = unsafe { &*header };
        let base = unsafe { libc::CMSG_LEN(0) } as usize;
        // SAFETY: header and msg_control point into the same live receive buffer.
        let offset = unsafe {
            header
                .cast::<u8>()
                .offset_from(message.msg_control.cast::<u8>())
        } as usize;
        let remaining = message.msg_controllen as usize - offset;
        let length = entry.cmsg_len as usize;
        if length < base {
            only_rights = false;
            break;
        }
        let complete = length <= remaining;
        only_rights &= complete;
        if entry.cmsg_level == libc::SOL_SOCKET && entry.cmsg_type == libc::SCM_RIGHTS {
            let bytes = length.min(remaining).saturating_sub(base);
            only_rights &= bytes > 0 && bytes.is_multiple_of(size_of::<RawFd>());
            for index in 0..bytes / size_of::<RawFd>() {
                // SAFETY: the kernel's SCM_RIGHTS payload contains these descriptor values.
                let raw = unsafe {
                    std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<RawFd>().add(index))
                };
                // SAFETY: successful recvmsg transferred ownership of this descriptor.
                descriptors.push(unsafe { OwnedFd::from_raw_fd(raw) });
            }
        } else {
            only_rights = false;
        }
        if !complete {
            break;
        }
        // SAFETY: both pointers refer to the same live recvmsg control buffer.
        header = unsafe { libc::CMSG_NXTHDR(message, header) };
    }
    if !only_rights {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon response contained unexpected control data",
        ));
    }
    Ok(descriptors)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::time::{SystemTime, UNIX_EPOCH};

    // Client behaviour against scripted servers.

    #[test]
    fn terminal_attach_reports_truncated_history_progress() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        server.write_all(&[0, 0, 0]).unwrap();
        drop(server);

        let error = receive_header(&mut client).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
        assert!(
            error
                .to_string()
                .contains("history length: received 3 of 8 bytes")
        );
    }

    #[test]
    fn terminal_attach_reports_when_daemon_is_busy() {
        let (mut server, mut client) = UnixStream::pair().unwrap();
        let response = thread::spawn(move || {
            server.write_all(&REJECTION_MARKER.to_be_bytes()).unwrap();
            server.write_all(&[4]).unwrap();
        });

        let error = receive_header(&mut client).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert_eq!(error.to_string(), "daemon is busy attaching terminals");
        response.join().unwrap();
    }

    #[test]
    fn terminal_attach_retries_when_daemon_reports_capacity() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let socket_path = std::env::temp_dir().join(format!(
            "axo-attach-capacity-{}-{unique}.sock",
            std::process::id()
        ));
        let listener = UnixListener::bind(&socket_path).unwrap();
        let descriptor = std::fs::File::open("/dev/null").unwrap();
        let server = thread::spawn(move || {
            let mut first = accept_test_attachment(&listener);
            first.write_all(&REJECTION_MARKER.to_be_bytes()).unwrap();
            first.write_all(&[4]).unwrap();
            drop(first);

            let mut second = accept_test_attachment(&listener);
            second.write_all(&0_u64.to_be_bytes()).unwrap();
            send_test_file_descriptor(second.as_raw_fd(), descriptor.as_raw_fd());
        });

        let Attachment {
            control,
            pty: master,
            ..
        } = connect(&socket_path, 1).unwrap();
        drop(master);
        drop(control);
        server.join().unwrap();
        std::fs::remove_file(socket_path).unwrap();
    }

    #[test]
    fn terminal_attach_retries_a_truncated_history_response() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let socket_path = std::env::temp_dir().join(format!(
            "axo-attach-retry-{}-{unique}.sock",
            std::process::id()
        ));
        let listener = UnixListener::bind(&socket_path).unwrap();
        let descriptor = std::fs::File::open("/dev/null").unwrap();
        let server = thread::spawn(move || {
            let mut first = accept_test_attachment(&listener);
            first.write_all(&[0, 0, 0]).unwrap();
            drop(first);

            let mut second = accept_test_attachment(&listener);
            second.write_all(&0_u64.to_be_bytes()).unwrap();
            send_test_file_descriptor(second.as_raw_fd(), descriptor.as_raw_fd());
        });

        let Attachment {
            control,
            pty: master,
            ..
        } = connect(&socket_path, 1).unwrap();
        drop(master);
        drop(control);
        server.join().unwrap();
        std::fs::remove_file(socket_path).unwrap();
    }

    fn accept_test_attachment(listener: &UnixListener) -> UnixStream {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut request = [0; 2];
        stream.read_exact(&mut request).unwrap();
        assert_eq!(&request, b"1\n");
        // Consume the request before closing: unread socket data can otherwise
        // reset the peer and race its request write instead of testing retries.
        stream
    }

    fn send_test_file_descriptor(socket_fd: RawFd, descriptor: RawFd) {
        send_descriptor(socket_fd, descriptor).unwrap();
    }

    fn listener() -> (UnixListener, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "axo-pty-attach-{}-{:?}.sock",
            std::process::id(),
            thread::current().id()
        ));
        let _ = std::fs::remove_file(&path);
        (UnixListener::bind(&path).unwrap(), path)
    }

    #[test]
    fn an_accepted_attachment_delivers_the_header_descriptor_and_replay() {
        let (listener, path) = listener();
        let (pipe_read, pipe_write) = {
            let mut fds = [0; 2];
            assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
            unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
        };
        let (release, released) = std::sync::mpsc::channel();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            assert_eq!(read_request(&mut stream).unwrap(), 42);
            write_acceptance(&mut stream, 5, &pipe_write).unwrap();
            stream.write_all(b"hello").unwrap();
            released.recv().unwrap();
        });
        let mut attachment = open(&path, 42).unwrap();
        assert_eq!(attachment.replay_bytes, 5);
        assert_eq!(attachment.control.read_timeout().unwrap(), None);
        assert_eq!(attachment.control.write_timeout().unwrap(), None);
        // SAFETY: the attachment owns this live received descriptor.
        let flags = unsafe { libc::fcntl(attachment.pty.as_raw_fd(), libc::F_GETFD) };
        assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0);
        let mut replay = [0_u8; 5];
        attachment.control.read_exact(&mut replay).unwrap();
        assert_eq!(&replay, b"hello");
        release.send(()).unwrap();
        server.join().unwrap();
        // The received descriptor is the pipe's write end.
        let mut written = std::fs::File::from(attachment.pty);
        written.write_all(b"x").unwrap();
        let mut byte = [0_u8; 1];
        std::fs::File::from(pipe_read)
            .read_exact(&mut byte)
            .unwrap();
        assert_eq!(&byte, b"x");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_peer_that_exits_during_handshake_can_still_deliver_buffered_output() {
        let (mut control, mut peer) = UnixStream::pair().unwrap();
        control
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        control
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        peer.write_all(b"last").unwrap();
        drop(peer);
        clear_handshake_timeouts(&control).unwrap();
        let mut bytes = [0; 4];
        control.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"last");
        assert_eq!(control.read(&mut [0]).unwrap(), 0);
    }

    fn test_pty(rows: u16, columns: u16) -> (OwnedFd, OwnedFd) {
        let mut master = -1;
        let mut slave = -1;
        let mut size = libc::winsize {
            ws_row: rows,
            ws_col: columns,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: writable descriptor outputs and initialized size; name/termios are optional.
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut size,
                )
            },
            0
        );
        // SAFETY: successful openpty returned two fresh owned descriptors.
        let descriptors = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
        crate::process::set_cloexec(master).unwrap();
        crate::process::set_cloexec(slave).unwrap();
        descriptors
    }

    #[test]
    fn prepared_attachment_preserves_grid_and_leaves_live_bytes_for_the_renderer() {
        let (control, mut peer) = UnixStream::pair().unwrap();
        let (pty, slave) = test_pty(45, 200);
        let flags = unsafe { libc::fcntl(pty.as_raw_fd(), libc::F_GETFL) };
        peer.write_all(b"historyLIVE").unwrap();
        let mut prepared = Attachment {
            control,
            pty,
            replay_bytes: 7,
        }
        .prepare_at(crate::process::WindowSize::new(45, 200).unwrap())
        .unwrap();
        assert_eq!(prepared.replay(), b"history");
        assert_eq!(
            (prepared.size().rows(), prepared.size().columns()),
            (45, 200)
        );
        assert_eq!(prepared.attachment.control.read_timeout().unwrap(), None);
        let mut live = [0; 4];
        prepared.attachment.control.read_exact(&mut live).unwrap();
        assert_eq!(&live, b"LIVE");
        prepared
            .attachment
            .resize(crate::process::WindowSize::new(24, 80).unwrap())
            .unwrap();
        assert_eq!(
            crate::process::window_size(&slave).unwrap(),
            crate::process::WindowSize::new(24, 80).unwrap()
        );
        assert_eq!(
            unsafe { libc::fcntl(prepared.attachment.pty.as_raw_fd(), libc::F_GETFL) },
            flags
        );
    }

    #[test]
    fn replay_bootstrap_rejects_truncation_oversize_and_unknown_grid() {
        for (rows, length, expected) in [
            (25, 6, io::ErrorKind::UnexpectedEof),
            (
                25,
                MAX_TERMINAL_REPLAY_BYTES as u64 + 1,
                io::ErrorKind::InvalidData,
            ),
            (0, 0, io::ErrorKind::InvalidData),
        ] {
            let (control, mut peer) = UnixStream::pair().unwrap();
            let (pty, _slave) = test_pty(rows, 80);
            peer.write_all(b"short").unwrap();
            drop(peer);
            let error = Attachment {
                control,
                pty,
                replay_bytes: length,
            }
            .prepare_at(crate::process::WindowSize::new(25, 80).unwrap())
            .unwrap_err();
            assert_eq!(error.kind(), expected);
        }
    }

    #[test]
    fn snapshot_grid_is_captured_metadata_not_a_later_pty_query() {
        let (listener, path) = listener();
        let (master, slave) = test_pty(45, 200);
        let captured = crate::process::WindowSize::new(45, 200).unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            assert_eq!(
                read_versioned_request(&mut stream).unwrap(),
                AttachRequest {
                    version: AttachVersion::V3,
                    shell_id: 42
                }
            );
            // A different client resized after snapshot capture, before descriptor receipt.
            let changed = libc::winsize {
                ws_row: 20,
                ws_col: 70,
                ws_xpixel: 0,
                ws_ypixel: 0,
            };
            assert_eq!(
                unsafe { libc::ioctl(slave.as_raw_fd(), libc::TIOCSWINSZ, &changed) },
                0
            );
            write_snapshot_acceptance(&mut stream, 7, &master, captured).unwrap();
            stream.write_all(b"historyLIVE").unwrap();
        });
        let mut prepared = open_snapshot(&path, 42).unwrap();
        assert_eq!(prepared.size(), captured);
        assert_eq!(prepared.replay(), b"history");
        assert_eq!(
            crate::process::window_size(&prepared.attachment.pty).unwrap(),
            crate::process::WindowSize::new(20, 70).unwrap()
        );
        let mut live = [0; 4];
        prepared.attachment.control.read_exact(&mut live).unwrap();
        assert_eq!(&live, b"LIVE");
        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn snapshot_requests_reject_bad_versions_and_bad_grid_metadata() {
        for request in [
            b"3:\n".as_slice(),
            b"4:42\n",
            b"3:-1\n",
            b"3:0\n",
            b"3:9223372036854775808\n",
        ] {
            let (mut server, mut client) = UnixStream::pair().unwrap();
            client.write_all(request).unwrap();
            assert!(read_versioned_request(&mut server).is_err());
        }
        let (listener, path) = listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            assert_eq!(
                read_versioned_request(&mut stream).unwrap().version,
                AttachVersion::V3
            );
            stream.write_all(&0_u64.to_be_bytes()).unwrap();
            stream.write_all(&[0, 0, 0, 80]).unwrap();
        });
        assert_eq!(
            open_snapshot(&path, 1).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn snapshot_refusal_never_retries_as_legacy() {
        let (listener, path) = listener();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            assert_eq!(
                read_versioned_request(&mut stream).unwrap().version,
                AttachVersion::V3
            );
            write_rejection(&mut stream, Rejection::Other).unwrap();
            listener
        });
        let error = open_snapshot(&path, 1).unwrap_err();
        assert!(error.to_string().contains("requires updated axod"));
        let listener = server.join().unwrap();
        listener.set_nonblocking(true).unwrap();
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn invalid_shell_ids_are_rejected_before_connecting() {
        for id in [0, -1, i64::MIN] {
            let error = open(Path::new("/no-such-axo-attach.sock"), id).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        }
    }

    #[test]
    fn rejected_descriptor_packets_close_every_delivered_descriptor() {
        for (count, payload) in [(1, b'X'), (2, b'1'), (8, b'1')] {
            let (client, server) = UnixStream::pair().unwrap();
            let (passed, observers): (Vec<_>, Vec<_>) =
                (0..count).map(|_| UnixStream::pair().unwrap()).unzip();
            for observer in &observers {
                // Set this before peer closure: Darwin refuses socket options afterwards.
                observer
                    .set_read_timeout(Some(Duration::from_secs(1)))
                    .unwrap();
            }
            let descriptors: Vec<_> = passed.iter().map(AsRawFd::as_raw_fd).collect();
            send_descriptor_packet(&server, &descriptors, payload);
            drop(passed);
            assert_eq!(
                receive_pty_master(&client).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
            for mut observer in observers {
                let observed = observer.read(&mut [0]);
                assert!(
                    matches!(observed, Ok(0)),
                    "leaked descriptor: count={count} payload={payload} observed={observed:?}"
                );
            }
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn truncated_descriptor_packets_close_delivered_descriptors() {
        let (client, server) = UnixStream::pair().unwrap();
        let (passed, mut observer) = UnixStream::pair().unwrap();
        observer
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        // Linux closes undisclosed descriptors on truncation; we must close those
        // it delivered. Do not run the deliberately undersized receive on Darwin.
        send_descriptor_packet(&server, &[passed.as_raw_fd(); 8], b'1');
        drop(passed);
        assert_eq!(
            receive_pty_master_with_capacity(&client, 1)
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(observer.read(&mut [0]).unwrap(), 0);
    }

    #[test]
    fn a_descriptor_marker_without_a_descriptor_is_refused() {
        let (client, mut server) = UnixStream::pair().unwrap();
        server.write_all(b"1").unwrap();
        assert_eq!(
            receive_pty_master(&client).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    fn send_descriptor_packet(socket: &UnixStream, descriptors: &[RawFd], mut payload: u8) {
        let bytes = std::mem::size_of_val(descriptors);
        // SAFETY: calculate native ancillary capacity for this test's descriptor slice.
        let capacity = unsafe { libc::CMSG_SPACE(bytes as u32) } as usize;
        let mut control = vec![0_usize; capacity.div_ceil(size_of::<usize>())];
        let mut vector = libc::iovec {
            iov_base: (&mut payload as *mut u8).cast(),
            iov_len: 1,
        };
        // SAFETY: zero initializes the unused pointer/count fields.
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = &mut vector;
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = capacity as _;
        // SAFETY: control is aligned and has room for this header and all descriptors.
        unsafe {
            let header = libc::CMSG_FIRSTHDR(&message);
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(bytes as u32) as _;
            std::ptr::copy_nonoverlapping(
                descriptors.as_ptr().cast::<u8>(),
                libc::CMSG_DATA(header),
                bytes,
            );
            assert_eq!(libc::sendmsg(socket.as_raw_fd(), &message, 0), 1);
        }
    }

    #[test]
    fn rejections_map_to_error_kinds() {
        for (rejection, kind) in [
            (Rejection::ShellNotOpen, io::ErrorKind::NotFound),
            (Rejection::Other, io::ErrorKind::Other),
            (Rejection::NotAllowed, io::ErrorKind::PermissionDenied),
        ] {
            let (listener, path) = listener();
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                read_request(&mut stream).unwrap();
                write_rejection(&mut stream, rejection).unwrap();
            });
            assert_eq!(open(&path, 7).unwrap_err().kind(), kind);
            server.join().unwrap();
            let _ = std::fs::remove_file(path);
        }
        assert_eq!(Rejection::from_code(1), Rejection::Other);
    }

    #[test]
    fn malformed_requests_are_refused() {
        for request in [&b"0\n"[..], b"-3\n", b"12a\n", b"99999999999999999999\n"] {
            let (listener, path) = listener();
            let server = thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                read_request(&mut stream)
            });
            let mut client = UnixStream::connect(&path).unwrap();
            client.write_all(request).unwrap();
            assert!(server.join().unwrap().is_err(), "{request:?}");
            let _ = std::fs::remove_file(path);
        }
    }
}
