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

use crate::credential::HostCredentialStore;
use crate::endpoint::RelayEndpoint;
use crate::fragments::Reassembler;
use crate::link::HostLinkStore;
use crate::relay::{
    CONNECT_TIMEOUT, MAX_FRAME_BYTES, RelaySocket, connect_websocket, host_websocket_request,
    read_message, send_json, set_read_timeout,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tungstenite::Message;
use tungstenite::protocol::WebSocketConfig;

/// Frames sent per second, half what the cloud allows a client (`FRAMES_PER_SECOND`).
const FRAMES_PER_SECOND: usize = 30;
/// Opens waiting for their reply at once.
const OPENS_IN_FLIGHT: usize = 4;
/// The cloud signs the socket in for an hour; it is opened again before that.
const SOCKET_LIFETIME: Duration = Duration::from_secs(50 * 60);
const PING_INTERVAL: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_millis(50);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);

/// Where a copy has got to, within one epoch of the cloud's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CopyState {
    pub epoch: u64,
    pub cursor: u64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ClientRecord {
    pub cursor: u64,
    pub line: String,
}

/// Which copy: the Mac that owns the Session, its Workspace there, and the Session.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Place {
    pub host_id: String,
    pub workspace: String,
    pub session_id: String,
}

impl Place {
    /// The place of a listed Session, if every part is a safe folder name. A Session without a
    /// Workspace goes in `no-workspace`.
    pub fn of(host_id: &str, workspace_id: Option<&str>, session_id: &str) -> Option<Self> {
        let workspace = workspace_id.unwrap_or("no-workspace");
        [host_id, workspace, session_id]
            .iter()
            .all(|part| is_id(part))
            .then(|| Self {
                host_id: host_id.to_owned(),
                workspace: workspace.to_owned(),
                session_id: session_id.to_owned(),
            })
    }
}

