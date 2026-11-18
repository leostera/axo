//! The Claude Code adapter (RFD0072): the TUI on the pane's PTY, reporting through HTTP hooks
//! to a listener of axod's, and taking axod's prompts as typed pastes.
//!
//! - `hooks`: the listener and the `--settings` document that points the hooks at it.
//! - `session`: the conversation's state as axod sees it, and hooks as Axo events; pure.
//! - `launch`: the TUI holding the agent lock, new or resuming its conversation.
//! - `link`: receives hooks and types axod's prompts.

pub mod hooks;
mod launch;
mod link;
pub mod session;

pub use crate::channel::{LinkCommands, LinkRequests, command_channel};
pub use launch::{ClaudeLaunch, ClaudePaths, ClaudeProcess, config_directory, launch, transcript_exists};
pub use link::{LinkConfig, paste, run};

#[cfg(test)]
mod tests;
