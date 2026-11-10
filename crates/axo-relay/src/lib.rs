//! Axo's cloud relay: pairs this host with an Axo account, then keeps an authenticated
//! WebSocket to the relay service so remote clients can list, create and drive sessions.

pub mod assets;
pub mod bash;
pub mod computer;
pub mod credential;
mod endpoint;
pub mod fragments;
mod host;
mod link;
mod outbound;
mod pairing;
pub mod peers;
mod relay;
pub mod signin;
mod sync;

pub use endpoint::{DEFAULT_RELAY_URL, RelayEndpoint};
pub use host::{
    ClientDelivery, CommandId, HostFuture, HostIdentity, MAX_STOP_COMMANDS, ModelChoice, ModelName,
    PiKey, RelayHost, RemoteAnswer, StopTarget, TurnId,
};
pub use link::{AccountLink, HostLink, HostLinkStore, PendingRedemption, host_label, link_host};
pub use outbound::{Priority, RelayCallError, RelayChannel, ReplySender, SocketEpoch};
pub use relay::{
    RelayControl, RelayDependencies, RelayWorker, current_timestamp, unavailable_status,
};
pub use sync::{
    Eviction, SessionMetadata, StoredSyncState, SyncCursor, SyncSession, SyncStore, WorkspaceState,
};

/// Runs `work` on the blocking pool: the Keychain, and what still speaks blocking HTTPS. A panic
/// there is this task's.
pub(crate) async fn blocking<R: Send + 'static>(work: impl FnOnce() -> R + Send + 'static) -> R {
    match tokio::task::spawn_blocking(work).await {
        Ok(result) => result,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}
