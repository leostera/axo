//! Other Macs' Sessions on this one (RFD0024): the list this Mac follows, a pane per Session a
//! person opens here, and the way that pane follows the copy and sends what is typed.
//!
//! A remote pane runs `pi --no-session` with pi-axo in remote mode. It is not a Session of this
//! Mac: it has no row in `axo.db`, is never listed by `axo.session.list` or uploaded, and its
//! shell id comes from a range the database never reaches, so it can never be mistaken for one
//! of this Mac's panes. Only the Mac that runs a Session writes its log; a remote pane learns
//! what a command did from the copy, never from the reply.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use axo_protocol::rpc::{
    self, PeerHost, PeerProgress, PeerRecord, PeerSession, PeerSessionList, PeerSessionView,
};
use axo_protocol::{Event, PaneRole, SessionId, SessionRecord, SessionStatus, ShellId};
use axo_pty::WindowSize;
use axo_relay::peers::{PeerCommandError, PeerIndex, PeerLive, Place, read_copy};
use serde_json::Value;

use crate::core::{Core, lock};
use crate::session::panes::{Running, RuntimeId, pi_environment, window_size};
use crate::terminal_input::TerminalInput;

/// Shell ids of remote panes start here; the database's AUTOINCREMENT ids never get near it.
const FIRST_VIEW_SHELL: i64 = 1 << 48;
/// How long a command waits for the other Mac before its outcome is unknown.
const COMMAND_TIMEOUT: Duration = Duration::from_secs(30);
/// Records a pane is given at once when it starts over, newest last.
const DEFAULT_WINDOW: usize = 400;
/// Records in one answer; the pane asks again at once for the rest.
const MAX_RECORDS_PER_VIEW: usize = 500;
/// The commands a remote pane may send: what a person at that Mac could type or press.
const PEER_COMMANDS: &[&str] = &[
    "axo.remote.session.prompt",
    "axo.remote.session.stop",
    "axo.remote.session.key",
];

/// How this Mac follows the others, once the relay has started.
pub(crate) struct PeerAccess {
    pub(crate) live: Arc<PeerLive>,
    pub(crate) index: PathBuf,
}

impl PeerAccess {
    fn read_index(&self) -> PeerIndex {
        std::fs::read(&self.index)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }
}

#[derive(Default)]
pub(crate) struct Peers {
    access: OnceLock<PeerAccess>,
    views: Mutex<Views>,
}

#[derive(Default)]
struct Views {
    by_session: HashMap<SessionId, PeerView>,
    next_shell: i64,
}

struct PeerView {
    host_id: String,
    shell_id: ShellId,
    running: Running,
}

/// A listed Session of another Mac, as the index holds it.
struct Listed<'a> {
    host_id: &'a str,
    session_id: SessionId,
    value: &'a Value,
}

/// The other Macs' open Sessions: what the sidebar lists.
fn listed_sessions(index: &PeerIndex) -> impl Iterator<Item = Listed<'_>> {
    known_sessions(index)
        .filter(|listed| listed.value["metadata"]["archived"].as_bool() != Some(true))
}

/// Every Session of the other Macs, archived ones too: a pane may show one (its copy is fetched
/// for the pane), or show one that gets archived.
fn known_sessions(index: &PeerIndex) -> impl Iterator<Item = Listed<'_>> {
    index.sessions.iter().filter_map(|value| {
        Some(Listed {
            host_id: value["hostId"].as_str()?,
            session_id: value["sessionId"].as_str()?.parse().ok()?,
            value,
        })
    })
}

fn place_of(listed: &Listed<'_>) -> Option<Place> {
    Place::of(listed.host_id, &listed.session_id.to_string())
}

fn host_of(index: &PeerIndex, host_id: &str) -> Option<PeerHost> {
    index
        .hosts
        .iter()
        .find(|host| host["hostId"].as_str() == Some(host_id))
        .map(|host| PeerHost {
            host_id: host_id.to_owned(),
            label: host["label"].as_str().unwrap_or("Mac").to_owned(),
            online: host["online"].as_bool().unwrap_or(false),
        })
}

