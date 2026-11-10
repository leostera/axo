//! Axo's local IPC: newline-delimited JSON-RPC over a Unix socket, who is calling (`peer`),
//! when they have given up (`cancel`), the extensions that offer methods (`extension`), and the
//! bounded event queues behind long-polled subscriptions.

pub mod cancel;
pub mod extension;
pub mod local;
pub mod peer;
mod server;
pub mod stop;

pub use extension::{Conflict, Extension, Methods};
pub use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
pub use local::{Local, LocalError};
pub use server::{Only, TypedMethods, Upgraded, Upgrades, serve};
pub use stop::Stop;

/// A method's error as jsonrpc-core writes it.
pub fn rpc_error(error: axo_protocol::rpc::MethodError) -> RpcError {
    RpcError {
        code: ErrorCode::from(error.code),
        message: error.message,
        data: None,
    }
}
