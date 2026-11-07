//! Axo's local IPC: newline-delimited JSON-RPC over a Unix socket, who is calling (`peer`),
//! when they have given up (`cancel`), the extensions that offer methods (`extension`), and the
//! bounded event queues behind long-polled subscriptions.

pub mod cancel;
pub mod event_queue;
pub mod extension;
pub mod local;
pub mod peer;
mod server;

pub use event_queue::{EventQueue, PushOutcome};
pub use extension::{Conflict, Extension, Methods};
pub use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
pub use local::{Local, LocalError};
pub use server::{Only, TypedMethods, Upgraded, Upgrades, serve};
