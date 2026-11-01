//! Session sync (RFD0018, Upload; modelled in `specs/session-sync.ts`).
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
//! This runs on its own thread and reaches the cloud through `RelayChannel`.

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use axo_protocol::{SessionId, SessionStatus};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::host::RelayHost;
use crate::outbound::{Priority, RelayCallError, RelayChannel};
use crate::pi3::{self, Transcript};

/// Records and bytes of lines in one append batch.
const BATCH_RECORDS: usize = 64;
const BATCH_BYTES: usize = 1_048_576;
/// Every request has this long to be answered; a timeout starts the handshake again.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// How often open Sessions' files and the catalog are checked for changes.
const POLL_OPEN: Duration = Duration::from_millis(500);
/// How often archived Sessions' files are checked; they rarely change.
const POLL_ARCHIVED: Duration = Duration::from_secs(60);
/// The wait before a handshake that failed is tried again.
const RETRY_DELAY: Duration = Duration::from_secs(5);
/// Positions one `chainAt` asks for.
const CHAIN_AT_POSITIONS: u64 = 32;
/// Heads the manifest carries per Session; they are informational until ATXF merges.
const MAX_HEADS: usize = 1024;

/// What the cloud lists a Session by. The host owns it, and raises its version on every change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMetadata {
    pub name: Option<String>,
    pub emoji: Option<String>,
    pub workspace_id: Option<String>,
    pub workspace_name: Option<String>,
    pub has_agent: bool,
    pub created_at: Option<i64>,
    pub last_message_at: Option<i64>,
    pub archived: bool,
    /// Where the Session's work is, as git saw it after the agent last settled (RFD0022). Absent
    /// means not known yet; the last known state is then kept, never erased.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_state: Option<WorkspaceState>,
}

/// A Session's folder and its repository, so another Mac can tell what it would need to continue
/// the Session (RFD0022). Outside a repository only `path` is set.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceState {
    pub path: String,
    pub repo_root: Option<String>,
    /// The upstream remote's URL, with any credentials removed.
    pub remote: Option<String>,
    /// None when HEAD is detached.
    pub branch: Option<String>,
    pub head: Option<String>,
    /// Where the branch's upstream was, as last fetched on this Mac.
    pub upstream_head: Option<String>,
    /// Paths `git status` lists, at most `WorkspaceState::MAX_DIRTY`.
    pub dirty: Vec<String>,
    /// Paths beyond those in `dirty`.
    pub dirty_more: u32,
    /// Unix seconds.
    pub at: i64,
}

impl WorkspaceState {
    pub const MAX_DIRTY: usize = 50;
    const MAX_PATH: usize = 1024;

    fn bounded(mut self) -> Self {
        let path = |value: String| value.chars().take(Self::MAX_PATH).collect::<String>();
        let short = |value: Option<String>, max: usize| {
            value.filter(|value| !value.is_empty() && value.chars().count() <= max)
        };
        let hash = |value: Option<String>| {
            value.filter(|value| {
                (7..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_hexdigit())
            })
        };
        self.path = path(self.path);
        self.repo_root = self.repo_root.map(path);
        self.remote = short(self.remote, Self::MAX_PATH);
        self.branch = short(self.branch, 255);
        self.head = hash(self.head);
        self.upstream_head = hash(self.upstream_head);
        let total = self.dirty.len() as u32 + self.dirty_more;
        self.dirty.truncate(Self::MAX_DIRTY);
        self.dirty = self.dirty.into_iter().map(path).collect();
        self.dirty_more = total - self.dirty.len() as u32;
        self.at = self.at.max(0);
        self
    }
}

impl SessionMetadata {
    /// Fits the cloud's bounds: a field that does not is left out rather than refused.
    pub fn bounded(mut self) -> Self {
        self.name = self
            .name
            .map(|name| name.trim().chars().take(80).collect::<String>())
            .filter(|name| !name.is_empty());
        self.emoji = self.emoji.filter(|emoji| {
            !emoji.is_empty()
                && emoji.chars().count() <= 16
                && !emoji.chars().any(|c| c.is_whitespace() || c.is_control())
        });
        self.workspace_id = self.workspace_id.filter(|id| is_uuid(id));
        self.workspace_name = self
            .workspace_name
            .map(|name| name.chars().take(80).collect());
        self.created_at = self.created_at.filter(|at| *at >= 0);
        self.last_message_at = self.last_message_at.filter(|at| *at >= 0);
        self.workspace_state = self.workspace_state.map(WorkspaceState::bounded);
        self
    }

