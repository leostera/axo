//! Axo's local runtime owner. Pi execution/history and native rendering remain separate owners.
#[cfg(not(target_os = "macos"))]
compile_error!("axod currently targets macOS");
pub mod ambient_pi;
mod bootstrap;
pub mod client;
pub mod journal;
mod local;
mod managed;
mod panes;
pub use managed::policy::Policy as PiPolicy;
pub mod model;
pub mod pi_control;
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
pub mod user_service;
pub mod work;
#[cfg(test)]
mod work_lifecycle_tests;
mod work_rpc;
