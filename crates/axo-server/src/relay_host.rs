//! What the relay asks of axod (`axo_relay::RelayHost`): the Sessions it uploads, its sync
//! state, the events it forwards, questions, computer use, and the account's calls, which it
//! hands to axod's own methods. The relay calls these from its blocking pool; the store is
//! reached with `call_blocking` there.
//!
//! Archived Sessions live in the cloud (RFD0027): once the cloud holds an archived Session's
//! transcript whole, it is deleted here, and reopening the Session fetches it back first.
//! `relay_sync.in_cloud` says the cloud has it. It is set before the file is deleted, and cleared
//! only when the Session reopens with its transcript back in place. While it is set the uploader
//! neither reads nor uploads the file, so a missing or partial one never cuts the cloud's copy.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use axo_protocol::{Event, RelayStatus, SessionId};
use axo_relay::peers::{Mirror, Place, restore_directory};
use jsonrpc_core::IoHandler;

use crate::core::{Core, lock};

/// Local events the relay takes in one wait.
const REMOTE_EVENTS_PER_WAIT: usize = 64;
/// How long reopening waits for a transcript to come back from the cloud.
const RESTORE_TIMEOUT: Duration = Duration::from_secs(60);

/// axod as the relay's host, and the methods the account's calls are answered with, set once
/// they are assembled.
pub(crate) struct RelayHostAdapter {
    core: Arc<Core>,
    methods: OnceLock<IoHandler>,
}

impl RelayHostAdapter {
    pub(crate) fn new(core: Arc<Core>) -> Self {
        Self {
            core,
            methods: OnceLock::new(),
        }
    }

    /// The methods the account's calls are answered with: axod's, as the relay's caller.
    pub(crate) fn answer_with(&self, methods: IoHandler) {
        let _ = self.methods.set(methods);
    }
}

impl axo_relay::HostLinkStore for RelayHostAdapter {
    fn load_link(&self) -> io::Result<axo_relay::HostLink> {
        let stored = self
            .core
            .store
            .call_blocking(|database| axo_store::load_host_link(database))?;
        let account = stored
            .account
            .map(|stored| axo_relay::AccountLink::parse(stored.account_id, stored.credential_id))
            .transpose()?;
        let pending = stored
            .pending_redemption
            .map(|stored| {
                axo_relay::PendingRedemption::parse(stored.credential_id, stored.host_generation)
            })
            .transpose()?;
        axo_relay::HostLink::new(account, pending)
    }

    fn save_link(&self, link: &axo_relay::HostLink) -> io::Result<()> {
        let stored = axo_store::StoredHostLink {
            account: link.account().map(|account| axo_store::StoredAccountLink {
                account_id: account.account_id().to_owned(),
                credential_id: account.credential_id().to_owned(),
            }),
            pending_redemption: link
                .pending()
                .map(|pending| axo_store::StoredPendingRedemption {
                    credential_id: pending.credential_id().to_owned(),
                    host_generation: pending.host_generation().to_owned(),
                }),
        };
        self.core
            .store
            .call_blocking(move |database| axo_store::store_host_link(database, &stored))
    }
}

impl axo_relay::RelayHost for RelayHostAdapter {
    fn host_id(&self) -> &str {
        &self.core.host_id
    }

    fn host_generation(&self) -> &str {
        &self.core.host_generation
    }

    fn pending_elicitations(&self) -> Vec<axo_protocol::elicitation::Elicitation> {
        self.core.questions.pending()
    }

    fn resolve_elicitation(
        &self,
        id: &str,
        answer: axo_protocol::elicitation::ElicitationAnswer,
        sealed: Option<axo_protocol::elicitation::Sealed>,
        device: Option<axo_protocol::elicitation::DeviceProof>,
    ) -> Result<(), (i64, String)> {
        crate::devices::check_answer(id, answer, sealed.as_ref(), device.as_ref())?;
        let reply = sealed.map_or(
            axo_protocol::elicitation::Reply::Bare,
            axo_protocol::elicitation::Reply::Sealed,
        );
        self.core
            .questions
            .resolve(self.core.as_ref(), id, answer, reply)
    }

    fn remote_computer(
        &self,
        request: &axo_relay::computer::ComputerParams,
    ) -> Result<serde_json::Value, (i64, String)> {
        self.core.computer.remote(self.core.as_ref(), request)
    }

    fn computer_status(&self) -> serde_json::Value {
        axo_computer_use::ComputerUse::status()
    }

    fn set_asset_source(&self, source: Option<axo_relay::assets::AssetSource>) {
        self.core.assets.set(source);
    }

    fn publish_relay_status(&self, status: &RelayStatus) {
        self.core.events.publish(Event::RelayStatus {
            status: status.clone(),
        });
    }

