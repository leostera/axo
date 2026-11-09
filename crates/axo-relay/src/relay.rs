//! The host's connection to the Axo relay: one authenticated WebSocket per linked host,
//! reconnected with backoff, over which remote clients list, create and drive Sessions.
//!
//! - `status`: the connection state Axo.app shows, and its manual retry.
//! - `socket`: connecting, and reading and sending whole messages (shared with `peers`).
//! - `session`: one connected session: negotiate, register, then serve until it closes.
//!
//! The connection is a task on axod's runtime (RFD0034, step 7). It waits on the socket, local
//! events, the outgoing queue, the heartbeat, stopping and the control's wake-up at once;
//! nothing polls, and whatever blocks (the Keychain, the host's answers, jobs) runs on the
//! blocking pool.
//! - `dispatch`: answering `axo.remote.*` requests through the host.
//! - `jobs`: bash, prompts with attachments and sign-ins, each on a thread of its own.
//! - `elicitation`: a person's answers to an agent's questions (RFD0029).
//! - `wire`: the JSON-RPC message types.

mod elicitation;
mod forward;
mod jobs;
mod session;
mod socket;
mod status;
mod wire;

pub use session::current_timestamp;
pub(crate) use socket::{
    MAX_FRAME_BYTES, RelaySink, RelayStream, connect_websocket, host_websocket_request, receive,
    send_json,
};
pub use status::{RelayControl, unavailable_status};

use std::io;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use axo_ipc::Stop;

use axo_protocol::HostKind;
use elicitation::ELICITATION_REQUESTED;
use futures_util::StreamExt;
use session::{RelaySessionContext, answer_requests, relay_session, rpc_call};
use socket::relay_websocket_request;
use tungstenite::protocol::WebSocketConfig;
use wire::{HOST_CAPABILITIES, HostRegistration, NegotiateParams};

use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::fragments::Reassembler;
use crate::host::RelayHost;
use crate::link::{AccountLink, HostLinkStore, host_label};
use crate::outbound::{Priority, RelayChannel};
use crate::peers::{PeersDependencies, PeersWorker};
use crate::sync::{SyncWaker, SyncWorker};

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);

#[cfg(not(windows))]
const NOT_LINKED: &str = "This Mac is not linked to an Axo account.";
#[cfg(windows)]
const NOT_LINKED: &str = "This PC is not linked to an Axo account.";

pub struct RelayWorker {
    stop: Stop,
    control: Arc<RelayControl>,
    channel: Arc<RelayChannel>,
    runtime: tokio::runtime::Handle,
    task: Option<tokio::task::JoinHandle<()>>,
    waker: SyncWaker,
    /// Uploads every Session's transcript while the socket is open (RFD0018).
    sync: SyncWorker,
    /// Keeps this Mac's copy of the other Macs' Sessions (RFD0022).
    peers: Option<PeersWorker>,
}

/// What the relay worker needs from axod.
pub struct RelayDependencies {
    pub host: Arc<dyn RelayHost>,
    pub endpoint: RelayEndpoint,
    pub links: Arc<dyn HostLinkStore>,
    pub credentials: Arc<dyn HostCredentialStore>,
    /// Where the other Macs' Sessions are copied (RFD0022); None copies nothing.
    pub peers: Option<crate::peers::PeersPaths>,
    /// Where prompts' attachments are fetched to, `~/.axo/assets` (RFD0030); None refuses
    /// prompts that have any.
    pub assets_directory: Option<std::path::PathBuf>,
}

/// How long stopping waits for the connection to say goodbye.
const SHUTDOWN_WAIT: Duration = Duration::from_secs(5);

