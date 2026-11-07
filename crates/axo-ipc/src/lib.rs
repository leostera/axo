//! Axo's local IPC: newline-delimited JSON-RPC over a Unix socket, who is calling (`peer`),
//! when they have given up (`cancel`), and the bounded event queues behind long-polled
//! subscriptions.

pub mod cancel;
pub mod event_queue;
pub mod peer;
mod server;

pub use event_queue::{EventQueue, PushOutcome};
pub use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
pub use server::{Only, TypedMethods, serve};
