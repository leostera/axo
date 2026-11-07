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
//! This runs as a task on axod's runtime, its turns on the blocking pool, and reaches the cloud
//! through `RelayChannel`.

mod metadata;
mod uploader;

pub use metadata::{SessionMetadata, StoredSyncState, SyncSession, WorkspaceState};

use std::io;
use std::sync::Arc;
use std::time::Duration;

use uploader::Uploader;

use crate::host::RelayHost;
use crate::outbound::RelayChannel;

/// Wakes the uploader early: a Session changed, or the socket reconnected. A wake while the
/// uploader works is kept, so its next wait ends at once.
#[derive(Clone, Default)]
pub struct SyncWaker(Arc<tokio::sync::Notify>);

impl SyncWaker {
    pub fn wake(&self) {
        self.0.notify_one();
    }

    async fn woken(&self) {
        self.0.notified().await;
    }
}

/// The uploader: a task on axod's runtime whose turns run on the blocking pool, since a turn
/// reads transcripts and waits for the cloud's acknowledgements in order.
pub struct SyncWorker {
    runtime: tokio::runtime::Handle,
    task: Option<tokio::task::JoinHandle<()>>,
}

/// How long stopping waits for the turn in progress.
const SHUTDOWN_WAIT: Duration = Duration::from_secs(5);

impl SyncWorker {
    pub fn start(
        host: Arc<dyn RelayHost>,
        channel: Arc<RelayChannel>,
        waker: SyncWaker,
        runtime: tokio::runtime::Handle,
        stop: axo_ipc::Stop,
    ) -> io::Result<Self> {
        let task = runtime.spawn(async move {
            let mut uploader = Uploader::new(host, channel);
            while !stop.is_stopped() {
                let turn = tokio::task::spawn_blocking(move || {
                    let delay = uploader.turn();
                    (uploader, delay)
                });
                let delay;
                (uploader, delay) = match turn.await {
                    Ok(done) => done,
                    Err(error) => std::panic::resume_unwind(error.into_panic()),
                };
                if !delay.is_zero() {
                    tokio::select! {
                        () = tokio::time::sleep(delay) => {}
                        () = waker.woken() => {}
                        () = stop.stopped() => {}
                    }
                }
            }
        });
        Ok(Self {
            runtime,
            task: Some(task),
        })
    }

    /// Waits for the uploader to finish its turn once axod stops. Call it from outside the
    /// runtime.
    pub fn join(&mut self) {
        if let Some(task) = self.task.take() {
            self.runtime.block_on(async {
                let _ = tokio::time::timeout(SHUTDOWN_WAIT, task).await;
            });
        }
    }
}

fn unix_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.char_indices().all(|(index, c)| match index {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
}
