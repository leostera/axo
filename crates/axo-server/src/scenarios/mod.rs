//! The core's behaviour as clients see it, driven through its own functions on a [`Fixture`]:
//! Sessions and their panes, prompts reaching Pi, attachments, restarts.
//!
//! [`Fixture`]: crate::test_support::Fixture

mod attachments;
#[cfg(target_os = "linux")]
mod desktop;
mod claude;
mod codex;
mod idle_pis;
mod input_key;
mod lifecycle;
mod opencode;
mod peers;
mod prompts;
mod transcripts;