    /// A state not known now (axod restarted, or the Session is archived) is the one known before.
    fn keep_workspace_state(&mut self, before: &SessionMetadata) {
        if self.workspace_state.is_none() {
            self.workspace_state = before.workspace_state.clone();
        }
    }
}

/// One Session as the uploader sees it: open or archived, with its Pi transcript.
#[derive(Clone, Debug, PartialEq)]
pub struct SyncSession {
    pub session_id: SessionId,
    pub pi_session_file: Option<PathBuf>,
    pub metadata: SessionMetadata,
    /// Open Sessions only: what the Mac shows.
    pub status: Option<SessionStatus>,
}

/// What `axo.db` keeps per Session: the last position and chain the cloud acknowledged, and the
/// metadata last sent with its version.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StoredSyncState {
    pub session_id: String,
    pub position: u64,
    pub chain: Option<String>,
    pub metadata_json: Option<String>,
    pub metadata_version: u64,
}

/// Wakes the uploader early: a Session changed, or the socket reconnected.
#[derive(Clone, Default)]
pub struct SyncWaker(Arc<(Mutex<bool>, Condvar)>);

impl SyncWaker {
    pub fn wake(&self) {
        let (flag, condvar) = &*self.0;
        if let Ok(mut woken) = flag.lock() {
            *woken = true;
            condvar.notify_all();
        }
    }

    fn wait(&self, timeout: Duration) {
        let (flag, condvar) = &*self.0;
        if let Ok(woken) = flag.lock() {
            let (mut woken, _) = condvar
                .wait_timeout_while(woken, timeout, |woken| !*woken)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *woken = false;
        }
    }
}

/// The uploader thread.
pub struct SyncWorker {
    thread: Option<JoinHandle<()>>,
}

impl SyncWorker {
    pub fn start(
        host: Arc<dyn RelayHost>,
        channel: Arc<RelayChannel>,
        waker: SyncWaker,
        stop: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        let thread = thread::Builder::new()
            .name("axo-cloud-sync".to_owned())
            .spawn(move || {
                let mut uploader = Uploader::new(host, channel);
                while !stop.load(Ordering::Relaxed) {
                    let delay = uploader.turn();
                    if !delay.is_zero() {
                        waker.wait(delay);
                    }
                }
            })?;
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

/// A Session's Pi file, hashed as far as its last complete line.
struct LocalFile {
    path: Option<PathBuf>,
    transcript: Option<Transcript>,
    /// Where each record's line starts in the file and how long it is (index = position - 1).
    lines: Vec<(u64, usize)>,
    /// Bytes of the file hashed: whole lines only.
    hashed: u64,
    /// The last record's content digest, to notice a file rewritten in place.
    last_digest: Option<String>,
    /// The first line that is not a record; nothing from there is uploaded until the file changes.
    invalid: bool,
    checked_at: Option<Instant>,
}

impl LocalFile {
    fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            transcript: None,
            lines: Vec::new(),
            hashed: 0,
            last_digest: None,
            invalid: false,
            checked_at: None,
        }
    }

    fn count(&self) -> u64 {
        self.transcript.as_ref().map_or(0, Transcript::count)
    }

