//! The upload loop: the `axo.host.sync` handshake, cutting a diverged cloud copy back to the
//! common prefix, and appending what the cloud is missing, open Sessions first.

use std::collections::HashMap;
use std::io;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axo_agent::pi::{TranscriptFile, pi3};
use axo_protocol::{SessionId, SessionStatus};
use serde::Deserialize;
use serde_json::{Value, json};

use super::metadata::{SessionMetadata, StoredMetadata};
use super::unix_seconds;
use super::watch::TranscriptWatch;
use super::{Eviction, SyncCursor, SyncStore};
use crate::host::HostIdentity;
use crate::outbound::{Priority, RelayCallError, RelayChannel, SocketEpoch};

/// Records and bytes of lines in one append batch.
const BATCH_RECORDS: usize = 64;
const BATCH_BYTES: usize = 1_048_576;
/// Every request has this long to be answered; a timeout starts the handshake again.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// The wait before a handshake that failed is tried again.
const RETRY_DELAY: Duration = Duration::from_secs(5);
/// The wait before a handshake after an append failed, so a cloud that keeps refusing is not
/// asked in a loop.
const APPEND_RETRY_DELAY: Duration = Duration::from_millis(500);

/// What the uploader does after a turn.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Next {
    /// There is more to send: turn again at once.
    Now,
    /// Retry at this instant, unless something wakes it first.
    At(Instant),
    /// Nothing to do until something changes.
    Idle,
}
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
    /// Whether `file` was read since its path last changed. An open Session's is read every turn;
    /// an archived one's changes only by being restored, which changes its path.
    read: bool,
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
    async fn refresh(&mut self) -> io::Result<bool> {
        self.read = true;
        off_runtime(&mut self.file, TranscriptFile::refresh).await
    }

    /// The file's length, if every byte of it is a record already hashed.
    async fn whole_length(&self) -> io::Result<Option<u64>> {
        let Some(path) = self.file.path().map(Path::to_path_buf) else {
            return Ok(None);
        };
        match tokio::fs::metadata(&path).await {
            Ok(metadata) => Ok(Some(metadata.len()).filter(|length| self.file.is_whole(*length))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }
}

/// Hashes a transcript on the blocking pool: the file is lent there and given back.
async fn off_runtime<T: Send + 'static>(
    file: &mut TranscriptFile,
    work: impl FnOnce(&mut TranscriptFile) -> T + Send + 'static,
) -> T {
    let mut lent = std::mem::replace(file, TranscriptFile::new(None));
    let worked = tokio::task::spawn_blocking(move || {
        let outcome = work(&mut lent);
        (lent, outcome)
    })
    .await;
    let (lent, outcome) =
        worked.unwrap_or_else(|error| std::panic::resume_unwind(error.into_panic()));
    *file = lent;
    outcome
}

pub(super) struct Uploader {
    store: Arc<dyn SyncStore>,
    identity: HostIdentity,
    channel: Arc<RelayChannel>,
    /// The kernel's events on open Sessions' transcripts, registered before they are read.
    watch: Arc<TranscriptWatch>,
    sessions: HashMap<SessionId, SessionSync>,
    /// The socket the last handshake ran on; another socket needs a new one.
    synced_on: Option<SocketEpoch>,
    handshake_due: bool,
    retry_at: Option<Instant>,
    round: u64,
    /// The catalog is read on the next turn: at start, after a Session event, or after a read
    /// that failed.
    catalog_due: bool,
    /// What `axo.db` held at start: cursors and metadata versions.
    stored: Option<HashMap<SessionId, StoredMetadata>>,
}

impl Uploader {
    pub(super) fn new(
        store: Arc<dyn SyncStore>,
        identity: HostIdentity,
        channel: Arc<RelayChannel>,
        watch: Arc<TranscriptWatch>,
    ) -> Self {
        Self {
            store,
            identity,
            channel,
            watch,
            sessions: HashMap::new(),
            synced_on: None,
            handshake_due: true,
            retry_at: None,
            round: 0,
            catalog_due: true,
            stored: None,
        }
    }

