//! Axo's local IPC: newline-delimited JSON-RPC over a Unix socket, and the bounded event queues
//! behind long-polled subscriptions.

pub mod event_queue;
mod server;

pub use event_queue::{EventQueue, PushOutcome};
pub use server::{BlockingMethods, serve};