    /// Hashes lines appended since the last check. A file that shrank, or whose last hashed line
    /// changed, is hashed again from the start. Returns whether anything changed.
    fn refresh(&mut self) -> io::Result<bool> {
        self.checked_at = Some(Instant::now());
        let Some(path) = self.path.clone() else {
            return Ok(false);
        };
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error),
        };
        let length = file.metadata()?.len();
        if length < self.hashed || !self.last_line_unchanged(&mut file)? {
            *self = Self::new(Some(path.clone()));
            self.checked_at = Some(Instant::now());
        }
        if length == self.hashed {
            return Ok(false);
        }
        file.seek(SeekFrom::Start(self.hashed))?;
        let mut appended = Vec::new();
        file.take(length - self.hashed).read_to_end(&mut appended)?;
        let mut changed = false;
        let mut start = 0;
        while let Some(end) = appended[start..].iter().position(|&b| b == b'\n') {
            let line = &appended[start..start + end];
            let offset = self.hashed + start as u64;
            start += end + 1;
            changed = true;
            if self.invalid {
                continue;
            }
            let Some(text) = std::str::from_utf8(line)
                .ok()
                .filter(|_| line.len() <= pi3::MAX_LINE_BYTES)
            else {
                self.mark_invalid(&path);
                continue;
            };
            match &mut self.transcript {
                None => self.transcript = Some(Transcript::start(text)),
                Some(transcript) => {
                    if transcript.push(text).is_none() {
                        self.mark_invalid(&path);
                        continue;
                    }
                    self.lines.push((offset, line.len()));
                    self.last_digest = Some(pi3::digest("content", text));
                }
            }
        }
        // A last line without its newline is not complete yet; it waits.
        self.hashed += start as u64;
        Ok(changed)
    }

    fn mark_invalid(&mut self, path: &std::path::Path) {
        self.invalid = true;
        log::warn!(
            "event=sync.invalid_line position={} file={}",
            self.count() + 1,
            path.file_name().unwrap_or_default().to_string_lossy()
        );
    }

    fn last_line_unchanged(&self, file: &mut File) -> io::Result<bool> {
        let (Some(&(offset, length)), Some(digest)) = (self.lines.last(), &self.last_digest) else {
            return Ok(true);
        };
        file.seek(SeekFrom::Start(offset))?;
        let mut line = vec![0; length];
        if file.read_exact(&mut line).is_err() {
            return Ok(false);
        }
        Ok(std::str::from_utf8(&line).is_ok_and(|text| &pi3::digest("content", text) == digest))
    }

    /// The raw lines of positions `from..=to`, read from the file.
    fn read(&self, from: u64, to: u64) -> io::Result<Vec<String>> {
        let path = self.path.as_ref().ok_or(io::ErrorKind::NotFound)?;
        let mut file = File::open(path)?;
        (from..=to)
            .map(|position| {
                let (offset, length) = self.lines[(position - 1) as usize];
                file.seek(SeekFrom::Start(offset))?;
                let mut line = vec![0; length];
                file.read_exact(&mut line)?;
                String::from_utf8(line).map_err(|_| io::ErrorKind::InvalidData.into())
            })
            .collect()
    }
}

/// What the cloud holds of one Session, as the last handshake or acknowledgement said.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Cloud {
    epoch: u64,
    count: u64,
}

struct SessionSync {
    file: LocalFile,
    metadata: SessionMetadata,
    metadata_version: u64,
    /// The highest metadata version the cloud acknowledged.
    metadata_sent: u64,
    status: Option<SessionStatus>,
    status_sent: Option<SessionStatus>,
    /// Known after a handshake; `None` until then, or while it needs another.
    cloud: Option<Cloud>,
}

struct Uploader {
    host: Arc<dyn RelayHost>,
    channel: Arc<RelayChannel>,
    sessions: HashMap<SessionId, SessionSync>,
    /// The socket the last handshake ran on; another socket needs a new one.
    synced_on: Option<u64>,
    handshake_due: bool,
    retry_at: Option<Instant>,
    round: u64,
    catalog_at: Option<Instant>,
    /// What `axo.db` held at start: cursors and metadata versions.
    stored: Option<HashMap<String, StoredSyncState>>,
}

impl Uploader {
    fn new(host: Arc<dyn RelayHost>, channel: Arc<RelayChannel>) -> Self {
        Self {
            host,
            channel,
            sessions: HashMap::new(),
            synced_on: None,
            handshake_due: true,
            retry_at: None,
            round: 0,
            catalog_at: None,
            stored: None,
        }
    }

