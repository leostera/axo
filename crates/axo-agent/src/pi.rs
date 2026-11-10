//! Pi (`source.agent: "pi"`): launching it with the pi-axo extension, the bridge axod steers
//! it through (`packages/pi-axo/src/protocol.ts`), and reading and hashing its session file for
//! upload (`pi3`, `TranscriptFile`).

pub mod connection;
mod launch;
pub mod link;
pub mod pi3;
pub mod protocol;
mod socket;
mod transcript_file;

pub use launch::{PiLaunch, PiProcess, RemoteViewLaunch, STOP_GRACE, spawn, spawn_remote_view};
pub use socket::{BridgeSocketPath, MAX_SOCKET_PATH_BYTES, SocketCleanup};
pub use transcript_file::{TranscriptFile, transcript_chain};
