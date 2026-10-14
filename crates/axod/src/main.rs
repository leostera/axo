use std::fs::{self, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use clap::{CommandFactory, FromArgMatches, Parser};

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
}

fn main() {
    let version = format!(
        "{} (build {})",
        env!("CARGO_PKG_VERSION"),
        axo_server::build_number()
    );
    let matches = Cli::command().version(version).get_matches();
    let cli = Cli::from_arg_matches(&matches).expect("clap validated the arguments");
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