/// Letters, digits and hyphens: an id, never `..` or a path.
fn is_id(part: &str) -> bool {
    !part.is_empty()
        && part.len() <= 64
        && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// The copies on disk, under `sessions/`.
pub struct Mirror {
    root: PathBuf,
    /// Copies checked against their state since this process started.
    checked: HashSet<Place>,
}

impl Mirror {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            checked: HashSet::new(),
        }
    }

    fn folder(&self, place: &Place) -> PathBuf {
        self.root.join(&place.host_id).join(&place.workspace)
    }

    pub fn file(&self, place: &Place) -> PathBuf {
        self.folder(place)
            .join(format!("{}.jsonl", place.session_id))
    }

    fn state_file(&self, place: &Place) -> PathBuf {
        self.folder(place)
            .join(format!("{}.state.json", place.session_id))
    }

    /// `host.json` says which Mac a folder is, as this Mac's own folder does.
    pub fn describe_host(&self, host_id: &str, label: &str) -> io::Result<()> {
        if !is_id(host_id) {
            return Ok(());
        }
        let folder = self.root.join(host_id);
        fs::create_dir_all(&folder)?;
        let description = json!({ "hostId": host_id, "label": label });
        write_atomically(
            &folder.join("host.json"),
            &serde_json::to_vec_pretty(&description).map_err(io::Error::other)?,
        )
    }

    /// Where the copy is, or None if there is no usable copy.
    pub fn state(&mut self, place: &Place) -> io::Result<Option<CopyState>> {
        let Ok(text) = fs::read_to_string(self.state_file(place)) else {
            return Ok(None);
        };
        let Ok(state) = serde_json::from_str::<CopyState>(&text) else {
            return Ok(None);
        };
        if !self.checked.contains(place) {
            // A crash between appending and saving the state leaves lines past the cursor.
            let file = self.file(place);
            match lines_in(&file) {
                Ok(lines) if lines > state.cursor + 1 => truncate_lines(&file, state.cursor + 1)?,
                Ok(lines) if lines == state.cursor + 1 => {}
                _ => return Ok(None),
            }
            self.checked.insert(place.clone());
        }
        Ok(Some(state))
    }

    /// The first records of a copy from nothing.
    pub fn start(
        &mut self,
        place: &Place,
        epoch: u64,
        header: &str,
        records: &[ClientRecord],
    ) -> io::Result<CopyState> {
        fs::create_dir_all(self.folder(place))?;
        let mut out = File::create(self.file(place))?;
        writeln!(out, "{}", one_line(header)?)?;
        out.sync_data()?;
        let state = CopyState { epoch, cursor: 0 };
        self.save(place, state)?;
        self.checked.insert(place.clone());
        self.append(place, epoch, records)
    }

    /// Appends the records that follow the copy. Records it holds already are skipped; a gap or
    /// another epoch is refused, and the Session is opened again from the copy.
    pub fn append(
        &mut self,
        place: &Place,
        epoch: u64,
        records: &[ClientRecord],
    ) -> io::Result<CopyState> {
        let Some(mut state) = self.state(place)? else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "no copy to append to",
            ));
        };
        if state.epoch != epoch {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "records of another epoch",
            ));
        }
        let fresh: Vec<&ClientRecord> = records
            .iter()
            .filter(|record| record.cursor > state.cursor)
            .collect();
        if fresh.is_empty() {
            return Ok(state);
        }
        let mut text = String::new();
        for (index, record) in fresh.iter().enumerate() {
            if record.cursor != state.cursor + 1 + index as u64 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "a gap in the records",
                ));
            }
            text.push_str(one_line(&record.line)?);
            text.push('\n');
        }
        let mut out = OpenOptions::new().append(true).open(self.file(place))?;
        out.write_all(text.as_bytes())?;
        out.sync_data()?;
        state.cursor += fresh.len() as u64;
        self.save(place, state)?;
        Ok(state)
    }

    /// The source Mac rewrote history: keep the header and the first `keep` records.
    pub fn reset(&mut self, place: &Place, epoch: u64, keep: u64) -> io::Result<CopyState> {
        let Some(state) = self.state(place)? else {
            return Err(io::Error::new(io::ErrorKind::NotFound, "no copy to reset"));
        };
        let keep = keep.min(state.cursor);
        truncate_lines(&self.file(place), keep + 1)?;
        let state = CopyState {
            epoch,
            cursor: keep,
        };
        self.save(place, state)?;
        Ok(state)
    }

    fn save(&self, place: &Place, state: CopyState) -> io::Result<()> {
        write_atomically(
            &self.state_file(place),
            &serde_json::to_vec(&state).map_err(io::Error::other)?,
        )
    }
}

/// The other Macs and their Sessions, as the cloud last listed them.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PeerIndex {
    pub hosts: Vec<Value>,
    pub sessions: Vec<Value>,
}

impl PeerIndex {
    /// Takes Sessions in, replacing those with the same host and id.
    fn merge(&mut self, sessions: &[Value]) {
        for session in sessions {
            let key = session_key(session);
            match self
                .sessions
                .iter_mut()
                .find(|known| session_key(known) == key)
            {
                Some(known) => *known = session.clone(),
                None => self.sessions.push(session.clone()),
            }
        }
    }

    /// What the account lists, for this Mac's catalog. It is this Mac's server state, so it is
    /// kept in `server/`, not with the copies.
    fn write(&self, path: &Path) -> io::Result<()> {
        if let Some(folder) = path.parent() {
            fs::create_dir_all(folder)?;
        }
        write_atomically(
            path,
            &serde_json::to_vec_pretty(self).map_err(io::Error::other)?,
        )
    }
}

fn session_key(session: &Value) -> (Option<&str>, Option<&str>) {
    (session["hostId"].as_str(), session["sessionId"].as_str())
}

/// A Pi line is one JSON value on one line; anything else would corrupt the copy.
fn one_line(line: &str) -> io::Result<&str> {
    if line.contains('\n') || line.contains('\r') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "a record spans lines",
        ));
    }
    Ok(line)
}

