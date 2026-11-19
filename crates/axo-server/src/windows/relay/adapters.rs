//! Async relay contracts over the Windows host's blocking Win32/SQLite operations.
//! An owned host shares its locks and never keeps a Tokio worker waiting on native IO.
use super::*;
use axo_protocol::rpc::MethodError;
use std::sync::atomic::{AtomicBool, Ordering};

impl HostLinkStore for Host {
    fn load_link(&self) -> HostFuture<'_, io::Result<HostLink>> {
        self.run_blocking(|host| host.read_link())
    }
    fn save_link(&self, link: HostLink) -> HostFuture<'_, io::Result<()>> {
        self.run_blocking(move |host| host.persist_link(&link))
    }
}

struct CancelOnDrop(Arc<AtomicBool>);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

impl RelayHost for Host {
    fn identity(&self) -> &HostIdentity {
        &self.identity
    }
    fn publish_relay_status(&self, status: &axo_protocol::RelayStatus) {
        Host::publish_relay_status(self, status);
    }
    fn set_asset_source(&self, source: Option<axo_relay::assets::AssetSource>) {
        Host::set_asset_source(self, source);
    }
    fn pending_elicitations(&self) -> Vec<axo_protocol::elicitation::Elicitation> {
        Host::pending_elicitations(self)
    }
    fn resolve_elicitation(&self, answer: RemoteAnswer) -> Result<(), MethodError> {
        Host::resolve_elicitation(
            self,
            &answer.elicitation_id,
            answer.answer,
            answer.sealed,
            answer.device,
        )
        .map_err(|(code, message)| MethodError::new(code, message))
    }
    fn computer_status(&self) -> HostFuture<'_, Value> {
        Box::pin(async move { Host::computer_status(self) })
    }
    fn remote_computer(
        &self,
        request: axo_relay::computer::ComputerParams,
    ) -> HostFuture<'_, Result<Value, MethodError>> {
        let host = self.clone();
        Box::pin(async move {
            let cancelled = Arc::new(AtomicBool::new(false));
            let _cancel_on_drop = CancelOnDrop(Arc::clone(&cancelled));
            tokio::task::spawn_blocking(move || Host::remote_computer(&host, &request, &cancelled))
                .await
                .map_err(|_| MethodError::new(-32603, "The Windows computer worker failed"))?
                .map_err(|(code, message)| MethodError::new(code, message))
        })
    }
    fn subscribe_remote_events(&self) -> io::Result<String> {
        Host::subscribe_remote_events(self)
    }
    fn next_remote_events<'a>(
        &'a self,
        id: &'a str,
        timeout: Duration,
    ) -> HostFuture<'a, io::Result<Vec<Event>>> {
        Host::next_remote_events(self, id, timeout)
    }
    fn unsubscribe_remote_events(&self, id: &str) -> io::Result<()> {
        Host::unsubscribe_remote_events(self, id)
    }
    fn answer_remote(&self, request: Value) -> HostFuture<'_, Option<Value>> {
        let host = self.clone();
        let id = request.get("id").cloned();
        Box::pin(async move {
            match tokio::task::spawn_blocking(move || remote::answer(&host, request)).await {
                Ok(answer) => answer,
                Err(error) => {
                    log::error!("event=windows.remote_worker_failed error={error}");
                    id.map(|id| json!({"jsonrpc":"2.0","id":id,"error":{"code":-32603,"message":"The Windows request worker failed"}}))
                }
            }
        })
    }
}

impl SyncStore for Host {
    fn catalog(&self) -> HostFuture<'_, io::Result<Vec<SyncSession>>> {
        self.run_blocking(|host| host.read_sync_catalog())
    }
    fn stored_metadata(&self) -> HostFuture<'_, io::Result<Vec<StoredMetadata>>> {
        self.run_blocking(|host| host.read_stored_metadata())
    }
    fn store_cursor(&self, id: SessionId, cursor: SyncCursor) -> HostFuture<'_, io::Result<()>> {
        self.run_blocking(move |host| host.store_sync_cursor(id, cursor.position, &cursor.chain))
    }
    fn store_metadata(
        &self,
        id: SessionId,
        metadata: String,
        version: u64,
    ) -> HostFuture<'_, io::Result<()>> {
        self.run_blocking(move |host| host.store_sync_metadata(id, &metadata, version))
    }
    fn evict_transcript(
        &self,
        _: SessionId,
        _: SyncCursor,
        _: u64,
    ) -> HostFuture<'_, io::Result<Eviction>> {
        // The Windows preview retains local history instead of deleting archived projections.
        Box::pin(std::future::ready(Ok(Eviction::Kept)))
    }
    fn next_round(&self) -> HostFuture<'_, io::Result<u64>> {
        self.run_blocking(|host| host.next_sync_round())
    }
}
