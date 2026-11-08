//! One connection's life: hello, open every Session from where its copy ends, then keep the
//! copies current and carry commands out.
//!
//! In protocol 2 that is one socket, the account's, which carries everything. In protocol 3
//! (RFD0032) the account's socket lists the Macs, and a socket on each Mac's HostDO carries that
//! Mac's index, records and commands: a reconnect then costs one hello per Mac, and a copy that
//! already holds a Session's head opens with no read. This Mac's own HostDO is opened only to
//! fetch back one of its archived Sessions (RFD0027).
//!
//! Each socket runs on its own task (`socket.rs`) and hands whole messages to one channel. The
//! loop waits on that, `PeerLive`'s wake-up (a pane, a command, a restore), the socket's
//! lifetime and stopping at once. Handling a message writes copies to disk, so it runs under
//! `block_in_place`.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::mpsc as channel;

use super::index::PeerIndex;
use super::live::{PeerCommand, PeerCommandError, PeerLive, Restoring};
use super::mirror::{ClientRecord, CopyState, Mirror, Place};
use super::socket::{Incoming, Route, SocketHandle};
use super::{PeersDependencies, restore_directory};
use crate::relay::{RelaySink, RelayStream};

/// Opens waiting for their reply at once.
const OPENS_IN_FLIGHT: usize = 4;
/// The cloud signs the socket in for an hour; it is opened again before that.
const SOCKET_LIFETIME: Duration = Duration::from_secs(50 * 60);

/// Which protocol a connection speaks (RFD0032).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Protocol {
    /// Everything on the account's socket, through the ClientDO.
    Relayed,
    /// The account's socket lists the Macs; each Mac's HostDO serves its own Sessions.
    Direct,
}

impl Protocol {
    /// What the account's socket is told in hello.
    fn version(self) -> u32 {
        match self {
            Protocol::Relayed => axo_protocol::rpc::PROTOCOL_VERSION,
            Protocol::Direct => 3,
        }
    }
}

/// Whether a Mac is online, as its HostDO says, and the run of it a command must name.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Presence {
    online: bool,
    host_generation: Option<String>,
}

/// A Mac's HostDO answering hello (protocol 3): its presence and its index.
#[derive(serde::Deserialize)]
struct HostHello {
    #[serde(flatten)]
    presence: Presence,
    sessions: Vec<Value>,
}

/// Numbers connections above the last one, from the clock: a HostDO keeps a client's newest
/// connection and refuses an older one, so a clock that steps back must not number one lower.
fn next_connection() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_micros() as u64);
    let mut last = LAST.load(Ordering::Relaxed);
    loop {
        let next = now.max(last + 1);
        match LAST.compare_exchange_weak(last, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return next,
            Err(seen) => last = seen,
        }
    }
}

/// Opens a socket on a Mac's HostDO (protocol 3).
pub(super) type Connect = Box<
    dyn Fn(
            String,
        )
            -> std::pin::Pin<Box<dyn Future<Output = io::Result<(RelaySink, RelayStream)>> + Send>>
        + Send
        + Sync,
>;

enum Pending {
    Hello,
    /// A Mac's HostDO answering with its index (protocol 3).
    HostHello {
        host_id: String,
    },
    Open {
        place: Place,
        from_nothing: bool,
    },
    /// A remote pane's command, on its way to the Mac it names.
    Command {
        host_id: String,
        reply: mpsc::Sender<Result<Value, PeerCommandError>>,
    },
}

impl Pending {
    /// Whether its answer is to come from, or about, `host_id`.
    fn waits_on(&self, host_id: &str) -> bool {
        match self {
            Pending::Hello => false,
            Pending::HostHello { host_id: asked } | Pending::Command { host_id: asked, .. } => {
                asked == host_id
            }
            Pending::Open { place, .. } => place.host_id == host_id,
        }
    }
}

/// How a connection ended.
pub(super) struct Ended {
    pub(super) outcome: io::Result<()>,
    /// It spoke protocol 3 and failed before every Mac it follows said hello: the cloud may not
    /// serve protocol 3 yet, so the next connections speak 2 for a while.
    pub(super) refused_direct: bool,
}

/// One connection's life: hello, then open every Session, then keep the copies current.
pub(super) struct Follower<'a> {
    protocol: Protocol,
    connect: Connect,
    /// The sockets open now; a Mac's is opened when the account lists it.
    sockets: HashMap<Route, SocketHandle>,
    /// Messages for a Mac's socket that isn't open yet, sent once it is.
    waiting: HashMap<String, Vec<Value>>,
    incoming: channel::UnboundedSender<Incoming>,
    received: channel::UnboundedReceiver<Incoming>,
    /// This connection's number: a HostDO keeps a client's newest and refuses an older one.
    connection: u64,
    /// Whether every Mac listed at hello has answered with its index.
    ready: bool,
    /// Each Mac's presence as its HostDO says (protocol 3), merged into the listing.
    presence: HashMap<String, Presence>,
    mirror: &'a mut Mirror,
    own_host_id: &'a str,
    index_path: &'a Path,
    live: &'a PeerLive,
    stop: &'a axo_ipc::Stop,
    next_id: u64,
    pending: HashMap<u64, Pending>,
    /// Sessions waiting to be opened, and those open on this connection, by Session id.
    to_open: std::collections::VecDeque<String>,
    open: HashMap<String, Place>,
    /// Every listed Session with records: where its copy goes, and its epoch.
    listed: HashMap<String, (Place, u64)>,
    /// Listed Sessions that are archived: copied only while a pane shows them.
    archived: HashSet<String>,
    /// What panes showed when last checked.
    kept: HashSet<String>,
    /// This Mac's own Sessions being fetched back, and where (`server/restoring`).
    restoring: HashMap<String, Restoring>,
    restore_mirror: Mirror,
    /// The epoch the cloud lists each of this Mac's own Sessions at.
    own_epochs: HashMap<String, u64>,
    index: PeerIndex,
}