fn lines_in(path: &Path) -> io::Result<u64> {
    let mut count = 0;
    for line in BufReader::new(File::open(path)?).split(b'\n') {
        line?;
        count += 1;
    }
    Ok(count)
}

/// Keeps the first `lines` lines of the file.
fn truncate_lines(path: &Path, lines: u64) -> io::Result<()> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut length = 0_u64;
    let mut buffer = Vec::new();
    for _ in 0..lines {
        buffer.clear();
        let read = reader.read_until(b'\n', &mut buffer)?;
        if read == 0 {
            break;
        }
        length += read as u64;
    }
    OpenOptions::new().write(true).open(path)?.set_len(length)
}

fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary = path.with_extension("tmp");
    let mut file = File::create(&temporary)?;
    file.write_all(bytes)?;
    file.sync_data()?;
    fs::rename(temporary, path)
}

/// Records of a copy, read while the peers worker may be writing it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CopyRead {
    pub state: CopyState,
    /// Records after the cursor asked for, as `(cursor, line)`, oldest first.
    pub records: Vec<(u64, String)>,
}

/// Reads the records of a copy after `after`, at most the last `limit` of them; None if there
/// is no copy. Only records the state file counts are read, so lines being appended are not.
/// `after` beyond the copy (another epoch, or a cut) reads nothing; the caller compares epochs.
pub fn read_copy(
    sessions_directory: &Path,
    place: &Place,
    after: u64,
    limit: usize,
) -> io::Result<Option<CopyRead>> {
    let mirror = Mirror::new(sessions_directory.to_path_buf());
    let Ok(text) = fs::read_to_string(mirror.state_file(place)) else {
        return Ok(None);
    };
    let Ok(state) = serde_json::from_str::<CopyState>(&text) else {
        return Ok(None);
    };
    let file = match File::open(mirror.file(place)) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let first = after.max(state.cursor.saturating_sub(limit as u64)) + 1;
    let mut records = Vec::new();
    // Line 0 is Pi's header; line n is record n.
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let cursor = index as u64;
        if cursor > state.cursor {
            break;
        }
        let line = line?;
        if cursor >= first {
            records.push((cursor, line));
        }
    }
    Ok(Some(CopyRead { state, records }))
}

// ─── Live state, shared with axod ──────────────────────────────────────────

/// A command the cloud refused or could not settle, as JSON-RPC reports it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerCommandError {
    pub code: i64,
    pub message: String,
}

impl PeerCommandError {
    /// Nothing was sent: the next try may go ahead (RFD0018's `-32005`).
    pub fn offline() -> Self {
        Self {
            code: -32005,
            message: "Host offline; nothing queued".to_owned(),
        }
    }

    /// It may have reached the Mac: try again with the same commandId (RFD0024).
    pub fn unknown() -> Self {
        Self {
            code: -32004,
            message: "Outcome unknown; reconcile commandId".to_owned(),
        }
    }
}

struct PeerCommand {
    host_id: String,
    method: String,
    params: Value,
    reply: mpsc::Sender<Result<Value, PeerCommandError>>,
}

#[derive(Default)]
struct LiveState {
    /// Bumped by every change a remote pane may show: records, progress, listing, the socket.
    version: u64,
    /// The newest snapshot of each progress slot, by Session.
    progress: HashMap<String, BTreeMap<String, Value>>,
    /// Commands waiting for the socket to send them.
    outbox: VecDeque<PeerCommand>,
    connected: bool,
}

type Observer = Box<dyn Fn() + Send + Sync>;

/// What the peers socket knows that axod's remote panes follow, and the way their commands go
/// out. Shared between the peers worker, which fills it, and axod's handlers, which read it.
#[derive(Default)]
pub struct PeerLive {
    state: Mutex<LiveState>,
    changed: Condvar,
    listing_observer: Mutex<Option<Observer>>,
}

