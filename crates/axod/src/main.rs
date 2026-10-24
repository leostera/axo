use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::mem::size_of;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use clap::{CommandFactory, FromArgMatches, Parser, Subcommand};

const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;
const MAX_TERMINAL_OUTPUT_HISTORY_BYTES: u64 = 8 * 1024 * 1024;
const ATTACH_REJECTION_MARKER: u64 = u64::MAX;
const ATTACH_RETRY_WINDOW: Duration = Duration::from_secs(10);
const ATTACH_RETRY_DELAY: Duration = Duration::from_millis(50);

static TERMINAL_RESIZE_REQUESTED: AtomicBool = AtomicBool::new(false);

#[derive(Parser)]
#[command(name = "axod", about = "Axo daemon command-line entrypoint")]
struct Cli {
    /// Override the default per-user Unix-domain socket path.
    #[arg(long)]
    socket: Option<PathBuf>,
    /// Override the directory for the daemon PID and stdout/stderr logs.
    #[arg(long, value_name = "PATH")]
    server_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Option<AxodCommand>,
}

#[derive(Subcommand)]
enum AxodCommand {
    /// Attach standard input and output to an existing daemon-owned PTY.
    TerminalAttach {
        #[arg(long, value_name = "PATH")]
        attach_socket: PathBuf,
        #[arg(long, value_name = "ID")]
        shell_id: i64,
    },
}

fn main() {
    let version = format!(
        "{} (build {})",
        env!("CARGO_PKG_VERSION"),
        axo_server::build_number()
    );
    let matches = Cli::command().version(version).get_matches();
    let cli = Cli::from_arg_matches(&matches).expect("clap validated the arguments");
    if let Some(AxodCommand::TerminalAttach {
        attach_socket,
        shell_id,
    }) = cli.command
    {
        if let Err(error) = attach_terminal(&attach_socket, shell_id) {
            eprintln!("axod terminal-attach: {error}");
            std::process::exit(1);
        }
        return;
    }

    let server_directory = match cli.server_dir {
        Some(path) => path,
        None => match axo_server::default_server_directory() {
            Ok(path) => path,
            Err(error) => {
                eprintln!("axod: could not determine the server directory: {error}");
                std::process::exit(1);
            }
        },
    };

    if let Err(error) = configure_process_logs(&server_directory) {
        eprintln!("axod: could not configure process logs: {error}");
        std::process::exit(1);
    }
    if let Err(error) =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
            .format_timestamp_millis()
            .try_init()
    {
        eprintln!("axod: could not initialize logging: {error}");
        std::process::exit(1);
    }

    log::info!(
        "event=daemon.started pid={} build={}",
        std::process::id(),
        axo_server::build_number()
    );
    if let Err(error) = axo_server::serve_ipc(
        cli.socket.as_deref(),
        &server_directory,
        env!("CARGO_PKG_VERSION"),
    ) {
        log::error!("event=daemon.failed reason={error:?}");
        std::process::exit(1);
    }
    log::info!("event=daemon.stopped");
}

fn attach_terminal(socket_path: &Path, shell_id: i64) -> io::Result<()> {
    if shell_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "shell ID must be positive",
        ));
    }

    // Attach protocol v2: output (replay, then live) arrives on the control socket from Axod's
    // PTY pump. The PTY descriptor is only for input and resizing; reading it would steal output.
    let (mut control, master) = connect_terminal_attachment(socket_path, shell_id)?;
    control.set_read_timeout(None)?;
    let mut writer = File::from(duplicate_descriptor(master.as_raw_fd())?);
    let _input_mode = TerminalInputModeGuard::raw(libc::STDIN_FILENO)
        .map_err(|error| io::Error::new(error.kind(), format!("set input mode: {error}")))?;
    let _resize_forwarder = TerminalResizeForwarder::start(libc::STDIN_FILENO, master.as_raw_fd())
        .map_err(|error| io::Error::new(error.kind(), format!("forward terminal size: {error}")))?;

    thread::Builder::new()
        .name("axo-terminal-input".into())
        .spawn(move || {
            let mut stdin = io::stdin().lock();
            let _ = io::copy(&mut stdin, &mut writer);
        })?;

    let mut stdout = File::from(duplicate_descriptor(libc::STDOUT_FILENO)?);
    let mut output = [0_u8; 64 * 1024];
    loop {
        match control.read(&mut output) {
            Ok(0) => return Ok(()),
            Ok(count) => stdout.write_all(&output[..count]).map_err(|error| {
                io::Error::new(error.kind(), format!("forward terminal output: {error}"))
            })?,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

struct TerminalInputModeGuard {
    file_descriptor: RawFd,
    original: libc::termios,
}

impl TerminalInputModeGuard {
    fn raw(file_descriptor: RawFd) -> io::Result<Option<Self>> {
        // SAFETY: termios is initialized by tcgetattr on success.
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: file_descriptor is borrowed and original points to writable termios storage.
        if unsafe { libc::tcgetattr(file_descriptor, &mut original) } == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ENOTTY) {
                return Ok(None);
            }
            return Err(error);
        }

        let mut raw = original;
        // SAFETY: cfmakeraw mutates the initialized termios value in place.
        unsafe { libc::cfmakeraw(&mut raw) };
        // SAFETY: file_descriptor remains open and raw is a valid termios structure.
        if unsafe { libc::tcsetattr(file_descriptor, libc::TCSANOW, &raw) } == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(Some(Self {
            file_descriptor,
            original,
        }))
    }
}

