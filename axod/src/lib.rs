//! Axo's local runtime owner. Pi execution/history and native rendering remain separate owners.
#[cfg(not(target_os = "macos"))]
compile_error!("axod currently targets macOS");
mod bootstrap;
pub mod journal;
mod local;
pub mod model;
mod private_file;
pub mod profiles;
mod pty;
pub mod relay;
pub mod rpc;
pub mod runtime;
pub mod server;
pub mod terminal;
#[cfg(test)]
mod terminal_lifecycle_tests;
#[cfg(test)]
mod test_support;