impl PeerLive {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Called whenever the listing of the other Macs or their Sessions changes.
    pub fn observe_listing(&self, observer: impl Fn() + Send + Sync + 'static) {
        if let Ok(mut slot) = self.listing_observer.lock() {
            *slot = Some(Box::new(observer));
        }
    }

    pub fn version(&self) -> u64 {
        self.state.lock().map_or(0, |state| state.version)
    }

    pub fn is_connected(&self) -> bool {
        self.state.lock().is_ok_and(|state| state.connected)
    }

    /// Waits until something changes after `since`, or `timeout` passes; returns the version.
    pub fn wait_for_change(&self, since: u64, timeout: Duration) -> u64 {
        let Ok(state) = self.state.lock() else {
            return since;
        };
        match self
            .changed
            .wait_timeout_while(state, timeout, |state| state.version <= since)
        {
            Ok((state, _)) => state.version,
            Err(_) => since,
        }
    }

    /// The newest snapshot of each progress slot of a Session, by slot.
    pub fn progress(&self, session_id: &str) -> Vec<(String, Value)> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.progress.get(session_id).cloned())
            .map(|slots| slots.into_iter().collect())
            .unwrap_or_default()
    }

    /// Sends `method` to the Mac `host_id` names, as a client would, and waits for its answer.
    /// With no socket nothing is sent (`offline`); a reply that does not come in time, or a socket
    /// that ends first, leaves the outcome unknown.
    pub fn command(
        &self,
        host_id: &str,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, PeerCommandError> {
        let (reply, answer) = mpsc::channel();
        {
            let mut state = self.state.lock().map_err(|_| PeerCommandError::offline())?;
            if !state.connected {
                return Err(PeerCommandError::offline());
            }
            state.outbox.push_back(PeerCommand {
                host_id: host_id.to_owned(),
                method: method.to_owned(),
                params,
                reply,
            });
        }
        match answer.recv_timeout(timeout) {
            Ok(outcome) => outcome,
            Err(_) => Err(PeerCommandError::unknown()),
        }
    }

    fn update(&self, change: impl FnOnce(&mut LiveState)) {
        if let Ok(mut state) = self.state.lock() {
            change(&mut state);
            state.version += 1;
        }
        self.changed.notify_all();
    }

    fn touch(&self) {
        self.update(|_| {});
    }

    fn listing_changed(&self) {
        self.touch();
        if let Ok(observer) = self.listing_observer.lock()
            && let Some(observer) = observer.as_ref()
        {
            observer();
        }
    }

    fn set_progress(&self, session_id: &str, slot: &str, snapshot: Value) {
        self.update(|state| {
            let slots = state.progress.entry(session_id.to_owned()).or_default();
            if snapshot.is_null() {
                slots.remove(slot);
            } else {
                slots.insert(slot.to_owned(), snapshot);
            }
        });
    }

    fn replace_progress(&self, session_id: &str, entries: &[Value]) {
        self.update(|state| {
            let slots = state.progress.entry(session_id.to_owned()).or_default();
            slots.clear();
            for entry in entries {
                if let Some(slot) = entry["slot"].as_str()
                    && !entry["snapshot"].is_null()
                {
                    slots.insert(slot.to_owned(), entry["snapshot"].clone());
                }
            }
        });
    }

    fn connected(&self) {
        self.update(|state| state.connected = true);
    }

    /// The socket ended: what it never sent was not sent, and what it sent is unknown. Progress
    /// is forgotten, since nothing keeps it current now.
    fn disconnected(&self, in_flight: Vec<mpsc::Sender<Result<Value, PeerCommandError>>>) {
        let mut unsent = Vec::new();
        self.update(|state| {
            state.connected = false;
            state.progress.clear();
            unsent.extend(state.outbox.drain(..));
        });
        for command in unsent {
            let _ = command.reply.send(Err(PeerCommandError::offline()));
        }
        for reply in in_flight {
            let _ = reply.send(Err(PeerCommandError::unknown()));
        }
    }

    fn take_commands(&self) -> Vec<PeerCommand> {
        self.state
            .lock()
            .map(|mut state| state.outbox.drain(..).collect())
            .unwrap_or_default()
    }
}

