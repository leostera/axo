//! The host's connection to the Axo relay: one authenticated WebSocket per linked host,
//! reconnected with backoff, over which remote clients list, create and drive Sessions.
//!
//! - `status`: the connection state Axo.app shows, and its manual retry.
//! - `socket`: connecting, and reading and sending whole messages (shared with `peers`).
//! - `session`: one connected session: negotiate, register, then serve until it closes.
//! - `dispatch`: answering `axo.remote.*` requests through the host.
//! - `jobs`: bash, prompts with attachments and sign-ins, each on a thread of its own.
//! - `elicitation`: a person's answers to an agent's questions (RFD0029).
//! - `wire`: the JSON-RPC message types.

mod dispatch;
mod elicitation;
mod jobs;
mod session;
mod socket;
mod status;
mod wire;

pub(crate) use socket::{
    CONNECT_TIMEOUT, MAX_FRAME_BYTES, RelaySocket, connect_websocket, host_websocket_request,
    read_message, send_json, set_read_timeout,
};
pub use status::{RelayControl, unavailable_status};

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use axo_protocol::HostKind;
use elicitation::ELICITATION_REQUESTED;
use session::{RelaySessionContext, relay_session, rpc_call};
use socket::{SOCKET_READ_TIMEOUT, relay_websocket_request};
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

const NOT_LINKED: &str = "This Mac is not linked to an Axo account.";