    /// One step of work; returns how long to wait before the next (zero: at once).
    fn turn(&mut self) -> Duration {
        let Some(socket) = self.channel.epoch() else {
            self.synced_on = None;
            return POLL_OPEN;
        };
        if self.synced_on != Some(socket) {
            self.handshake_due = true;
        }
        if let Err(error) = self.refresh() {
            log::warn!("event=sync.catalog_unavailable reason={error}");
            return RETRY_DELAY;
        }
        if self.handshake_due {
            if self.retry_at.is_some_and(|at| Instant::now() < at) {
                return POLL_OPEN;
            }
            match self.handshake() {
                Ok(()) => {
                    self.synced_on = Some(socket);
                    self.handshake_due = false;
                    self.retry_at = None;
                }
                Err(error) => {
                    log::warn!("event=sync.handshake outcome=failed reason={error}");
                    self.retry_at = Some(Instant::now() + RETRY_DELAY);
                    return POLL_OPEN;
                }
            }
        }
        self.send_metadata_and_status();
        match self.upload_next() {
            Ok(true) => Duration::ZERO,
            Ok(false) => POLL_OPEN,
            Err(error) => {
                log::warn!("event=sync.append outcome=failed reason={error}");
                self.handshake_due = true;
                POLL_OPEN
            }
        }
    }

    /// Reads the catalog and checks files: open Sessions every turn, archived ones rarely.
    fn refresh(&mut self) -> io::Result<()> {
        if self.catalog_at.is_none_or(|at| at.elapsed() >= POLL_OPEN) {
            self.catalog_at = Some(Instant::now());
            if self.stored.is_none() {
                self.stored = Some(
                    self.host
                        .sync_states()?
                        .into_iter()
                        .map(|state| (state.session_id.clone(), state))
                        .collect(),
                );
            }
            for session in self.host.sync_catalog()? {
                let mut metadata = session.metadata.clone().bounded();
                if !self.sessions.contains_key(&session.session_id) {
                    let state = self
                        .stored
                        .as_ref()
                        .and_then(|stored| stored.get(&session.session_id.to_string()))
                        .cloned()
                        .unwrap_or_default();
                    let known: Option<SessionMetadata> = state
                        .metadata_json
                        .as_deref()
                        .and_then(|json| serde_json::from_str(json).ok());
                    self.sessions.insert(
                        session.session_id,
                        SessionSync {
                            file: LocalFile::new(session.pi_session_file.clone()),
                            metadata: known.unwrap_or_else(|| metadata.clone()),
                            metadata_version: state.metadata_version,
                            metadata_sent: 0,
                            status: None,
                            status_sent: None,
                            cloud: None,
                        },
                    );
                }
                let entry = self
                    .sessions
                    .get_mut(&session.session_id)
                    .expect("inserted above");
                metadata.keep_workspace_state(&entry.metadata);
                if entry.file.path != session.pi_session_file {
                    entry.file = LocalFile::new(session.pi_session_file.clone());
                }
                if entry.metadata != metadata || entry.metadata_version == 0 {
                    entry.metadata = metadata;
                    entry.metadata_version += 1;
                    self.host.store_sync_metadata(
                        session.session_id,
                        &serde_json::to_string(&entry.metadata).map_err(io::Error::other)?,
                        entry.metadata_version,
                    )?;
                }
                entry.status = session.status;
            }
        }
        for session in self.sessions.values_mut() {
            let every = if session.metadata.archived {
                POLL_ARCHIVED
            } else {
                POLL_OPEN
            };
            if session
                .file
                .checked_at
                .is_none_or(|at| at.elapsed() >= every)
                && session.file.refresh()?
                && session
                    .cloud
                    .is_some_and(|cloud| cloud.count > session.file.count())
            {
                // The file shrank below what the cloud holds: only a handshake can tell.
                self.handshake_due = true;
            }
        }
        Ok(())
    }

