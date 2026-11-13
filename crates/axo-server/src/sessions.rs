//! What spans Sessions (RFD0041): which are open, restoring them when axod starts, creating,
//! importing, resuming and reopening them, prompting their Pis, and stopping them all. Each
//! Session's own state is its task's; this only finds the task and asks it.

use std::collections::HashMap;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use axo_agent::pi::BridgeSocketPath;
use axo_protocol::asset::FetchedAttachment;
use axo_protocol::commands::CommandId;
use axo_protocol::rpc::{self, PromptAccepted, PromptDelivery, PromptSession, PromptText};
use axo_protocol::{Event, PaneRole, SessionId, SessionRecord, ShellId, Viewport, new_uuid_v4};
use axo_store::{PiHistoryOwner, StoredLifecycle, StoredSession};
use tokio::sync::oneshot;

use crate::catalog::PiPhase;
use crate::core::{Core, lock};
use crate::session::panes::RuntimeId;
use crate::session::pi::Admission;
use crate::session::prompts::{self, Prompt, PromptError};
use crate::session::{self, PiStart, SessionHandle};
use crate::stop_notice::{self, DaemonStop};

/// How long after its last activity a Session's Pi starts with axod; older ones stay dormant.
const ACTIVE_ON_START: i64 = 60 * 60;
/// The longest axod waits for the Pis it started before calling itself ready.
const LAUNCH_READY_LIMIT: Duration = Duration::from_secs(15);
/// How long a client's prompt waits for a starting Pi to bind its bridge. With Pi's own answer
/// it stays inside the cloud's 10 s command deadline; a Pi slower than that is answered as still
/// starting, and the client retries with the same commandId.
const CLIENT_PROMPT_START_WAIT: Duration = Duration::from_secs(4);
/// How long a Session waits for its Pi when the waiting is the point: creating or reopening it.
const PI_START_WAIT: Duration = Duration::from_secs(30);
/// The longest transcript path Pi may ask to resume; the extension enforces the same bound.
const MAX_RESUME_PATH_BYTES: usize = 4096;
/// How many recently closed Sessions reopening tries before giving up.
const REOPEN_CANDIDATES: usize = 10;
/// How long stopping waits for every Session's panes.
const STOP_WAIT: Duration = Duration::from_secs(8);

/// The open Sessions' tasks, by id.
#[derive(Default)]
pub(crate) struct Registry(std::sync::Mutex<HashMap<SessionId, SessionHandle>>);

impl Registry {
    pub(crate) fn insert(&self, handle: SessionHandle) {
        lock(&self.0).insert(handle.id, handle);
    }

    pub(crate) fn remove(&self, id: SessionId) {
        lock(&self.0).remove(&id);
    }

    pub(crate) fn get(&self, id: SessionId) -> Option<SessionHandle> {
        lock(&self.0).get(&id).cloned()
    }

    pub(crate) fn contains(&self, id: SessionId) -> bool {
        lock(&self.0).contains_key(&id)
    }

    pub(crate) fn all(&self) -> Vec<SessionHandle> {
        lock(&self.0).values().cloned().collect()
    }
}

pub(crate) fn handle(core: &Core, id: SessionId) -> io::Result<SessionHandle> {
    core.registry
        .get(id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session is not open"))
}

/// The open Session `shell_id` belongs to, which must be `session_id` when given.
pub(crate) fn owner_of(
    core: &Core,
    session_id: Option<SessionId>,
    shell_id: ShellId,
) -> io::Result<SessionHandle> {
    let owner = core
        .catalog
        .view()
        .owner_of(shell_id)
        .filter(|owner| session_id.is_none_or(|expected| expected == *owner));
    owner
        .and_then(|owner| core.registry.get(owner))
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))
}

