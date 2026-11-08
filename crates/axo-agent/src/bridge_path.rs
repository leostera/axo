//! Validated legacy Pi bridge addresses, independent of the Unix transport.
use axo_protocol::is_uuid;
use std::io;
use std::path::{Path, PathBuf};

pub const MAX_SOCKET_PATH_BYTES: usize = 100;

/// An absolute UTF-8 path short enough for `sockaddr_un` on every client. Kept as a `String`:
/// it is UTF-8 by construction, and it goes on the wire as text.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BridgeSocketPath(String);

impl BridgeSocketPath {
    pub fn parse(path: PathBuf) -> io::Result<Self> {
        let invalid = || {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi bridge socket path must be absolute UTF-8 within the supported byte limit",
            )
        };
        if !path.is_absolute() {
            return Err(invalid());
        }
        let path = path.into_os_string().into_string().map_err(|_| invalid())?;
        if path.len() > MAX_SOCKET_PATH_BYTES || path.contains('\0') {
            return Err(invalid());
        }
        Ok(Self(path))
    }

    pub fn for_session(pi_session_directory: &Path, session_uuid: &str) -> io::Result<Self> {
        if !is_uuid(session_uuid) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi session UUID is invalid",
            ));
        }
        let scoped = pi_session_directory.join(format!("{session_uuid}.sock"));
        if let Ok(path) = Self::parse(scoped) {
            return Ok(path);
        }
        // macOS's per-user temporary directory is too long for sockaddr_un.
        #[cfg(unix)]
        let fallback = PathBuf::from("/tmp");
        #[cfg(windows)]
        let fallback = std::env::temp_dir();
        Self::parse(fallback.join(format!("axo-pi-{session_uuid}.sock")))
    }

    pub fn as_path(&self) -> &Path {
        Path::new(&self.0)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}
