//! The OpenCode adapter (RFD0072): a private `opencode serve` per Session on a loopback port
//! with its own password, the TUI attached to it with `--server`, and axod's link as another
//! client of its v2 HTTP API.
//!
//! - `client`: the HTTP requests axod makes, with the server's password.
//! - `sse`: the event stream's framing.
//! - `session`: the session's state as axod sees it, and OpenCode's events as Axo events; pure.
//! - `launch`: the server under the lifeline guard holding the agent lock, then the TUI.
//! - `link`: follows the event stream and carries out axod's commands.

pub mod client;
mod launch;
mod link;
pub mod session;
pub mod sse;

pub use crate::channel::{LinkCommands, LinkRequests, ServerProcess, WhileRunning, command_channel};
pub use client::ServerAddress;
pub use launch::{OpenCodeLaunch, OpenCodePaths, OpenCodeProcess, attach, start_server};
pub use link::{LinkConfig, create_session, run, wait_until_listening};
