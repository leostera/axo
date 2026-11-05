//! One socket's life: hello, open every Session from where its copy ends, then keep the copies
//! current and carry commands out.

use std::collections::{HashMap, HashSet, VecDeque};
use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tungstenite::Message;

use super::index::PeerIndex;
use super::live::{PeerCommand, PeerCommandError, PeerLive, Restoring};
use super::mirror::{ClientRecord, CopyState, Mirror, Place};
use super::{PeersDependencies, restore_directory};
use crate::fragments::Reassembler;
use crate::relay::{CONNECT_TIMEOUT, RelaySocket, read_message, send_json, set_read_timeout};

/// Frames sent per second, half what the cloud allows a client (`FRAMES_PER_SECOND`).
const FRAMES_PER_SECOND: usize = 30;
/// Opens waiting for their reply at once.
const OPENS_IN_FLIGHT: usize = 4;
/// The cloud signs the socket in for an hour; it is opened again before that.
const SOCKET_LIFETIME: Duration = Duration::from_secs(50 * 60);
const PING_INTERVAL: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_millis(50);

enum Pending {
    Hello,
    Open {
        place: Place,
        from_nothing: bool,
    },
    Command {
        reply: mpsc::Sender<Result<Value, PeerCommandError>>,
    },
}

/// One socket's life: hello, then open every Session, then keep the copies current.
pub(super) struct Follower<'a> {
    socket: RelaySocket,
    reassembler: Reassembler,
    mirror: &'a mut Mirror,
    own_host_id: &'a str,
    index_path: &'a Path,
    live: &'a PeerLive,
    stop: &'a AtomicBool,
    next_id: u64,
    pending: HashMap<u64, Pending>,
    /// Sessions waiting to be opened, and those open on this socket, by Session id.
    to_open: VecDeque<String>,
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
    sent: VecDeque<Instant>,
}

impl<'a> Follower<'a> {
    pub(super) fn new(
        mut socket: RelaySocket,
        mirror: &'a mut Mirror,
        dependencies: &'a PeersDependencies,
        stop: &'a AtomicBool,
    ) -> io::Result<Self> {
        set_read_timeout(&mut socket, READ_TIMEOUT)?;
        Ok(Self {
            socket,
            reassembler: Reassembler::default(),
            mirror,
            own_host_id: &dependencies.host_id,
            index_path: &dependencies.index,
            live: &dependencies.live,
            stop,
            next_id: 1,
            pending: HashMap::new(),
            to_open: VecDeque::new(),
            open: HashMap::new(),
            listed: HashMap::new(),
            archived: HashSet::new(),
            kept: HashSet::new(),
            restoring: HashMap::new(),
            restore_mirror: Mirror::new(restore_directory(&dependencies.index)),
            own_epochs: HashMap::new(),
            index: PeerIndex::default(),
            sent: VecDeque::new(),
        })
    }

    pub(super) fn run(mut self) -> io::Result<()> {
        self.live.connected();
        let outcome = self.follow();
        let in_flight = self
            .pending
            .drain()
            .filter_map(|(_, pending)| match pending {
                Pending::Command { reply } => Some(reply),
                _ => None,
            })
            .collect();
        self.live.disconnected(in_flight);
        outcome
    }