// ─── The socket ─────────────────────────────────────────────────────────────

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
    thread: Option<JoinHandle<()>>,
}

impl PeersWorker {
    pub fn start(dependencies: PeersDependencies, stop: Arc<AtomicBool>) -> io::Result<Self> {
        let thread = thread::Builder::new()
            .name("axo-peers".to_owned())
            .spawn(move || run(dependencies, stop))?;
        Ok(Self {
            thread: Some(thread),
        })
    }

    pub fn join(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run(dependencies: PeersDependencies, stop: Arc<AtomicBool>) {
    let mut mirror = Mirror::new(dependencies.sessions_directory.clone());
    let mut delay = Duration::from_secs(1);
    while !stop.load(Ordering::Relaxed) {
        let account = match dependencies.links.load_link() {
            Ok(link) => link.account().cloned(),
            Err(error) => {
                log::warn!("event=peers.link_unavailable reason={error}");
                None
            }
        };
        let Some(account) = account else {
            // Not paired: nothing to follow until it is.
            sleep_unless_stopped(&stop, Duration::from_secs(5));
            continue;
        };
        let started = Instant::now();
        let outcome = host_websocket_request(
            dependencies
                .endpoint
                .peers_url(account.account_id(), &dependencies.host_id),
            &account,
            dependencies.credentials.as_ref(),
        )
        .and_then(|request| {
            let config = WebSocketConfig::default()
                .max_message_size(Some(MAX_FRAME_BYTES))
                .max_frame_size(Some(MAX_FRAME_BYTES));
            connect_websocket(request, config)
        })
        .and_then(|socket| Follower::new(socket, &mut mirror, &dependencies, &stop)?.run());
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
        sleep_unless_stopped(&stop, delay);
    }
}

fn sleep_unless_stopped(stop: &AtomicBool, delay: Duration) {
    let until = Instant::now() + delay;
    while Instant::now() < until && !stop.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(100));
    }
}

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
struct Follower<'a> {
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
    index: PeerIndex,
    sent: VecDeque<Instant>,
}