impl<'a> Follower<'a> {
    pub(super) fn new(
        mirror: &'a mut Mirror,
        dependencies: &'a PeersDependencies,
        stop: &'a axo_ipc::Stop,
        protocol: Protocol,
        connect: Connect,
    ) -> Self {
        let (incoming, received) = channel::unbounded_channel();
        let connection = next_connection();
        Self {
            protocol,
            connect,
            sockets: HashMap::new(),
            waiting: HashMap::new(),
            incoming,
            received,
            connection,
            ready: false,
            presence: HashMap::new(),
            mirror,
            own_host_id: &dependencies.host_id,
            index_path: &dependencies.index,
            live: &dependencies.live,
            stop,
            next_id: 1,
            pending: HashMap::new(),
            to_open: std::collections::VecDeque::new(),
            open: HashMap::new(),
            listed: HashMap::new(),
            archived: HashSet::new(),
            kept: HashSet::new(),
            restoring: HashMap::new(),
            restore_mirror: Mirror::new(restore_directory(&dependencies.index)),
            own_epochs: HashMap::new(),
            index: PeerIndex::default(),
        }
    }

    pub(super) async fn run(mut self, sink: RelaySink, stream: RelayStream) -> Ended {
        self.live.connected();
        let outcome = self.follow(sink, stream).await;
        let in_flight = self
            .pending
            .drain()
            .filter_map(|(_, pending)| match pending {
                Pending::Command { reply, .. } => Some(reply),
                _ => None,
            })
            .collect();
        self.live.disconnected(in_flight);
        self.sockets.clear();
        let refused_direct = self.protocol == Protocol::Direct && !self.ready && outcome.is_err();
        Ended {
            outcome,
            refused_direct,
        }
    }

    async fn follow(&mut self, sink: RelaySink, stream: RelayStream) -> io::Result<()> {
        let lifetime = tokio::time::sleep(SOCKET_LIFETIME);
        let mut lifetime = std::pin::pin!(lifetime);
        self.sockets.insert(
            Route::Account,
            super::socket::spawn(Route::Account, sink, stream, self.incoming.clone()),
        );
        log::info!(
            "event=peers.connecting protocol={}",
            self.protocol.version()
        );
        if self.protocol == Protocol::Relayed {
            self.ready = true;
        }
        self.call(
            Route::Account,
            Pending::Hello,
            "axo.client.hello",
            json!({ "protocolVersion": self.protocol.version(), "clientId": self.client_id() }),
        )?;
        while !self.stop.is_stopped() {
            // What panes, commands and restores asked for since the last turn.
            tokio::task::block_in_place(|| -> io::Result<()> {
                self.follow_panes()?;
                self.start_restores()?;
                self.open_more()?;
                for command in self.live.take_commands() {
                    self.forward(command)?;
                }
                Ok(())
            })?;
            self.open_sockets().await?;
            tokio::select! {
                () = self.stop.stopped() => {}
                () = self.live.woken() => {}
                () = &mut lifetime => break,
                incoming = self.received.recv() => {
                    let Some((route, message)) = incoming else { break };
                    let message = message?;
                    // Handling it writes the copies to disk before they are acknowledged.
                    tokio::task::block_in_place(|| self.receive(&route, message))?;
                }
            }
        }
        Ok(())
    }

    fn client_id(&self) -> String {
        format!("host-{}", self.own_host_id)
    }

    /// Where messages about `host_id`'s Sessions go: its HostDO in protocol 3.
    fn route_of(&self, host_id: &str) -> Route {
        match self.protocol {
            Protocol::Relayed => Route::Account,
            Protocol::Direct => Route::Host(host_id.to_owned()),
        }
    }

