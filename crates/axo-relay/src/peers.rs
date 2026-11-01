//! This Mac's copy of the account's other Macs' Sessions (RFD0022).
//!
//! Pairing is the sign-in: axod opens the account's client socket at `/peers` with its host
//! credential, and the cloud serves it as an ordinary client that leaves out this Mac's own
//! Sessions. Every other Mac's Session is opened from where its copy ends, and every record batch
//! is appended to `<root>/<hostId>/<sessionId>.jsonl`, the same lines Pi wrote, before it is
//! acknowledged. So the history is already here when a Session is continued on this Mac.
//!
//! Invariants:
//! - A copy is Pi's header line and then records 1..=cursor of one epoch, in order, and nothing
//!   else. A reset cuts it back to the header and `keep` records.
//! - A batch is acknowledged only once it is written, so a crash loses nothing the cloud forgets.
//! - Copies are never uploaded: they live outside `pi-sessions/`, and the uploader lists only the
//!   Sessions this Mac owns.

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
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
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

/// The copies on disk.
pub struct Mirror {
    root: PathBuf,
    /// Copies checked against their state since this process started.
    checked: HashSet<(String, String)>,
}

impl Mirror {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            checked: HashSet::new(),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn file(&self, host_id: &str, session_id: &str) -> PathBuf {
        self.root.join(host_id).join(format!("{session_id}.jsonl"))
    }

    fn state_file(&self, host_id: &str, session_id: &str) -> PathBuf {
        self.root
            .join(host_id)
            .join(format!("{session_id}.state.json"))
    }

    /// Where the copy is, or None if there is no usable copy.
    pub fn state(&mut self, host_id: &str, session_id: &str) -> io::Result<Option<CopyState>> {
        let Ok(text) = fs::read_to_string(self.state_file(host_id, session_id)) else {
            return Ok(None);
        };
        let Ok(state) = serde_json::from_str::<CopyState>(&text) else {
            return Ok(None);
        };
        let key = (host_id.to_owned(), session_id.to_owned());
        if !self.checked.contains(&key) {
            // A crash between appending and saving the state leaves lines past the cursor.
            let file = self.file(host_id, session_id);
            match lines_in(&file) {
                Ok(lines) if lines > state.cursor => truncate_lines(&file, state.cursor + 1)?,
                Ok(lines) if lines == state.cursor + 1 => {}
                _ => return Ok(None),
            }
            self.checked.insert(key);
        }
        Ok(Some(state))
    }

    /// The first records of a copy from nothing.
    pub fn start(
        &mut self,
        host_id: &str,
        session_id: &str,
        epoch: u64,
        header: &str,
        records: &[ClientRecord],
    ) -> io::Result<CopyState> {
        let file = self.file(host_id, session_id);
        fs::create_dir_all(file.parent().expect("a copy is in a host's folder"))?;
        let mut out = File::create(&file)?;
        writeln!(out, "{}", one_line(header)?)?;
        out.sync_data()?;
        let state = CopyState { epoch, cursor: 0 };
        self.save(host_id, session_id, state)?;
        self.checked
            .insert((host_id.to_owned(), session_id.to_owned()));
        self.append(host_id, session_id, epoch, records)
    }