impl Drop for TerminalInputModeGuard {
    fn drop(&mut self) {
        // SAFETY: this guard borrows a live standard-input descriptor and restores its saved mode.
        unsafe { libc::tcsetattr(self.file_descriptor, libc::TCSANOW, &self.original) };
    }
}

struct TerminalResizeForwarder {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    previous_handler: libc::sighandler_t,
}

impl TerminalResizeForwarder {
    fn start(input_fd: RawFd, pty_master_fd: RawFd) -> io::Result<Self> {
        copy_terminal_size(input_fd, pty_master_fd)?;
        TERMINAL_RESIZE_REQUESTED.store(false, Ordering::Relaxed);

        // SAFETY: the handler only updates an atomic flag and is valid for the process lifetime.
        let previous_handler = unsafe {
            libc::signal(
                libc::SIGWINCH,
                request_terminal_resize as *const () as libc::sighandler_t,
            )
        };
        if previous_handler == libc::SIG_ERR {
            return Err(io::Error::last_os_error());
        }

        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let resize_thread = thread::Builder::new()
            .name("axo-terminal-resize".into())
            .spawn(move || {
                while !thread_stop.load(Ordering::Relaxed) {
                    if TERMINAL_RESIZE_REQUESTED.swap(false, Ordering::Relaxed) {
                        let _ = copy_terminal_size(input_fd, pty_master_fd);
                    }
                    thread::sleep(Duration::from_millis(25));
                }
            });

        match resize_thread {
            Ok(thread) => Ok(Self {
                stop,
                thread: Some(thread),
                previous_handler,
            }),
            Err(error) => {
                // SAFETY: restore the handler that was active before installing ours.
                unsafe { libc::signal(libc::SIGWINCH, previous_handler) };
                Err(error)
            }
        }
    }
}

impl Drop for TerminalResizeForwarder {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        // SAFETY: restore the handler that was active before this forwarder started.
        unsafe { libc::signal(libc::SIGWINCH, self.previous_handler) };
    }
}

extern "C" fn request_terminal_resize(_signal: libc::c_int) {
    TERMINAL_RESIZE_REQUESTED.store(true, Ordering::Relaxed);
}

fn copy_terminal_size(input_fd: RawFd, pty_master_fd: RawFd) -> io::Result<bool> {
    // SAFETY: winsize is a plain C struct and TIOCGWINSZ initializes it on success.
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    // SAFETY: input_fd is borrowed and size points to writable memory for the ioctl call.
    if unsafe { libc::ioctl(input_fd, libc::TIOCGWINSZ, &mut size) } == -1 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOTTY) {
            return Ok(false);
        }
        return Err(error);
    }

    // SAFETY: pty_master_fd is borrowed and size contains a valid winsize structure.
    if unsafe { libc::ioctl(pty_master_fd, libc::TIOCSWINSZ, &size) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(true)
}

fn duplicate_descriptor(descriptor: libc::c_int) -> io::Result<OwnedFd> {
    // SAFETY: fcntl duplicates a valid descriptor into a newly owned descriptor.
    let duplicate = unsafe { libc::fcntl(descriptor, libc::F_DUPFD_CLOEXEC, 0) };
    if duplicate == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fcntl returned a new descriptor owned by this process.
    Ok(unsafe { OwnedFd::from_raw_fd(duplicate) })
}

