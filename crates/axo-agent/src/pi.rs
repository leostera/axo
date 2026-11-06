//! Pi (`source.agent: "pi"`): launching it with the pi-axo extension, and the bridge axod
//! steers it through (`packages/pi-axo/src/protocol.ts`).

pub mod bridge;
pub mod connection;
mod launch;
pub mod protocol;
mod socket;
pub mod worker;

pub use launch::{PiLaunch, PiProcess, RemoteViewLaunch, STOP_GRACE, spawn, spawn_remote_view};
pub use socket::{BridgeSocketPath, MAX_SOCKET_PATH_BYTES, SocketCleanup};
