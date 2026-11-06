//! The upload loop: the `axo.host.sync` handshake, cutting a diverged cloud copy back to the
//! common prefix, and appending what the cloud is missing, open Sessions first.

use std::collections::HashMap;
use std::io;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axo_agent::pi::{TranscriptFile, pi3};
use axo_protocol::{SessionId, SessionStatus};
use serde::Deserialize;
use serde_json::{Value, json};

use super::metadata::{SessionMetadata, StoredSyncState};
use super::unix_seconds;
use crate::host::RelayHost;
use crate::outbound::{Priority, RelayCallError, RelayChannel};

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

/// What the cloud holds of one Session, as the last handshake or acknowledgement said.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Cloud {
    epoch: u64,
    count: u64,
}

struct SessionSync {
    file: TranscriptFile,
    /// When `file` was last read for changes.
    checked_at: Option<Instant>,
    metadata: SessionMetadata,
    metadata_version: u64,
    /// The highest metadata version the cloud acknowledged.
    metadata_sent: u64,
    status: Option<SessionStatus>,
    status_sent: Option<SessionStatus>,
    /// Known after a handshake; `None` until then, or while it needs another.
    cloud: Option<Cloud>,
    /// axod would not delete the transcript; not asked again until the Session changes.
    eviction_refused: bool,
}

impl SessionSync {
    /// Reads the file for lines appended or rewritten since the last check.
    fn refresh(&mut self) -> io::Result<bool> {
        self.checked_at = Some(Instant::now());
        self.file.refresh()
    }
}

pub(super) struct Uploader {
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
    pub(super) fn new(host: Arc<dyn RelayHost>, channel: Arc<RelayChannel>) -> Self {
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
    pub(super) fn turn(&mut self) -> Duration {
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
            Ok(false) => {
                if let Err(error) = self.evict_next() {
                    log::warn!("event=sync.evict outcome=failed reason={error}");
                }
                POLL_OPEN
            }
            Err(error) => {
                log::warn!("event=sync.append outcome=failed reason={error}");
                self.handshake_due = true;
                POLL_OPEN
            }
        }
    }

    /// Reads the catalog and checks files: open Sessions every turn, archived ones rarely.
    pub(super) fn refresh(&mut self) -> io::Result<()> {
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
                            file: TranscriptFile::new(session.pi_session_file.clone()),
                            checked_at: None,
                            metadata: known.unwrap_or_else(|| metadata.clone()),
                            metadata_version: state.metadata_version,
                            metadata_sent: 0,
                            status: None,
                            status_sent: None,
                            cloud: None,
                            eviction_refused: false,
                        },
                    );
                }
                let entry = self
                    .sessions
                    .get_mut(&session.session_id)
                    .expect("inserted above");
                metadata.keep_workspace_state(&entry.metadata);
                // A transcript in the cloud is not read: a file there is one being restored.
                let path = (!session.transcript_in_cloud)
                    .then(|| session.pi_session_file.clone())
                    .flatten();
                if entry.file.path() != path.as_deref() {
                    entry.file = TranscriptFile::new(path);
                    entry.checked_at = None;
                }
                if entry.metadata != metadata || entry.metadata_version == 0 {
                    entry.metadata = metadata;
                    entry.metadata_version += 1;
                    entry.eviction_refused = false;
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
            if session.checked_at.is_none_or(|at| at.elapsed() >= every)
                && session.refresh()?
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
                let upload = session.file.transcript().map(|transcript| {
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
            let local = session.file.transcript();
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
                .transcript()
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
            .transcript()
            .cloned()
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
            .transcript()
            .expect("only Sessions with records upload");
        let from = cloud.count + 1;
        let mut to = from;
        let line_length = |position| {
            session
                .file
                .line_length(position)
                .expect("every hashed record has a line")
        };
        let mut bytes = line_length(from);
        while to < transcript.count() && (to - from + 1) < BATCH_RECORDS as u64 {
            let next = line_length(to + 1);
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
                        session.file.mark_invalid();
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

    /// Deletes one archived Session's transcript the cloud holds whole (RFD0027). Its file is
    /// read again first: a line written since then waits for its upload.
    fn evict_next(&mut self) -> io::Result<()> {
        let candidate = self.sessions.iter().find_map(|(id, session)| {
            let count = session.file.count();
            (session.metadata.archived
                && !session.eviction_refused
                && count > 0
                && session.cloud.is_some_and(|cloud| cloud.count == count))
            .then_some(*id)
        });
        let Some(session_id) = candidate else {
            return Ok(());
        };
        let session = self.sessions.get_mut(&session_id).expect("found above");
        if session.refresh()? {
            return Ok(());
        }
        let count = session.file.count();
        let (Some(length), Some(chain)) = (
            session.file.whole_length()?,
            session
                .file
                .transcript()
                .and_then(|transcript| transcript.chain_at(count))
                .map(str::to_owned),
        ) else {
            return Ok(());
        };
        if session.cloud.is_none_or(|cloud| cloud.count != count) {
            return Ok(());
        }
        let evicted = self
            .host
            .evict_transcript(session_id, count, &chain, length)?;
        log::info!(
            "event=sync.evict session_id={session_id} records={count} bytes={length} outcome={}",
            if evicted { "deleted" } else { "kept" }
        );
        if let Some(session) = self.sessions.get_mut(&session_id) {
            if evicted {
                session.file = TranscriptFile::new(None);
                session.checked_at = None;
            } else {
                session.eviction_refused = true;
            }
        }
        Ok(())
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
