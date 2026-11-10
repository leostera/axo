use std::fs::{self, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

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
    axo_server::permissions::request_automation_if_launch_agent();
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