fn status_of(value: &Value) -> Option<SessionStatus> {
    serde_json::from_value(value["status"].clone()).ok()
}

/// Where a remote pane starts: the Session's folder if this Mac has it too, else home.
fn view_directory(value: &Value, home: &Path) -> PathBuf {
    value["metadata"]["workspaceState"]["path"]
        .as_str()
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && path.is_dir())
        .unwrap_or_else(|| home.to_path_buf())
}

fn not_found(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, what.to_owned())
}

impl Peers {
    /// Follows the other Macs through the relay's peers socket: lists their Sessions, and tells
    /// clients when that list changes.
    pub(crate) fn attach(core: &Arc<Core>, live: Arc<PeerLive>, index: PathBuf) {
        let weak = Arc::downgrade(core);
        live.observe_listing(move || {
            if let Some(core) = weak.upgrade() {
                core.events.publish(Event::PeerSessionsChanged);
            }
        });
        let _ = core.peers.access.set(PeerAccess { live, index });
    }

    pub(crate) fn access(&self) -> io::Result<&PeerAccess> {
        self.access
            .get()
            .ok_or_else(|| not_found("this Mac does not follow the account's other Macs"))
    }

    pub(crate) fn list(&self, core: &Core) -> io::Result<PeerSessionList> {
        let Ok(access) = self.access() else {
            return Ok(PeerSessionList {
                connected: false,
                hosts: Vec::new(),
                sessions: Vec::new(),
            });
        };
        let index = access.read_index();
        let views = lock(&self.views);
        let sessions = listed_sessions(&index)
            .filter(|listed| listed.host_id != core.host_id)
            .map(|listed| record(core, &views, &listed))
            .collect();
        let hosts = index
            .hosts
            .iter()
            .filter_map(|host| host["hostId"].as_str())
            .filter(|host_id| *host_id != core.host_id)
            .filter_map(|host_id| host_of(&index, host_id))
            .collect();
        Ok(PeerSessionList {
            connected: access.live.is_connected(),
            hosts,
            sessions,
        })
    }

    /// Opens a pane on another Mac's Session here, or returns the one already open.
    pub(crate) fn open(
        core: &Arc<Core>,
        host_id: &str,
        session_id: SessionId,
    ) -> io::Result<PeerSession> {
        let peers = &core.peers;
        let access = peers.access()?;
        let index = access.read_index();
        let listed = known_sessions(&index)
            .find(|listed| listed.host_id == host_id && listed.session_id == session_id)
            .ok_or_else(|| not_found("that Session is not listed"))?;
        let label = host_of(&index, host_id).map_or_else(|| "Mac".to_owned(), |host| host.label);
        // An archived Session has no copy here until a pane shows it: the peers socket fetches it.
        access.live.want(&session_id.to_string());
        {
            let mut views = lock(&peers.views);
            if !views.by_session.contains_key(&session_id) {
                let directory = view_directory(listed.value, &core.home);
                let environment = pi_environment(&core.agent_socket);
                // The whole terminal area: a remote pane is shown alone.
                let size = core
                    .viewport
                    .borrow()
                    .map_or(WindowSize::DEFAULT, |viewport| {
                        window_size(viewport.full_grid())
                    });
                let session = session_id.to_string();
                let agent_command = core.settings().agent_command;
                let pty = axo_agent::pi::spawn_remote_view(
                    &axo_agent::pi::RemoteViewLaunch {
                        agent_command: &agent_command,
                        initial_pwd: &directory,
                        home: &core.home,
                        host_id,
                        host_label: &label,
                        session_id: &session,
                        environment: &environment,
                        lifeline: &core.lifeline,
                    },
                    size,
                )?;
                let running = Running::new(PaneRole::Pi, None, directory, pty, None)?;
                let shell_id = ShellId::new(FIRST_VIEW_SHELL + views.next_shell)
                    .expect("remote pane shell ids are positive");
                views.next_shell += 1;
                let runtime_id = running.runtime_id;
                let weak = Arc::downgrade(core);
                let runtime = tokio::runtime::Handle::current();
                // The exit may be heard at once, here, with the views locked: handled apart.
                running.bind(core, session_id, shell_id, move || {
                    runtime.spawn(async move {
                        if let Some(core) = weak.upgrade() {
                            Peers::exited(&core, session_id, runtime_id);
                        }
                    });
                });
                log::info!(
                    "event=peer.view_opened session_id={session_id} host_id={host_id} shell_id={}",
                    shell_id.get()
                );
                views.by_session.insert(
                    session_id,
                    PeerView {
                        host_id: host_id.to_owned(),
                        shell_id,
                        running,
                    },
                );
            }
        }
        core.events.publish(Event::PeerSessionsChanged);
        Ok(record(core, &lock(&peers.views), &listed))
    }