    fn follow(&mut self) -> io::Result<()> {
        let opened = Instant::now();
        let mut pinged = Instant::now();
        let client_id = format!("host-{}", self.own_host_id);
        self.call(
            Pending::Hello,
            "axo.client.hello",
            json!({ "protocolVersion": axo_protocol::rpc::PROTOCOL_VERSION, "clientId": client_id }),
        )?;
        while !self.stop.load(Ordering::Relaxed) && opened.elapsed() < SOCKET_LIFETIME {
            self.follow_panes()?;
            self.start_restores()?;
            self.open_more()?;
            for command in self.live.take_commands() {
                self.forward(command)?;
            }
            if pinged.elapsed() >= PING_INTERVAL {
                self.socket
                    .send(Message::Ping(Vec::new().into()))
                    .map_err(io::Error::other)?;
                pinged = Instant::now();
            }
            let Some(text) = read_message(&mut self.socket, &mut self.reassembler)? else {
                continue;
            };
            let message: Value = serde_json::from_str(&text).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, "the cloud sent invalid JSON")
            })?;
            self.receive(message)?;
        }
        let _ = self.socket.close(None);
        Ok(())
    }

    fn receive(&mut self, message: Value) -> io::Result<()> {
        if let Some(id) = message.get("id").and_then(Value::as_u64) {
            let Some(pending) = self.pending.remove(&id) else {
                return Ok(());
            };
            if let Some(error) = message.get("error") {
                return match pending {
                    Pending::Hello => Err(io::Error::other(format!("hello refused: {error}"))),
                    Pending::Open { place, .. } => {
                        log::warn!(
                            "event=peers.open_failed session_id={} error={error}",
                            place.session_id
                        );
                        self.open.remove(&place.session_id);
                        self.fail_restore(&place.session_id, format!("the cloud refused: {error}"));
                        Ok(())
                    }
                    Pending::Command { reply } => {
                        let _ = reply.send(Err(PeerCommandError {
                            code: error["code"].as_i64().unwrap_or(-32603),
                            message: error["message"]
                                .as_str()
                                .unwrap_or("The Mac refused the command")
                                .to_owned(),
                        }));
                        Ok(())
                    }
                };
            }
            let result = &message["result"];
            return match pending {
                Pending::Hello => {
                    let hosts = result["hosts"].as_array().cloned().unwrap_or_default();
                    self.listed_hosts(hosts)?;
                    let sessions = result["sessions"].as_array().cloned().unwrap_or_default();
                    self.listed_sessions(&sessions)
                }
                Pending::Open {
                    place,
                    from_nothing,
                } => self.opened(&place, from_nothing, result),
                Pending::Command { reply } => {
                    let _ = reply.send(Ok(result.clone()));
                    Ok(())
                }
            };
        }
        let params = &message["params"];
        match message.get("method").and_then(Value::as_str) {
            Some("axo.client.hosts") => {
                let hosts = params["hosts"].as_array().cloned().unwrap_or_default();
                self.listed_hosts(hosts)
            }
            Some("axo.client.sessions") => {
                let sessions = params["sessions"].as_array().cloned().unwrap_or_default();
                self.listed_sessions(&sessions)
            }
            Some("axo.client.session.records") => self.records(params),
            Some("axo.client.session.reset") => self.reset(params),
            Some("axo.client.session.progress") => {
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

    fn listed_hosts(&mut self, hosts: Vec<Value>) -> io::Result<()> {
        let hosts: Vec<Value> = hosts
            .into_iter()
            .filter(|host| host["hostId"].as_str() != Some(self.own_host_id))
            .collect();
        for host in &hosts {
            if let (Some(host_id), Some(label)) = (host["hostId"].as_str(), host["label"].as_str())
                && let Err(error) = self.mirror.describe_host(host_id, label)
            {
                log::warn!("event=peers.host_description_failed host_id={host_id} error={error}");
            }
        }
        self.index.hosts = hosts;
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
            Pending::Command {
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

    fn call(&mut self, pending: Pending, method: &str, params: Value) -> io::Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        self.pending.insert(id, pending);
        self.send(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))
    }

    fn notify(&mut self, method: &str, params: Value) -> io::Result<()> {
        self.send(&json!({ "jsonrpc": "2.0", "method": method, "params": params }))
    }

    /// Sends, at most `FRAMES_PER_SECOND`: the cloud closes a client that sends faster.
    fn send(&mut self, value: &Value) -> io::Result<()> {
        let now = Instant::now();
        while self
            .sent
            .front()
            .is_some_and(|at| now.duration_since(*at) >= Duration::from_secs(1))
        {
            self.sent.pop_front();
        }
        if self.sent.len() >= FRAMES_PER_SECOND {
            let wait = Duration::from_secs(1).saturating_sub(now.duration_since(self.sent[0]));
            thread::sleep(wait.min(CONNECT_TIMEOUT));
            self.sent.pop_front();
        }
        self.sent.push_back(Instant::now());
        send_json(&mut self.socket, value)
    }
}
