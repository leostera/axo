//! Session sync (RFD0018, Upload; modelled in `specs/sessions/session-sync.ts`).
//!
//! Once paired, Axod uploads every Session's Pi transcript, open or archived, whether or not a
//! client is watching. On every connect it sends `axo.host.sync`, a manifest of every Session
//! with what it holds locally, and the cloud answers with what it holds. Axod classifies each
//! Session, finds the common prefix of a diverged one with `chainAt` and cuts the cloud back to
//! it with `truncate`, then appends the lines the cloud is missing, a batch at a time, moving
//! its cursor only when the cloud acknowledges a commit. New lines in open Sessions go ahead of
//! backfill. Any failure (a gap, a conflict, a timeout) starts the handshake again, and its
//! answer says what the cloud holds.
//!
//! An archived Session the cloud acknowledged whole is deleted here (RFD0027). From then on its
//! manifest row has no upload, which leaves the cloud's copy as it is, until reopening it
//! restores the file.
//!
//! This runs as a task on axod's runtime, reading transcripts on the blocking pool, and reaches the cloud
//! through `RelayChannel`. It waits for a cause, never for a tick (RFD0037,
//! `specs/sessions/upload-wakes.ts`): a Session event or a new socket (`SyncWaker`), the kernel
//! reporting a write to an open transcript (`TranscriptWatch`), its own commit when there is more
//! to send, or a retry's deadline.

mod metadata;
#[cfg(test)]
mod tests;
mod uploader;
mod watch;

pub use metadata::{SessionMetadata, StoredSyncState, SyncSession, WorkspaceState};

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use axo_protocol::SessionId;
use uploader::{Next, Uploader};
use watch::TranscriptWatch;

use crate::host::{HostFuture, HostIdentity};
use crate::outbound::RelayChannel;

/// Where the cloud's copy of a transcript ends: the records it acknowledged, and the chain
/// through them, which says they are the records this Mac has.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncCursor {
    pub position: u64,
    pub chain: String,
}

/// What happened to a transcript the cloud holds whole.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Eviction {
    /// Recorded as in the cloud, then deleted here (RFD0027).
    Deleted,
    /// Kept: the Session reopened, is reopening, or changed since.
    Kept,
}

/// What the uploader reads and keeps in axod's database. Implemented by axod.
pub trait SyncStore: Send + Sync {
    /// Every Session, open and archived, with its Pi transcript (RFD0018, Upload).
    fn catalog(&self) -> HostFuture<'_, io::Result<Vec<SyncSession>>>;
    /// What `axo.db` keeps of each Session's upload.
    fn states(&self) -> HostFuture<'_, io::Result<Vec<StoredSyncState>>>;
    /// Where the cloud's copy of a Session ends now.
    fn store_cursor(
        &self,
        session_id: SessionId,
        cursor: SyncCursor,
    ) -> HostFuture<'_, io::Result<()>>;
    /// The metadata last sent for a Session, and its version.
    fn store_metadata(
        &self,
        session_id: SessionId,
        metadata_json: String,
        version: u64,
    ) -> HostFuture<'_, io::Result<()>>;
    /// Deletes an archived Session's transcript, which the cloud acknowledged whole at
    /// `acknowledged` while the file was `length` bytes (RFD0027). Records it in `axo.db` first.
    fn evict_transcript(
        &self,
        session_id: SessionId,
        acknowledged: SyncCursor,
        length: u64,
    ) -> HostFuture<'_, io::Result<Eviction>>;
    /// Raises and returns the handshake round, which outlives sockets and restarts.
    fn next_round(&self) -> HostFuture<'_, io::Result<u64>>;
}

/// Wakes the uploader: a Session changed, or the socket reconnected, so the catalog is read
/// again. A wake while the uploader works is kept, so its next wait ends at once.
#[derive(Clone, Default)]
pub struct SyncWaker(Arc<Wakes>);

#[derive(Default)]
struct Wakes {
    notify: tokio::sync::Notify,
    catalog_changed: AtomicBool,
}

impl SyncWaker {
    pub fn wake(&self) {
        self.0.catalog_changed.store(true, Ordering::SeqCst);
        self.0.notify.notify_one();
    }

    async fn woken(&self) {
        self.0.notify.notified().await;
    }

    /// Whether the catalog changed since the last call.
    fn take_catalog_changed(&self) -> bool {
        self.0.catalog_changed.swap(false, Ordering::SeqCst)
    }
}

/// The uploader: a task on axod's runtime. Its turns wait for the cloud's acknowledgements in
/// order; reading transcripts goes to the blocking pool.
pub struct SyncWorker {
    task: Option<tokio::task::JoinHandle<()>>,
}

/// How long stopping waits for the turn in progress.
const SHUTDOWN_WAIT: Duration = Duration::from_secs(5);

impl SyncWorker {
    pub fn start(
        store: Arc<dyn SyncStore>,
        identity: HostIdentity,
        channel: Arc<RelayChannel>,
        waker: SyncWaker,
        runtime: tokio::runtime::Handle,
        stop: axo_ipc::Stop,
    ) -> io::Result<Self> {
        let watch = {
            let _runtime = runtime.enter();
            Arc::new(TranscriptWatch::new()?)
        };
        let task = runtime.spawn(async move {
            let mut uploader = Uploader::new(store, identity, channel, Arc::clone(&watch));
            // The first turn reads the catalog.
            let mut catalog_changed = true;
            while !stop.is_stopped() {
                let next = uploader.turn(catalog_changed).await;
                let deadline = match next {
                    Next::Now => {
                        catalog_changed = waker.take_catalog_changed();
                        continue;
                    }
                    Next::At(at) => Some(tokio::time::Instant::from_std(at)),
                    Next::Idle => None,
                };
                // Only a retry has a deadline; an idle uploader waits for a cause alone.
                let retry = async move {
                    match deadline {
                        Some(deadline) => tokio::time::sleep_until(deadline).await,
                        None => std::future::pending().await,
                    }
                };
                tokio::select! {
                    () = retry => {}
                    () = waker.woken() => {}
                    changed = watch.changed() => {
                        if let Err(error) = changed {
                            log::warn!("event=sync.watch outcome=failed reason={error}");
                        }
                    }
                    () = stop.stopped() => {}
                }
                catalog_changed = waker.take_catalog_changed();
            }
        });
        Ok(Self { task: Some(task) })
    }

    /// Waits for the uploader to finish its turn once axod stops.
    pub async fn join(&mut self) {
        crate::finish_task(&mut self.task, SHUTDOWN_WAIT).await;
    }
}

impl Drop for SyncWorker {
    fn drop(&mut self) {
        if let Some(task) = &self.task {
            task.abort();
        }
    }
}

fn unix_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
