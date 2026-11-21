//! Windows Pi uses the upstream stdio RPC mode, independent of the Unix terminal bridge.
#[path = "windows_rpc.rs"]
mod windows_rpc;
pub use crate::bridge_path::BridgeSocketPath;
pub use windows_rpc::{PiRpc, PiRuntime};
#[path = "pi/pi3.rs"]
pub mod pi3;
#[path = "pi/transcript_file.rs"]
mod transcript_file;
pub use transcript_file::{TranscriptFile, transcript_chain};
