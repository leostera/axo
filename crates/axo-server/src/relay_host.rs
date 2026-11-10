//! What the relay asks of axod: the Mac's identity, the events it forwards, questions, computer
//! use and the account's calls, which it hands to axod's own methods (`axo_relay::RelayHost`);
//! what the uploader reads and keeps (`axo_relay::SyncStore`); and the link to the account
//! (`axo_relay::HostLinkStore`). The database is reached through the store's own thread.
//!
//! Archived Sessions live in the cloud (RFD0027): once the cloud holds an archived Session's
//! transcript whole, it is deleted here, and reopening the Session fetches it back first.
//! `relay_sync.in_cloud` says the cloud has it. It is set before the file is deleted, and cleared
//! only when the Session reopens with its transcript back in place. While it is set the uploader
//! neither reads nor uploads the file, so a missing or partial one never cuts the cloud's copy.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use axo_protocol::rpc::MethodError;
use axo_protocol::{Event, RelayStatus, SessionId};
use axo_relay::peers::{Mirror, Place, restore_directory};
use axo_relay::{Eviction, HostFuture, HostIdentity, SyncCursor};
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
    identity: HostIdentity,
    methods: OnceLock<IoHandler>,
}

impl RelayHostAdapter {
    pub(crate) fn new(core: Arc<Core>) -> Self {
        let identity = HostIdentity {
            host_id: core.host_id.clone(),
            host_generation: core.host_generation.clone(),
        };
        Self {
            core,
            identity,
            methods: OnceLock::new(),
        }
    }

    /// The methods the account's calls are answered with: axod's, as the relay's caller.
    pub(crate) fn answer_with(&self, methods: IoHandler) {
        let _ = self.methods.set(methods);
    }
}

impl axo_relay::HostLinkStore for RelayHostAdapter {
    fn load_link(&self) -> HostFuture<'_, io::Result<axo_relay::HostLink>> {
        Box::pin(async move {
            let stored = self
                .core
                .store
                .call(|database| axo_store::load_host_link(database))
                .await?;
            let account = stored
                .account
                .map(|stored| {
                    axo_relay::AccountLink::parse(stored.account_id, stored.credential_id)
                })
                .transpose()?;
            let pending = stored
                .pending_redemption
                .map(|stored| {
                    axo_relay::PendingRedemption::parse(
                        stored.credential_id,
                        stored.host_generation,
                    )
                })
                .transpose()?;
            axo_relay::HostLink::new(account, pending)
        })
    }

    fn save_link(&self, link: axo_relay::HostLink) -> HostFuture<'_, io::Result<()>> {
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
        Box::pin(
            self.core
                .store
                .call(move |database| axo_store::store_host_link(database, &stored)),
        )
    }
}

impl axo_relay::RelayHost for RelayHostAdapter {
    fn identity(&self) -> &HostIdentity {
        &self.identity
    }

    fn publish_relay_status(&self, status: &RelayStatus) {
        self.core.events.publish(Event::RelayStatus {
            status: status.clone(),
        });
    }

    fn subscribe_remote_events(&self) -> io::Result<String> {
        let core = &self.core;
        core.events.subscribe(None, true, || core.catalog.records())
    }

    fn next_remote_events<'a>(
        &'a self,
        subscription_id: &'a str,
        timeout: Duration,
    ) -> HostFuture<'a, io::Result<Vec<Event>>> {
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

    fn pending_elicitations(&self) -> Vec<axo_protocol::elicitation::Elicitation> {
        self.core.questions.pending()
    }

    fn resolve_elicitation(&self, answer: axo_relay::RemoteAnswer) -> Result<(), MethodError> {
        let axo_relay::RemoteAnswer {
            elicitation_id,
            answer,
            sealed,
            device,
        } = answer;
        crate::devices::check_answer(&elicitation_id, answer, sealed.as_ref(), device.as_ref())?;
        let reply = sealed.map_or(
            axo_protocol::elicitation::Reply::Bare,
            axo_protocol::elicitation::Reply::Sealed,
        );
        self.core
            .questions
            .resolve(self.core.as_ref(), &elicitation_id, answer, reply)
    }

    fn remote_computer(
        &self,
        request: axo_relay::computer::ComputerParams,
    ) -> HostFuture<'_, Result<serde_json::Value, MethodError>> {
        Box::pin(async move {
            self.core
                .computer
                .remote(self.core.as_ref(), &request)
                .await
        })
    }

    fn computer_status(&self) -> HostFuture<'_, serde_json::Value> {
        // Cua's probe asks the window server and TCC, which may take a moment.
        Box::pin(async {
            tokio::task::spawn_blocking(axo_computer_use::ComputerUse::status)
                .await
                .unwrap_or_else(|_| serde_json::json!({ "available": false }))
        })
    }

    fn set_asset_source(&self, source: Option<axo_relay::assets::AssetSource>) {
        self.core.assets.set(source);
    }

    fn answer_remote(
        &self,
        request: serde_json::Value,
    ) -> HostFuture<'_, Option<serde_json::Value>> {
        Box::pin(async move {
            let Some(methods) = self.methods.get() else {
                // A call that arrives while axod is still assembling its methods.
                return Some(serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": request.get("id").cloned().unwrap_or_default(),
                    "error": MethodError::new(
                        axo_protocol::rpc::error_code::REFUSED,
                        "Operation failed",
                    ),
                }));
            };
            let request = request.to_string();
            let reply = axo_ipc::peer::as_relay(methods.handle_request(&request)).await?;
            serde_json::from_str(&reply).ok()
        })
    }
}