    fn sync_catalog(&self) -> io::Result<Vec<axo_relay::SyncSession>> {
        let core = &self.core;
        let (archived, states) = core.store.call_blocking(|database| {
            Ok((
                axo_store::read_archived_sessions(database)?,
                axo_store::load_sync_states(database)?,
            ))
        })?;
        let in_cloud: std::collections::HashSet<String> = states
            .into_iter()
            .filter(|state| state.in_cloud)
            .map(|state| state.session_id)
            .collect();
        let open = core.catalog.records().into_iter().map(|session| {
            let workspace_state = core.workspace_states.get(session.id);
            if workspace_state.is_none() {
                // Not read since axod started: read it once now, for the next round.
                core.workspace_states
                    .refresh(session.id, session.folder.clone());
            }
            axo_relay::SyncSession {
                session_id: session.id,
                metadata: axo_relay::SessionMetadata {
                    name: Some(
                        session
                            .manual_name
                            .clone()
                            .unwrap_or_else(|| session.name.clone()),
                    ),
                    emoji: session.emoji.clone(),
                    folder_name: axo_protocol::folder_name(&session.folder),
                    has_agent: session.has_agent(),
                    created_at: (session.created_at > 0).then_some(session.created_at),
                    last_message_at: session.last_message_at,
                    archived: false,
                    workspace_state,
                    pi: session.pi.clone(),
                },
                status: Some(session.status),
                transcript_in_cloud: in_cloud.contains(&session.id.to_string()),
                pi_session_file: session.pi_session_file,
            }
        });
        let archived = archived.into_iter().map(|session| axo_relay::SyncSession {
            session_id: session.id,
            metadata: axo_relay::SessionMetadata {
                name: Some(session.name),
                folder_name: axo_protocol::folder_name(&session.folder),
                emoji: session.emoji,
                has_agent: session.pi_session_file.is_some(),
                created_at: None,
                last_message_at: session.last_message_at,
                archived: true,
                workspace_state: None,
                pi: None,
            },
            status: None,
            transcript_in_cloud: in_cloud.contains(&session.id.to_string()),
            pi_session_file: session.pi_session_file,
        });
        Ok(open.chain(archived).collect())
    }

    fn sync_states(&self) -> io::Result<Vec<axo_relay::StoredSyncState>> {
        Ok(self
            .core
            .store
            .call_blocking(|database| axo_store::load_sync_states(database))?
            .into_iter()
            .map(|state| axo_relay::StoredSyncState {
                session_id: state.session_id,
                position: state.position,
                chain: state.chain,
                metadata_json: state.metadata_json,
                metadata_version: state.metadata_version,
                in_cloud: state.in_cloud,
            })
            .collect())
    }

    fn store_sync_cursor(
        &self,
        session_id: SessionId,
        position: u64,
        chain: &str,
    ) -> io::Result<()> {
        let chain = chain.to_owned();
        self.core.store.call_blocking(move |database| {
            axo_store::store_sync_cursor(database, &session_id.to_string(), position, &chain)
        })
    }

    fn store_sync_metadata(
        &self,
        session_id: SessionId,
        metadata_json: &str,
        version: u64,
    ) -> io::Result<()> {
        let metadata_json = metadata_json.to_owned();
        self.core.store.call_blocking(move |database| {
            axo_store::store_sync_metadata(
                database,
                &session_id.to_string(),
                &metadata_json,
                version,
            )
        })
    }

    fn evict_transcript(
        &self,
        session_id: SessionId,
        position: u64,
        chain: &str,
        length: u64,
    ) -> io::Result<bool> {
        evict_transcript(&self.core, session_id, position, chain, length)
    }

    fn next_sync_round(&self) -> io::Result<u64> {
        self.core
            .store
            .call_blocking(|database| axo_store::next_sync_round(database))
    }

    fn subscribe_remote_events(&self) -> io::Result<String> {
        let core = &self.core;
        core.events.subscribe(None, true, || core.catalog.records())
    }

    fn next_remote_events<'a>(
        &'a self,
        subscription_id: &'a str,
        timeout: Duration,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Vec<Event>>> + Send + 'a>>
    {
        Box::pin(async move {
            let events = self
                .core
                .events
                .next(subscription_id, timeout, REMOTE_EVENTS_PER_WAIT)
                .await?;
            Ok(events.into_iter().map(Arc::unwrap_or_clone).collect())
        })
    }

    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()> {
        self.core.events.unsubscribe(subscription_id)
    }

    fn answer_remote(&self, request: serde_json::Value) -> Option<serde_json::Value> {
        let reply = match self.methods.get() {
            Some(methods) => {
                let request = request.to_string();
                axo_ipc::peer::as_relay(|| {
                    tokio::runtime::Handle::current().block_on(methods.handle_request(&request))
                })?
            }
            None => {
                // A call that arrives while axod is still assembling its methods.
                return Some(serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": request.get("id").cloned().unwrap_or_default(),
                    "error": { "code": -32003, "message": "Operation failed" },
                }));
            }
        };
        serde_json::from_str(&reply).ok()
    }
}

