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
use std::sync::{Arc, OnceLock, Weak};
use std::time::Duration;

use super::catalog::running_shell_record;
use super::spawn::pi_environment;
use super::{RunningShell, SessionManager, SessionState, stop_panes};
use axo_panes::RuntimeId;
use axo_protocol::rpc::{
    self, PeerHost, PeerProgress, PeerRecord, PeerSession, PeerSessionList, PeerSessionView,
};
use axo_protocol::{Event, PaneRole, SessionId, SessionRecord, SessionStatus, ShellId};
use axo_pty::WindowSize;
use axo_relay::peers::{PeerCommandError, PeerIndex, PeerLive, Place, read_copy};
use serde_json::Value;

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
pub(super) struct PeerAccess {
    live: Arc<PeerLive>,
    index: PathBuf,
    sessions_directory: PathBuf,
}

/// The remote panes open on this Mac, by the Session they show.
#[derive(Default)]
pub(super) struct PeerViews {
    views: HashMap<SessionId, PeerView>,
    next_shell: i64,
}

struct PeerView {
    host_id: String,
    shell_id: ShellId,
    running: RunningShell,
}

impl PeerViews {
    fn next_shell_id(&mut self) -> ShellId {
        let id = FIRST_VIEW_SHELL + self.next_shell;
        self.next_shell += 1;
        ShellId::new(id).expect("remote pane shell ids are positive")
    }

    pub(super) fn running_mut(&mut self, shell_id: ShellId) -> Option<&mut RunningShell> {
        self.views
            .values_mut()
            .find(|view| view.shell_id == shell_id)
            .map(|view| &mut view.running)
    }

    pub(super) fn running_in(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> Option<&RunningShell> {
        self.views
            .get(&session_id)
            .filter(|view| view.shell_id == shell_id)
            .map(|view| &view.running)
    }

    pub(super) fn running_in_mut(
        &mut self,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> Option<&mut RunningShell> {
        self.views
            .get_mut(&session_id)
            .filter(|view| view.shell_id == shell_id)
            .map(|view| &mut view.running)
    }

    /// The panes whose Pi has exited, taken out.
    fn take_exited(&mut self) -> Vec<(SessionId, RunningShell)> {
        let exited: Vec<SessionId> = self
            .views
            .iter_mut()
            .filter_map(|(session_id, view)| {
                matches!(view.running.child.try_wait(), Ok(Some(_))).then_some(*session_id)
            })
            .collect();
        exited
            .into_iter()
            .filter_map(|session_id| {
                self.views
                    .remove(&session_id)
                    .map(|view| (session_id, view.running))
            })
            .collect()
    }

    pub(super) fn drain(&mut self) -> Vec<RunningShell> {
        self.views.drain().map(|(_, view)| view.running).collect()
    }
}

/// A listed Session of another Mac, as the index holds it.
struct Listed<'a> {
    host_id: &'a str,
    session_id: SessionId,
    value: &'a Value,
}

fn listed_sessions(index: &PeerIndex) -> impl Iterator<Item = Listed<'_>> {
    index.sessions.iter().filter_map(|value| {
        if value["metadata"]["archived"].as_bool() == Some(true) {
            return None;
        }
        Some(Listed {
            host_id: value["hostId"].as_str()?,
            session_id: value["sessionId"].as_str()?.parse().ok()?,
            value,
        })
    })
}