impl RelayWorker {
    /// Starts the connection on `runtime`. It stays idle until the host is linked, then keeps one
    /// authenticated connection to the relay, reconnecting with backoff, until `stop`.
    pub fn start(
        dependencies: RelayDependencies,
        runtime: tokio::runtime::Handle,
        stop: Stop,
    ) -> io::Result<Self> {
        let observed_host = Arc::downgrade(&dependencies.host);
        let control = Arc::new(
            RelayControl::new(host_label(), HostKind::platform()).with_observer(Box::new(
                move |status| {
                    if let Some(host) = observed_host.upgrade() {
                        host.publish_relay_status(status);
                    }
                },
            )),
        );
        let channel = RelayChannel::new();
        let waker = SyncWaker::default();
        let sync = SyncWorker::start(
            Arc::clone(&dependencies.host),
            Arc::clone(&channel),
            waker.clone(),
            runtime.clone(),
            stop.clone(),
        )?;
        let peers = match dependencies.peers.clone() {
            Some(paths) => Some(PeersWorker::start(
                PeersDependencies {
                    host_id: dependencies.host.host_id().to_owned(),
                    endpoint: dependencies.endpoint.clone(),
                    links: Arc::clone(&dependencies.links),
                    credentials: Arc::clone(&dependencies.credentials),
                    sessions_directory: paths.sessions_directory,
                    index: paths.index,
                    live: paths.live,
                },
                runtime.clone(),
                stop.clone(),
            )?),
            None => None,
        };
        let task = runtime.spawn(run_reconnect_loop(
            Arc::new(dependencies),
            stop.clone(),
            Arc::clone(&control),
            Arc::clone(&channel),
            waker.clone(),
        ));
        Ok(Self {
            stop,
            control,
            channel,
            runtime,
            task: Some(task),
            waker,
            sync,
            peers,
        })
    }

    pub fn control_handle(&self) -> Arc<RelayControl> {
        Arc::clone(&self.control)
    }

    /// What other threads use to send requests and notifications to the cloud.
    pub fn channel_handle(&self) -> Arc<RelayChannel> {
        Arc::clone(&self.channel)
    }

    /// Stops the connection and waits for it to close. Call it from outside the runtime.
    pub fn shutdown(&mut self) {
        self.stop.stop();
        self.waker.wake();
        if let Some(task) = self.task.take() {
            self.runtime.block_on(async {
                let _ = tokio::time::timeout(SHUTDOWN_WAIT, task).await;
            });
        }
        self.sync.join();
        if let Some(peers) = &mut self.peers {
            peers.join();
        }
    }
}