    /// One step of work, woken by something; `catalog_changed` when a Session event or a new
    /// socket said the catalog may have changed. Returns what to do next.
    pub(super) async fn turn(&mut self, catalog_changed: bool) -> Next {
        self.catalog_due |= catalog_changed;
        // A new socket wakes the uploader.
        let Some(socket) = self.channel.epoch() else {
            self.synced_on = None;
            return Next::Idle;
        };
        if self.synced_on != Some(socket) {
            self.handshake_due = true;
        }
        if let Err(error) = self.refresh().await {
            log::warn!("event=sync.catalog_unavailable reason={error}");
            return Next::At(Instant::now() + RETRY_DELAY);
        }
        if self.handshake_due {
            if let Some(at) = self.retry_at.filter(|at| Instant::now() < *at) {
                return Next::At(at);
            }
            match self.handshake().await {
                Ok(()) => {
                    self.synced_on = Some(socket);
                    self.handshake_due = false;
                    self.retry_at = None;
                }
                Err(error) => {
                    log::warn!("event=sync.handshake outcome=failed reason={error}");
                    let at = Instant::now() + RETRY_DELAY;
                    self.retry_at = Some(at);
                    return Next::At(at);
                }
            }
        }
        self.send_metadata_and_status().await;
        match self.upload_next().await {
            Ok(true) => Next::Now,
            Ok(false) => match self.evict_next().await {
                Ok(true) => Next::Now,
                Ok(false) => Next::Idle,
                Err(error) => {
                    log::warn!("event=sync.evict outcome=failed reason={error}");
                    Next::Idle
                }
            },
            Err(error) => {
                log::warn!("event=sync.append outcome=failed reason={error}");
                self.handshake_due = true;
                let at = Instant::now() + APPEND_RETRY_DELAY;
                self.retry_at = Some(at);
                Next::At(at)
            }
        }
    }