    /// Opens a socket on each Mac that has messages waiting, says hello on it first, then sends
    /// what waited. A Mac whose socket fails ends the connection.
    async fn open_sockets(&mut self) -> io::Result<()> {
        let wanted: Vec<String> = self
            .waiting
            .keys()
            .filter(|host_id| !self.sockets.contains_key(&Route::Host((*host_id).clone())))
            .cloned()
            .collect();
        for host_id in wanted {
            let (sink, stream) = (self.connect)(host_id.clone()).await.map_err(|error| {
                io::Error::new(error.kind(), format!("Mac {host_id}'s socket: {error}"))
            })?;
            let route = Route::Host(host_id.clone());
            let socket = super::socket::spawn(route.clone(), sink, stream, self.incoming.clone());
            let id = self.next_id;
            self.next_id += 1;
            self.pending.insert(
                id,
                Pending::HostHello {
                    host_id: host_id.clone(),
                },
            );
            socket.send(json!({
                "jsonrpc": "2.0", "id": id, "method": "axo.client.hello",
                "params": { "protocolVersion": 3, "clientId": self.client_id(), "connection": self.connection },
            }))?;
            for value in self.waiting.remove(&host_id).unwrap_or_default() {
                socket.send(value)?;
            }
            self.sockets.insert(route, socket);
        }
        Ok(())
    }

