use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use jsonrpc_core::IoHandler;
use jsonrpc_ipc_server::{Separator, ServerBuilder};
use serde_json::json;

const MAX_SOCKET_PATH_BYTES: usize = 103;

include!(concat!(env!("OUT_DIR"), "/build_number.rs"));

/// Returns the default directory for daemon metadata and logs.
pub fn default_server_directory() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not set"))?;
    Ok(PathBuf::from(home).join(".axo/server"))
}

/// Creates the daemon's per-user directory with private permissions.
pub fn prepare_server_directory(path: &Path) -> io::Result<()> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "server directory must be an absolute path",
        ));
    }
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

/// Starts Axo's local JSON-RPC server and blocks for the daemon's lifetime.
pub fn serve_ipc(
    socket_override: Option<&Path>,
    server_directory: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    prepare_server_directory(server_directory)?;
    let socket_path = match socket_override {
        Some(path) => SocketPath::parse(path.to_path_buf())?,
        None => default_socket_path()?,
    };
    prepare_runtime_directory(&socket_path.0)?;
    remove_stale_socket(&socket_path.0)?;

    let server = ServerBuilder::new(rpc_handler())
        .request_separators(Separator::Byte(b'\n'), Separator::Byte(b'\n'))
        .start(path_as_str(&socket_path.0)?)?;
    fs::set_permissions(&socket_path.0, fs::Permissions::from_mode(0o600))?;
    let _pid_file = PidFile::write(&server_directory.join("axo.pid"))?;
    log::info!("event=daemon.ready pid={}", std::process::id());
    server.wait();
    log::info!("event=daemon.server_stopped");
    Ok(())
}

fn rpc_handler() -> IoHandler {
    let mut handler = IoHandler::new();
    handler.add_sync_method("axo.daemon.health", |_| {
        Ok(json!({
            "buildNumber": BUILD_NUMBER,
            "status": "running"
        }))
    });
    handler
}

#[derive(Debug, Eq, PartialEq)]
struct SocketPath(PathBuf);

impl SocketPath {
    fn parse(path: PathBuf) -> Result<Self, &'static str> {
        let byte_length = path.as_os_str().as_bytes().len();
        if !path.is_absolute() || path.file_name().is_none() {
            return Err("socket path must be an absolute file path");
        }
        if byte_length > MAX_SOCKET_PATH_BYTES {
            return Err("socket path is too long for a Unix-domain socket");
        }
        Ok(Self(path))
    }
}

fn default_socket_path() -> Result<SocketPath, Box<dyn std::error::Error>> {
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(SocketPath::parse(
        PathBuf::from(home).join("Library/Application Support/Axo/run/axod.sock"),
    )?)
}

fn path_as_str(path: &Path) -> Result<&str, io::Error> {
    path.to_str().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket path must be valid UTF-8 for the IPC transport",
        )
    })
}

fn prepare_runtime_directory(socket_path: &Path) -> io::Result<()> {
    let runtime_directory = socket_path
        .parent()
        .ok_or_else(|| io::Error::other("socket path must have a parent directory"))?;
    fs::create_dir_all(runtime_directory)?;
    fs::set_permissions(runtime_directory, fs::Permissions::from_mode(0o700))
}

fn remove_stale_socket(socket_path: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(socket_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };

    if !metadata.file_type().is_socket() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "refusing to replace a non-socket path",
        ));
    }
    if UnixStream::connect(socket_path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "another Axo server is already listening on this socket",
        ));
    }

    log::warn!("event=daemon.stale_socket_removed");
    fs::remove_file(socket_path)
}

struct PidFile {
    path: PathBuf,
    process_id: u32,
}

impl PidFile {
    fn write(path: &Path) -> io::Result<Self> {
        let process_id = std::process::id();
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temporary_path = path.with_file_name(format!("axo.pid.{process_id}.{nonce}.tmp"));
        let mut temporary_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary_path)?;
        writeln!(temporary_file, "{process_id}")?;
        temporary_file.sync_all()?;
        drop(temporary_file);
        if let Err(error) = fs::rename(&temporary_path, path) {
            let _ = fs::remove_file(&temporary_path);
            return Err(error);
        }

        Ok(Self {
            path: path.to_path_buf(),
            process_id,
        })
    }
}

impl Drop for PidFile {
    fn drop(&mut self) {
        let still_ours = fs::read_to_string(&self.path)
            .map(|contents| contents.trim() == self.process_id.to_string())
            .unwrap_or(false);
        if still_ours {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_directory() -> PathBuf {
        static NEXT_DIRECTORY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = NEXT_DIRECTORY.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        std::env::temp_dir().join(format!("axo-server-test-{}-{unique}", std::process::id()))
    }

    #[test]
    fn health_method_reports_this_build() {
        let response = rpc_handler()
            .handle_request_sync(r#"{"jsonrpc":"2.0","id":1,"method":"axo.daemon.health"}"#)
            .expect("health is a request with a response");
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(response["result"]["buildNumber"], BUILD_NUMBER);
        assert_eq!(response["result"]["status"], "running");
    }

    #[test]
    fn unknown_methods_use_the_json_rpc_method_not_found_error() {
        let response = rpc_handler()
            .handle_request_sync(r#"{"jsonrpc":"2.0","id":1,"method":"axo.unknown"}"#)
            .expect("unknown method requests have an error response");
        let response: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(response["error"]["code"], -32601);
    }

    #[test]
    fn socket_paths_are_bounded_absolute_file_paths() {
        assert!(SocketPath::parse(PathBuf::from("/tmp/axod.sock")).is_ok());
        assert!(SocketPath::parse(PathBuf::from("relative/axod.sock")).is_err());
        assert!(
            SocketPath::parse(PathBuf::from(format!(
                "/{}",
                "x".repeat(MAX_SOCKET_PATH_BYTES)
            )))
            .is_err()
        );
    }

    #[test]
    fn stale_socket_cleanup_never_removes_regular_files() {
        let file = temporary_directory();
        fs::write(&file, b"keep me").unwrap();

        let error = remove_stale_socket(&file).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&file).unwrap(), b"keep me");
        fs::remove_file(file).unwrap();
    }

    #[test]
    fn server_directory_is_private_and_must_be_absolute() {
        let directory = temporary_directory();
        prepare_server_directory(&directory).unwrap();
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        fs::remove_dir_all(directory).unwrap();

        assert_eq!(
            prepare_server_directory(Path::new("relative"))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn pid_file_is_removed_on_drop_only_when_it_still_identifies_this_process() {
        let directory = temporary_directory();
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("axo.pid");

        let pid_file = PidFile::write(&path).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap().trim(),
            std::process::id().to_string()
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(pid_file);
        assert!(!path.exists());

        let pid_file = PidFile::write(&path).unwrap();
        fs::write(&path, "different process\n").unwrap();
        drop(pid_file);

        assert_eq!(fs::read_to_string(&path).unwrap(), "different process\n");
        fs::remove_dir_all(directory).unwrap();
    }
}