    /// Reads the catalog if it may have changed, registers the open Sessions' transcripts with
    /// the kernel, then reads them: the watches first, so a write after the read is seen.
    pub(super) async fn refresh(&mut self) -> io::Result<()> {
        if self.catalog_due {
            if self.stored.is_none() {
                self.stored = Some(
                    self.store
                        .stored_metadata()
                        .await?
                        .into_iter()
                        .map(|stored| (stored.session_id, stored))
                        .collect(),
                );
            }
            for session in self.store.catalog().await? {
                let mut metadata = session.metadata.clone().bounded();
                if !self.sessions.contains_key(&session.session_id) {
                    let stored = self
                        .stored
                        .as_ref()
                        .and_then(|stored| stored.get(&session.session_id));
                    let known: Option<SessionMetadata> = stored
                        .and_then(|stored| stored.json.as_deref())
                        .and_then(|json| serde_json::from_str(json).ok());
                    self.sessions.insert(
                        session.session_id,
                        SessionSync {
                            file: TranscriptFile::new(session.pi_session_file.clone()),
                            read: false,
                            metadata: known.unwrap_or_else(|| metadata.clone()),
                            metadata_version: stored.map_or(0, |stored| stored.version),
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
                    entry.read = false;
                }
                if entry.metadata != metadata || entry.metadata_version == 0 {
                    entry.metadata = metadata;
                    entry.metadata_version += 1;
                    entry.eviction_refused = false;
                    self.store
                        .store_metadata(
                            session.session_id,
                            serde_json::to_string(&entry.metadata).map_err(io::Error::other)?,
                            entry.metadata_version,
                        )
                        .await?;
                }
                entry.status = session.status;
            }
            self.catalog_due = false;
        }
        self.watch.watch(
            self.sessions
                .values()
                .filter(|session| !session.metadata.archived)
                .filter_map(|session| session.file.path()),
        );
        for session in self.sessions.values_mut() {
            if (!session.metadata.archived || !session.read)
                && session.refresh().await?
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

    async fn handshake(&mut self) -> io::Result<()> {
        self.round = self.store.next_round().await?;
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
        let reply: SyncReply = self
            .call(
                "axo.host.sync",
                json!({
                    "hostId": self.identity.host_id,
                    "hostGeneration": self.identity.host_generation,
                    "round": round,
                    "sessions": manifest,
                }),
                Priority::Control,
            )
            .await?;
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
            let session_id = state.session_id();
            let Some(session) = self.sessions.get(&session_id) else {
                continue;
            };
            let local = session.file.transcript();
            let CloudState::Known {
                epoch,
                count,
                chain,
                ..
            } = state
            else {
                unknown += 1;
                self.adopt(session_id, Cloud { epoch: 1, count: 0 }).await?;
                continue;
            };
            let prefix = local.is_none_or(|local| {
                count <= local.count() && local.chain_at(count) == Some(chain.as_str())
            });
            let cloud = if prefix {
                // In sync, or the cloud holds a prefix. A Mac with no transcript leaves the
                // cloud's copy as it is.
                if local.is_some_and(|local| count < local.count()) {
                    behind += 1;
                }
                Cloud { epoch, count }
            } else {
                diverged += 1;
                match self.realign(session_id, count).await? {
                    Some(cloud) => cloud,
                    None => continue,
                }
            };
            self.adopt(session_id, cloud).await?;
        }
        log::info!(
            "event=sync.handshake sessions={} unknown={unknown} behind={behind} diverged={diverged}",
            self.sessions.len()
        );
        Ok(())
    }

    /// Takes what the cloud holds of a Session as its upload's starting point, and stores the
    /// cursor where this Mac's copy agrees with it.
    async fn adopt(&mut self, session_id: SessionId, cloud: Cloud) -> io::Result<()> {
        let chain = self.sessions[&session_id]
            .file
            .transcript()
            .and_then(|transcript| transcript.chain_at(cloud.count))
            .map(str::to_owned);
        if let Some(chain) = chain {
            let cursor = SyncCursor {
                position: cloud.count,
                chain,
            };
            self.store.store_cursor(session_id, cursor).await?;
        }
        if let Some(session) = self.sessions.get_mut(&session_id) {
            session.cloud = Some(cloud);
        }
        Ok(())
    }

    /// Finds the longest prefix both copies share and cuts the cloud back to it (the host wins).
    async fn realign(
        &mut self,
        session_id: SessionId,
        cloud_count: u64,
    ) -> io::Result<Option<Cloud>> {
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
            let reply: ChainAtReply = self
                .call(
                    "axo.host.session.chainAt",
                    json!({ "sessionId": session_id, "round": self.round, "positions": positions }),
                    Priority::Control,
                )
                .await?;
            if reply.round != self.round {
                return Err(io::Error::other("a newer handshake replaced this one"));
            }
            let compared = compare_chains(&positions, reply.chains, |position| {
                local.chain_at(position)
            })?;
            best = compared.agreed.or(best);
            cloud_chains.extend(compared.cloud_chains);
            let Some(differs_at) = compared.differs_at else {
                break;
            };
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
            let cursor = SyncCursor {
                position: keep,
                chain: chain.to_owned(),
            };
            self.store.store_cursor(session_id, cursor).await?;
        }
        let reply: TruncateReply = self
            .call(
                "axo.host.session.truncate",
                json!({ "sessionId": session_id, "round": self.round, "keep": keep, "expectedChain": expected }),
                Priority::Control,
            )
            .await?;
        log::info!(
            "event=sync.diverged session_id={session_id} keep={keep} header_differs={header_differs} outcome={}",
            reply.outcome.name()
        );
        match reply.outcome {
            TruncateOutcome::Truncated { epoch } if reply.round == self.round => {
                Ok(Some(Cloud { epoch, count: keep }))
            }
            _ => {
                self.handshake_due = true;
                Ok(None)
            }
        }
    }

    /// Uploads one batch of the Session that most needs it. Returns whether there was one.
    async fn upload_next(&mut self) -> io::Result<bool> {
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
        let range = session.file.line_range(from, to)?;
        let lines = tokio::task::spawn_blocking(move || range.read())
            .await
            .map_err(io::Error::other)??;
        let records: Vec<Value> = lines
            .iter()
            .zip(&transcript.records()[(from - 1) as usize..to as usize])
            .map(|(line, record)| json!({ "id": record.id, "line": line, "hash": record.hash }))
            .collect();
        let mut params = json!({ "sessionId": session_id, "epoch": cloud.epoch, "from": from, "records": records });
        if from == 1 {
            params["header"] = json!(transcript.header());
        }
        let result: AppendReply = match self
            .call("axo.host.session.append", params, Priority::Durable)
            .await
        {
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
            result.outcome.name()
        );
        let committed_chain = transcript.chain_at(result.count).map(str::to_owned);
        match result.outcome {
            AppendOutcome::Committed { epoch } => {
                if let Some(chain) = committed_chain {
                    let cursor = SyncCursor {
                        position: result.count,
                        chain,
                    };
                    self.store.store_cursor(session_id, cursor).await?;
                }
                if let Some(session) = self.sessions.get_mut(&session_id) {
                    session.cloud = Some(Cloud {
                        epoch,
                        count: result.count,
                    });
                }
            }
            AppendOutcome::Invalid => {
                // The cloud cannot take this line; the next handshake tries again.
                log::warn!("event=sync.invalid_line session_id={session_id} position={from}");
                if let Some(session) = self.sessions.get_mut(&session_id) {
                    session.cloud = None;
                }
            }
            // A gap, a conflict or another epoch: only a handshake can tell where the cloud is.
            AppendOutcome::Other => self.handshake_due = true,
        }
        Ok(true)
    }

    /// Deletes one archived Session's transcript the cloud holds whole (RFD0027). Its file is
    /// read again first: a line written since then waits for its upload. Returns whether it
    /// did anything, so the next candidate gets its turn at once; none left is false.
    async fn evict_next(&mut self) -> io::Result<bool> {
        let candidate = self.sessions.iter().find_map(|(id, session)| {
            let count = session.file.count();
            (session.metadata.archived
                && !session.eviction_refused
                && count > 0
                && session.cloud.is_some_and(|cloud| cloud.count == count))
            .then_some(*id)
        });
        let Some(session_id) = candidate else {
            return Ok(false);
        };
        let session = self.sessions.get_mut(&session_id).expect("found above");
        if session.refresh().await? {
            // Changed since: uploaded first.
            return Ok(true);
        }
        let count = session.file.count();
        let (Some(length), Some(chain)) = (
            session.whole_length().await?,
            session
                .file
                .transcript()
                .and_then(|transcript| transcript.chain_at(count))
                .map(str::to_owned),
        ) else {
            // Not whole: it stays until the Session changes, and the next candidate goes.
            session.eviction_refused = true;
            return Ok(true);
        };
        if session.cloud.is_none_or(|cloud| cloud.count != count) {
            session.eviction_refused = true;
            return Ok(true);
        }
        let acknowledged = SyncCursor {
            position: count,
            chain,
        };
        let eviction = self
            .store
            .evict_transcript(session_id, acknowledged, length)
            .await?;
        log::info!(
            "event=sync.evict session_id={session_id} records={count} bytes={length} outcome={}",
            match eviction {
                Eviction::Deleted => "deleted",
                Eviction::Kept => "kept",
            }
        );
        if let Some(session) = self.sessions.get_mut(&session_id) {
            match eviction {
                Eviction::Deleted => {
                    session.file = TranscriptFile::new(None);
                    session.read = false;
                }
                Eviction::Kept => session.eviction_refused = true,
            }
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
    async fn send_metadata_and_status(&mut self) {
        for (id, session) in &mut self.sessions {
            if session.metadata_sent < session.metadata_version {
                let reply: io::Result<Value> = call(
                    &self.channel,
                    "axo.host.session.meta",
                    json!({ "sessionId": id, "metadataVersion": session.metadata_version, "metadata": session.metadata }),
                    Priority::Control,
                )
                .await;
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

    async fn call<T: for<'de> Deserialize<'de>>(
        &self,
        method: &str,
        params: Value,
        priority: Priority,
    ) -> io::Result<T> {
        let result = call(&self.channel, method, params, priority).await?;
        serde_json::from_value(result)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }
}

async fn call(
    channel: &RelayChannel,
    method: &str,
    params: Value,
    priority: Priority,
) -> io::Result<Value> {
    channel
        .request(method, params, priority, REQUEST_TIMEOUT)
        .await
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

/// What the cloud holds of one Session, as the handshake answers.
#[derive(Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
enum CloudState {
    #[serde(rename_all = "camelCase")]
    Known {
        session_id: SessionId,
        epoch: u64,
        count: u64,
        chain: String,
    },
    #[serde(rename_all = "camelCase")]
    Unknown { session_id: SessionId },
}

impl CloudState {
    fn session_id(&self) -> SessionId {
        match self {
            CloudState::Known { session_id, .. } | CloudState::Unknown { session_id } => {
                *session_id
            }
        }
    }
}

#[derive(Deserialize)]
struct ChainAtReply {
    round: u64,
    chains: Vec<Option<String>>,
}

/// A truncate's answer: cut, starting `epoch`, or refused (the chain moved, or a fence).
#[derive(Deserialize)]
struct TruncateReply {
    round: u64,
    #[serde(flatten)]
    outcome: TruncateOutcome,
}

#[derive(Deserialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
enum TruncateOutcome {
    Truncated {
        epoch: u64,
    },
    #[serde(other)]
    Refused,
}

impl TruncateOutcome {
    fn name(&self) -> &'static str {
        match self {
            TruncateOutcome::Truncated { .. } => "truncated",
            TruncateOutcome::Refused => "refused",
        }
    }
}

#[derive(Deserialize)]
struct AppendReply {
    #[serde(flatten)]
    outcome: AppendOutcome,
    count: u64,
}

/// An append's answer. `Other` is a gap, a conflict or another epoch: the cloud is not where this
/// Mac thought, and a handshake finds out where.
#[derive(Deserialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
enum AppendOutcome {
    Committed {
        epoch: u64,
    },
    Invalid,
    #[serde(other)]
    Other,
}

impl AppendOutcome {
    fn name(&self) -> &'static str {
        match self {
            AppendOutcome::Committed { .. } => "committed",
            AppendOutcome::Invalid => "invalid",
            AppendOutcome::Other => "other",
        }
    }
}

/// One `chainAt` round compared with this Mac's copy.
struct ChainComparison {
    /// The last position asked about where both copies agree, before any where they differ.
    agreed: Option<u64>,
    /// The first position asked about where they differ, or the cloud has nothing.
    differs_at: Option<u64>,
    /// The cloud's chains, by position, up to `differs_at`.
    cloud_chains: Vec<(u64, String)>,
}

/// Compares the cloud's chains at `positions` (one each, in order) with `local`'s. A reply with
/// another number of chains is refused: read short, it would seem to agree everywhere it
/// stopped, and the search would cut the cloud back further than the copies differ.
fn compare_chains<'a>(
    positions: &[u64],
    chains: Vec<Option<String>>,
    local: impl Fn(u64) -> Option<&'a str>,
) -> io::Result<ChainComparison> {
    if chains.len() != positions.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "the cloud answered {} chains for {} positions",
                chains.len(),
                positions.len()
            ),
        ));
    }
    let mut compared = ChainComparison {
        agreed: None,
        differs_at: None,
        cloud_chains: Vec::new(),
    };
    for (&position, chain) in positions.iter().zip(chains) {
        let agrees = chain.is_some() && local(position) == chain.as_deref();
        if let Some(chain) = chain {
            compared.cloud_chains.push((position, chain));
        }
        if !agrees {
            compared.differs_at = Some(position);
            break;
        }
        compared.agreed = Some(position);
    }
    Ok(compared)
}

#[cfg(test)]
mod reply_tests {
    use super::*;