fn connect_terminal_attachment(
    socket_path: &Path,
    shell_id: i64,
) -> io::Result<(UnixStream, OwnedFd)> {
    let deadline = Instant::now() + ATTACH_RETRY_WINDOW;
    loop {
        match open_terminal_attachment(socket_path, shell_id) {
            Ok(attachment) => return Ok(attachment),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::UnexpectedEof
                ) && Instant::now() < deadline =>
            {
                thread::sleep(ATTACH_RETRY_DELAY);
            }
            Err(error) => return Err(error),
        }
    }
}

fn open_terminal_attachment(
    socket_path: &Path,
    shell_id: i64,
) -> io::Result<(UnixStream, OwnedFd)> {
    let mut control = UnixStream::connect(socket_path)?;
    control.set_read_timeout(Some(Duration::from_secs(5)))?;
    writeln!(control, "{shell_id}")?;
    receive_attachment_header(&mut control).map_err(|error| {
        io::Error::new(error.kind(), format!("read attachment header: {error}"))
    })?;
    let master = receive_pty_master(&control)
        .map_err(|error| io::Error::new(error.kind(), format!("receive PTY: {error}")))?;
    Ok((control, master))
}

/// Returns the replay length; the replay itself follows the PTY descriptor on the stream.
fn receive_attachment_header(control: &mut UnixStream) -> io::Result<u64> {
    let mut length_bytes = [0_u8; size_of::<u64>()];
    read_exact_with_progress(control, &mut length_bytes, "history length")?;
    let length = u64::from_be_bytes(length_bytes);
    if length == ATTACH_REJECTION_MARKER {
        let mut code = [0_u8; 1];
        control.read_exact(&mut code)?;
        let (kind, message) = match code[0] {
            2 => (io::ErrorKind::NotFound, "shell is no longer open"),
            4 => (
                io::ErrorKind::WouldBlock,
                "daemon is busy attaching terminals",
            ),
            _ => (
                io::ErrorKind::Other,
                "daemon rejected the terminal attachment",
            ),
        };
        return Err(io::Error::new(kind, message));
    }
    if length > MAX_TERMINAL_OUTPUT_HISTORY_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon announced an oversized terminal history",
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

fn configure_process_logs(server_directory: &Path) -> io::Result<()> {
    axo_server::prepare_server_directory(server_directory)?;
    let stdout_path = server_directory.join("stdout.log");
    let stderr_path = server_directory.join("stderr.log");
    rotate_if_oversized(&stdout_path)?;
    rotate_if_oversized(&stderr_path)?;

    redirect_standard_stream(libc::STDOUT_FILENO, &stdout_path)?;
    redirect_standard_stream(libc::STDERR_FILENO, &stderr_path)?;
    Ok(())
}

fn rotate_if_oversized(path: &Path) -> io::Result<()> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if metadata.len() <= MAX_LOG_BYTES {
        return Ok(());
    }

    let previous_path = path.with_extension("log.1");
    match fs::remove_file(&previous_path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    fs::rename(path, previous_path)
}

fn redirect_standard_stream(file_descriptor: libc::c_int, path: &Path) -> io::Result<()> {
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;

    // SAFETY: `file` is open for the duration of dup2, and dup2 atomically
    // replaces the process-owned stdout/stderr descriptor with this file.
    if unsafe { libc::dup2(file.as_raw_fd(), file_descriptor) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn terminal_attach_reports_truncated_history_progress() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        server.write_all(&[0, 0, 0]).unwrap();
        drop(server);

        let error = receive_attachment_header(&mut client).unwrap_err();
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
            server
                .write_all(&ATTACH_REJECTION_MARKER.to_be_bytes())
                .unwrap();
            server.write_all(&[4]).unwrap();
        });

        let error = receive_attachment_header(&mut client).unwrap_err();
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
        let descriptor = File::open("/dev/null").unwrap();
        let server = thread::spawn(move || {
            let mut first = accept_test_attachment(&listener);
            first
                .write_all(&ATTACH_REJECTION_MARKER.to_be_bytes())
                .unwrap();
            first.write_all(&[4]).unwrap();
            drop(first);

            let mut second = accept_test_attachment(&listener);
            second.write_all(&0_u64.to_be_bytes()).unwrap();
            send_test_file_descriptor(second.as_raw_fd(), descriptor.as_raw_fd());
        });

        let (control, master) = connect_terminal_attachment(&socket_path, 1).unwrap();
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
        let descriptor = File::open("/dev/null").unwrap();
        let server = thread::spawn(move || {
            let mut first = accept_test_attachment(&listener);
            first.write_all(&[0, 0, 0]).unwrap();
            drop(first);

            let mut second = accept_test_attachment(&listener);
            second.write_all(&0_u64.to_be_bytes()).unwrap();
            send_test_file_descriptor(second.as_raw_fd(), descriptor.as_raw_fd());
        });

        let (control, master) = connect_terminal_attachment(&socket_path, 1).unwrap();
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
        let mut payload = b'1';
        let mut vector = libc::iovec {
            iov_base: (&mut payload as *mut u8).cast(),
            iov_len: 1,
        };
        let control_size = unsafe { libc::CMSG_SPACE(size_of::<libc::c_int>() as u32) } as usize;
        let mut ancillary = vec![0_usize; control_size.div_ceil(size_of::<usize>())];
        // SAFETY: zeroed msghdr is initialized before it is passed to sendmsg.
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = &mut vector;
        message.msg_iovlen = 1;
        message.msg_control = ancillary.as_mut_ptr().cast();
        message.msg_controllen = control_size as _;
        // SAFETY: the ancillary buffer is large enough for one descriptor.
        let header = unsafe { libc::CMSG_FIRSTHDR(&message) };
        assert!(!header.is_null());
        // SAFETY: header points into the initialized ancillary buffer.
        unsafe {
            (*header).cmsg_level = libc::SOL_SOCKET;
            (*header).cmsg_type = libc::SCM_RIGHTS;
            (*header).cmsg_len = libc::CMSG_LEN(size_of::<libc::c_int>() as u32) as _;
            std::ptr::write(libc::CMSG_DATA(header).cast::<libc::c_int>(), descriptor);
        }
        // SAFETY: message references valid payload and ancillary storage.
        assert_eq!(unsafe { libc::sendmsg(socket_fd, &message, 0) }, 1);
    }

    #[test]
    fn raw_input_mode_is_restored_when_the_guard_drops() {
        let (_master, slave) = open_pty();
        // SAFETY: termios is initialized by tcgetattr on success.
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: slave is an open PTY and original is writable.
        assert_eq!(
            unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut original) },
            0
        );

        let guard = TerminalInputModeGuard::raw(slave.as_raw_fd())
            .unwrap()
            .expect("PTY slave should support terminal modes");
        // SAFETY: termios is initialized by tcgetattr on success.
        let mut raw: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: slave is an open PTY and raw is writable.
        assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut raw) }, 0);
        assert_eq!(raw.c_lflag & (libc::ICANON | libc::ECHO | libc::ISIG), 0);

        drop(guard);
        // SAFETY: termios is initialized by tcgetattr on success.
        let mut restored: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: slave is an open PTY and restored is writable.
        assert_eq!(
            unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut restored) },
            0
        );
        let relevant_local_flags = libc::ICANON | libc::ECHO | libc::ISIG;
        assert_eq!(
            restored.c_lflag & relevant_local_flags,
            original.c_lflag & relevant_local_flags
        );
    }

    #[test]
    fn forwards_window_size_to_daemon_owned_pty() {
        let (input_master, input_slave) = open_pty();
        let (output_master, _output_slave) = open_pty();
        let expected = libc::winsize {
            ws_row: 41,
            ws_col: 137,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        // SAFETY: input_slave is an open PTY and expected points to a valid winsize.
        assert_eq!(
            unsafe { libc::ioctl(input_slave.as_raw_fd(), libc::TIOCSWINSZ, &expected) },
            0
        );
        assert!(copy_terminal_size(input_slave.as_raw_fd(), output_master.as_raw_fd()).unwrap());

        // SAFETY: winsize is initialized by TIOCGWINSZ on success.
        let mut actual: libc::winsize = unsafe { std::mem::zeroed() };
        // SAFETY: output_master is an open PTY and actual is writable for the ioctl call.
        assert_eq!(
            unsafe { libc::ioctl(output_master.as_raw_fd(), libc::TIOCGWINSZ, &mut actual) },
            0
        );
        assert_eq!(actual.ws_row, expected.ws_row);
        assert_eq!(actual.ws_col, expected.ws_col);
        drop(input_master);
    }

    fn open_pty() -> (OwnedFd, OwnedFd) {
        let mut master = -1;
        let mut slave = -1;
        // SAFETY: openpty initializes both descriptors on success; no optional attributes are used.
        let result = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(result, 0, "{}", io::Error::last_os_error());
        // SAFETY: openpty returned two new descriptors owned by this test.
        unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) }
    }
}