/// Restores every open Session as axod starts. Pis start for the Sessions the last stop
/// interrupted and those active in the last hour; the rest stay dormant until wanted.
pub(crate) async fn restore(core: &Arc<Core>, previous: Option<DaemonStop>) -> io::Result<()> {
    let active_since = axo_store::unix_timestamp() - ACTIVE_ON_START;
    let stored = core
        .store
        .call(move |database| {
            let mut open = Vec::new();
            for record in axo_store::read_open_sessions(database)? {
                if record.shell_ids.is_empty() {
                    axo_store::archive_session(database, record.id, "missing_open_pane")?;
                    continue;
                }
                let activity = axo_store::open_session_row(database, record.id)
                    .map(|row| row.last_message_at.unwrap_or(0).max(row.created_at))
                    .unwrap_or(0);
                open.push((record, activity));
            }
            Ok(open)
        })
        .await?;
    let interrupted = previous
        .as_ref()
        .map_or(&[][..], |stop| &stop.interrupted[..]);
    let (mut starting, mut dormant) = (0, 0);
    for (record, activity) in stored {
        let start = if interrupted.contains(&record.id) || activity >= active_since {
            starting += 1;
            PiStart::Now
        } else {
            dormant += 1;
            PiStart::Dormant
        };
        let id = record.id;
        if let Err(error) = session::open(core, record, start, None).await {
            log::warn!("event=session.restore_failed session_id={id} reason={error}");
        }
    }
    log::info!("event=session.pis_restoring starting={starting} dormant={dormant}");
    tokio::spawn(launch_ready(Arc::clone(core)));
    tokio::spawn(crate::idle_pis::run(Arc::downgrade(core)));
    // Sessions a stop interrupted mid-turn are told, once their Pi takes prompts.
    if let Some(stop) = previous {
        let notice = match PromptText::parse(stop.notice(&stop_notice::this_daemon(Vec::new()))) {
            Ok(notice) => notice,
            Err(error) => {
                log::warn!("event=session.stop_notice_skipped reason={error}");
                return Ok(());
            }
        };
        for session_id in stop.interrupted {
            let core = Arc::clone(core);
            let notice = notice.clone();
            tokio::spawn(async move {
                let told = prompt(
                    &core,
                    PromptSession {
                        session_id,
                        text: notice,
                        delivery: PromptDelivery::FollowUp,
                        from_session_id: None,
                    },
                    None,
                    Vec::new(),
                )
                .await;
                match told {
                    Ok(_) => log::info!("event=session.stop_notice_sent session_id={session_id}"),
                    Err(error) => log::warn!(
                        "event=session.stop_notice_skipped session_id={session_id} reason={error}"
                    ),
                }
            });
        }
    }
    Ok(())
}

/// axod is ready not when it answers, but once the Pis it started at launch have come up, so a
/// client finds their agents taking prompts. A Pi that dies on the way stops counting, and after
/// [`LAUNCH_READY_LIMIT`] axod is ready whatever is still starting.
async fn launch_ready(core: Arc<Core>) {
    let mut catalog = core.catalog.subscribe();
    let waiting: Vec<SessionId> = catalog
        .borrow()
        .sessions
        .values()
        .filter(|entry| entry.pi.starting())
        .map(|entry| entry.record.id)
        .collect();
    log::info!("event=daemon.launch_waiting pis={}", waiting.len());
    let deadline = tokio::time::Instant::now() + LAUNCH_READY_LIMIT;
    let timed_out = loop {
        let still = {
            let view = catalog.borrow_and_update();
            waiting
                .iter()
                .filter(|id| {
                    view.sessions
                        .get(id)
                        .is_some_and(|entry| entry.pi.starting())
                })
                .count()
        };
        if still == 0 {
            break false;
        }
        tokio::select! {
            changed = catalog.changed() => if changed.is_err() { break false },
            () = tokio::time::sleep_until(deadline) => break true,
        }
    };
    core.ready.store(true, Ordering::Release);
    log::info!("event=daemon.launch_ready timed_out={timed_out}");
    core.events.publish(Event::DaemonReady);
}

/// Where a new Session starts: `folder`, the folder of the open Session `like`, or the home
/// directory. Canonical, so Sessions in one folder share one path.
fn new_session_folder(core: &Core, request: &rpc::CreateSession) -> io::Result<PathBuf> {
    let folder = match request {
        rpc::CreateSession::InFolder(folder) => folder.clone(),
        rpc::CreateSession::Like(like) => {
            core.catalog
                .record(*like)
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "that Session is not open"))?
                .folder
        }
        rpc::CreateSession::AtHome => core.home.clone(),
    };
    let folder = folder.canonicalize()?;
    if !folder.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "a Session's folder must be a directory",
        ));
    }
    Ok(folder)
}

