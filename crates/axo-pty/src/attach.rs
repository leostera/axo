//! Attach protocol v2, both ends.
//!
//! The client writes its shell ID and a newline. Axod answers with either `u64::MAX` and a
//! one-byte rejection code, or:
//!
//! 1. the replay length as a big-endian `u64` (at most `MAX_TERMINAL_REPLAY_BYTES`),
//! 2. a one-byte message (`'1'`) carrying the PTY master descriptor (`SCM_RIGHTS`), then
//! 3. the replay followed by live output, as raw bytes, until the PTY reaches end of file.
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
}

impl Rejection {
    /// Unknown codes (including v1's retired `1`) are `Other`.
    pub fn from_code(code: u8) -> Rejection {
        match code {
            2 => Rejection::ShellNotOpen,
            4 => Rejection::DaemonBusy,
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

// Server side.

const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);

const MAX_SHELL_ID_DIGITS: usize = 19;

/// Reads the client's request: one positive shell ID and a newline, within `REQUEST_TIMEOUT`.
pub fn read_request(stream: &mut UnixStream) -> io::Result<i64> {
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut request = Vec::with_capacity(MAX_SHELL_ID_DIGITS);
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
            Ok(_) if byte[0].is_ascii_digit() && request.len() < MAX_SHELL_ID_DIGITS => {
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
    let shell_id = text
        .parse::<i64>()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "shell ID is invalid"))?;
    if shell_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "shell ID must be positive",
        ));
    }
    Ok(shell_id)
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

/// Clients never write after their request; readable means closed (or a protocol violation,
/// which is discarded).
pub fn peer_closed(stream: &mut UnixStream) -> bool {
    let mut descriptor = libc::pollfd {
        fd: stream.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: descriptor points to one initialized pollfd for this live socket.
    if unsafe { libc::poll(&mut descriptor, 1, 0) } <= 0 {
        return false;
    }
    let mut scratch = [0_u8; 4096];
    match stream.read(&mut scratch) {
        Ok(0) => true,
        Ok(_) => false,
        Err(error) => !matches!(
            error.kind(),
            io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        ),
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
    let mut control = UnixStream::connect(socket_path)?;
    control.set_read_timeout(Some(Duration::from_secs(5)))?;
    writeln!(control, "{shell_id}")?;
    let replay_bytes = receive_header(&mut control).map_err(|error| {
        io::Error::new(error.kind(), format!("read attachment header: {error}"))
    })?;
    let pty = receive_pty_master(&control)
        .map_err(|error| io::Error::new(error.kind(), format!("receive PTY: {error}")))?;
    Ok(Attachment {
        control,
        pty,
        replay_bytes,
    })
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
    let mut payload = [0_u8; 1];
    let mut vector = libc::iovec {
        iov_base: payload.as_mut_ptr().cast(),
        iov_len: payload.len(),
    };
    let control_size = unsafe { libc::CMSG_SPACE(size_of::<libc::c_int>() as u32) } as usize;
    let mut ancillary = vec![0_usize; control_size.div_ceil(size_of::<usize>())];
    // SAFETY: zeroed msghdr is a valid starting point before its fields are initialized.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = ancillary.as_mut_ptr().cast();
    message.msg_controllen = control_size as _;

    // SAFETY: message points to initialized payload and ancillary storage.
    let received = unsafe { libc::recvmsg(control.as_raw_fd(), &mut message, 0) };
    if received == -1 {
        return Err(io::Error::last_os_error());
    }
    if received != 1 || payload[0] != b'1' || message.msg_flags & libc::MSG_CTRUNC != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon did not provide a PTY descriptor",
        ));
    }

    // SAFETY: message's control storage was sized for one descriptor.
    let header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    if header.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon response did not contain a control message",
        ));
    }
    let minimum_length = unsafe { libc::CMSG_LEN(size_of::<libc::c_int>() as u32) } as usize;
    // SAFETY: header points to the control data supplied by recvmsg.
    if unsafe { (*header).cmsg_level != libc::SOL_SOCKET }
        || unsafe { (*header).cmsg_type != libc::SCM_RIGHTS }
        || unsafe { (*header).cmsg_len as usize } < minimum_length
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon response contained an unexpected control message",
        ));
    }

    // SAFETY: the header is SCM_RIGHTS and contains at least one descriptor.
    let descriptor = unsafe { std::ptr::read_unaligned(libc::CMSG_DATA(header).cast()) };
    if descriptor < 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon supplied an invalid PTY descriptor",
        ));
    }
    // SAFETY: recvmsg installed this descriptor in the current process.
    Ok(unsafe { OwnedFd::from_raw_fd(descriptor) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::time::{SystemTime, UNIX_EPOCH};

    // Client behaviour against scripted servers (moved from `axod terminal-attach`).

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
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            assert_eq!(read_request(&mut stream).unwrap(), 42);
            write_acceptance(&mut stream, 5, &pipe_write).unwrap();
            stream.write_all(b"hello").unwrap();
        });
        let mut attachment = open(&path, 42).unwrap();
        server.join().unwrap();
        assert_eq!(attachment.replay_bytes, 5);
        let mut replay = [0_u8; 5];
        attachment.control.read_exact(&mut replay).unwrap();
        assert_eq!(&replay, b"hello");
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
    fn rejections_map_to_error_kinds() {
        for (rejection, kind) in [
            (Rejection::ShellNotOpen, io::ErrorKind::NotFound),
            (Rejection::Other, io::ErrorKind::Other),
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