impl Drop for RelayWorker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Runs `work` on the blocking pool: the Keychain, the host's locks and its database.
async fn blocking<R: Send + 'static>(work: impl FnOnce() -> R + Send + 'static) -> R {
    match tokio::task::spawn_blocking(work).await {
        Ok(result) => result,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}

async fn run_reconnect_loop(
    dependencies: Arc<RelayDependencies>,
    stop: Stop,
    control: Arc<RelayControl>,
    channel: Arc<RelayChannel>,
    waker: SyncWaker,
) {
    let mut retry_delay = Duration::from_secs(1);
    while !stop.is_stopped() {
        let links = Arc::clone(&dependencies.links);
        let link = match blocking(move || links.load_link()).await {
            Ok(link) => link,
            Err(error) => {
                control.mark_disconnected(&error);
                log::warn!("event=relay.link_unavailable reason={error}");
                wait_for_reconnect(&control, &stop, retry_delay).await;
                retry_delay = (retry_delay * 2).min(MAX_RECONNECT_DELAY);
                continue;
            }
        };
        // Only a linked host connects; linking requests a reconnect, which ends this wait.
        let Some(account) = link.account().cloned() else {
            control.mark_disconnected(NOT_LINKED);
            wait_for_reconnect(&control, &stop, Duration::from_secs(1)).await;
            retry_delay = Duration::from_secs(1);
            continue;
        };

        control.mark_connecting();
        match run_connection(&dependencies, account, &stop, &control, &channel, &waker).await {
            Ok(()) if stop.is_stopped() => break,
            Ok(()) => {
                control.mark_disconnected("relay connection ended");
                log::warn!("event=relay.connection_ended");
            }
            Err(error) => {
                control.mark_disconnected(&error);
                log::warn!("event=relay.connection_retry reason={error}");
            }
        }
        if stop.is_stopped() {
            break;
        }
        let requested_now = wait_for_reconnect(&control, &stop, retry_delay).await;
        retry_delay = if requested_now {
            Duration::from_secs(1)
        } else {
            (retry_delay * 2).min(MAX_RECONNECT_DELAY)
        };
    }
}

/// Waits `delay`, or less if a reconnect is asked for (true) or axod stops.
async fn wait_for_reconnect(control: &RelayControl, stop: &Stop, delay: Duration) -> bool {
    let until = Instant::now() + delay;
    loop {
        if stop.is_stopped() {
            return false;
        }
        if control.reconnect_requested.swap(false, Ordering::Relaxed) {
            return true;
        }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        tokio::select! {
            () = tokio::time::sleep(left) => {}
            () = control.woken() => {}
            () = stop.stopped() => {}
        }
    }
}

async fn run_connection(
    dependencies: &RelayDependencies,
    account: AccountLink,
    stop: &Stop,
    control: &Arc<RelayControl>,
    channel: &Arc<RelayChannel>,
    waker: &SyncWaker,
) -> io::Result<()> {
    let sessions = &dependencies.host;
    let host_id = sessions.host_id().to_owned();
    let host_generation = sessions.host_generation().to_owned();
    let request = {
        let (endpoint, account, host_id, credentials) = (
            dependencies.endpoint.clone(),
            account.clone(),
            host_id.clone(),
            Arc::clone(&dependencies.credentials),
        );
        // The credential comes from the Keychain, which may take its time.
        blocking(move || {
            relay_websocket_request(&endpoint, &account, &host_id, credentials.as_ref())
        })
        .await?
    };

    let websocket_config = WebSocketConfig::default()
        .read_buffer_size(8192)
        .write_buffer_size(4096)
        .max_write_buffer_size(131_072)
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let socket = connect_websocket(request, websocket_config).await?;
    let (mut sink, mut stream) = socket.split();

    let mut request_number = 0_u64;
    // Partial messages die with this socket (RFD0016, Transport).
    let mut reassembler = Reassembler::default();
    rpc_call(
        &mut sink,
        &mut stream,
        &mut reassembler,
        &mut request_number,
        "axo.protocol.negotiate",
        NegotiateParams {
            protocol_version: axo_protocol::rpc::PROTOCOL_VERSION,
        },
        sessions,
    )
    .await?;
    let subscription_id = {
        let sessions = Arc::clone(sessions);
        blocking(move || sessions.subscribe_remote_events()).await?
    };
    let unsubscribe = |subscription_id: String| {
        let sessions = Arc::clone(sessions);
        blocking(move || {
            let _ = sessions.unsubscribe_remote_events(&subscription_id);
        })
    };
    let label = host_label();
    let registration = HostRegistration {
        protocol_version: axo_protocol::rpc::PROTOCOL_VERSION,
        host_id: &host_id,
        host_generation: &host_generation,
        label: &label,
        host_kind: HostKind::platform(),
        capabilities: HOST_CAPABILITIES,
        sessions: [],
    };
    if let Err(error) = rpc_call(
        &mut sink,
        &mut stream,
        &mut reassembler,
        &mut request_number,
        "axo.host.register",
        registration,
        sessions,
    )
    .await
    {
        unsubscribe(subscription_id).await;
        return Err(error);
    }
    control.mark_connected();

    // Threads queue onto this socket only while it lives (RFD0016, Transport).
    let (epoch, outgoing, replies) = channel.attach();
    // A new socket needs a new handshake: the uploader starts it now.
    waker.wake();
    // What agents are asking the person goes up again on every socket (RFD0029).
    let pending = {
        let sessions = Arc::clone(sessions);
        blocking(move || sessions.pending_elicitations()).await
    };
    for elicitation in pending {
        let _ = channel.notify(
            ELICITATION_REQUESTED,
            serde_json::to_value(&elicitation).expect("an elicitation serializes"),
            Priority::Control,
        );
    }
    let assets =
        dependencies
            .assets_directory
            .as_ref()
            .map(|directory| crate::assets::AssetSource {
                endpoint: dependencies.endpoint.clone(),
                account: account.clone(),
                host_id: host_id.clone(),
                credentials: Arc::clone(&dependencies.credentials),
                directory: directory.clone(),
            });
    // Local callers fetch the account's assets through this socket's account while it lives.
    sessions.set_asset_source(assets.clone());
    let context = Arc::new(RelaySessionContext {
        sessions: Arc::clone(sessions),
        host_id,
        host_generation,
        subscription_id: subscription_id.clone(),
        stop: stop.clone(),
        control: Arc::clone(control),
        channel: Arc::clone(channel),
        replies,
        waker: waker.clone(),
        socket_id: format!("axod-{}-{epoch}", std::process::id()),
        account_id: account.account_id().to_owned(),
        assets,
    });
    // The host's answers, in order, beside the loop, so a slow one never holds up the socket.
    let (requests, waiting) = tokio::sync::mpsc::unbounded_channel();
    let answering = tokio::spawn(answer_requests(waiting, Arc::clone(&context)));
    let result = relay_session(
        &mut sink,
        &mut stream,
        &mut reassembler,
        &mut request_number,
        &context,
        outgoing,
        requests,
    )
    .await;
    let _ = answering.await;
    channel.detach(epoch);
    sessions.set_asset_source(None);
    unsubscribe(subscription_id).await;
    result
}
