//! Pseudo-terminals for Axod: launching programs on a PTY, the permanent output pump that fans a
//! PTY's output out to any number of subscribers, and attach protocol v2.

pub mod attach;
pub mod command;
pub mod output;
pub mod process;

pub use command::CommandLine;
pub use output::{NextOutput, OutputSubscriber, TerminalOutput, TerminalOutputSink};
pub use process::{PtyProcess, WindowSize};