    /// Stops the remote pane on a Session, if one is open.
    pub(crate) fn close(core: &Core, session_id: SessionId) -> bool {
        let view = lock(&core.peers.views).by_session.remove(&session_id);
        let Some(view) = view else {
            return false;
        };
        log::info!(
            "event=peer.view_closed session_id={session_id} host_id={}",
            view.host_id
        );
        if let Ok(access) = core.peers.access() {
            access.live.unwant(&session_id.to_string());
        }
        tokio::spawn(view.running.stop());
        core.events.publish(Event::PeerSessionsChanged);
        true
    }

    /// A remote pane whose Pi exited is gone.
    fn exited(core: &Arc<Core>, session_id: SessionId, runtime_id: RuntimeId) {
        let mut views = lock(&core.peers.views);
        if views
            .by_session
            .get(&session_id)
            .is_none_or(|view| view.running.runtime_id != runtime_id)
        {
            return;
        }
        let view = views.by_session.remove(&session_id);
        drop(views);
        log::info!("event=peer.view_exited session_id={session_id}");
        if let Ok(access) = core.peers.access() {
            access.live.unwant(&session_id.to_string());
        }
        if let Some(view) = view {
            tokio::spawn(view.running.stop());
        }
        core.events.publish(Event::PeerSessionsChanged);
    }

    /// Stops every remote pane, as axod stops.
    pub(crate) async fn stop_all(&self) {
        let views: Vec<PeerView> = lock(&self.views)
            .by_session
            .drain()
            .map(|(_, v)| v)
            .collect();
        let mut stopping = tokio::task::JoinSet::new();
        for view in views {
            stopping.spawn(view.running.stop());
        }
        while stopping.join_next().await.is_some() {}
    }

    /// Runs `read` on the remote pane `shell_id` of `session_id`, if it is one.
    pub(crate) fn with_pane<T>(
        &self,
        session_id: Option<SessionId>,
        shell_id: ShellId,
        read: impl FnOnce(SessionId, &mut Running) -> T,
    ) -> Option<T> {
        let mut views = lock(&self.views);
        views
            .by_session
            .iter_mut()
            .find(|(id, view)| {
                view.shell_id == shell_id && session_id.is_none_or(|expected| expected == **id)
            })
            .map(|(id, view)| read(*id, &mut view.running))
    }