impl<'a> Follower<'a> {
    fn new(
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
            index: PeerIndex::default(),
            sent: VecDeque::new(),
        })
    }

    fn run(mut self) -> io::Result<()> {
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
            self.listed.insert(session_id.to_owned(), (place, epoch));
            if !self.open.contains_key(session_id)
                && !self.to_open.iter().any(|queued| queued == session_id)
            {
                self.to_open.push_back(session_id.to_owned());
            }
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
                return Ok(());
            };
            self.mirror.start(place, epoch, header, &records)
        } else {
            self.mirror.append(place, epoch, &records)
        };
        self.copied(place, copied).map(|_| ())?;
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
        let copied = self.mirror.append(&place, epoch, &records);
        if let Some(state) = self.copied(&place, copied)? {
            // Only what is on disk is acknowledged; the next batch follows the acknowledgement.
            self.notify(
                "axo.client.session.ack",
                json!({ "sessionId": session_id, "cursor": state.cursor }),
            )?;
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
        let reset = self.mirror.reset(&place, epoch, keep);
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

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let n = NEXT.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!("axo-peers-{}-{n}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const HOST: &str = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7";
    const WORKSPACE: &str = "04d389d1-9896-420e-9b42-fc7835522937";
    const SESSION: &str = "8f8f8f8f-0000-4000-8000-000000000001";
    const HEADER: &str = r#"{"type":"session","version":3,"id":"8f8f8f8f-0000-4000-8000-000000000001","cwd":"/Users/leo/src/axo"}"#;

    fn place() -> Place {
        Place::of(HOST, Some(WORKSPACE), SESSION).unwrap()
    }

    fn record(cursor: u64) -> ClientRecord {
        ClientRecord {
            cursor,
            line: format!(r#"{{"type":"message","id":"m{cursor}"}}"#),
        }
    }

    fn records(range: std::ops::RangeInclusive<u64>) -> Vec<ClientRecord> {
        range.map(record).collect()
    }

    fn copy(mirror: &Mirror) -> String {
        fs::read_to_string(mirror.file(&place())).unwrap()
    }

    fn expected(cursors: std::ops::RangeInclusive<u64>) -> String {
        let mut text = format!("{HEADER}\n");
        for cursor in cursors {
            text.push_str(&record(cursor).line);
            text.push('\n');
        }
        text
    }

    #[test]
    fn a_copy_is_at_the_same_place_under_sessions_as_on_its_mac() {
        let scratch = Scratch::new();
        let mirror = Mirror::new(scratch.0.clone());
        assert_eq!(
            mirror.file(&place()),
            scratch
                .0
                .join(HOST)
                .join(WORKSPACE)
                .join(format!("{SESSION}.jsonl"))
        );
        assert_eq!(
            Place::of(HOST, None, SESSION).unwrap().workspace,
            "no-workspace"
        );
    }

    #[test]
    fn a_place_the_cloud_names_must_be_ids() {
        assert!(Place::of("..", Some(WORKSPACE), SESSION).is_none());
        assert!(Place::of(HOST, Some("../../server"), SESSION).is_none());
        assert!(Place::of(HOST, Some(WORKSPACE), "a/b").is_none());
        assert!(Place::of(HOST, Some(""), SESSION).is_none());
    }

    #[test]
    fn a_copy_is_the_header_and_the_records_in_order() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        assert_eq!(mirror.state(&place()).unwrap(), None);
        mirror.start(&place(), 1, HEADER, &records(1..=3)).unwrap();
        // A batch that repeats what the copy holds adds only what follows.
        let state = mirror.append(&place(), 1, &records(2..=5)).unwrap();
        assert_eq!(
            state,
            CopyState {
                epoch: 1,
                cursor: 5
            }
        );
        assert_eq!(copy(&mirror), expected(1..=5));
    }

    #[test]
    fn a_gap_or_another_epoch_is_refused_and_changes_nothing() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 1, HEADER, &records(1..=2)).unwrap();
        assert_eq!(
            mirror
                .append(&place(), 1, &records(4..=5))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            mirror
                .append(&place(), 2, &records(3..=3))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(copy(&mirror), expected(1..=2));
    }

    #[test]
    fn a_reset_cuts_the_copy_back_and_it_goes_on_in_the_new_epoch() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 1, HEADER, &records(1..=5)).unwrap();
        assert_eq!(
            mirror.reset(&place(), 2, 3).unwrap(),
            CopyState {
                epoch: 2,
                cursor: 3
            }
        );
        mirror.append(&place(), 2, &records(4..=4)).unwrap();
        assert_eq!(copy(&mirror), expected(1..=4));
    }

    #[test]
    fn lines_written_but_not_saved_before_a_crash_are_dropped() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 1, HEADER, &records(1..=2)).unwrap();
        let mut out = OpenOptions::new()
            .append(true)
            .open(mirror.file(&place()))
            .unwrap();
        writeln!(out, "{}", record(3).line).unwrap();
        // A new process checks the copy against its state once.
        let mut restarted = Mirror::new(scratch.0.clone());
        assert_eq!(
            restarted.state(&place()).unwrap(),
            Some(CopyState {
                epoch: 1,
                cursor: 2
            })
        );
        assert_eq!(copy(&restarted), expected(1..=2));
        // A copy shorter than its state is no copy: it is made again from nothing.
        fs::write(restarted.file(&place()), format!("{HEADER}\n")).unwrap();
        assert_eq!(
            Mirror::new(scratch.0.clone()).state(&place()).unwrap(),
            None
        );
    }

    #[test]
    fn a_pane_reads_only_the_records_the_state_counts_after_its_cursor() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror.start(&place(), 3, HEADER, &records(1..=4)).unwrap();
        // A line appended but not yet counted is not read.
        let mut out = OpenOptions::new()
            .append(true)
            .open(mirror.file(&place()))
            .unwrap();
        writeln!(out, "{}", record(5).line).unwrap();
        let read = read_copy(&scratch.0, &place(), 2, usize::MAX)
            .unwrap()
            .unwrap();
        assert_eq!(
            read.state,
            CopyState {
                epoch: 3,
                cursor: 4
            }
        );
        assert_eq!(
            read.records
                .iter()
                .map(|(cursor, _)| *cursor)
                .collect::<Vec<_>>(),
            vec![3, 4]
        );
        assert_eq!(read.records[0].1, record(3).line);
        let window = read_copy(&scratch.0, &place(), 0, 2).unwrap().unwrap();
        assert_eq!(
            window
                .records
                .iter()
                .map(|(cursor, _)| *cursor)
                .collect::<Vec<_>>(),
            vec![3, 4],
            "starting over reads the newest `limit`"
        );
        let elsewhere = Place::of(HOST, None, SESSION).unwrap();
        assert!(read_copy(&scratch.0, &elsewhere, 0, 10).unwrap().is_none());
    }

    #[test]
    fn a_command_with_no_socket_is_not_sent_and_one_cut_off_is_unknown() {
        let live = PeerLive::new();
        let offline = live.command(
            HOST,
            "axo.remote.session.prompt",
            json!({}),
            Duration::from_secs(1),
        );
        assert_eq!(offline, Err(PeerCommandError::offline()));

        live.connected();
        let follower = Arc::clone(&live);
        let sent = thread::spawn(move || {
            follower.command(
                HOST,
                "axo.remote.session.prompt",
                json!({ "text": "yes" }),
                Duration::from_secs(5),
            )
        });
        let command = loop {
            if let Some(command) = live.take_commands().pop() {
                break command;
            }
            thread::sleep(Duration::from_millis(5));
        };
        assert_eq!(command.params["text"], "yes");
        // The socket ends after sending it: it may have reached the Mac.
        live.disconnected(vec![command.reply]);
        assert_eq!(sent.join().unwrap(), Err(PeerCommandError::unknown()));
        assert!(!live.is_connected());
    }

    #[test]
    fn progress_is_kept_per_slot_and_a_change_wakes_a_waiting_pane() {
        let live = PeerLive::new();
        let before = live.version();
        let waiter = Arc::clone(&live);
        let woke = thread::spawn(move || waiter.wait_for_change(before, Duration::from_secs(5)));
        live.set_progress(SESSION, "message", json!({ "text": "Wor" }));
        assert!(woke.join().unwrap() > before);
        live.set_progress(SESSION, "call-1", json!({ "toolCallId": "call-1" }));
        live.set_progress(SESSION, "message", Value::Null);
        assert_eq!(
            live.progress(SESSION),
            vec![("call-1".to_owned(), json!({ "toolCallId": "call-1" }))]
        );
        live.replace_progress(
            SESSION,
            &[json!({ "slot": "question", "snapshot": { "kind": "confirm" } })],
        );
        assert_eq!(live.progress(SESSION).len(), 1);
        assert_eq!(live.progress(SESSION)[0].0, "question");
    }

    #[test]
    fn the_index_keeps_the_latest_listing_of_each_session() {
        let mut index = PeerIndex::default();
        index.merge(&[json!({ "hostId": HOST, "sessionId": SESSION, "head": 1 })]);
        index.merge(&[
            json!({ "hostId": HOST, "sessionId": SESSION, "head": 4 }),
            json!({ "hostId": HOST, "sessionId": "other", "head": 1 }),
        ]);
        assert_eq!(index.sessions.len(), 2);
        assert_eq!(index.sessions[0]["head"], 4);
    }
}