/// Creates a Session with Pi beside a terminal, and returns it once its Pi has started.
pub(crate) async fn create(
    core: &Arc<Core>,
    request: rpc::CreateSession,
) -> io::Result<SessionRecord> {
    let folder = new_session_folder(core, &request)?;
    create_in(core, folder, None).await
}

/// Creates a Session in `folder` (canonical, an existing directory). Its transcript is
/// `<sessions>/<hostId>/<sessionId>.jsonl` (RFD0038); with `import`, a copy of that transcript.
async fn create_in(
    core: &Arc<Core>,
    folder: PathBuf,
    import: Option<PathBuf>,
) -> io::Result<SessionRecord> {
    if core.is_stopping() {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "Axod is shutting down",
        ));
    }
    let session_id = SessionId::new_v4()?;
    let session_uuid = session_id.to_string();
    let pane_id = new_uuid_v4()?;
    let split_id = new_uuid_v4()?;
    let transcript = core
        .pi_directories
        .transcripts
        .join(format!("{session_uuid}.jsonl"));
    let bridge_socket = BridgeSocketPath::for_session(&core.pi_directories.bridges, &session_uuid)?;
    if let Some(source) = import.clone() {
        let (destination, workspace) = (transcript.clone(), folder.clone());
        tokio::task::spawn_blocking(move || copy_pi_transcript(&source, &destination, &workspace))
            .await
            .map_err(io::Error::other)??;
    }
    let inserted = {
        let (folder, transcript, pane_id) = (folder.clone(), transcript.clone(), pane_id.clone());
        core.store
            .call(move |database| {
                let ordinal = axo_store::next_session_ordinal(database, &folder)?;
                axo_store::insert_new_session(
                    database,
                    &axo_store::NewSession {
                        session_id,
                        folder: &folder,
                        name: &format!("Session {ordinal}"),
                        pi_session_file: &transcript,
                        bridge_socket: &bridge_socket,
                        pane_id: &pane_id,
                        split_id: &split_id,
                    },
                )
            })
            .await
    };
    let inserted = match inserted {
        Ok(inserted) => inserted,
        Err(error) => {
            if import.is_some() {
                let _ = fs::remove_file(&transcript);
            }
            return Err(error);
        }
    };
    let stored = StoredSession {
        id: session_id,
        initial_pwd: folder,
        shell_ids: vec![
            (inserted.pi, PaneRole::Pi, Some(pane_id)),
            (inserted.terminal, PaneRole::Terminal, None),
        ],
    };
    let (waiter, started) = oneshot::channel();
    let handle = session::open(core, stored, PiStart::Now, Some(waiter)).await?;
    match wait_for_start(started).await {
        Ok(()) => {
            let record = handle.with(|session| session.record()).await?;
            log::info!("event=session.created session_id={session_id}");
            Ok(record)
        }
        Err(error) => {
            let _ = handle
                .call(|session| Box::pin(session.close("pi_spawn_failed")))
                .await;
            if import.is_some() {
                let _ = fs::remove_file(&transcript);
            }
            Err(error)
        }
    }
}

async fn wait_for_start(started: oneshot::Receiver<Result<(), String>>) -> io::Result<()> {
    match tokio::time::timeout(PI_START_WAIT, started).await {
        Ok(Ok(Ok(()))) => Ok(()),
        Ok(Ok(Err(message))) => Err(io::Error::other(message)),
        Ok(Err(_)) => Err(io::Error::other("the Session closed while Pi started")),
        Err(_) => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "Pi is still starting",
        )),
    }
}