    const SESSION: &str = "8f8f8f8f-0000-4000-8000-000000000001";

    #[test]
    fn chains_agree_up_to_the_first_difference_and_a_short_answer_is_refused() {
        let local = |position: u64| ["h", "a", "b", "c"].get(position as usize).copied();
        let chains = |found: &[Option<&str>]| -> Vec<Option<String>> {
            found.iter().map(|chain| chain.map(str::to_owned)).collect()
        };

        let compared = compare_chains(
            &[0, 1, 2],
            chains(&[Some("h"), Some("a"), Some("x")]),
            local,
        )
        .unwrap();
        assert_eq!((compared.agreed, compared.differs_at), (Some(1), Some(2)));
        assert_eq!(
            compared.cloud_chains.len(),
            3,
            "the differing chain is kept"
        );

        let compared = compare_chains(&[0, 3], chains(&[Some("h"), None]), local).unwrap();
        assert_eq!((compared.agreed, compared.differs_at), (Some(0), Some(3)));

        // Read short, this agreed everywhere and the search took 1 as the common prefix.
        let short = compare_chains(&[0, 1, 2, 3], chains(&[Some("h"), Some("a")]), local);
        assert!(short.is_err());
        let long = compare_chains(&[0], chains(&[Some("h"), Some("a")]), local);
        assert!(long.is_err());
    }

