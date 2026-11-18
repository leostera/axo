//! The Codex adapter (RFD0072): a private `codex app-server` per Session on a Unix socket, the
//! TUI attached to it with `--remote`, and axod's link as its second client.
//!
//! - `rpc`: the app-server's JSON-RPC frames (no `"jsonrpc"` member).
//! - `thread`: the thread's state as axod sees it, and Codex's items as Axo events; pure.
//! - `launch`: the server under the lifeline guard holding the agent lock, then the TUI.
//! - `link`: the WebSocket client that follows the thread and carries out axod's commands.

mod launch;
mod link;
pub mod rpc;
pub mod thread;

pub use launch::{CodexLaunch, CodexPaths, CodexProcess, attach, start_server};
pub use link::{
    LinkCommands, LinkConfig, LinkRequests, ServerProcess, command_channel, create_thread, run,
};