impl axo_relay::SyncStore for RelayHostAdapter {
    fn catalog(&self) -> HostFuture<'_, io::Result<Vec<axo_relay::SyncSession>>> {
        Box::pin(sync_catalog(&self.core))
    }

    fn states(&self) -> HostFuture<'_, io::Result<Vec<axo_relay::StoredSyncState>>> {
        Box::pin(async move {
            let states = self
                .core
                .store
                .call(|database| axo_store::load_sync_states(database))
                .await?;
            Ok(states
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
        })
    }

    fn store_cursor(
        &self,
        session_id: SessionId,
        cursor: SyncCursor,
    ) -> HostFuture<'_, io::Result<()>> {
        Box::pin(self.core.store.call(move |database| {
            axo_store::store_sync_cursor(
                database,
                &session_id.to_string(),
                cursor.position,
                &cursor.chain,
            )
        }))
    }

    fn store_metadata(
        &self,
        session_id: SessionId,
        metadata_json: String,
        version: u64,
    ) -> HostFuture<'_, io::Result<()>> {
        Box::pin(self.core.store.call(move |database| {
            axo_store::store_sync_metadata(
                database,
                &session_id.to_string(),
                &metadata_json,
                version,
            )
        }))
    }

    fn evict_transcript(
        &self,
        session_id: SessionId,
        acknowledged: SyncCursor,
        length: u64,
    ) -> HostFuture<'_, io::Result<Eviction>> {
        Box::pin(evict_transcript(
            &self.core,
            session_id,
            acknowledged,
            length,
        ))
    }

    fn next_round(&self) -> HostFuture<'_, io::Result<u64>> {
        Box::pin(
            self.core
                .store
                .call(|database| axo_store::next_sync_round(database)),
        )
    }
}

/// Every Session the uploader keeps in the cloud: the open ones as the catalog has them, then the
/// archived ones as the store does.
async fn sync_catalog(core: &Core) -> io::Result<Vec<axo_relay::SyncSession>> {
    let archived = core
        .store
        .call(|database| axo_store::read_archived_sessions(database))
        .await?;
    let in_cloud: HashSet<String> = core
        .store
        .call(|database| axo_store::load_sync_states(database))
        .await?
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

/// Deletes an archived Session's transcript the cloud acknowledged whole at `acknowledged`, while
/// the file was `length` bytes. Kept, deleting nothing, if the Session reopened, is reopening,
/// changed, or is not at that cursor any more.
pub(crate) async fn evict_transcript(
    core: &Core,
    session_id: SessionId,
    acknowledged: SyncCursor,
    length: u64,
) -> io::Result<Eviction> {
    if core.registry.contains(session_id) || lock(&core.reopening).contains(&session_id) {
        return Ok(Eviction::Kept);
    }
    let position = acknowledged.position;
    // The store's thread does the file work too: it is a few syscalls, kept in step with the
    // record that says the cloud has it.
    let eviction = core
        .store
        .call(move |database| {
            let id = session_id.to_string();
            let Some(transcript) = axo_store::load_transcript(database, Some(&id), None)? else {
                return Ok(Eviction::Kept);
            };
            let Some(file) = transcript.pi_session_file.map(PathBuf::from) else {
                return Ok(Eviction::Kept);
            };
            if !transcript.archived || fs::metadata(&file)?.len() != length {
                return Ok(Eviction::Kept);
            }
            // Recorded before anything is deleted: a crash in between leaves a file to delete
            // again.
            if !axo_store::mark_transcript_in_cloud(
                database,
                &id,
                acknowledged.position,
                &acknowledged.chain,
            )? {
                return Ok(Eviction::Kept);
            }
            remove_if_present(&file)?;
            remove_if_present(&lock_file(&file))?;
            Ok(Eviction::Deleted)
        })
        .await?;
    if eviction == Eviction::Deleted {
        log::info!(
            "event=session.transcript_evicted session_id={session_id} records={position} bytes={length}"
        );
    }
    Ok(eviction)
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
    restore_from_cloud(core, transcript).await
}

async fn restore_from_cloud(
    core: &Core,
    transcript: axo_store::StoredTranscript,
) -> io::Result<()> {
    let (Some(file), Some(chain)) = (
        transcript.pi_session_file.as_deref().map(PathBuf::from),
        transcript.chain.as_deref(),
    ) else {
        return Err(unavailable("its record is incomplete"));
    };
    let expected = Some((transcript.position, chain.to_owned()));
    // Deleted after a crash, or restored by a reopen that failed later: already in place.
    let already_restored = {
        let file = file.clone();
        let expected = expected.clone();
        tokio::task::spawn_blocking(move || -> io::Result<bool> {
            Ok(file.exists() && axo_agent::pi::transcript_chain(&file)? == expected)
        })
        .await
        .map_err(io::Error::other)??
    };
    if already_restored {
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
        .await
        .map_err(|error| unavailable(&error.to_string()))?;
    let directory = restore_directory(&access.index);
    tokio::task::spawn_blocking(move || -> io::Result<()> {
        let mut staging = Mirror::new(directory);
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
        Ok(())
    })
    .await
    .map_err(io::Error::other)??;
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

pub(crate) fn lock_file(file: &Path) -> PathBuf {
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
