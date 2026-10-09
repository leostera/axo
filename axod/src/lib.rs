//! Axo's local runtime owner. Pi execution/history and native rendering remain separate owners.
#[cfg(not(target_os = "macos"))]
compile_error!("axod currently targets macOS");
pub mod journal;
pub mod model;
pub mod protocol;
mod pty;
pub mod runtime;
pub mod server;
#[cfg(test)]
mod test_support;
