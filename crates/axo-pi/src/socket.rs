//! Where a Pi's bridge listens, and cleaning up after a Pi that died without removing it.

use std::fs;
use std::io;
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};

use axo_protocol::is_uuid;

use crate::WriterLock;

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
        Self::parse(PathBuf::from("/tmp").join(format!("axo-pi-{session_uuid}.sock")))
    }

    pub fn as_path(&self) -> &Path {
        Path::new(&self.0)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// What `remove_abandoned` found at a bridge socket path.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SocketCleanup {
    Absent,
    /// A socket left by a Pi that was killed; removed.
    Removed,
    /// Something other than a socket; left in place (Pi will fail to listen and report it).
    NotASocket,
    /// A Pi still holds the Session's writer lock; its socket is kept.
    InUse,
}

impl BridgeSocketPath {
    /// Removes a socket file a killed Pi left behind; Pi cannot listen over one. Holding the
    /// Session's `WriterLock` proves no Pi for it is alive.
    pub fn remove_abandoned(&self, _writer: &WriterLock) -> io::Result<SocketCleanup> {
        self.remove_socket_file()
    }

    /// Like `remove_abandoned`, for a Session Axod is not launching: the writer lock is probed
    /// (and held while removing) without creating a lock file.
    pub fn reconcile(&self, session_file: &Path) -> io::Result<SocketCleanup> {
        match WriterLock::acquire_existing(session_file) {
            Ok(Some(writer)) => self.remove_abandoned(&writer),
            // No lock file: no Pi was ever launched holding this transcript's lock.
            Ok(None) => self.remove_socket_file(),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(SocketCleanup::InUse),
            Err(error) => Err(error),
        }
    }

    fn remove_socket_file(&self) -> io::Result<SocketCleanup> {
        match fs::symlink_metadata(&self.0) {
            Ok(metadata) if metadata.file_type().is_socket() => {
                fs::remove_file(&self.0)?;
                Ok(SocketCleanup::Removed)
            }
            Ok(_) => Ok(SocketCleanup::NotASocket),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(SocketCleanup::Absent),
            Err(error) => Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    /// A socket file whose listener is gone, as a killed Pi leaves it.
    fn abandoned_socket(path: &Path) {
        drop(UnixListener::bind(path).unwrap());
        assert!(fs::symlink_metadata(path).is_ok());
    }

    #[test]
    fn abandoned_bridge_socket_is_removed_but_other_files_are_not() {
        let directory = crate::test_directory();
        let writer = WriterLock::acquire(&directory.join("session.jsonl")).unwrap();
        let socket = BridgeSocketPath::parse(directory.join("abandoned.sock")).unwrap();
        abandoned_socket(socket.as_path());
        assert_eq!(
            socket.remove_abandoned(&writer).unwrap(),
            SocketCleanup::Removed
        );
        assert!(!socket.as_path().exists());
        assert_eq!(
            socket.remove_abandoned(&writer).unwrap(),
            SocketCleanup::Absent
        );

        let regular = BridgeSocketPath::parse(directory.join("regular.sock")).unwrap();
        fs::write(regular.as_path(), b"not a socket").unwrap();
        assert_eq!(
            regular.remove_abandoned(&writer).unwrap(),
            SocketCleanup::NotASocket
        );
        assert!(regular.as_path().exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn reconciliation_keeps_the_socket_of_a_live_pi_only() {
        let directory = crate::test_directory();
        let live_file = directory.join("live.jsonl");
        let live = BridgeSocketPath::parse(directory.join("live.sock")).unwrap();
        let dead_file = directory.join("dead.jsonl");
        let dead = BridgeSocketPath::parse(directory.join("dead.sock")).unwrap();
        let never_file = directory.join("never.jsonl");
        let never = BridgeSocketPath::parse(directory.join("never.sock")).unwrap();
        for socket in [&live, &dead, &never] {
            abandoned_socket(socket.as_path());
        }
        let live_writer = WriterLock::acquire(&live_file).unwrap();
        // A dead Pi's lock file, never locked by this process: locking and unlocking it here
        // would let a child forked meanwhile (by another test) keep a copy of the lock.
        fs::write(dead_file.with_extension("jsonl.lock"), b"").unwrap();

        assert_eq!(live.reconcile(&live_file).unwrap(), SocketCleanup::InUse);
        assert_eq!(dead.reconcile(&dead_file).unwrap(), SocketCleanup::Removed);
        assert_eq!(
            never.reconcile(&never_file).unwrap(),
            SocketCleanup::Removed
        );
        assert!(live.as_path().exists());
        assert!(
            !never_file.with_extension("jsonl.lock").exists(),
            "reconciliation must not create lock files"
        );
        drop(live_writer);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn pi_bridge_socket_path_is_stable_and_within_the_shared_byte_limit() {
        let session_uuid = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
        let exact_limit_directory = PathBuf::from(format!("/{}", "d".repeat(57)));
        let exact_limit =
            BridgeSocketPath::for_session(&exact_limit_directory, session_uuid).unwrap();
        assert_eq!(exact_limit.0.len(), MAX_SOCKET_PATH_BYTES);

        let too_long_directory = PathBuf::from(format!("/{}", "d".repeat(58)));
        let fallback = BridgeSocketPath::for_session(&too_long_directory, session_uuid).unwrap();
        assert_eq!(
            fallback.as_path(),
            Path::new(&format!("/tmp/axo-pi-{session_uuid}.sock"))
        );
        assert!(fallback.as_path().as_os_str().as_encoded_bytes().len() <= MAX_SOCKET_PATH_BYTES);

        assert!(BridgeSocketPath::parse(PathBuf::from(format!("/{}", "x".repeat(100)))).is_err());
        assert!(BridgeSocketPath::parse(PathBuf::from("relative.sock")).is_err());
        let not_utf8 =
            <std::ffi::OsStr as std::os::unix::ffi::OsStrExt>::from_bytes(b"/tmp/axo-\xff.sock");
        assert!(BridgeSocketPath::parse(PathBuf::from(not_utf8)).is_err());
        assert!(BridgeSocketPath::parse(PathBuf::from("/tmp/axo-\0.sock")).is_err());
        assert!(BridgeSocketPath::for_session(&too_long_directory, "not-a-uuid").is_err());
    }
}
