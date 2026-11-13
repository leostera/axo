//! Axo's cloud relay: pairs this host with an Axo account, then keeps an authenticated
//! WebSocket to the relay service so remote clients can list, create and drive sessions.

pub mod ai;
pub mod assets;
pub mod bash;
pub mod computer;
pub mod credential;
mod endpoint;
pub mod fragments;
mod host;
mod link;
mod model;
mod outbound;
mod pairing;
pub mod peers;
mod relay;
pub mod signin;
mod sync;

pub use endpoint::{DEFAULT_RELAY_URL, RelayEndpoint};
pub use host::{
    ClientDelivery, HostFuture, HostIdentity, ModelChoice, ModelName, PiKey, RelayHost,
    RemoteAnswer,
};
pub use link::{AccountLink, HostLink, HostLinkStore, PendingRedemption, host_label, link_host};
pub use model::{HostModel, host_model};
pub use outbound::{Priority, RelayCallError, RelayChannel, ReplySender, SocketEpoch};
pub use relay::{
    RelayControl, RelayDependencies, RelayWorker, current_timestamp, unavailable_status,
};
pub use sync::{
    Eviction, SessionMetadata, StoredMetadata, SyncCursor, SyncSession, SyncStore, WorkspaceState,
};

/// Runs `work` on the blocking pool: the Keychain, and what still speaks blocking HTTPS. A panic
/// there is this task's.
pub(crate) async fn blocking<R: Send + 'static>(work: impl FnOnce() -> R + Send + 'static) -> R {
    match tokio::task::spawn_blocking(work).await {
        Ok(result) => result,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}

/// Gives a worker time to close normally, then cancels and joins it rather than detaching it.
async fn finish_task(task: &mut Option<tokio::task::JoinHandle<()>>, wait: std::time::Duration) {
    if let Some(mut task) = task.take() {
        if tokio::time::timeout(wait, &mut task).await.is_err() {
            task.abort();
            let _ = task.await;
        }
    }
}

#[cfg(test)]
mod worker_tests {
    #[tokio::test]
    async fn shutdown_cancels_and_joins_a_worker_that_never_finishes() {
        let (started, ready) = tokio::sync::oneshot::channel();
        let (held, released) = tokio::sync::oneshot::channel::<()>();
        let mut task = Some(tokio::spawn(async move {
            let _held = held;
            started.send(()).unwrap();
            std::future::pending::<()>().await;
        }));
        ready.await.unwrap();
        super::finish_task(&mut task, std::time::Duration::ZERO).await;
        assert!(task.is_none());
        assert!(
            released.await.is_err(),
            "a timed-out worker must not remain detached"
        );
    }
}