pub(crate) fn copy_pi_transcript(
    source: &Path,
    destination: &Path,
    workspace: &Path,
) -> io::Result<()> {
    if !source.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Import path must be absolute",
        ));
    }
    let mut input = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(source)?;
    if !input.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Import source is not a regular file",
        ));
    }
    let mut reader = BufReader::new(&mut input);
    let mut header = String::new();
    if reader.read_line(&mut header)? == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Import source is empty",
        ));
    }
    let not_a_session = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Import source is not a Pi session",
        )
    };
    let mut header: serde_json::Value =
        serde_json::from_str(header.trim_end()).map_err(|_| not_a_session())?;
    if header["type"] != "session"
        || header["id"].as_str().is_none_or(str::is_empty)
        || header["cwd"].as_str().is_none_or(str::is_empty)
    {
        return Err(not_a_session());
    }
    header["cwd"] = serde_json::Value::String(workspace.to_string_lossy().into_owned());
    let mut output = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(destination)?;
    let result = (|| {
        output.write_all(header.to_string().as_bytes())?;
        output.write_all(b"\n")?;
        io::copy(&mut reader, &mut output)?;
        output.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(destination);
    }
    result
}

/// Whether the Pi `runtime_id` still runs for `session_id`.
async fn pi_is_current(core: &Core, session_id: SessionId, runtime_id: RuntimeId) -> bool {
    match core.registry.get(session_id) {
        Some(handle) => handle
            .with(move |session| session.pi_is_current(runtime_id))
            .await
            .unwrap_or(false),
        None => false,
    }
}

/// A Session task's own work that opens other Sessions: boxed, so its type does not depend on
/// the Session task that starts it.
pub(crate) type Spawned =
    std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send>>;

/// Imports a Pi transcript as a new Session in the folder of the Session whose Pi asked.
pub(crate) fn import(
    core: Arc<Core>,
    requester: SessionId,
    runtime_id: RuntimeId,
    folder: PathBuf,
    source: String,
) -> Spawned {
    Box::pin(async move { import_now(&core, requester, runtime_id, folder, &source).await })
}

async fn import_now(
    core: &Arc<Core>,
    requester: SessionId,
    runtime_id: RuntimeId,
    folder: PathBuf,
    source: &str,
) -> io::Result<()> {
    let source = PathBuf::from(source);
    if !source.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Import path is invalid",
        ));
    }
    if !pi_is_current(core, requester, runtime_id).await {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "Pi Session is no longer current",
        ));
    }
    let session = create_in(core, folder, Some(source)).await?;
    core.events.publish(Event::SessionFocus {
        session_id: session.id,
    });
    Ok(())
}

/// Pi's `/resume` picked a saved Session: its own, another open one, or an archived one, which
/// reopens. The Session whose Pi asked closes, and clients focus the one resumed.
pub(crate) fn resume(
    core: Arc<Core>,
    requester: SessionId,
    runtime_id: RuntimeId,
    requested: String,
) -> Spawned {
    Box::pin(async move { resume_now(&core, requester, runtime_id, &requested).await })
}

async fn resume_now(
    core: &Arc<Core>,
    requester: SessionId,
    runtime_id: RuntimeId,
    requested: &str,
) -> io::Result<()> {
    if requested.is_empty() || requested.len() > MAX_RESUME_PATH_BYTES || requested.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Pi session path is invalid",
        ));
    }
    let session_file = PathBuf::from(requested);
    if !session_file.exists() {
        // An archived Session's transcript may be in the cloud only (RFD0027).
        crate::relay_host::restore_transcript(
            core,
            crate::relay_host::TranscriptRequest::File(requested.to_owned()),
        )
        .await?;
    }
    let canonical_directory = fs::canonicalize(core.pi_directories.home_of(&session_file))?;
    let canonical_file = fs::canonicalize(&session_file)?;
    if !canonical_file.starts_with(&canonical_directory)
        || !fs::metadata(&canonical_file)?.is_file()
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Pi session is not an Axo-owned history file",
        ));
    }
    if !pi_is_current(core, requester, runtime_id).await {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Pi resume request came from a stale pane",
        ));
    }
    let requested = requested.to_owned();
    let canonical = canonical_file.to_string_lossy().into_owned();
    let owner = core
        .store
        .call(move |database| {
            let mut owners = axo_store::pi_history_owners(database, &requested)?;
            if owners.is_empty() {
                // A Pi started before its folder moved names the old path (RFD0022).
                owners = axo_store::pi_history_owners(database, &canonical)?;
            }
            match <[_; 1]>::try_from(owners) {
                Ok([owner]) => Ok(owner),
                Err(_) => Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "no unique Axo Session owns this Pi history",
                )),
            }
        })
        .await?;
    let target = owner.session_id;
    let handle = match owner.lifecycle {
        StoredLifecycle::Open => handle(core, target)?,
        StoredLifecycle::Archived => reopen_archived(core, &owner).await?,
    };
    // The resumed Session's Pi must be up before the one that asked goes.
    let (waiter, started) = oneshot::channel();
    handle
        .call(move |session| Box::pin(session.start_pi(Some(waiter))))
        .await?;
    wait_for_start(started).await.map_err(|error| {
        io::Error::new(
            io::ErrorKind::WouldBlock,
            format!("resumed Pi pane is not available: {error}"),
        )
    })?;
    if requester != target
        && let Some(requesting) = core.registry.get(requester)
    {
        requesting
            .call(move |session| {
                Box::pin(async move {
                    if session.pi_is_current(runtime_id) {
                        session.close("explicit_close").await;
                    }
                })
            })
            .await?;
    }
    core.request_focus(target);
    log::info!("event=session.pi_resume_completed session_id={target}");
    Ok(())
}

