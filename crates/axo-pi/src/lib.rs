//! Pi processes for Axod: launching Pi for a Session, the transcript writer lock that proves
//! whether one is alive, its bridge socket, taking a transcript over from a running Pi, and the
//! bridge transport.
//!
//! Nothing here knows about the session catalog or its database; callers decide which Pi to
//! launch and when, and what its events mean for the catalog.

pub mod activity;
pub mod bridge;
mod command;
pub mod connection;
mod history;
mod launch;
mod lock;
mod process_inspection;
pub mod protocol;
mod socket;
pub mod takeover;
pub mod worker;

pub use activity::Activity;
pub use command::AgentCommand;
pub use history::{HistoryIdentity, ensure_existing_history};
pub use launch::{PiLaunch, PiProcess, STOP_GRACE, spawn};
pub use lock::WriterLock;
pub use socket::{BridgeSocketPath, MAX_SOCKET_PATH_BYTES, SocketCleanup};

/// A fresh directory under /tmp (not the per-user temp directory: socket paths are limited to
/// 104 bytes).
#[cfg(test)]
pub(crate) fn test_directory() -> std::path::PathBuf {
    let directory = std::path::PathBuf::from("/tmp").join(format!(
        "axo-pi-test-{}",
        axo_protocol::new_uuid_v4().unwrap()
    ));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}
