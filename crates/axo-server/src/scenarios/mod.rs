//! The core's behaviour as clients see it, driven through its own functions on a [`Fixture`]:
//! Sessions and their panes, prompts reaching Pi, attachments, restarts.
//!
//! [`Fixture`]: crate::test_support::Fixture

mod attachments;
mod idle_pis;
mod input_key;
mod lifecycle;
mod peers;
mod prompts;
mod transcripts;