/// Reopens the Session a person most recently closed, as it was when it closed: Pi resumes its
/// history and terminals start fresh in its folder. One that can no longer be reopened (its
/// folder or history is gone) is skipped for the next most recent.
pub(crate) async fn reopen_closed(core: &Arc<Core>) -> io::Result<SessionRecord> {
    let candidates = core
        .store
        .call(|database| axo_store::recently_closed_sessions(database, REOPEN_CANDIDATES))
        .await?;
    let mut skipped = None;
    for owner in candidates {
        match reopen_archived(core, &owner).await {
            Ok(handle) => {
                log::info!("event=session.reopened session_id={}", owner.session_id);
                return handle.with(|session| session.record()).await;
            }
            Err(error) => {
                log::warn!(
                    "event=session.reopen_skipped session_id={} error_kind={:?} reason={error}",
                    owner.session_id,
                    error.kind()
                );
                skipped = Some(error);
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        match skipped {
            Some(error) => format!("no closed Session could be reopened: {error}"),
            None => "no closed Session to reopen".to_owned(),
        },
    ))
}

/// Marks an archived Session as reopening while it lives: its transcript is not deleted
/// meanwhile (RFD0027).
struct Reopening<'a> {
    core: &'a Core,
    session_id: SessionId,
}

impl<'a> Reopening<'a> {
    fn begin(core: &'a Core, session_id: SessionId) -> io::Result<Self> {
        if !lock(&core.reopening).insert(session_id) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "the Session is already being reopened",
            ));
        }
        Ok(Self { core, session_id })
    }
}

impl Drop for Reopening<'_> {
    fn drop(&mut self) {
        lock(&self.core.reopening).remove(&self.session_id);
    }
}

/// Reopens archived `owner` with the panes that closed with it, and returns once its Pi has
/// started or could not.
async fn reopen_archived(core: &Arc<Core>, owner: &PiHistoryOwner) -> io::Result<SessionHandle> {
    let session_id = owner.session_id;
    if !owner.initial_pwd.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "the Session's folder is unavailable",
        ));
    }
    let count = core
        .store
        .call(move |database| axo_store::archived_pi_pane_count(database, session_id))
        .await?;
    if count != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "archived Session does not have exactly one Pi pane",
        ));
    }
    let _reopening = Reopening::begin(core, session_id)?;
    // Its transcript may be in the cloud only (RFD0027): fetched back first.
    crate::relay_host::restore_transcript(
        core,
        crate::relay_host::TranscriptRequest::Session(session_id),
    )
    .await?;
    if core.is_stopping() {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "Axod is shutting down",
        ));
    }
    if core.registry.contains(session_id) {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "archived Session is still open",
        ));
    }
    let stored = core
        .store
        .call(move |database| {
            crate::relay_host::reopened_with_transcript(database, session_id)?;
            axo_store::reopen_archived_session(database, session_id)?;
            axo_store::read_open_sessions(database)?
                .into_iter()
                .find(|record| record.id == session_id)
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "resumed Session record is missing")
                })
        })
        .await?;
    let (waiter, started) = oneshot::channel();
    let handle = session::open(core, stored, PiStart::Now, Some(waiter)).await?;
    if let Err(error) = wait_for_start(started).await {
        log::warn!("event=session.pi_restore_unavailable session_id={session_id} reason={error}");
    }
    Ok(handle)
}