    pub(crate) fn input(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> Option<Arc<TerminalInput>> {
        self.with_pane(Some(session_id), shell_id, |_, running| {
            Arc::clone(&running.input)
        })
    }

    /// The copy and live state a remote pane shows, once something has changed since what it
    /// has (or at once the first time, or after `timeout`). Blocks; run it on the blocking pool.
    pub(crate) fn watch(
        &self,
        core: &Core,
        request: &rpc::WatchPeerSession,
    ) -> io::Result<PeerSessionView> {
        let access = self.access()?;
        let timeout = Duration::from_millis(
            request
                .timeout_ms
                .unwrap_or(rpc::MAX_WAIT_MS)
                .min(rpc::MAX_WAIT_MS),
        );
        let version = if request.version == 0 {
            access.live.version()
        } else {
            access.live.wait_for_change(request.version, timeout)
        };
        let index = access.read_index();
        let session_id = request.session_id.to_string();
        let listed = known_sessions(&index).find(|listed| {
            listed.host_id == request.host_id && listed.session_id == request.session_id
        });
        let host = host_of(&index, &request.host_id);
        let copy = match listed.as_ref().and_then(place_of) {
            Some(place) => {
                let window = request.window.unwrap_or(DEFAULT_WINDOW);
                // Read from the pane's cursor when it is in this copy, else start over.
                let continuing =
                    read_copy(&core.sessions_directory, &place, 0, 0)?.is_some_and(|copy| {
                        Some(copy.state.epoch) == request.epoch
                            && request.cursor <= copy.state.cursor
                    });
                let (after, limit) = if continuing {
                    (request.cursor, usize::MAX)
                } else {
                    (0, window)
                };
                read_copy(&core.sessions_directory, &place, after, limit)?
                    .map(|copy| (continuing, copy))
            }
            None => None,
        };
        let (reset, epoch, cursor, records, more) = match copy {
            Some((continuing, copy)) => {
                let more = copy.records.len() > MAX_RECORDS_PER_VIEW;
                let records: Vec<PeerRecord> = copy
                    .records
                    .into_iter()
                    .take(MAX_RECORDS_PER_VIEW)
                    .map(|(cursor, line)| PeerRecord { cursor, line })
                    .collect();
                let cursor = records
                    .last()
                    .map_or(if continuing { request.cursor } else { 0 }, |record| {
                        record.cursor
                    });
                (!continuing, Some(copy.state.epoch), cursor, records, more)
            }
            // No copy yet: nothing to draw, and nothing drawn stays.
            None => (request.epoch.is_some(), None, 0, Vec::new(), false),
        };
        Ok(PeerSessionView {
            version,
            epoch,
            cursor,
            reset,
            records,
            more,
            progress: access
                .live
                .progress(&session_id)
                .into_iter()
                .map(|(slot, snapshot)| PeerProgress { slot, snapshot })
                .collect(),
            status: listed.as_ref().and_then(|listed| status_of(listed.value)),
            host_label: host
                .as_ref()
                .map_or_else(|| "Mac".to_owned(), |host| host.label.clone()),
            host_online: host.is_some_and(|host| host.online),
            connected: access.live.is_connected(),
        })
    }

    /// Sends a remote pane's command to the Mac its Session runs on. Blocks; run it on the
    /// blocking pool.
    pub(crate) fn command(&self, request: rpc::PeerCommand) -> Result<Value, PeerCommandError> {
        if !PEER_COMMANDS.contains(&request.method.as_str()) {
            return Err(PeerCommandError {
                code: -32602,
                message: format!("{} cannot be sent to another Mac", request.method),
            });
        }
        let access = self.access().map_err(|_| PeerCommandError::offline())?;
        access.live.command(
            &request.host_id,
            &request.method,
            Value::Object(request.params),
            COMMAND_TIMEOUT,
        )
    }
}

fn record(core: &Core, views: &Views, listed: &Listed<'_>) -> PeerSession {
    let metadata = &listed.value["metadata"];
    let view = views.by_session.get(&listed.session_id);
    let shells = view
        .map(|view| vec![view.running.record(view.shell_id, &core.attach_socket_path)])
        .unwrap_or_default();
    let copy = place_of(listed).map(|place| {
        core.sessions_directory
            .join(&place.host_id)
            .join(format!("{}.jsonl", place.session_id))
    });
    PeerSession {
        host_id: listed.host_id.to_owned(),
        session: SessionRecord {
            id: listed.session_id,
            pi_session_file: copy.filter(|path| path.is_file()),
            pi_session_id: None,
            name: metadata["name"].as_str().unwrap_or("Session").to_owned(),
            manual_name: None,
            emoji: metadata["emoji"].as_str().map(str::to_owned),
            last_message_at: metadata["lastMessageAt"].as_i64(),
            created_at: metadata["createdAt"].as_i64().unwrap_or(0),
            status: status_of(listed.value).unwrap_or(SessionStatus::Ready),
            folder: view.map_or_else(
                || view_directory(listed.value, &core.home),
                |view| view.running.initial_pwd.clone(),
            ),
            shells,
            layout: None,
            pi: None,
        },
    }
}