    /// A Mac's HostDO answered its hello with its index and presence (protocol 3). An answer
    /// that isn't one ends the connection, as a refused hello does.
    fn host_hello(&mut self, host_id: &str, result: &Value) -> io::Result<()> {
        let hello = HostHello::deserialize(result).map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Mac {host_id}'s HostDO answered hello with something else: {error}"),
            )
        })?;
        self.presence.insert(host_id.to_owned(), hello.presence);
        self.listed_sessions(&stamped(hello.sessions, Some(host_id)))?;
        self.check_ready();
        self.publish_hosts()
    }

    /// Ready once no Mac followed at hello is still to answer it (protocol 3).
    fn check_ready(&mut self) {
        let answering = self
            .pending
            .values()
            .any(|pending| matches!(pending, Pending::HostHello { .. }));
        if !self.ready && !answering && self.waiting.is_empty() {
            self.ready = true;
            log::info!("event=peers.direct_ready hosts={}", self.presence.len());
        }
    }

    /// A message from one of the sockets: the answer to a call, or a notice.
    fn receive(&mut self, route: &Route, message: Value) -> io::Result<()> {
        if let Some(id) = message.get("id").and_then(Value::as_u64) {
            let Some(pending) = self.pending.remove(&id) else {
                return Ok(());
            };
            return match message.get("error") {
                Some(error) => self.refused(pending, error),
                None => self.answered(pending, &message["result"]),
            };
        }
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return Ok(());
        };
        self.notified(route, method, &message["params"])
    }

    /// A call was refused. A refused hello ends the connection; an open or a command fails alone.
    fn refused(&mut self, pending: Pending, error: &Value) -> io::Result<()> {
        match pending {
            Pending::Hello => Err(io::Error::other(format!("hello refused: {error}"))),
            Pending::HostHello { host_id } => Err(io::Error::other(format!(
                "Mac {host_id}'s HostDO refused hello: {error}"
            ))),
            Pending::Open { place, .. } => {
                log::warn!(
                    "event=peers.open_failed session_id={} error={error}",
                    place.session_id
                );
                self.open.remove(&place.session_id);
                self.fail_restore(&place.session_id, format!("the cloud refused: {error}"));
                Ok(())
            }
            Pending::Command { reply, .. } => {
                let _ = reply.send(Err(PeerCommandError {
                    code: error["code"].as_i64().unwrap_or(-32603),
                    message: error["message"]
                        .as_str()
                        .unwrap_or("The Mac refused the command")
                        .to_owned(),
                }));
                Ok(())
            }
        }
    }

    /// A call was answered.
    fn answered(&mut self, pending: Pending, result: &Value) -> io::Result<()> {
        match pending {
            Pending::Hello => {
                let hosts = result["hosts"].as_array().cloned().unwrap_or_default();
                self.listed_hosts(hosts)?;
                if self.protocol == Protocol::Direct {
                    self.check_ready();
                }
                let sessions = result["sessions"].as_array().cloned().unwrap_or_default();
                self.listed_sessions(&sessions)
            }
            Pending::HostHello { host_id } => self.host_hello(&host_id, result),
            Pending::Open {
                place,
                from_nothing,
            } => self.opened(&place, from_nothing, result),
            Pending::Command { reply, .. } => {
                let _ = reply.send(Ok(result.clone()));
                Ok(())
            }
        }
    }

    /// A notice. Presence and names come only from a Mac's own HostDO (protocol 3), and its
    /// Sessions are that Mac's whatever they say.
    fn notified(&mut self, route: &Route, method: &str, params: &Value) -> io::Result<()> {
        let from_host = match route {
            Route::Host(host_id) => Some(host_id.as_str()),
            Route::Account => None,
        };
        match (method, from_host) {
            ("axo.client.host.presence", Some(host_id)) => {
                let Ok(presence) = Presence::deserialize(params) else {
                    log::warn!("event=peers.invalid_notice method={method} host_id={host_id}");
                    return Ok(());
                };
                self.presence.insert(host_id.to_owned(), presence);
                self.publish_hosts()
            }
            ("axo.client.host.label", Some(host_id)) => {
                let Some(label) = params["label"].as_str() else {
                    log::warn!("event=peers.invalid_notice method={method} host_id={host_id}");
                    return Ok(());
                };
                for host in &mut self.index.hosts {
                    if host["hostId"].as_str() == Some(host_id) {
                        host["label"] = json!(label);
                    }
                }
                self.publish_hosts()
            }
            ("axo.client.hosts", None) => {
                let hosts = params["hosts"].as_array().cloned().unwrap_or_default();
                self.listed_hosts(hosts)
            }
            ("axo.client.sessions", _) => {
                let sessions = params["sessions"].as_array().cloned().unwrap_or_default();
                self.listed_sessions(&stamped(sessions, from_host))
            }
            ("axo.client.session.records", _) => self.records(params),
            ("axo.client.session.reset", _) => self.reset(params),
            ("axo.client.session.progress", _) => {
                if let (Some(session_id), Some(slot)) =
                    (params["sessionId"].as_str(), params["slot"].as_str())
                {
                    self.live
                        .set_progress(session_id, slot, params["snapshot"].clone());
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    /// The account's Macs. One it no longer lists is let go of, with everything this connection
    /// holds for it; in protocol 3 a new one gets a socket next turn.
    fn listed_hosts(&mut self, hosts: Vec<Value>) -> io::Result<()> {
        let hosts: Vec<Value> = hosts
            .into_iter()
            .filter(|host| host["hostId"].as_str() != Some(self.own_host_id))
            .collect();
        let listed: HashSet<String> = hosts
            .iter()
            .filter_map(|host| host["hostId"].as_str().map(str::to_owned))
            .collect();
        let dropped: Vec<String> = self
            .followed_hosts()
            .filter(|host_id| !listed.contains(host_id))
            .collect();
        for host_id in dropped {
            self.forget_host(&host_id);
        }
        if self.protocol == Protocol::Direct {
            for host_id in &listed {
                if !self.sockets.contains_key(&Route::Host(host_id.clone())) {
                    self.waiting.entry(host_id.clone()).or_default();
                }
            }
        }
        self.index.hosts = hosts;
        self.publish_hosts()
    }

    /// Every other Mac this connection holds anything for.
    fn followed_hosts(&self) -> impl Iterator<Item = String> + '_ {
        let listed = self
            .index
            .hosts
            .iter()
            .filter_map(|host| host["hostId"].as_str().map(str::to_owned));
        let with_sockets = self.sockets.keys().filter_map(|route| match route {
            Route::Host(host_id) => Some(host_id.clone()),
            Route::Account => None,
        });
        let with_sessions = self.listed.values().map(|(place, _)| place.host_id.clone());
        let all: HashSet<String> = listed
            .chain(with_sockets)
            .chain(with_sessions)
            .chain(self.waiting.keys().cloned())
            .filter(|host_id| host_id != self.own_host_id)
            .collect();
        all.into_iter()
    }

    /// Lets go of a Mac the account no longer lists: its socket, its Sessions' opens, and what
    /// waits on it. A command waiting on it fails as offline. Its copies stay on disk.
    fn forget_host(&mut self, host_id: &str) {
        log::info!("event=peers.host_dropped host_id={host_id}");
        self.sockets.remove(&Route::Host(host_id.to_owned()));
        self.waiting.remove(host_id);
        self.presence.remove(host_id);
        let sessions: HashSet<String> = self
            .listed
            .iter()
            .filter(|(_, (place, _))| place.host_id == host_id)
            .map(|(session_id, _)| session_id.clone())
            .collect();
        self.listed
            .retain(|session_id, _| !sessions.contains(session_id));
        self.open
            .retain(|session_id, _| !sessions.contains(session_id));
        self.to_open
            .retain(|session_id| !sessions.contains(session_id));
        self.archived
            .retain(|session_id| !sessions.contains(session_id));
        let gone: Vec<u64> = self
            .pending
            .iter()
            .filter(|(_, pending)| pending.waits_on(host_id))
            .map(|(id, _)| *id)
            .collect();
        for id in gone {
            // Nothing will answer it now: a command fails as one for an offline Mac does.
            if let Some(Pending::Command { reply, .. }) = self.pending.remove(&id) {
                let _ = reply.send(Err(PeerCommandError::offline()));
            }
        }
        if self.protocol == Protocol::Direct {
            self.check_ready();
        }
    }

    /// Writes the listing with each Mac's presence as its HostDO says, and names each Mac's folder.
    fn publish_hosts(&mut self) -> io::Result<()> {
        for host in &mut self.index.hosts {
            let Some(host_id) = host["hostId"].as_str().map(str::to_owned) else {
                continue;
            };
            if let Some(presence) = self.presence.get(&host_id) {
                host["online"] = json!(presence.online);
                if let Some(generation) = &presence.host_generation {
                    host["hostGeneration"] = json!(generation);
                }
            }
            if let Some(label) = host["label"].as_str()
                && let Err(error) = self.mirror.describe_host(&host_id, label)
            {
                log::warn!("event=peers.host_description_failed host_id={host_id} error={error}");
            }
        }
        self.index.write(self.index_path)?;
        self.live.listing_changed();
        Ok(())
    }

    /// Lists Sessions, and opens those with records this Mac has not opened yet.
    fn listed_sessions(&mut self, sessions: &[Value]) -> io::Result<()> {
        for session in sessions {
            if session["hostId"].as_str() == Some(self.own_host_id)
                && let (Some(session_id), Some(epoch)) =
                    (session["sessionId"].as_str(), session["epoch"].as_u64())
            {
                self.own_epochs.insert(session_id.to_owned(), epoch);
            }
        }
        let theirs: Vec<Value> = sessions
            .iter()
            .filter(|session| session["hostId"].as_str() != Some(self.own_host_id))
            .cloned()
            .collect();
        self.index.merge(&theirs);
        self.index.write(self.index_path)?;
        self.live.listing_changed();
        for session in &theirs {
            let (Some(host_id), Some(session_id), Some(epoch)) = (
                session["hostId"].as_str(),
                session["sessionId"].as_str(),
                session["epoch"].as_u64(),
            ) else {
                continue;
            };
            let workspace_id = session["metadata"]["workspaceId"].as_str();
            let Some(place) = Place::of(host_id, workspace_id, session_id) else {
                log::warn!("event=peers.unsafe_place session_id={session_id}");
                continue;
            };
            self.listed
                .insert(session_id.to_owned(), (place.clone(), epoch));
            // Archived Sessions stay in the cloud; a copy is kept only while a pane shows one.
            if session["metadata"]["archived"].as_bool() == Some(true) {
                self.archived.insert(session_id.to_owned());
                if !self.kept.contains(session_id) {
                    self.drop_copy(session_id, &place)?;
                    continue;
                }
            } else {
                self.archived.remove(session_id);
            }
            if !self.open.contains_key(session_id)
                && !self.to_open.iter().any(|queued| queued == session_id)
            {
                self.to_open.push_back(session_id.to_owned());
            }
        }
        Ok(())
    }

    /// Opens this Mac's own Sessions that are to be fetched back, each from nothing.
    fn start_restores(&mut self) -> io::Result<()> {
        for request in self.live.take_restores() {
            let session_id = request.place.session_id.clone();
            if request.place.host_id != self.own_host_id || self.restoring.contains_key(&session_id)
            {
                let _ = request.reply.send(Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "only one restore of this Mac's own Session at a time",
                )));
                continue;
            }
            if let Err(error) = self.restore_mirror.forget(&request.place) {
                let _ = request.reply.send(Err(error));
                continue;
            }
            let epoch = self.own_epochs.get(&session_id).copied().unwrap_or(1);
            self.restoring.insert(
                session_id.clone(),
                Restoring {
                    count: request.count,
                    reply: request.reply,
                },
            );
            self.open.insert(session_id.clone(), request.place.clone());
            log::info!(
                "event=peers.restore_started session_id={session_id} records={}",
                request.count
            );
            self.call(
                self.route_of(self.own_host_id),
                Pending::Open {
                    place: request.place,
                    from_nothing: true,
                },
                "axo.client.session.open",
                json!({
                    "hostId": self.own_host_id,
                    "sessionId": session_id,
                    "have": { "epoch": epoch, "cursor": 0 },
                }),
            )?;
        }
        Ok(())
    }

    /// A restore is done once its copy has every record; it is closed on the socket then.
    fn restored(&mut self, place: &Place, state: CopyState) -> io::Result<()> {
        let Some(restoring) = self.restoring.get(&place.session_id) else {
            return Ok(());
        };
        if state.cursor < restoring.count {
            return Ok(());
        }
        let restoring = self
            .restoring
            .remove(&place.session_id)
            .expect("found above");
        self.open.remove(&place.session_id);
        self.notify(
            self.route_of(&place.host_id),
            "axo.client.session.close",
            json!({ "sessionId": place.session_id }),
        )?;
        log::info!(
            "event=peers.restored session_id={} records={}",
            place.session_id,
            state.cursor
        );
        let _ = restoring.reply.send(Ok(self.restore_mirror.file(place)));
        Ok(())
    }

    fn fail_restore(&mut self, session_id: &str, reason: String) {
        if let Some(restoring) = self.restoring.remove(session_id) {
            log::warn!("event=peers.restore_failed session_id={session_id} reason={reason}");
            self.open.remove(session_id);
            let _ = restoring.reply.send(Err(io::Error::other(reason)));
        }
    }

    /// This Mac's own Sessions are restored apart from the copies of other Macs'.
    fn mirror_of(&mut self, place: &Place) -> &mut Mirror {
        if place.host_id == self.own_host_id {
            &mut self.restore_mirror
        } else {
            self.mirror
        }
    }

    /// Fetches the archived Sessions panes now show, and drops those no pane shows any more.
    fn follow_panes(&mut self) -> io::Result<()> {
        let wanted = self.live.wanted();
        if wanted == self.kept {
            return Ok(());
        }
        let shown: Vec<String> = wanted.difference(&self.kept).cloned().collect();
        let hidden: Vec<String> = self.kept.difference(&wanted).cloned().collect();
        self.kept = wanted;
        for session_id in shown {
            if self.archived.contains(&session_id)
                && !self.open.contains_key(&session_id)
                && !self.to_open.contains(&session_id)
            {
                self.to_open.push_back(session_id);
            }
        }
        for session_id in hidden {
            if self.archived.contains(&session_id)
                && let Some((place, _)) = self.listed.get(&session_id).cloned()
            {
                self.drop_copy(&session_id, &place)?;
            }
        }
        Ok(())
    }

    /// Stops following an archived Session and deletes its copy.
    fn drop_copy(&mut self, session_id: &str, place: &Place) -> io::Result<()> {
        if self.open.remove(session_id).is_some() {
            self.notify(
                self.route_of(&place.host_id),
                "axo.client.session.close",
                json!({ "sessionId": session_id }),
            )?;
        }
        self.to_open.retain(|queued| queued != session_id);
        if self.mirror.forget(place)? {
            log::info!("event=peers.copy_dropped session_id={session_id} reason=archived");
            self.live.touch();
        }
        Ok(())
    }

    /// Opens queued Sessions while few opens wait for their reply.
    fn open_more(&mut self) -> io::Result<()> {
        let in_flight = self
            .pending
            .values()
            .filter(|pending| matches!(pending, Pending::Open { .. }))
            .count();
        for _ in in_flight..OPENS_IN_FLIGHT {
            let Some(session_id) = self.to_open.pop_front() else {
                break;
            };
            let Some((place, listed_epoch)) = self.listed.get(&session_id).cloned() else {
                continue;
            };
            let state = self.mirror.state(&place)?;
            let have = state.unwrap_or(CopyState {
                epoch: listed_epoch,
                cursor: 0,
            });
            self.open.insert(session_id.clone(), place.clone());
            let params = json!({
                "hostId": place.host_id,
                "sessionId": session_id,
                "have": { "epoch": have.epoch, "cursor": have.cursor },
            });
            self.call(
                self.route_of(&place.host_id),
                Pending::Open {
                    place,
                    from_nothing: state.is_none(),
                },
                "axo.client.session.open",
                params,
            )?;
        }
        Ok(())
    }

    fn opened(&mut self, place: &Place, from_nothing: bool, result: &Value) -> io::Result<()> {
        if let Some(progress) = result["progress"].as_array() {
            self.live.replace_progress(&place.session_id, progress);
        }
        let Some(epoch) = result["epoch"].as_u64() else {
            return Ok(());
        };
        let records: Vec<ClientRecord> =
            serde_json::from_value(result["records"].clone()).unwrap_or_default();
        let copied = if from_nothing {
            let Some(header) = result["header"].as_str() else {
                log::warn!(
                    "event=peers.open_without_header session_id={}",
                    place.session_id
                );
                self.fail_restore(&place.session_id, "the cloud has no header".to_owned());
                return Ok(());
            };
            self.mirror_of(place).start(place, epoch, header, &records)
        } else {
            self.mirror_of(place).append(place, epoch, &records)
        };
        if let Some(state) = self.copied(place, copied)? {
            self.restored(place, state)?;
        }
        self.live.touch();
        Ok(())
    }

    fn records(&mut self, params: &Value) -> io::Result<()> {
        let (Some(session_id), Some(epoch)) =
            (params["sessionId"].as_str(), params["epoch"].as_u64())
        else {
            return Ok(());
        };
        let Some(place) = self.open.get(session_id).cloned() else {
            return Ok(());
        };
        let records: Vec<ClientRecord> =
            serde_json::from_value(params["records"].clone()).unwrap_or_default();
        let copied = self.mirror_of(&place).append(&place, epoch, &records);
        if let Some(state) = self.copied(&place, copied)? {
            // Only what is on disk is acknowledged; the next batch follows the acknowledgement.
            self.notify(
                self.route_of(&place.host_id),
                "axo.client.session.ack",
                json!({ "sessionId": session_id, "cursor": state.cursor }),
            )?;
            self.restored(&place, state)?;
            self.live.touch();
        }
        Ok(())
    }

    fn reset(&mut self, params: &Value) -> io::Result<()> {
        let (Some(session_id), Some(epoch), Some(keep)) = (
            params["sessionId"].as_str(),
            params["epoch"].as_u64(),
            params["keep"].as_u64(),
        ) else {
            return Ok(());
        };
        let Some(place) = self.open.get(session_id).cloned() else {
            return Ok(());
        };
        // A restore told of another epoch before its first records has nothing to cut.
        if self.restoring.contains_key(session_id) && self.restore_mirror.state(&place)?.is_none() {
            return Ok(());
        }
        let reset = self.mirror_of(&place).reset(&place, epoch, keep);
        self.copied(&place, reset).map(|_| ())?;
        self.live.touch();
        Ok(())
    }

    /// Sends a remote pane's command to the Mac it names, addressed to that Mac's current
    /// generation as the account lists it.
    fn forward(&mut self, command: PeerCommand) -> io::Result<()> {
        let generation = self
            .index
            .hosts
            .iter()
            .find(|host| host["hostId"].as_str() == Some(command.host_id.as_str()))
            .and_then(|host| host["hostGeneration"].as_str())
            .map(str::to_owned);
        let (Some(generation), Value::Object(mut params)) = (generation, command.params) else {
            let _ = command.reply.send(Err(PeerCommandError::offline()));
            return Ok(());
        };
        params.insert(
            "target".to_owned(),
            json!({ "hostId": command.host_id, "hostGeneration": generation }),
        );
        self.call(
            self.route_of(&command.host_id),
            Pending::Command {
                host_id: command.host_id.clone(),
                reply: command.reply,
            },
            "axo.client.command",
            json!({ "hostId": command.host_id, "method": command.method, "params": params }),
        )
    }

    /// A copy that could not take the records is opened again from where it is.
    fn copied(
        &mut self,
        place: &Place,
        outcome: io::Result<CopyState>,
    ) -> io::Result<Option<CopyState>> {
        match outcome {
            Ok(state) => Ok(Some(state)),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::InvalidData | io::ErrorKind::NotFound
                ) =>
            {
                if self.restoring.contains_key(&place.session_id) {
                    self.notify(
                        self.route_of(&place.host_id),
                        "axo.client.session.close",
                        json!({ "sessionId": place.session_id }),
                    )?;
                    self.fail_restore(&place.session_id, error.to_string());
                    return Ok(None);
                }
                log::warn!(
                    "event=peers.copy_reopened session_id={} reason={error}",
                    place.session_id
                );
                self.notify(
                    self.route_of(&place.host_id),
                    "axo.client.session.close",
                    json!({ "sessionId": place.session_id }),
                )?;
                self.open.remove(&place.session_id);
                self.to_open.push_back(place.session_id.clone());
                Ok(None)
            }
            // The disk itself failed: the socket ends, and nothing unwritten was acknowledged.
            Err(error) => Err(error),
        }
    }

    fn call(
        &mut self,
        route: Route,
        pending: Pending,
        method: &str,
        params: Value,
    ) -> io::Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        self.pending.insert(id, pending);
        self.send(
            route,
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }),
        )
    }

    fn notify(&mut self, route: Route, method: &str, params: Value) -> io::Result<()> {
        self.send(
            route,
            json!({ "jsonrpc": "2.0", "method": method, "params": params }),
        )
    }

    /// Sends on the route's socket, or keeps it for a Mac's socket that opens next turn. Only a
    /// Mac the account lists, or this Mac's own, gets a socket: the cloud refuses any other, and
    /// that would end the connection.
    fn send(&mut self, route: Route, value: Value) -> io::Result<()> {
        if let Some(socket) = self.sockets.get(&route) {
            return socket.send(value);
        }
        match route {
            Route::Host(host_id) if self.may_open(&host_id) => {
                self.waiting.entry(host_id).or_default().push(value);
                Ok(())
            }
            Route::Host(host_id) => {
                log::warn!(
                    "event=peers.unlisted_host host_id={host_id} method={}",
                    value["method"]
                );
                Ok(())
            }
            Route::Account => Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "the account's socket has ended",
            )),
        }
    }
}