    fn handshake(&mut self) -> io::Result<()> {
        self.round = self.host.next_sync_round()?;
        let round = self.round;
        let mut ids: Vec<SessionId> = self.sessions.keys().copied().collect();
        ids.sort();
        let manifest: Vec<Value> = ids
            .iter()
            .map(|id| {
                let session = &self.sessions[id];
                let upload = session.file.transcript.as_ref().map(|transcript| {
                    let mut heads = transcript.heads();
                    heads.truncate(MAX_HEADS);
                    json!({ "count": transcript.count(), "chain": transcript.chain(), "heads": heads })
                });
                json!({
                    "sessionId": id,
                    "metadataVersion": session.metadata_version,
                    "metadata": session.metadata,
                    "format": pi3::FORMAT,
                    "upload": upload,
                })
            })
            .collect();
        let reply: SyncReply = self.call(
            "axo.host.sync",
            json!({
                "hostId": self.host.host_id(),
                "hostGeneration": self.host.host_generation(),
                "round": round,
                "sessions": manifest,
            }),
            Priority::Control,
        )?;
        if reply.round != round || !reply.applied {
            return Err(io::Error::other("the cloud applied a newer handshake"));
        }
        for session in self.sessions.values_mut() {
            session.cloud = None;
            session.metadata_sent = session.metadata_version;
            session.status_sent = None;
        }
        let (mut unknown, mut behind, mut diverged) = (0, 0, 0);
        for state in reply.sessions {
            let Some(session) = self.sessions.get(&state.session_id) else {
                continue;
            };
            let local = session.file.transcript.as_ref();
            let (epoch, count) = (state.epoch.unwrap_or(1), state.count.unwrap_or(0));
            let prefix = local.is_none_or(|local| {
                count <= local.count() && local.chain_at(count) == state.chain.as_deref()
            });
            let cloud = if state.state == "unknown" {
                unknown += 1;
                Cloud { epoch: 1, count: 0 }
            } else if prefix {
                // In sync, or the cloud holds a prefix. A Mac with no transcript leaves the
                // cloud's copy as it is.
                if local.is_some_and(|local| count < local.count()) {
                    behind += 1;
                }
                Cloud { epoch, count }
            } else {
                diverged += 1;
                match self.realign(state.session_id, count)? {
                    Some(cloud) => cloud,
                    None => continue,
                }
            };
            let chain = self.sessions[&state.session_id]
                .file
                .transcript
                .as_ref()
                .and_then(|transcript| transcript.chain_at(cloud.count))
                .map(str::to_owned);
            if let Some(chain) = chain {
                self.host
                    .store_sync_cursor(state.session_id, cloud.count, &chain)?;
            }
            if let Some(session) = self.sessions.get_mut(&state.session_id) {
                session.cloud = Some(cloud);
            }
        }
        log::info!(
            "event=sync.handshake sessions={} unknown={unknown} behind={behind} diverged={diverged}",
            self.sessions.len()
        );
        Ok(())
    }

    /// Finds the longest prefix both copies share and cuts the cloud back to it (the host wins).
    fn realign(&mut self, session_id: SessionId, cloud_count: u64) -> io::Result<Option<Cloud>> {
        let local = self.sessions[&session_id]
            .file
            .transcript
            .clone()
            .expect("only a local transcript can diverge");
        // Copies that agree at a position agree at every position before it, so the search
        // narrows [low, high] to the last position where they agree, 32 positions a round.
        let mut best: Option<u64> = None;
        let mut cloud_chains: HashMap<u64, String> = HashMap::new();
        let (mut low, mut high) = (0, cloud_count.min(local.count()));
        loop {
            let step = (high - low).div_ceil(CHAIN_AT_POSITIONS - 1).max(1);
            let mut positions: Vec<u64> = (0..CHAIN_AT_POSITIONS - 1)
                .map(|index| low + index * step)
                .take_while(|position| *position < high)
                .collect();
            positions.push(high);
            let reply: ChainAtReply = self.call(
                "axo.host.session.chainAt",
                json!({ "sessionId": session_id, "round": self.round, "positions": positions }),
                Priority::Control,
            )?;
            if reply.round != self.round {
                return Err(io::Error::other("a newer handshake replaced this one"));
            }
            let mut differs_at = None;
            for (position, chain) in positions.iter().zip(reply.chains) {
                let agrees =
                    chain.as_deref().is_some() && local.chain_at(*position) == chain.as_deref();
                if let Some(chain) = chain {
                    cloud_chains.insert(*position, chain);
                }
                if !agrees {
                    differs_at = Some(*position);
                    break;
                }
                best = Some(*position);
            }
            let Some(differs_at) = differs_at else { break };
            let next_low = best.map_or(low, |best| best + 1);
            if differs_at == 0 || next_low >= differs_at {
                break;
            }
            (low, high) = (next_low, differs_at - 1);
        }
        // With no common prefix, even the headers differ: keep nothing, and the next append
        // carries this Mac's header.
        let keep = best.unwrap_or(0);
        let header_differs = best.is_none();
        let Some(expected) = cloud_chains.get(&keep).cloned() else {
            return Ok(None);
        };
        // Never claim records the cloud is about to delete.
        if let Some(chain) = local.chain_at(keep) {
            self.host.store_sync_cursor(session_id, keep, chain)?;
        }
        let reply: TruncateReply = self.call(
            "axo.host.session.truncate",
            json!({ "sessionId": session_id, "round": self.round, "keep": keep, "expectedChain": expected }),
            Priority::Control,
        )?;
        log::info!(
            "event=sync.diverged session_id={session_id} keep={keep} header_differs={header_differs} outcome={}",
            reply.outcome
        );
        if reply.round != self.round || reply.outcome != "truncated" {
            self.handshake_due = true;
            return Ok(None);
        }
        Ok(Some(Cloud {
            epoch: reply.epoch.unwrap_or(1),
            count: keep,
        }))
    }