    /// Appends the records that follow the copy. Records it holds already are skipped; a gap or
    /// another epoch is refused, and the Session is opened again from the copy.
    pub fn append(
        &mut self,
        host_id: &str,
        session_id: &str,
        epoch: u64,
        records: &[ClientRecord],
    ) -> io::Result<CopyState> {
        let Some(mut state) = self.state(host_id, session_id)? else {
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
        let mut out = OpenOptions::new()
            .append(true)
            .open(self.file(host_id, session_id))?;
        out.write_all(text.as_bytes())?;
        out.sync_data()?;
        state.cursor += fresh.len() as u64;
        self.save(host_id, session_id, state)?;
        Ok(state)
    }

    /// The source Mac rewrote history: keep the header and the first `keep` records.
    pub fn reset(
        &mut self,
        host_id: &str,
        session_id: &str,
        epoch: u64,
        keep: u64,
    ) -> io::Result<CopyState> {
        let Some(state) = self.state(host_id, session_id)? else {
            return Err(io::Error::new(io::ErrorKind::NotFound, "no copy to reset"));
        };
        let keep = keep.min(state.cursor);
        truncate_lines(&self.file(host_id, session_id), keep + 1)?;
        let state = CopyState {
            epoch,
            cursor: keep,
        };
        self.save(host_id, session_id, state)?;
        Ok(state)
    }

    fn save(&self, host_id: &str, session_id: &str, state: CopyState) -> io::Result<()> {
        write_atomically(
            &self.state_file(host_id, session_id),
            &serde_json::to_vec(&state).map_err(io::Error::other)?,
        )
    }

    /// What the account lists, for this Mac's catalog: the other Macs and their Sessions.
    pub fn write_index(&self, index: &PeerIndex) -> io::Result<()> {
        fs::create_dir_all(&self.root)?;
        write_atomically(
            &self.root.join("index.json"),
            &serde_json::to_vec_pretty(index).map_err(io::Error::other)?,
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

// ─── The socket ─────────────────────────────────────────────────────────────

/// What following the account needs from axod.
pub struct PeersDependencies {
    pub host_id: String,
    pub endpoint: RelayEndpoint,
    pub links: Arc<dyn HostLinkStore>,
    pub credentials: Arc<dyn HostCredentialStore>,
    /// Where the copies go: outside `pi-sessions/`, so they are never uploaded.
    pub directory: PathBuf,
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
    let mut mirror = Mirror::new(dependencies.directory.clone());
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
        .and_then(|socket| Follower::new(socket, &mut mirror, &dependencies.host_id, &stop)?.run());
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
        host_id: String,
        session_id: String,
        from_nothing: bool,
    },
}

/// One socket's life: hello, then open every Session, then keep the copies current.
struct Follower<'a> {
    socket: RelaySocket,
    reassembler: Reassembler,
    mirror: &'a mut Mirror,
    client_id: String,
    stop: &'a AtomicBool,
    next_id: u64,
    pending: HashMap<u64, Pending>,
    /// Sessions waiting to be opened, and those open on this socket, by Session id.
    to_open: VecDeque<(String, String)>,
    open: HashMap<String, String>,
    listed: HashMap<(String, String), Option<u64>>,
    index: PeerIndex,
    sent: VecDeque<Instant>,
}

impl<'a> Follower<'a> {
    fn new(
        mut socket: RelaySocket,
        mirror: &'a mut Mirror,
        host_id: &str,
        stop: &'a AtomicBool,
    ) -> io::Result<Self> {
        set_read_timeout(&mut socket, READ_TIMEOUT)?;
        Ok(Self {
            socket,
            reassembler: Reassembler::default(),
            mirror,
            client_id: format!("host-{host_id}"),
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
        let opened = Instant::now();
        let mut pinged = Instant::now();
        self.call(
            Pending::Hello,
            "axo.client.hello",
            json!({ "protocolVersion": axo_protocol::rpc::PROTOCOL_VERSION, "clientId": self.client_id }),
        )?;
        while !self.stop.load(Ordering::Relaxed) && opened.elapsed() < SOCKET_LIFETIME {
            self.open_more()?;
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
                    Pending::Open { session_id, .. } => {
                        log::warn!("event=peers.open_failed session_id={session_id} error={error}");
                        Ok(())
                    }
                };
            }
            let result = &message["result"];
            return match pending {
                Pending::Hello => {
                    self.index.hosts = result["hosts"].as_array().cloned().unwrap_or_default();
                    let sessions = result["sessions"].as_array().cloned().unwrap_or_default();
                    self.listed_sessions(&sessions)
                }
                Pending::Open {
                    host_id,
                    session_id,
                    from_nothing,
                } => self.opened(&host_id, &session_id, from_nothing, result),
            };
        }
        let params = &message["params"];
        match message.get("method").and_then(Value::as_str) {
            Some("axo.client.hosts") => {
                self.index.hosts = params["hosts"].as_array().cloned().unwrap_or_default();
                self.mirror.write_index(&self.index)
            }
            Some("axo.client.sessions") => {
                let sessions = params["sessions"].as_array().cloned().unwrap_or_default();
                self.listed_sessions(&sessions)
            }
            Some("axo.client.session.records") => self.records(params),
            Some("axo.client.session.reset") => self.reset(params),
            _ => Ok(()),
        }
    }

    /// Lists Sessions, and opens those with records this Mac has not opened yet.
    fn listed_sessions(&mut self, sessions: &[Value]) -> io::Result<()> {
        self.index.merge(sessions);
        self.mirror.write_index(&self.index)?;
        for session in sessions {
            let (Some(host_id), Some(session_id)) =
                (session["hostId"].as_str(), session["sessionId"].as_str())
            else {
                continue;
            };
            let epoch = session["epoch"].as_u64();
            self.listed
                .insert((host_id.to_owned(), session_id.to_owned()), epoch);
            let queued = self.to_open.iter().any(|(_, queued)| queued == session_id);
            if epoch.is_some() && !self.open.contains_key(session_id) && !queued {
                self.to_open
                    .push_back((host_id.to_owned(), session_id.to_owned()));
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
            let Some((host_id, session_id)) = self.to_open.pop_front() else {
                break;
            };
            let Some(listed_epoch) = self
                .listed
                .get(&(host_id.clone(), session_id.clone()))
                .copied()
                .flatten()
            else {
                continue;
            };
            let state = self.mirror.state(&host_id, &session_id)?;
            let have = state.unwrap_or(CopyState {
                epoch: listed_epoch,
                cursor: 0,
            });
            self.open.insert(session_id.clone(), host_id.clone());
            self.call(
                Pending::Open { host_id: host_id.clone(), session_id: session_id.clone(), from_nothing: state.is_none() },
                "axo.client.session.open",
                json!({ "hostId": host_id, "sessionId": session_id, "have": { "epoch": have.epoch, "cursor": have.cursor } }),
            )?;
        }
        Ok(())
    }

    fn opened(
        &mut self,
        host_id: &str,
        session_id: &str,
        from_nothing: bool,
        result: &Value,
    ) -> io::Result<()> {
        let Some(epoch) = result["epoch"].as_u64() else {
            return Ok(());
        };
        let records: Vec<ClientRecord> =
            serde_json::from_value(result["records"].clone()).unwrap_or_default();
        let copied = if from_nothing {
            let Some(header) = result["header"].as_str() else {
                log::warn!("event=peers.open_without_header session_id={session_id}");
                return Ok(());
            };
            self.mirror
                .start(host_id, session_id, epoch, header, &records)
        } else {
            self.mirror.append(host_id, session_id, epoch, &records)
        };
        self.copied(host_id, session_id, copied).map(|_| ())
    }

    fn records(&mut self, params: &Value) -> io::Result<()> {
        let (Some(session_id), Some(epoch)) =
            (params["sessionId"].as_str(), params["epoch"].as_u64())
        else {
            return Ok(());
        };
        let Some(host_id) = self.open.get(session_id).cloned() else {
            return Ok(());
        };
        let records: Vec<ClientRecord> =
            serde_json::from_value(params["records"].clone()).unwrap_or_default();
        let copied = self.mirror.append(&host_id, session_id, epoch, &records);
        if let Some(state) = self.copied(&host_id, session_id, copied)? {
            // Only what is on disk is acknowledged; the next batch follows the acknowledgement.
            self.notify(
                "axo.client.session.ack",
                json!({ "sessionId": session_id, "cursor": state.cursor }),
            )?;
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
        let Some(host_id) = self.open.get(session_id).cloned() else {
            return Ok(());
        };
        let reset = self.mirror.reset(&host_id, session_id, epoch, keep);
        self.copied(&host_id, session_id, reset).map(|_| ())
    }

    /// A copy that could not take the records is opened again from where it is.
    fn copied(
        &mut self,
        host_id: &str,
        session_id: &str,
        outcome: io::Result<CopyState>,
    ) -> io::Result<Option<CopyState>> {
        match outcome {
            Ok(state) => Ok(Some(state)),
            Err(error)
                if error.kind() == io::ErrorKind::InvalidData
                    || error.kind() == io::ErrorKind::NotFound =>
            {
                log::warn!("event=peers.copy_reopened session_id={session_id} reason={error}");
                self.notify(
                    "axo.client.session.close",
                    json!({ "sessionId": session_id }),
                )?;
                self.open.remove(session_id);
                self.to_open
                    .push_back((host_id.to_owned(), session_id.to_owned()));
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
    const SESSION: &str = "8f8f8f8f-0000-4000-8000-000000000001";
    const HEADER: &str = r#"{"type":"session","version":3,"id":"8f8f8f8f-0000-4000-8000-000000000001","cwd":"/Users/leo/src/axo"}"#;

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
        fs::read_to_string(mirror.file(HOST, SESSION)).unwrap()
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
    fn a_copy_is_the_header_and_the_records_in_order() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        assert_eq!(mirror.state(HOST, SESSION).unwrap(), None);
        mirror
            .start(HOST, SESSION, 1, HEADER, &records(1..=3))
            .unwrap();
        // A batch that repeats what the copy holds adds only what follows.
        let state = mirror.append(HOST, SESSION, 1, &records(2..=5)).unwrap();
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
        mirror
            .start(HOST, SESSION, 1, HEADER, &records(1..=2))
            .unwrap();
        assert_eq!(
            mirror
                .append(HOST, SESSION, 1, &records(4..=5))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            mirror
                .append(HOST, SESSION, 2, &records(3..=3))
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
        mirror
            .start(HOST, SESSION, 1, HEADER, &records(1..=5))
            .unwrap();
        assert_eq!(
            mirror.reset(HOST, SESSION, 2, 3).unwrap(),
            CopyState {
                epoch: 2,
                cursor: 3
            }
        );
        mirror.append(HOST, SESSION, 2, &records(4..=4)).unwrap();
        assert_eq!(copy(&mirror), expected(1..=4));
    }

    #[test]
    fn lines_written_but_not_saved_before_a_crash_are_dropped() {
        let scratch = Scratch::new();
        let mut mirror = Mirror::new(scratch.0.clone());
        mirror
            .start(HOST, SESSION, 1, HEADER, &records(1..=2))
            .unwrap();
        let mut out = OpenOptions::new()
            .append(true)
            .open(mirror.file(HOST, SESSION))
            .unwrap();
        writeln!(out, "{}", record(3).line).unwrap();
        // A new process checks the copy against its state once.
        let mut restarted = Mirror::new(scratch.0.clone());
        assert_eq!(
            restarted.state(HOST, SESSION).unwrap(),
            Some(CopyState {
                epoch: 1,
                cursor: 2
            })
        );
        assert_eq!(copy(&restarted), expected(1..=2));
        // A copy shorter than its state is no copy: it is made again from nothing.
        fs::write(restarted.file(HOST, SESSION), format!("{HEADER}\n")).unwrap();
        assert_eq!(
            Mirror::new(scratch.0.clone()).state(HOST, SESSION).unwrap(),
            None
        );
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