impl Follower<'_> {
    /// Whether a socket may be opened on `host_id`: it is listed, or it is this Mac.
    fn may_open(&self, host_id: &str) -> bool {
        host_id == self.own_host_id
            || self
                .index
                .hosts
                .iter()
                .any(|host| host["hostId"].as_str() == Some(host_id))
    }
}

/// A Mac's HostDO serves only that Mac's Sessions: its rows are that Mac's, whatever they say.
fn stamped(mut sessions: Vec<Value>, host_id: Option<&str>) -> Vec<Value> {
    if let Some(host_id) = host_id {
        for session in &mut sessions {
            session["hostId"] = json!(host_id);
        }
    }
    sessions
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::credential::HostCredentialStore;
    use crate::endpoint::RelayEndpoint;
    use crate::link::{HostLink, HostLinkStore};
    use crate::peers::test_support::{SESSION, Scratch};

    const OWN: &str = "f30dc1f0-2229-44a2-9c65-fc958d7e0d25";
    const STUDIO: &str = "38b053a6-5b91-4dad-bbcf-2d2cbc9f0509";
    const GENERATION: &str = "7a3b1c2d-0000-4000-8000-000000000001";

    struct Unlinked;
    impl HostLinkStore for Unlinked {
        fn load_link(&self) -> io::Result<HostLink> {
            Ok(HostLink::default())
        }
        fn save_link(&self, _: &HostLink) -> io::Result<()> {
            Ok(())
        }
    }
    struct NoCredentials;
    impl HostCredentialStore for NoCredentials {
        fn store(&self, _: &str, _: &[u8]) -> io::Result<()> {
            Ok(())
        }
        fn load(&self, _: &str) -> io::Result<Vec<u8>> {
            Err(io::ErrorKind::NotFound.into())
        }
        fn delete(&self, _: &str) -> io::Result<()> {
            Ok(())
        }
    }

    fn dependencies(scratch: &Scratch) -> PeersDependencies {
        PeersDependencies {
            host_id: OWN.to_owned(),
            endpoint: RelayEndpoint::parse("http://127.0.0.1:9").unwrap(),
            links: Arc::new(Unlinked),
            credentials: Arc::new(NoCredentials),
            sessions_directory: scratch.0.join("sessions"),
            index: scratch.0.join("server/peers.json"),
            live: PeerLive::new(),
        }
    }

    fn never_connects() -> Connect {
        Box::new(|_| Box::pin(async { Err(io::Error::other("no sockets in this test")) }))
    }

    fn studio() -> Value {
        json!({ "hostId": STUDIO, "hostGeneration": GENERATION, "label": "Studio", "online": false })
    }

    fn studio_hello() -> Value {
        json!({
            "online": true, "hostGeneration": GENERATION,
            "sessions": [{ "sessionId": SESSION, "epoch": 1, "head": 2, "metadata": { "workspaceId": null } }],
        })
    }

    #[test]
    fn a_mac_the_account_stops_listing_is_let_go_of_with_what_waits_on_it() {
        let scratch = Scratch::new();
        std::fs::create_dir_all(scratch.0.join("server")).unwrap();
        let dependencies = dependencies(&scratch);
        let mut mirror = Mirror::new(dependencies.sessions_directory.clone());
        let stop = axo_ipc::Stop::default();
        let mut follower = Follower::new(
            &mut mirror,
            &dependencies,
            &stop,
            Protocol::Direct,
            never_connects(),
        );

        // The Studio is listed, says hello with a Session, and an open and a command wait on it.
        follower.listed_hosts(vec![studio()]).unwrap();
        assert!(
            follower.waiting.contains_key(STUDIO),
            "a socket is wanted on the Studio"
        );
        follower.host_hello(STUDIO, &studio_hello()).unwrap();
        follower.open_more().unwrap();
        let (reply, answer) = mpsc::channel();
        follower
            .forward(PeerCommand {
                host_id: STUDIO.to_owned(),
                method: "axo.remote.session.prompt".to_owned(),
                params: json!({ "sessionId": SESSION, "text": "hi" }),
                reply,
            })
            .unwrap();
        assert_eq!(
            follower.waiting[STUDIO].len(),
            2,
            "the open and the command wait for its socket"
        );

        // Unpaired: nothing of it is kept, and nothing is sent its way.
        follower.listed_hosts(vec![]).unwrap();
        assert!(
            follower.waiting.is_empty(),
            "no socket may be asked for on a Mac the cloud doesn't list"
        );
        assert!(follower.pending.is_empty(), "{:?}", follower.pending.len());
        assert!(
            follower.open.is_empty() && follower.to_open.is_empty() && follower.listed.is_empty()
        );
        let refused = answer
            .try_recv()
            .expect("the command is answered")
            .unwrap_err();
        assert_eq!(refused.code, PeerCommandError::offline().code);
        follower
            .notify(
                Route::Host(STUDIO.to_owned()),
                "axo.client.session.ack",
                json!({}),
            )
            .unwrap();
        assert!(
            follower.waiting.is_empty(),
            "a late message for it is dropped"
        );
    }

    #[test]
    fn a_mac_let_go_of_before_its_hello_does_not_keep_the_connection_from_being_ready() {
        let scratch = Scratch::new();
        std::fs::create_dir_all(scratch.0.join("server")).unwrap();
        let dependencies = dependencies(&scratch);
        let mut mirror = Mirror::new(dependencies.sessions_directory.clone());
        let stop = axo_ipc::Stop::default();
        let mut follower = Follower::new(
            &mut mirror,
            &dependencies,
            &stop,
            Protocol::Direct,
            never_connects(),
        );
        follower
            .answered(
                Pending::Hello,
                &json!({ "hosts": [studio()], "sessions": [] }),
            )
            .unwrap();
        follower.waiting.clear();
        follower.pending.insert(
            7,
            Pending::HostHello {
                host_id: STUDIO.to_owned(),
            },
        );
        assert!(!follower.ready, "the Studio has not answered");
        follower.listed_hosts(vec![]).unwrap();
        assert!(follower.ready, "no Mac is left to answer");
    }

    #[test]
    fn a_hosts_hello_that_is_not_one_ends_the_connection() {
        let scratch = Scratch::new();
        std::fs::create_dir_all(scratch.0.join("server")).unwrap();
        let dependencies = dependencies(&scratch);
        let mut mirror = Mirror::new(dependencies.sessions_directory.clone());
        let stop = axo_ipc::Stop::default();
        let mut follower = Follower::new(
            &mut mirror,
            &dependencies,
            &stop,
            Protocol::Direct,
            never_connects(),
        );
        follower.listed_hosts(vec![studio()]).unwrap();
        let error = follower
            .host_hello(STUDIO, &json!({ "online": "yes", "sessions": [] }))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn connections_are_numbered_above_the_last() {
        let first = next_connection();
        let second = next_connection();
        assert!(second > first);
    }
}