pub struct RelayWorker {
    stop: Arc<AtomicBool>,
    control: Arc<RelayControl>,
    channel: Arc<RelayChannel>,
    thread: Option<JoinHandle<()>>,
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

impl RelayWorker {
    /// Starts the worker thread. It stays idle until the host is linked, then keeps one
    /// authenticated connection to the relay, reconnecting with backoff.
    pub fn start(dependencies: RelayDependencies) -> io::Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let observed_host = Arc::downgrade(&dependencies.host);
        let control = Arc::new(
            RelayControl::new(host_label(), HostKind::MacOS).with_observer(Box::new(
                move |status| {
                    if let Some(host) = observed_host.upgrade() {
                        host.publish_relay_status(status);
                    }
                },
            )),
        );
        let worker_stop = Arc::clone(&stop);
        let worker_control = Arc::clone(&control);
        let channel = RelayChannel::new();
        let worker_channel = Arc::clone(&channel);
        let waker = SyncWaker::default();
        let sync = SyncWorker::start(
            Arc::clone(&dependencies.host),
            Arc::clone(&channel),
            waker.clone(),
            Arc::clone(&stop),
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
                Arc::clone(&stop),
            )?),
            None => None,
        };
        let worker = thread::Builder::new()
            .name("axo-cloud-relay".to_owned())
            .spawn(move || {
                run_reconnect_loop(
                    dependencies,
                    worker_stop,
                    worker_control,
                    worker_channel,
                    waker,
                )
            })?;
        Ok(Self {
            stop,
            control,
            channel,
            thread: Some(worker),
            sync,
            peers,
        })
    }

    pub fn stop_handle(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.stop)
    }

    pub fn control_handle(&self) -> Arc<RelayControl> {
        Arc::clone(&self.control)
    }

    /// What other threads use to send requests and notifications to the cloud.
    pub fn channel_handle(&self) -> Arc<RelayChannel> {
        Arc::clone(&self.channel)
    }

    pub fn shutdown(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.thread.take() {
            let _ = worker.join();
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

fn run_reconnect_loop(
    dependencies: RelayDependencies,
    stop: Arc<AtomicBool>,
    control: Arc<RelayControl>,
    channel: Arc<RelayChannel>,
    waker: SyncWaker,
) {
    let mut retry_delay = Duration::from_secs(1);
    while !stop.load(Ordering::Relaxed) {
        let link = match dependencies.links.load_link() {
            Ok(link) => link,
            Err(error) => {
                control.mark_disconnected(&error);
                log::warn!("event=relay.link_unavailable reason={error}");
                wait_for_reconnect(&control, &stop, retry_delay);
                retry_delay = (retry_delay * 2).min(MAX_RECONNECT_DELAY);
                continue;
            }
        };
        // Only a linked host connects; linking requests a reconnect, which ends this wait.
        let Some(account) = link.account() else {
            control.mark_disconnected(NOT_LINKED);
            wait_for_reconnect(&control, &stop, Duration::from_secs(1));
            retry_delay = Duration::from_secs(1);
            continue;
        };

        control.mark_connecting();
        match run_connection(&dependencies, account, &stop, &control, &channel, &waker) {
            Ok(()) if stop.load(Ordering::Relaxed) => break,
            Ok(()) => {
                control.mark_disconnected("relay connection ended");
                log::warn!("event=relay.connection_ended");
            }
            Err(error) => {
                control.mark_disconnected(&error);
                log::warn!("event=relay.connection_retry reason={error}");
            }
        }
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let requested_now = wait_for_reconnect(&control, &stop, retry_delay);
        retry_delay = if requested_now {
            Duration::from_secs(1)
        } else {
            (retry_delay * 2).min(MAX_RECONNECT_DELAY)
        };
    }
}

fn wait_for_reconnect(control: &RelayControl, stop: &AtomicBool, delay: Duration) -> bool {
    let until = Instant::now() + delay;
    while Instant::now() < until && !stop.load(Ordering::Relaxed) {
        if control.reconnect_requested.swap(false, Ordering::Relaxed) {
            return true;
        }
        thread::sleep(Duration::from_millis(100));
    }
    false
}

fn run_connection(
    dependencies: &RelayDependencies,
    account: &AccountLink,
    stop: &AtomicBool,
    control: &RelayControl,
    channel: &RelayChannel,
    waker: &SyncWaker,
) -> io::Result<()> {
    let sessions = &dependencies.host;
    let host_id = sessions.host_id().to_owned();
    let host_generation = sessions.host_generation().to_owned();
    let request = relay_websocket_request(
        &dependencies.endpoint,
        account,
        &host_id,
        dependencies.credentials.as_ref(),
    )?;

    let websocket_config = WebSocketConfig::default()
        .read_buffer_size(8192)
        .write_buffer_size(4096)
        .max_write_buffer_size(131_072)
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let mut socket = connect_websocket(request, websocket_config)?;
    set_read_timeout(&mut socket, SOCKET_READ_TIMEOUT)?;

    let mut request_number = 0_u64;
    // Partial messages die with this socket (RFD0016, Transport).
    let mut reassembler = Reassembler::default();
    rpc_call(
        &mut socket,
        &mut reassembler,
        &mut request_number,
        "axo.protocol.negotiate",
        NegotiateParams {
            protocol_version: axo_protocol::rpc::PROTOCOL_VERSION,
        },
        sessions,
        &host_id,
        &host_generation,
    )?;
    let subscription_id = sessions.subscribe_remote_events()?;
    let label = host_label();
    let registration = HostRegistration {
        protocol_version: axo_protocol::rpc::PROTOCOL_VERSION,
        host_id: &host_id,
        host_generation: &host_generation,
        label: &label,
        host_kind: HostKind::MacOS,
        capabilities: HOST_CAPABILITIES,
        sessions: [],
    };
    if let Err(error) = rpc_call(
        &mut socket,
        &mut reassembler,
        &mut request_number,
        "axo.host.register",
        registration,
        sessions,
        &host_id,
        &host_generation,
    ) {
        let _ = sessions.unsubscribe_remote_events(&subscription_id);
        return Err(error);
    }
    control.mark_connected();

    // Threads queue onto this socket only while it lives (RFD0016, Transport).
    let (epoch, outgoing, replies) = channel.attach();
    // A new socket needs a new handshake: the uploader starts it now.
    waker.wake();
    // What agents are asking the person goes up again on every socket (RFD0029).
    for elicitation in sessions.pending_elicitations() {
        let _ = channel.notify(
            ELICITATION_REQUESTED,
            serde_json::to_value(&elicitation).expect("an elicitation serializes"),
            Priority::Control,
        );
    }
    let result = relay_session(
        &mut socket,
        &mut reassembler,
        &mut request_number,
        RelaySessionContext {
            sessions,
            host_id: &host_id,
            host_generation: &host_generation,
            subscription_id: &subscription_id,
            stop,
            control,
            channel,
            outgoing,
            replies,
            waker,
            socket_id: format!("axod-{}-{epoch}", std::process::id()),
            account_id: account.account_id().to_owned(),
            assets: dependencies.assets_directory.as_ref().map(|directory| {
                crate::assets::AssetSource {
                    endpoint: dependencies.endpoint.clone(),
                    account: account.clone(),
                    host_id: host_id.clone(),
                    credentials: Arc::clone(&dependencies.credentials),
                    directory: directory.clone(),
                }
            }),
        },
    );
    channel.detach(epoch);
    let _ = sessions.unsubscribe_remote_events(&subscription_id);
    result
}