    #[test]
    fn a_handshake_answer_is_known_with_where_the_cloud_is_or_unknown() {
        let known: CloudState = serde_json::from_value(json!({
            "sessionId": SESSION, "state": "known", "epoch": 2, "count": 7, "chain": "sha256:ab", "heads": [],
        }))
        .unwrap();
        assert!(
            matches!(known, CloudState::Known { epoch: 2, count: 7, ref chain, .. } if chain == "sha256:ab")
        );
        let unknown: CloudState =
            serde_json::from_value(json!({ "sessionId": SESSION, "state": "unknown" })).unwrap();
        assert_eq!(unknown.session_id().to_string(), SESSION);
        // Known without where: a broken answer, not the start of a Session.
        assert!(
            serde_json::from_value::<CloudState>(json!({ "sessionId": SESSION, "state": "known" }))
                .is_err()
        );
    }

    #[test]
    fn an_append_answer_is_committed_in_an_epoch_invalid_or_something_a_handshake_sorts_out() {
        let committed: AppendReply = serde_json::from_value(
            json!({ "outcome": "committed", "epoch": 3, "count": 9, "chain": "sha256:cd" }),
        )
        .unwrap();
        assert!(matches!(
            committed.outcome,
            AppendOutcome::Committed { epoch: 3 }
        ));
        assert_eq!(committed.count, 9);
        for outcome in ["gap", "conflict", "epoch"] {
            let other: AppendReply = serde_json::from_value(
                json!({ "outcome": outcome, "epoch": null, "count": 0, "chain": null }),
            )
            .unwrap();
            assert!(matches!(other.outcome, AppendOutcome::Other), "{outcome}");
        }
        let invalid: AppendReply = serde_json::from_value(
            json!({ "outcome": "invalid", "epoch": 1, "count": 4, "chain": "sha256:ef" }),
        )
        .unwrap();
        assert!(matches!(invalid.outcome, AppendOutcome::Invalid));
    }

    #[test]
    fn a_truncate_answer_is_cut_into_an_epoch_or_refused() {
        let cut: TruncateReply = serde_json::from_value(json!({
            "round": 4, "outcome": "truncated", "epoch": 2, "count": 3, "chain": "sha256:01",
        }))
        .unwrap();
        assert!(matches!(
            cut.outcome,
            TruncateOutcome::Truncated { epoch: 2 }
        ));
        assert_eq!(cut.round, 4);
        let refused: TruncateReply =
            serde_json::from_value(json!({ "round": 4, "outcome": "mismatch" })).unwrap();
        assert!(matches!(refused.outcome, TruncateOutcome::Refused));
    }
}
