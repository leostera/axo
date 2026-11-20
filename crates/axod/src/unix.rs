use std::fs::{self, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use clap::{CommandFactory, FromArgMatches, Parser, Subcommand};

const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;
/// How often a running axod checks its logs' size: axod runs for weeks (RFD0023).
const LOG_CHECK_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

#[derive(Parser)]
#[command(name = "axod", about = "Axo daemon command-line entrypoint")]
struct Cli {
    /// Override the default per-user Unix-domain socket path.
    #[arg(long)]
    socket: Option<PathBuf>,
    /// Override the directory for the daemon PID and stdout/stderr logs.
    #[arg(long, value_name = "PATH")]
    server_dir: Option<PathBuf>,
    /// Where to keep per-host relay credentials. Defaults to the Keychain on macOS and to
    /// private files in the server directory elsewhere.
    #[arg(long, value_enum)]
    host_credentials: Option<HostCredentialsArg>,
    /// The Axo relay's origin. Defaults to `AXO_RELAY_URL`, then to the production relay.
    /// Must be https, except for a loopback relay.
    #[arg(long, value_name = "URL")]
    relay_url: Option<String>,
    #[command(subcommand)]
    command: Option<AxodCommand>,
}

#[derive(Clone, Copy, clap::ValueEnum)]
enum HostCredentialsArg {
    Keychain,
    Files,
}

impl From<HostCredentialsArg> for axo_server::HostCredentialStorage {
    fn from(value: HostCredentialsArg) -> Self {
        match value {
            HostCredentialsArg::Keychain => Self::Keychain,
            HostCredentialsArg::Files => Self::Files,
        }
    }
}

#[derive(Subcommand)]
enum AxodCommand {
    /// Serve the Session in `AXO_SESSION_ID` to its agent as an MCP server on standard input
    /// and output, reaching Axod at `AXO_SOCKET` (RFD0015).
    Mcp,
}

fn main() {
    let version = format!(
        "{} (build {})",
        env!("CARGO_PKG_VERSION"),
        axo_server::build_number()
    );
    let matches = Cli::command().version(version).get_matches();
    let cli = Cli::from_arg_matches(&matches).expect("clap validated the arguments");
    match cli.command {
        Some(AxodCommand::Mcp) => {
            if let Err(error) = axo_mcp::serve_stdio() {
                eprintln!("axod mcp: {error}");
                std::process::exit(1);
            }
            return;
        }
        None => {}
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

    let relay_url = cli
        .relay_url
        .or_else(|| std::env::var("AXO_RELAY_URL").ok())
        .unwrap_or_else(|| axo_server::DEFAULT_RELAY_URL.to_owned());
    let endpoint = match axo_server::RelayEndpoint::parse(&relay_url) {
        Ok(endpoint) => endpoint,
        Err(error) => {
            eprintln!("axod: invalid relay URL: {error}");
            std::process::exit(2);
        }
    };

    log::info!(
        "event=daemon.started pid={} build={}",
        std::process::id(),
        axo_server::build_number()
    );
    raise_open_file_limit();
    keep_process_logs_bounded(server_directory.clone());
    if let Err(error) = axo_server::serve_ipc(
        cli.socket.as_deref(),
        &server_directory,
        env!("CARGO_PKG_VERSION"),
        axo_server::RemoteAccess {
            endpoint,
            credential_storage: cli.host_credentials.map_or_else(
                axo_server::HostCredentialStorage::platform_default,
                Into::into,
            ),
        },
    ) {
        log::error!("event=daemon.failed reason={error:?}");
        std::process::exit(1);
    }
    log::info!("event=daemon.stopped");
}

/// launchd starts agents with a soft limit of 256 descriptors. Every pane costs about four (PTY
/// master, attach socket, pump wake pipe, child pipes) plus one per client connection, so a few
/// dozen panes with the app and web clients attached would exhaust it. Raise the soft limit to
/// the hard limit, capped at macOS's per-process maximum (`OPEN_MAX`).
fn raise_open_file_limit() {
    const TARGET: libc::rlim_t = 10_240;
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: getrlimit/setrlimit read and write one initialized rlimit.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        log::warn!(
            "event=daemon.nofile_unknown error_kind={:?}",
            io::Error::last_os_error().kind()
        );
        return;
    }
    let wanted = TARGET.min(limit.rlim_max);
    if limit.rlim_cur >= wanted {
        return;
    }
    let previous = limit.rlim_cur;
    limit.rlim_cur = wanted;
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) } == 0 {
        log::info!("event=daemon.nofile_raised from={previous} to={wanted}");
    } else {
        log::warn!(
            "event=daemon.nofile_raise_failed from={previous} wanted={wanted} error_kind={:?}",
            io::Error::last_os_error().kind()
        );
    }
}