    /// Uploads one batch of the Session that most needs it. Returns whether there was one.
    fn upload_next(&mut self) -> io::Result<bool> {
        let Some(session_id) = self.next_session() else {
            return Ok(false);
        };
        let session = &self.sessions[&session_id];
        let cloud = session.cloud.expect("only synced Sessions upload");
        let transcript = session
            .file
            .transcript
            .as_ref()
            .expect("only Sessions with records upload");
        let from = cloud.count + 1;
        let mut to = from;
        let mut bytes = session.file.lines[(from - 1) as usize].1;
        while to < transcript.count() && (to - from + 1) < BATCH_RECORDS as u64 {
            let next = session.file.lines[to as usize].1;
            if bytes + next > BATCH_BYTES {
                break;
            }
            bytes += next;
            to += 1;
        }
        let lines = session.file.read(from, to)?;
        let records: Vec<Value> = lines
            .iter()
            .zip(&transcript.records()[(from - 1) as usize..to as usize])
            .map(|(line, record)| json!({ "id": record.id, "line": line, "hash": record.hash }))
            .collect();
        let mut params = json!({ "sessionId": session_id, "epoch": cloud.epoch, "from": from, "records": records });
        if from == 1 {
            params["header"] = json!(transcript.header());
        }
        let result: AppendReply =
            match self.call("axo.host.session.append", params, Priority::Durable) {
                Ok(result) => result,
                Err(error) if error.kind() == io::ErrorKind::InvalidInput => {
                    // Too large for the relay: treated like a line the cloud cannot take.
                    log::warn!(
                        "event=sync.append session_id={session_id} from={from} outcome=too_large"
                    );
                    if let Some(session) = self.sessions.get_mut(&session_id) {
                        session.file.invalid = true;
                    }
                    return Ok(true);
                }
                Err(error) => return Err(error),
            };
        log::debug!(
            "event=sync.append session_id={session_id} from={from} records={} outcome={}",
            to - from + 1,
            result.outcome
        );
        let committed_chain = transcript.chain_at(result.count).map(str::to_owned);
        match result.outcome.as_str() {
            "committed" => {
                if let Some(chain) = committed_chain {
                    self.host
                        .store_sync_cursor(session_id, result.count, &chain)?;
                }
                if let Some(session) = self.sessions.get_mut(&session_id) {
                    session.cloud = Some(Cloud {
                        epoch: result.epoch.unwrap_or(cloud.epoch),
                        count: result.count,
                    });
                }
            }
            "invalid" => {
                // The cloud cannot take this line; the next handshake tries again.
                log::warn!("event=sync.invalid_line session_id={session_id} position={from}");
                if let Some(session) = self.sessions.get_mut(&session_id) {
                    session.cloud = None;
                }
            }
            _ => self.handshake_due = true,
        }
        Ok(true)
    }