pub(crate) async fn close(core: &Core, session_id: SessionId) -> io::Result<()> {
    handle(core, session_id)?
        .call(|session| Box::pin(session.close("explicit_close")))
        .await
}

/// Records the latest client's viewport and sizes every pane no client is attached to.
pub(crate) async fn set_viewport(core: &Core, viewport: Viewport) -> io::Result<()> {
    if *core.viewport.borrow() == Some(viewport) {
        return Ok(());
    }
    core.store
        .call(move |database| axo_store::store_viewport(database, &viewport))
        .await?;
    core.viewport.send_replace(Some(viewport));
    for handle in core.registry.all() {
        handle.post(|session| session.fit_unattached_panes());
    }
    Ok(())
}

/// Sends a prompt to the Session's Pi: from an agent of another Session (`from_session_id`) or
/// from a person. A Pi still starting queues it; a dormant one starts for it.
pub(crate) async fn prompt(
    core: &Core,
    request: PromptSession,
    command_id: Option<CommandId>,
    attachments: Vec<FetchedAttachment>,
) -> Result<PromptAccepted, PromptError> {
    let PromptSession {
        session_id: target,
        text,
        delivery,
        from_session_id: from,
    } = request;
    let refused = |error: PromptError| {
        prompts::log_prompt(target, from, delivery, prompts::refusal(&error));
        error
    };
    prompts::check_prompt(&text, &attachments).map_err(refused)?;
    let handle = core
        .registry
        .get(target)
        .ok_or(PromptError::NoPi)
        .map_err(refused)?;
    // The receiving agent, and whoever reads its transcript, sees who sent the prompt.
    let text = match from {
        Some(from) => {
            let sender = core
                .catalog
                .record(from)
                .ok_or(PromptError::Invalid("the sending Session is not open"))
                .map_err(refused)?;
            let name = sender.manual_name.unwrap_or(sender.name);
            lock(&core.provenance)
                .admit(from, from == target, Instant::now())
                .map_err(refused)?;
            format!("[From Axo Session {from} {name:?}]\n\n{}", text.as_str())
        }
        None => text.into_string(),
    };
    let prompt = Prompt {
        text,
        delivery,
        command_id,
        attachments,
    };
    let queued = prompt.clone();
    let admission = handle
        .call(move |session| Box::pin(session.admit_prompt(queued)))
        .await
        .map_err(|_| PromptError::NoPi)
        .and_then(|admitted| admitted)
        .map_err(refused)?;
    match admission {
        Admission::Queued => {
            prompts::log_prompt(target, from, delivery, "queued");
            Ok(PromptAccepted {
                accepted: true,
                queued: true,
            })
        }
        Admission::Send(link) => {
            let sent = prompts::send(&link, &prompt).await;
            prompts::log_prompt(
                target,
                from,
                delivery,
                sent.as_ref()
                    .map_or_else(prompts::refusal, |()| "delivered"),
            );
            sent?;
            Ok(PromptAccepted {
                accepted: true,
                queued: false,
            })
        }
    }
}

/// A person away from the Mac prompts the Session's Pi with their `command_id`: pi-axo takes it
/// once (RFD0024, RFD0033). This returns once Pi has it in its log, so a Pi still starting is
/// waited for, briefly; nothing a client was told is accepted waits only in axod's memory.
pub(crate) async fn prompt_from_client(
    core: &Core,
    session_id: SessionId,
    text: PromptText,
    command_id: CommandId,
    attachments: Vec<FetchedAttachment>,
    delivery: PromptDelivery,
) -> io::Result<()> {
    prompts::check_prompt(&text, &attachments)?;
    let handle = handle(core, session_id)?;
    handle
        .call(|session| Box::pin(async move { session.wake(None).await }))
        .await?;
    wait_for_pi(core, session_id, CLIENT_PROMPT_START_WAIT).await?;
    let accepted = prompt(
        core,
        PromptSession {
            session_id,
            text,
            delivery,
            from_session_id: None,
        },
        Some(command_id),
        attachments,
    )
    .await
    .map_err(io::Error::from)?;
    if accepted.queued {
        // Pi's bridge dropped after the wait: what was queued here goes when it binds again,
        // and the client, told to try again, sends the same commandId, which Pi takes once.
        return Err(prompts::still_starting());
    }
    Ok(())
}

