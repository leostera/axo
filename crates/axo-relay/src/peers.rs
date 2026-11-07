//! This Mac's copy of the account's other Macs' Sessions (RFD0022).
//!
//! Pairing is the sign-in: axod opens the account's client socket at `/peers` with its host
//! credential, and the cloud serves it as an ordinary client that leaves out this Mac's own
//! Sessions. Every other Mac's Session is opened from where its copy ends, and every record batch
//! is appended to `~/.axo/sessions/<hostId>/<workspaceId>/<sessionId>.jsonl` before it is
//! acknowledged: the same lines Pi wrote, at the same place under `sessions/` as on the Mac that
//! owns it. So the history is already here when a Session is continued on this Mac.
//!
//! Invariants:
//! - A copy is Pi's header line and then records 1..=cursor of one epoch, in order, and nothing
//!   else. A reset cuts it back to the header and `keep` records.
//! - A batch is acknowledged only once it is written, so a crash loses nothing the cloud forgets.
//! - Copies are never uploaded: the uploader lists only the Sessions this Mac owns.
//! - This Mac's own folder is never written here, and every path segment is an id, so a copy
//!   can neither replace one of this Mac's transcripts nor land outside `sessions/`.
//!
//! The same socket carries this Mac's commands to the others (RFD0024): a remote pane's prompt
//! or stop goes out as `axo.client.command`, and the copies, progress and listing it follows are
//! shared with axod through [`PeerLive`].

mod follower;
mod index;
mod live;
mod mirror;

#[cfg(test)]
mod test_support;

pub use index::PeerIndex;
pub use live::{PeerCommandError, PeerLive};
pub use mirror::{ClientRecord, CopyRead, CopyState, Mirror, Place, read_copy};

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use follower::Follower;
use tungstenite::protocol::WebSocketConfig;

use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::link::HostLinkStore;
use futures_util::StreamExt;

use crate::relay::{MAX_FRAME_BYTES, connect_websocket, host_websocket_request};

const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);

/// Where following the account writes: every Mac's transcripts, and this Mac's index of them.
#[derive(Clone)]
pub struct PeersPaths {
    /// `~/.axo/sessions`.
    pub sessions_directory: PathBuf,
    /// `~/.axo/server/peers.json`.
    pub index: PathBuf,
    /// What axod's remote panes follow, and their way out.
    pub live: Arc<PeerLive>,
}

/// What following the account needs from axod.
pub struct PeersDependencies {
    pub host_id: String,
    pub endpoint: RelayEndpoint,
    pub links: Arc<dyn HostLinkStore>,
    pub credentials: Arc<dyn HostCredentialStore>,
    /// `~/.axo/sessions`: every Mac's transcripts by host.
    pub sessions_directory: PathBuf,
    /// `~/.axo/server/peers.json`: what the account lists.
    pub index: PathBuf,
    pub live: Arc<PeerLive>,
}

pub struct PeersWorker {
    runtime: tokio::runtime::Handle,
    task: Option<tokio::task::JoinHandle<()>>,
}

/// How long stopping waits for the socket to close.
const SHUTDOWN_WAIT: Duration = Duration::from_secs(5);

impl PeersWorker {
    /// Follows the account on `runtime` until `stop`.
    pub fn start(
        dependencies: PeersDependencies,
        runtime: tokio::runtime::Handle,
        stop: axo_ipc::Stop,
    ) -> io::Result<Self> {
        let task = runtime.spawn(run(dependencies, stop));
        Ok(Self {
            runtime,
            task: Some(task),
        })
    }

    /// Waits for the socket to close once axod stops. Call it from outside the runtime.
    pub fn join(&mut self) {
        if let Some(task) = self.task.take() {
            self.runtime.block_on(async {
                let _ = tokio::time::timeout(SHUTDOWN_WAIT, task).await;
            });
        }
    }
}

/// Waits `delay`, or less if axod stops.
async fn wait(stop: &axo_ipc::Stop, delay: Duration) {
    tokio::select! {
        () = tokio::time::sleep(delay) => {}
        () = stop.stopped() => {}
    }
}

async fn run(dependencies: PeersDependencies, stop: axo_ipc::Stop) {
    let dependencies = Arc::new(dependencies);
    let mut mirror = Mirror::new(dependencies.sessions_directory.clone());
    let mut delay = Duration::from_secs(1);
    while !stop.is_stopped() {
        let links = Arc::clone(&dependencies.links);
        let account = match tokio::task::spawn_blocking(move || links.load_link()).await {
            Ok(Ok(link)) => link.account().cloned(),
            Ok(Err(error)) => {
                log::warn!("event=peers.link_unavailable reason={error}");
                None
            }
            Err(error) => {
                log::warn!("event=peers.link_unavailable reason={error}");
                None
            }
        };
        let Some(account) = account else {
            // Not paired: nothing to follow until it is.
            wait(&stop, Duration::from_secs(5)).await;
            continue;
        };
        let started = Instant::now();
        let outcome = follow(&dependencies, account, &mut mirror, &stop).await;
        match outcome {
            Ok(()) => log::info!("event=peers.socket_renewed"),
            Err(error) => log::warn!("event=peers.connection_retry reason={error}"),
        }
        // A socket that lasted was healthy: start the backoff afresh.
        delay = if started.elapsed() > Duration::from_secs(60) {
            Duration::from_secs(1)
        } else {
            (delay * 2).min(MAX_RETRY_DELAY)
        };
        wait(&stop, delay).await;
    }
}

/// One socket's life, from connecting to its end.
async fn follow(
    dependencies: &Arc<PeersDependencies>,
    account: crate::link::AccountLink,
    mirror: &mut Mirror,
    stop: &axo_ipc::Stop,
) -> io::Result<()> {
    let request = {
        let dependencies = Arc::clone(dependencies);
        // The credential comes from the Keychain, which may take its time.
        tokio::task::spawn_blocking(move || {
            host_websocket_request(
                dependencies
                    .endpoint
                    .peers_url(account.account_id(), &dependencies.host_id),
                &account,
                dependencies.credentials.as_ref(),
            )
        })
        .await
        .map_err(io::Error::other)??
    };
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let (sink, stream) = connect_websocket(request, config).await?.split();
    Follower::new(mirror, dependencies, stop)
        .run(sink, stream)
        .await
}

/// Where this Mac's own transcripts are fetched to before they are checked and moved into
/// place: `server/restoring`, beside the index.
pub fn restore_directory(index: &Path) -> PathBuf {
    index.parent().map_or_else(
        || PathBuf::from("restoring"),
        |server| server.join("restoring"),
    )
}