    /// Open Sessions first, the most recently active first, then archived ones.
    fn next_session(&self) -> Option<SessionId> {
        self.sessions
            .iter()
            .filter(|(_, session)| {
                session
                    .cloud
                    .is_some_and(|cloud| cloud.count < session.file.count())
            })
            .max_by_key(|(id, session)| {
                (
                    !session.metadata.archived,
                    session.metadata.last_message_at.unwrap_or(0),
                    **id,
                )
            })
            .map(|(id, _)| *id)
    }

    /// Metadata changes since the cloud last heard, and status changes of open Sessions.
    fn send_metadata_and_status(&mut self) {
        for (id, session) in &mut self.sessions {
            if session.metadata_sent < session.metadata_version {
                let reply: io::Result<Value> = call(
                    &self.channel,
                    "axo.host.session.meta",
                    json!({ "sessionId": id, "metadataVersion": session.metadata_version, "metadata": session.metadata }),
                    Priority::Control,
                );
                match reply {
                    Ok(_) => {
                        session.metadata_sent = session.metadata_version;
                        // A Session the cloud just learned of starts empty.
                        session.cloud.get_or_insert(Cloud { epoch: 1, count: 0 });
                    }
                    Err(error) => {
                        log::warn!("event=sync.meta outcome=failed reason={error}");
                        self.handshake_due = true;
                        return;
                    }
                }
            }
            if let Some(status) = session.status
                && session.status_sent != Some(status)
                && self
                    .channel
                    .notify(
                        "axo.host.session.status",
                        json!({ "sessionId": id, "status": status, "at": unix_seconds() }),
                        Priority::Ephemeral,
                    )
                    .is_ok()
            {
                session.status_sent = Some(status);
            }
        }
    }

    fn call<T: for<'de> Deserialize<'de>>(
        &self,
        method: &str,
        params: Value,
        priority: Priority,
    ) -> io::Result<T> {
        let result = call(&self.channel, method, params, priority)?;
        serde_json::from_value(result)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }
}

fn call(
    channel: &RelayChannel,
    method: &str,
    params: Value,
    priority: Priority,
) -> io::Result<Value> {
    channel
        .request(method, params, priority, REQUEST_TIMEOUT)
        .map_err(|error| match error {
            RelayCallError::TooLarge => io::Error::new(io::ErrorKind::InvalidInput, error),
            error => io::Error::other(error),
        })
}

#[derive(Deserialize)]
struct SyncReply {
    round: u64,
    applied: bool,
    sessions: Vec<CloudState>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CloudState {
    session_id: SessionId,
    state: String,
    epoch: Option<u64>,
    count: Option<u64>,
    chain: Option<String>,
}

#[derive(Deserialize)]
struct ChainAtReply {
    round: u64,
    chains: Vec<Option<String>>,
}

#[derive(Deserialize)]
struct TruncateReply {
    round: u64,
    outcome: String,
    epoch: Option<u64>,
}

#[derive(Deserialize)]
struct AppendReply {
    outcome: String,
    epoch: Option<u64>,
    count: u64,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_file(contents: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("axo-sync-{}.jsonl", uuid_like()));
        std::fs::write(&path, contents).unwrap();
        path
    }

    fn uuid_like() -> String {
        format!(
            "{:x}{:x}",
            std::process::id(),
            Instant::now().elapsed().as_nanos() ^ rand_seed()
        )
    }

