use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::mem::size_of;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use clap::{CommandFactory, FromArgMatches, Parser, Subcommand};

const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;

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
        session_id: i64,
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
        session_id,
    }) = cli.command
    {
        if let Err(error) = attach_terminal(&attach_socket, session_id) {
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
    if let Err(error) = axo_server::serve_ipc(cli.socket.as_deref(), &server_directory) {
        log::error!("event=daemon.failed reason={error:?}");
        std::process::exit(1);
    }
    log::info!("event=daemon.stopped");
}

fn attach_terminal(socket_path: &Path, session_id: i64) -> io::Result<()> {
    if session_id <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "session ID must be positive",
        ));
    }

    let mut control = UnixStream::connect(socket_path)?;
    control.set_read_timeout(Some(Duration::from_secs(5)))?;
    writeln!(control, "{session_id}")?;
    let master = receive_pty_master(&control)?;
    let mut writer = File::from(duplicate_descriptor(master.as_raw_fd())?);
    let mut reader = File::from(master);

    thread::Builder::new()
        .name("axo-terminal-input".into())
        .spawn(move || {
            let mut stdin = io::stdin().lock();
            let _ = io::copy(&mut stdin, &mut writer);
        })?;

    let mut stdout = io::stdout().lock();
    match io::copy(&mut reader, &mut stdout) {
        Ok(_) => Ok(()),
        Err(error) if error.raw_os_error() == Some(libc::EIO) => Ok(()),
        Err(error) => Err(error),
    }
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
