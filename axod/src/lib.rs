//! Axo's local runtime owner. Pi execution/history and native rendering remain separate owners.
#[cfg(not(target_os = "macos"))]
compile_error!("axod currently targets macOS");
pub mod ambient_pi;
mod bootstrap;
pub mod client;
pub mod host;
pub mod journal;
mod local;
pub mod pi_session;
pub use pi_session::policy::Policy as PiPolicy;
pub mod model;
pub mod pi_control;
mod private_file;
pub mod profiles;
mod pty;
pub mod relay;
pub mod rpc;
mod rpc_owner;
pub mod runtime;
pub mod server;
pub mod state;
pub mod terminal;
pub mod terminal_client;
pub mod terminal_frontend;
#[cfg(test)]
mod terminal_lifecycle_tests;
mod terminal_transport;
#[cfg(test)]
mod test_support;
mod upgrade;
mod user_path;
pub mod user_service;
mod user_shell;