    fn rand_seed() -> u128 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    }

    const HEADER: &str = r#"{"type":"session","version":3,"id":"s"}"#;

    #[test]
    fn a_file_is_hashed_line_by_line_and_a_partial_last_line_waits() {
        let path = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\",\"parentId\":null}}\n{{\"id\":\"b\""
        ));
        let mut file = LocalFile::new(Some(path.clone()));
        assert!(file.refresh().unwrap());
        assert_eq!(file.count(), 1);
        let mut handle = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        handle.write_all(b",\"parentId\":\"a\"}\n").unwrap();
        assert!(file.refresh().unwrap());
        assert_eq!(file.count(), 2);
        assert_eq!(
            file.read(1, 2).unwrap(),
            vec![
                r#"{"id":"a","parentId":null}"#,
                r#"{"id":"b","parentId":"a"}"#
            ]
        );
        let mut expected = Transcript::start(HEADER);
        expected.push(r#"{"id":"a","parentId":null}"#);
        expected.push(r#"{"id":"b","parentId":"a"}"#);
        assert_eq!(file.transcript.as_ref().unwrap().chain(), expected.chain());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn a_rewritten_file_is_hashed_again_from_the_start() {
        let path = temp_file(&format!("{HEADER}\n{{\"id\":\"a\"}}\n{{\"id\":\"b\"}}\n"));
        let mut file = LocalFile::new(Some(path.clone()));
        file.refresh().unwrap();
        assert_eq!(file.count(), 2);
        std::fs::write(
            &path,
            format!("{HEADER}\n{{\"id\":\"a\"}}\n{{\"id\":\"c\"}}\n"),
        )
        .unwrap();
        file.refresh().unwrap();
        let mut expected = Transcript::start(HEADER);
        expected.push(r#"{"id":"a"}"#);
        expected.push(r#"{"id":"c"}"#);
        assert_eq!(file.transcript.as_ref().unwrap().chain(), expected.chain());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn a_line_that_is_not_a_record_stops_the_upload_there() {
        let path = temp_file(&format!(
            "{HEADER}\n{{\"id\":\"a\"}}\nnot json\n{{\"id\":\"b\"}}\n"
        ));
        let mut file = LocalFile::new(Some(path.clone()));
        file.refresh().unwrap();
        assert_eq!(file.count(), 1);
        assert!(file.invalid);
        std::fs::remove_file(path).unwrap();
    }

    fn state(head: &str) -> WorkspaceState {
        WorkspaceState {
            path: "/Users/leo/src/axo".into(),
            repo_root: Some("/Users/leo/src/axo".into()),
            remote: Some("https://github.com/leostera/axo.git".into()),
            branch: Some("main".into()),
            head: Some(head.into()),
            upstream_head: None,
            dirty: Vec::new(),
            dirty_more: 0,
            at: 1,
        }
    }

    fn listed(workspace_state: Option<WorkspaceState>) -> SessionMetadata {
        SessionMetadata {
            name: Some("Relay".into()),
            emoji: None,
            workspace_id: None,
            workspace_name: None,
            has_agent: true,
            created_at: None,
            last_message_at: None,
            archived: false,
            workspace_state,
        }
    }

    #[test]
    fn a_workspace_state_not_known_now_is_the_one_known_before() {
        let before = listed(Some(state("3f2c1aa")));
        let mut now = listed(None);
        now.keep_workspace_state(&before);
        assert_eq!(now, before, "unchanged, so the version is not raised");
        let mut read = listed(Some(state("9e01b2c")));
        read.keep_workspace_state(&before);
        assert_eq!(
            read.workspace_state,
            Some(state("9e01b2c")),
            "a new read replaces it"
        );
    }

    #[test]
    fn a_workspace_state_fits_the_clouds_bounds() {
        let mut wide = state("not-a-hash");
        wide.dirty = (0..60).map(|n| format!("file{n}.rs")).collect();
        wide.dirty_more = 5;
        wide.branch = Some("b".repeat(300));
        let bounded = listed(Some(wide)).bounded().workspace_state.unwrap();
        assert_eq!(bounded.head, None);
        assert_eq!(bounded.branch, None);
        assert_eq!((bounded.dirty.len(), bounded.dirty_more), (50, 15));
        // Absent stays absent on the wire, so a cloud without the field still takes the metadata.
        let json = serde_json::to_value(listed(None)).unwrap();
        assert!(json.get("workspaceState").is_none());
    }

    #[test]
    fn metadata_outside_the_clouds_bounds_is_left_out() {
        let metadata = SessionMetadata {
            name: Some("  ".into()),
            emoji: Some("a b".into()),
            workspace_id: Some("not-a-uuid".into()),
            workspace_name: Some("w".repeat(100)),
            has_agent: true,
            created_at: Some(-1),
            last_message_at: Some(5),
            archived: false,
            workspace_state: None,
        }
        .bounded();
        assert_eq!(metadata.name, None);
        assert_eq!(metadata.emoji, None);
        assert_eq!(metadata.workspace_id, None);
        assert_eq!(metadata.workspace_name.unwrap().chars().count(), 80);
        assert_eq!(metadata.created_at, None);
        assert_eq!(metadata.last_message_at, Some(5));
    }
}
