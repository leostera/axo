//! Pseudo-terminals for Axod: launching programs on a PTY, the permanent output pump that fans a
//! PTY's output out to any number of subscribers, and attach protocols v2/v3.

pub mod attach;
pub mod command;
pub mod exit;
pub mod lifeline;
#[cfg(target_os = "linux")]
mod linux;
pub mod output;
pub mod process;
mod runtime;

pub use command::CommandLine;
pub use output::{NextOutput, OutputSubscriber, TerminalOutput, TerminalOutputSink};
pub use process::{PtyProcess, WindowSize};