/// Deletes an archived Session's transcript the cloud acknowledged whole, at `position` and
/// `chain`, while the file was `length` bytes. Returns false, deleting nothing, if the Session
/// reopened, is reopening, changed, or is not at that cursor any more.
fn evict_transcript(
    core: &Core,
    session_id: SessionId,
    position: u64,
    chain: &str,
    length: u64,
) -> io::Result<bool> {
    if core.registry.contains(session_id) || lock(&core.reopening).contains(&session_id) {
        return Ok(false);
    }
    let chain = chain.to_owned();
    let evicted = core.store.call_blocking(move |database| {
        let id = session_id.to_string();
        let Some(transcript) = axo_store::load_transcript(database, Some(&id), None)? else {
            return Ok(false);
        };
        let Some(file) = transcript.pi_session_file.map(PathBuf::from) else {
            return Ok(false);
        };
        if !transcript.archived || fs::metadata(&file)?.len() != length {
            return Ok(false);
        }
        // Recorded before anything is deleted: a crash in between leaves a file to delete again.
        if !axo_store::mark_transcript_in_cloud(database, &id, position, &chain)? {
            return Ok(false);
        }
        remove_if_present(&file)?;
        remove_if_present(&lock_file(&file))?;
        Ok(true)
    })?;
    if evicted {
        log::info!(
            "event=session.transcript_evicted session_id={session_id} records={position} bytes={length}"
        );
    }
    Ok(evicted)
}

/// Puts an archived Session's transcript back from the cloud if it is there, checked against
/// what the cloud acknowledged when it was deleted. `in_cloud` stays set until the reopen clears
/// it (`reopened_with_transcript`).
pub(crate) async fn restore_transcript(
    core: &Arc<Core>,
    session_id: Option<SessionId>,
    pi_session_file: Option<String>,
) -> io::Result<()> {
    let id = session_id.map(|id| id.to_string());
    let transcript = core
        .store
        .call(move |database| {
            axo_store::load_transcript(database, id.as_deref(), pi_session_file.as_deref())
        })
        .await?;
    let Some(transcript) = transcript.filter(|transcript| transcript.in_cloud) else {
        return Ok(());
    };
    let core = Arc::clone(core);
    tokio::task::spawn_blocking(move || restore_from_cloud(&core, transcript))
        .await
        .map_err(io::Error::other)?
}

fn restore_from_cloud(core: &Core, transcript: axo_store::StoredTranscript) -> io::Result<()> {
    let (Some(file), Some(chain)) = (
        transcript.pi_session_file.as_deref().map(PathBuf::from),
        transcript.chain.as_deref(),
    ) else {
        return Err(unavailable("its record is incomplete"));
    };
    let expected = Some((transcript.position, chain.to_owned()));
    // Deleted after a crash, or restored by a reopen that failed later: already in place.
    if file.exists() && axo_agent::pi::transcript_chain(&file)? == expected {
        return Ok(());
    }
    let place = Place::of(&core.host_id, &transcript.session_id)
        .ok_or_else(|| unavailable("its place is not valid"))?;
    let access = core
        .peers
        .access()
        .map_err(|error| unavailable(&error.to_string()))?;
    log::info!(
        "event=session.transcript_restore session_id={} records={}",
        transcript.session_id,
        transcript.position
    );
    let staged = access
        .live
        .restore(place.clone(), transcript.position, RESTORE_TIMEOUT)
        .map_err(|error| unavailable(&error.to_string()))?;
    let mut staging = Mirror::new(restore_directory(&access.index));
    let outcome = if axo_agent::pi::transcript_chain(&staged)? == expected {
        if let Some(folder) = file.parent() {
            fs::create_dir_all(folder)?;
        }
        fs::rename(&staged, &file)
    } else {
        Err(unavailable("the cloud's copy is not the one deleted here"))
    };
    staging.forget(&place)?;
    outcome?;
    log::info!(
        "event=session.transcript_restored session_id={}",
        transcript.session_id
    );
    Ok(())
}

/// Called in the store as an archived Session reopens: its transcript must be here, and from now
/// on the uploader reads it again.
pub(crate) fn reopened_with_transcript(
    database: &axo_store::Connection,
    session_id: SessionId,
) -> io::Result<()> {
    let id = session_id.to_string();
    let Some(transcript) = axo_store::load_transcript(database, Some(&id), None)? else {
        return Ok(());
    };
    if !transcript.in_cloud {
        return Ok(());
    }
    let on_disk = match transcript.pi_session_file.as_deref().map(Path::new) {
        Some(file) if file.exists() => axo_agent::pi::transcript_chain(file)?,
        _ => None,
    };
    if on_disk != transcript.chain.map(|chain| (transcript.position, chain)) {
        return Err(unavailable("it is not back on this Mac"));
    }
    axo_store::clear_transcript_in_cloud(database, &id)
}

fn unavailable(reason: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::NotFound,
        format!("This Session's transcript is in the cloud and could not be fetched: {reason}"),
    )
}

fn lock_file(file: &Path) -> PathBuf {
    let mut name = file.as_os_str().to_owned();
    name.push(".lock");
    PathBuf::from(name)
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}