fn place_of(listed: &Listed<'_>) -> Option<Place> {
    Place::of(
        listed.host_id,
        listed.value["metadata"]["workspaceId"].as_str(),
        &listed.session_id.to_string(),
    )
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

impl PeerAccess {
    fn read_index(&self) -> PeerIndex {
        std::fs::read(&self.index)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }
}

/// Set once by `attach_peers`; until then there are no other Macs to show.
pub(super) type PeerSlot = OnceLock<PeerAccess>;

impl SessionManager {
    /// Follows the other Macs through the relay's peers socket: lists their Sessions, and tells
    /// clients when that list changes.
    pub fn attach_peers(self: &Arc<Self>, live: Arc<PeerLive>, index: PathBuf) {
        let manager: Weak<Self> = Arc::downgrade(self);
        live.observe_listing(move || {
            if let Some(manager) = manager.upgrade() {
                manager.publish_event(Event::PeerSessionsChanged);
            }
        });
        let _ = self.peers.set(PeerAccess {
            live,
            index,
            sessions_directory: self.sessions_directory.clone(),
        });
    }

    fn peer_access(&self) -> io::Result<&PeerAccess> {
        self.peers
            .get()
            .ok_or_else(|| not_found("this Mac does not follow the account's other Macs"))
    }

    pub(super) fn peer_sessions(&self) -> io::Result<PeerSessionList> {
        let Ok(access) = self.peer_access() else {
            return Ok(PeerSessionList {
                connected: false,
                hosts: Vec::new(),
                sessions: Vec::new(),
            });
        };
        let index = access.read_index();
        let home = crate::current_user_home_directory()?;
        let state = self.lock_state()?;
        let sessions = listed_sessions(&index)
            .filter(|listed| listed.host_id != self.host_id)
            .map(|listed| self.peer_record(&state, &access.sessions_directory, &listed, &home))
            .collect();
        let hosts = index
            .hosts
            .iter()
            .filter_map(|host| host["hostId"].as_str())
            .filter(|host_id| *host_id != self.host_id)
            .filter_map(|host_id| host_of(&index, host_id))
            .collect();
        Ok(PeerSessionList {
            connected: access.live.is_connected(),
            hosts,
            sessions,
        })
    }

    fn peer_record(
        &self,
        state: &SessionState,
        sessions_directory: &Path,
        listed: &Listed<'_>,
        home: &Path,
    ) -> PeerSession {
        let metadata = &listed.value["metadata"];
        let view = state.peer_views.views.get(&listed.session_id);
        let shells = view
            .map(|view| {
                vec![running_shell_record(
                    view.shell_id,
                    &view.running,
                    &self.attach_socket_path,
                )]
            })
            .unwrap_or_default();
        let copy = place_of(listed).map(|place| {
            sessions_directory
                .join(&place.host_id)
                .join(&place.workspace)
                .join(format!("{}.jsonl", place.session_id))
        });
        PeerSession {
            host_id: listed.host_id.to_owned(),
            session: SessionRecord {
                id: listed.session_id,
                pi_session_file: copy.filter(|path| path.is_file()),
                pi_session_id: None,
                workspace_id: metadata["workspaceId"].as_str().map(str::to_owned),
                workspace_name: metadata["workspaceName"].as_str().map(str::to_owned),
                name: metadata["name"].as_str().unwrap_or("Session").to_owned(),
                manual_name: None,
                emoji: metadata["emoji"].as_str().map(str::to_owned),
                last_message_at: metadata["lastMessageAt"].as_i64(),
                created_at: metadata["createdAt"].as_i64().unwrap_or(0),
                status: status_of(listed.value).unwrap_or(SessionStatus::Ready),
                initial_pwd: view.map_or_else(
                    || view_directory(listed.value, home),
                    |view| view.running.initial_pwd.clone(),
                ),
                shells,
                layout: None,
            },
        }
    }

    /// Opens a pane on another Mac's Session here, or returns the one already open.
    pub(super) fn open_peer_session(
        self: &Arc<Self>,
        host_id: &str,
        session_id: SessionId,
    ) -> io::Result<PeerSession> {
        let access = self.peer_access()?;
        let index = access.read_index();
        let listed = listed_sessions(&index)
            .find(|listed| listed.host_id == host_id && listed.session_id == session_id)
            .ok_or_else(|| not_found("that Session is not listed"))?;
        let label = host_of(&index, host_id).map_or_else(|| "Mac".to_owned(), |host| host.label);
        let home = crate::current_user_home_directory()?;
        {
            let mut state = self.lock_state()?;
            if !state.peer_views.views.contains_key(&session_id) {
                let directory = view_directory(listed.value, &home);
                let environment = pi_environment();
                // The whole terminal area: a remote pane is shown alone.
                let size = state.viewport.map_or(WindowSize::DEFAULT, |viewport| {
                    super::terminal::window_size(viewport.full_grid())
                });
                let session = session_id.to_string();
                let pty = axo_pi::spawn_remote_view(
                    &axo_pi::RemoteViewLaunch {
                        agent_command: &state.agent_command,
                        initial_pwd: &directory,
                        home: &home,
                        host_id,
                        host_label: &label,
                        session_id: &session,
                        environment: &environment,
                    },
                    size,
                )?;
                let shell_id = state.peer_views.next_shell_id();
                let running = RunningShell {
                    runtime_id: RuntimeId::next(),
                    session_id,
                    role: PaneRole::Pi,
                    pane_id: None,
                    initial_pwd: directory,
                    child: pty.child,
                    wait_error_reported: false,
                    master: pty.master,
                    slave_device: pty.device,
                    attachments: 0,
                    output: pty.output,
                    last_input_sequence: None,
                    _writer_lock: None,
                    pi_bridge_socket: None,
                    pi_bridge_token: None,
                    pi_commands: None,
                };
                state.bind_output(shell_id, &running);
                log::info!(
                    "event=peer.view_opened session_id={session_id} host_id={host_id} shell_id={}",
                    shell_id.get()
                );
                state.peer_views.views.insert(
                    session_id,
                    PeerView {
                        host_id: host_id.to_owned(),
                        shell_id,
                        running,
                    },
                );
            }
        }
        self.publish_event(Event::PeerSessionsChanged);
        let state = self.lock_state()?;
        Ok(self.peer_record(&state, &access.sessions_directory, &listed, &home))
    }

    /// Stops the remote pane on a Session, if one is open.
    pub(super) fn close_peer_session(&self, session_id: SessionId) -> io::Result<bool> {
        let view = self.lock_state()?.peer_views.views.remove(&session_id);
        let Some(view) = view else {
            return Ok(false);
        };
        log::info!(
            "event=peer.view_closed session_id={session_id} host_id={}",
            view.host_id
        );
        stop_panes(vec![view.running]);
        self.publish_event(Event::PeerSessionsChanged);
        Ok(true)
    }

    /// Called by the reaper: a remote pane whose Pi exited is gone.
    pub(super) fn reap_exited_peer_views(&self) -> io::Result<()> {
        let exited = self.lock_state()?.peer_views.take_exited();
        if exited.is_empty() {
            return Ok(());
        }
        for (session_id, _) in &exited {
            log::info!("event=peer.view_exited session_id={session_id}");
        }
        stop_panes(exited.into_iter().map(|(_, running)| running).collect());
        self.publish_event(Event::PeerSessionsChanged);
        Ok(())
    }

    /// The copy and live state a remote pane shows, once something has changed since what it
    /// has (or at once the first time, or after `timeout`).
    pub(super) fn watch_peer_session(
        &self,
        request: &rpc::WatchPeerSession,
    ) -> io::Result<PeerSessionView> {
        let access = self.peer_access()?;
        let timeout = Duration::from_millis(
            request
                .timeout_ms
                .unwrap_or(rpc::MAX_EVENTS_TIMEOUT_MS)
                .min(rpc::MAX_EVENTS_TIMEOUT_MS),
        );
        let version = if request.version == 0 {
            access.live.version()
        } else {
            access.live.wait_for_change(request.version, timeout)
        };
        let index = access.read_index();
        let session_id = request.session_id.to_string();
        let listed = listed_sessions(&index).find(|listed| {
            listed.host_id == request.host_id && listed.session_id == request.session_id
        });
        let host = host_of(&index, &request.host_id);
        let copy = match listed.as_ref().and_then(place_of) {
            Some(place) => {
                let window = request.window.unwrap_or(DEFAULT_WINDOW);
                // Read from the pane's cursor when it is in this copy, else start over.
                let continuing =
                    read_copy(&access.sessions_directory, &place, 0, 0)?.is_some_and(|copy| {
                        Some(copy.state.epoch) == request.epoch
                            && request.cursor <= copy.state.cursor
                    });
                let (after, limit) = if continuing {
                    (request.cursor, usize::MAX)
                } else {
                    (0, window)
                };
                read_copy(&access.sessions_directory, &place, after, limit)?
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

    /// Sends a remote pane's command to the Mac its Session runs on.
    pub(super) fn peer_command(
        &self,
        request: rpc::PeerCommand,
    ) -> Result<Value, PeerCommandError> {
        if !PEER_COMMANDS.contains(&request.method.as_str()) {
            return Err(PeerCommandError {
                code: -32602,
                message: format!("{} cannot be sent to another Mac", request.method),
            });
        }
        let access = self
            .peer_access()
            .map_err(|_| PeerCommandError::offline())?;
        access.live.command(
            &request.host_id,
            &request.method,
            Value::Object(request.params),
            COMMAND_TIMEOUT,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::test_support::LifecycleFixture;
    use axo_pi::AgentCommand;
    use axo_relay::peers::{ClientRecord, Mirror};
    use serde_json::json;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    const STUDIO: &str = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7";
    const SESSION: &str = "8f8f8f8f-0000-4000-8000-000000000001";
    const ARCHIVED: &str = "8f8f8f8f-0000-4000-8000-000000000002";
    const HEADER: &str = r#"{"type":"session","version":3,"id":"8f8f8f8f-0000-4000-8000-000000000001","cwd":"/tmp"}"#;

    struct Peers {
        fixture: LifecycleFixture,
        live: Arc<PeerLive>,
    }

    /// A Mac that follows a Studio with one Session, one archived Session, and a listing of
    /// one of its own Sessions (which the cloud should not send, and which is never shown).
    fn peers() -> Peers {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let index = fixture.directory.join("peers.json");
        let session = |id: &str, host: &str, archived: bool| {
            json!({
                "hostId": host, "sessionId": id, "epoch": 1, "head": 2, "status": "working",
                "metadata": {
                    "name": "Fix the bug", "emoji": "🐛", "workspaceId": null, "workspaceName": null,
                    "hasAgent": true, "createdAt": 10, "lastMessageAt": 20, "archived": archived,
                },
            })
        };
        let listing = json!({
            "hosts": [{ "hostId": STUDIO, "hostGeneration": "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230", "label": "Mac Studio", "online": true }],
            "sessions": [
                session(SESSION, STUDIO, false),
                session(ARCHIVED, STUDIO, true),
                session("8f8f8f8f-0000-4000-8000-000000000003", &manager.host_id, false),
            ],
        });
        fs::write(&index, serde_json::to_vec(&listing).unwrap()).unwrap();
        let live = PeerLive::new();
        manager.attach_peers(Arc::clone(&live), index);
        Peers { fixture, live }
    }

    fn place() -> Place {
        Place::of(STUDIO, None, SESSION).unwrap()
    }

    fn record(cursor: u64) -> ClientRecord {
        serde_json::from_value(json!({ "cursor": cursor, "line": format!(r#"{{"type":"message","id":"m{cursor}"}}"#) })).unwrap()
    }

    fn watch(peers: &Peers, epoch: Option<u64>, cursor: u64, version: u64) -> PeerSessionView {
        peers
            .fixture
            .manager
            .watch_peer_session(&rpc::WatchPeerSession {
                host_id: STUDIO.to_owned(),
                session_id: SESSION.parse().unwrap(),
                epoch,
                cursor,
                version,
                timeout_ms: Some(10),
                window: None,
            })
            .unwrap()
    }

    #[test]
    fn other_macs_sessions_are_listed_but_never_as_this_macs() {
        let peers = peers();
        let list = peers.fixture.manager.peer_sessions().unwrap();
        assert_eq!(list.hosts.len(), 1);
        assert_eq!(list.hosts[0].label, "Mac Studio");
        assert_eq!(
            list.sessions
                .iter()
                .map(|peer| peer.session.id.to_string())
                .collect::<Vec<_>>(),
            vec![SESSION],
            "archived Sessions and this Mac's own are left out"
        );
        let session = &list.sessions[0];
        assert_eq!(session.host_id, STUDIO);
        assert_eq!(
            (session.session.name.as_str(), session.session.status),
            ("Fix the bug", SessionStatus::Working)
        );
        assert!(
            session.session.shells.is_empty(),
            "no pane until one is opened"
        );
        let local = peers.fixture.manager.list_sessions().unwrap();
        assert!(local.iter().all(|record| record.id.to_string() != SESSION));
        assert!(!list.connected);
    }

    #[test]
    fn a_pane_reads_on_from_its_cursor_and_starts_over_after_a_cut() {
        let peers = peers();
        let mut mirror = Mirror::new(peers.fixture.directory.join("sessions"));
        mirror
            .start(&place(), 1, HEADER, &[record(1), record(2)])
            .unwrap();

        let first = watch(&peers, None, 0, 0);
        assert!(first.reset, "a first look draws from nothing");
        assert_eq!((first.epoch, first.cursor), (Some(1), 2));
        assert_eq!(
            first
                .records
                .iter()
                .map(|record| record.cursor)
                .collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(
            (first.host_label.as_str(), first.status),
            ("Mac Studio", Some(SessionStatus::Working))
        );

        mirror.append(&place(), 1, &[record(3)]).unwrap();
        let next = watch(&peers, Some(1), 2, first.version);
        assert!(!next.reset);
        assert_eq!(
            next.records
                .iter()
                .map(|record| record.cursor)
                .collect::<Vec<_>>(),
            vec![3]
        );

        // The Studio cut its log back: the pane drops what it drew and draws the copy again.
        mirror.reset(&place(), 2, 1).unwrap();
        let cut = watch(&peers, Some(1), 3, next.version);
        assert!(cut.reset);
        assert_eq!((cut.epoch, cut.cursor), (Some(2), 1));
        assert_eq!(
            cut.records
                .iter()
                .map(|record| record.cursor)
                .collect::<Vec<_>>(),
            vec![1]
        );
    }

    #[test]
    fn a_remote_pane_is_pi_with_no_session_file_in_remote_mode() {
        let peers = peers();
        let manager = &peers.fixture.manager;
        let recorded = peers.fixture.directory.join("launched");
        let agent = peers.fixture.directory.join("fake-pi");
        fs::write(
            &agent,
            format!(
                "#!/bin/sh\necho \"$@\" \"$AXO_REMOTE_HOST_ID\" \"$AXO_REMOTE_SESSION_ID\" \"$AXO_REMOTE_HOST_LABEL\" \"${{AXO_SESSION_ID:-none}}\" > {}\nexec /bin/sleep 60\n",
                recorded.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&agent, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(agent.to_str().unwrap()).unwrap();

        let opened = manager
            .open_peer_session(STUDIO, SESSION.parse().unwrap())
            .unwrap();
        let shell = opened.session.shells[0].clone();
        assert!(shell.id.get() >= FIRST_VIEW_SHELL);
        assert_eq!(shell.role, PaneRole::Pi);
        let again = manager
            .open_peer_session(STUDIO, SESSION.parse().unwrap())
            .unwrap();
        assert_eq!(again.session.shells[0].id, shell.id, "one pane per Session");

        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let launched = loop {
            if let Ok(text) = fs::read_to_string(&recorded)
                && !text.is_empty()
            {
                break text;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the pane never started Pi"
            );
            std::thread::sleep(Duration::from_millis(20));
        };
        assert!(
            launched.starts_with(
                "--no-session --no-extensions --no-mcp --no-skills --no-prompt-templates --extension "
            ),
            "{launched}"
        );
        assert!(
            launched
                .trim_end()
                .ends_with(&format!("{STUDIO} {SESSION} Mac Studio none")),
            "{launched}"
        );

        assert!(
            manager.attach_shell(shell.id).is_ok(),
            "the Mac app attaches as to any pane"
        );
        assert!(
            manager
                .list_sessions()
                .unwrap()
                .iter()
                .all(|record| record.id.to_string() != SESSION)
        );
        let listed = manager.peer_sessions().unwrap();
        assert_eq!(listed.sessions[0].session.shells.len(), 1);

        assert!(
            manager
                .close_peer_session(SESSION.parse().unwrap())
                .unwrap()
        );
        assert!(
            manager.peer_sessions().unwrap().sessions[0]
                .session
                .shells
                .is_empty()
        );
    }

    #[test]
    fn commands_go_out_only_while_following_and_only_prompts_stops_and_keys() {
        let peers = peers();
        let manager = &peers.fixture.manager;
        let command = |method: &str| rpc::PeerCommand {
            host_id: STUDIO.to_owned(),
            method: method.to_owned(),
            params: serde_json::Map::new(),
        };
        assert_eq!(
            manager.peer_command(command("axo.remote.session.prompt")),
            Err(PeerCommandError::offline())
        );
        assert_eq!(
            manager
                .peer_command(command("axo.remote.session.close"))
                .unwrap_err()
                .code,
            -32602
        );
        assert!(!peers.live.is_connected());
    }
}