/// Waits up to `timeout` for the Session's Pi to bind its bridge: `NotFound` if it has no Pi
/// that runs or is starting, `TimedOut` if it is still starting, `Interrupted` if the request
/// is cancelled. It waits on the catalog; nothing polls.
pub(crate) async fn wait_for_pi(core: &Core, id: SessionId, timeout: Duration) -> io::Result<()> {
    let mut catalog = core.catalog.subscribe();
    let cancellation = axo_ipc::cancel::current();
    let cancelled = || {
        io::Error::new(
            io::ErrorKind::Interrupted,
            "the prompt was cancelled while Pi started",
        )
    };
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if cancellation.is_cancelled() {
            return Err(cancelled());
        }
        match catalog
            .borrow_and_update()
            .sessions
            .get(&id)
            .map(|entry| entry.pi)
        {
            Some(PiPhase::Connected) => return Ok(()),
            Some(phase) if phase.starting() => {}
            _ => return Err(PromptError::NoPi.into()),
        }
        tokio::select! {
            changed = catalog.changed() => if changed.is_err() { return Err(PromptError::NoPi.into()) },
            () = tokio::time::sleep_until(deadline) => return Err(prompts::still_starting()),
            () = cancellation.cancelled() => return Err(cancelled()),
        }
    }
}

/// Writes down this axod's version and the Sessions whose Pi is mid-turn, most recently active
/// first, for the next axod to restore first and tell.
async fn record_stop(core: &Core) {
    let mut interrupted: Vec<(SessionId, i64)> = core
        .catalog
        .view()
        .sessions
        .values()
        .filter(|entry| entry.pi == PiPhase::Connected && entry.working)
        .map(|entry| (entry.record.id, entry.record.last_message_at.unwrap_or(0)))
        .collect();
    interrupted.sort_by(|left, right| right.1.cmp(&left.1).then(left.0.cmp(&right.0)));
    let stop = stop_notice::this_daemon(interrupted.into_iter().map(|(id, _)| id).collect());
    let count = stop.interrupted.len();
    let stored = stop.to_stored();
    match core
        .store
        .call(move |database| axo_store::store_daemon_stop(database, &stored))
        .await
    {
        Ok(()) => log::info!("event=daemon.stop_recorded interrupted={count}"),
        Err(error) => log::warn!("event=daemon.stop_record_failed reason={error}"),
    }
}

/// Stops every Session's panes and every remote pane, as axod stops.
pub(crate) async fn stop(core: &Core) {
    if core.stopping.swap(true, Ordering::AcqRel) {
        return;
    }
    // First, before anything slow: launchd kills an axod that takes too long to stop.
    record_stop(core).await;
    let mut stopping = tokio::task::JoinSet::new();
    for handle in core.registry.all() {
        stopping.spawn(async move {
            let _ = handle.call(|session| Box::pin(session.shut_down())).await;
        });
    }
    let peers = core.peers.stop_all();
    let all = async {
        while stopping.join_next().await.is_some() {}
        peers.await;
    };
    if tokio::time::timeout(STOP_WAIT, all).await.is_err() {
        log::warn!("event=daemon.stop_slow");
    }
}

/// The record the previous axod left of how it stopped, if it left one that reads.
pub(crate) fn take_previous_stop(
    database: &axo_store::Connection,
) -> io::Result<Option<DaemonStop>> {
    let Some(stored) = axo_store::take_daemon_stop(database)? else {
        return Ok(None);
    };
    match DaemonStop::parse(&stored) {
        Ok(stop) => Ok(Some(stop)),
        Err(error) => {
            log::warn!("event=daemon.stop_record_invalid reason={error}");
            Ok(None)
        }
    }
}