/// The process's standard streams and the logs they write to.
fn process_logs(server_directory: &Path) -> [(libc::c_int, PathBuf); 2] {
    [
        (libc::STDOUT_FILENO, server_directory.join("stdout.log")),
        (libc::STDERR_FILENO, server_directory.join("stderr.log")),
    ]
}

fn configure_process_logs(server_directory: &Path) -> io::Result<()> {
    axo_server::prepare_server_directory(server_directory)?;
    for (stream, path) in process_logs(server_directory) {
        rotate_if_oversized(&path)?;
        redirect_standard_stream(stream, &path)?;
    }
    Ok(())
}

/// Keeps each log under [`MAX_LOG_BYTES`] (plus one interval's writes) while axod runs: an
/// oversized log moves to `.log.1` and the stream reopens a fresh one.
fn keep_process_logs_bounded(server_directory: PathBuf) {
    std::thread::Builder::new()
        .name("axod-logs".into())
        .spawn(move || {
            loop {
                std::thread::sleep(LOG_CHECK_INTERVAL);
                for (stream, path) in process_logs(&server_directory) {
                    if let Err(error) = rotate_open_log(stream, &path) {
                        log::warn!(
                            "event=daemon.log_rotation_failed error_kind={:?}",
                            error.kind()
                        );
                    }
                }
            }
        })
        .map(drop)
        .unwrap_or_else(|error| {
            log::warn!(
                "event=daemon.log_rotation_unavailable error_kind={:?}",
                error.kind()
            )
        });
}

/// Rotates the log `stream` writes to if it is oversized, then points `stream` at a fresh one.
/// Lines written in between land in the rotated file. Whether it rotated.
fn rotate_open_log(stream: libc::c_int, path: &Path) -> io::Result<bool> {
    if !rotate_if_oversized(path)? {
        return Ok(false);
    }
    redirect_standard_stream(stream, path)?;
    Ok(true)
}

/// Moves an oversized log to `.log.1`, replacing the previous one. Whether it moved.
fn rotate_if_oversized(path: &Path) -> io::Result<bool> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if metadata.len() <= MAX_LOG_BYTES {
        return Ok(false);
    }

    let previous_path = path.with_extension("log.1");
    match fs::remove_file(&previous_path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    fs::rename(path, previous_path)?;
    Ok(true)
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
    use std::io::Write;

    /// A log that grows past its limit while axod runs moves aside, and what is written next
    /// goes to a fresh log.
    #[test]
    fn a_running_log_past_its_limit_moves_aside_and_writing_continues_in_a_fresh_one() {
        let directory = std::env::temp_dir().join(format!("axod-logs-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("stderr.log");
        // A stream of this test's own, standing in for stderr.
        // SAFETY: duplicates a descriptor this process holds; the copy is owned below.
        let stream = unsafe { libc::dup(libc::STDERR_FILENO) };
        assert!(stream >= 0);
        redirect_standard_stream(stream, &path).unwrap();
        // SAFETY: a fresh duplicate, owned only by this File.
        let mut writer =
            unsafe { <fs::File as std::os::fd::FromRawFd>::from_raw_fd(libc::dup(stream)) };
        assert!(!rotate_open_log(stream, &path).unwrap(), "small logs stay");
        writer
            .write_all(&vec![b'x'; MAX_LOG_BYTES as usize + 1])
            .unwrap();
        assert!(rotate_open_log(stream, &path).unwrap());
        // SAFETY: `stream` is ours and owned only by this File from here on.
        let mut fresh = unsafe { <fs::File as std::os::fd::FromRawFd>::from_raw_fd(stream) };
        fresh.write_all(b"after\n").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "after\n");
        assert_eq!(
            fs::metadata(path.with_extension("log.1")).unwrap().len(),
            MAX_LOG_BYTES + 1
        );
        drop(writer);
        fs::remove_dir_all(directory).unwrap();
    }
}
