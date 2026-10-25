use std::collections::HashMap;
use std::fs;
use std::os::fd::OwnedFd;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::panes::{PaneProcess, Panes, RuntimeId};
use crate::workspace_access::WorkspaceDirectoryAccess;
use axo_pi::{AgentCommand, BridgeSocketPath, WriterLock};
use axo_protocol::{PaneRole, SessionId, Viewport, new_uuid_v4};
use axo_pty::TerminalOutput;
use axo_pty::process;
use axo_store::Connection;
use axo_store::{
    DATABASE_FILE, ensure_pi_bridge_socket_paths, load_or_create_host_id, load_viewport,
};

mod base64;
mod catalog;
mod events;
mod handlers;
mod lifecycle;
mod pi_bridge;
mod pi_recovery;
mod settings;
mod spawn;
mod terminal;
mod workspaces;

use self::events::{EventBus, LocalSubscription};
pub(crate) use self::handlers::RelayHostAdapter;
use self::pi_bridge::remove_abandoned_pi_bridge_sockets;
use self::settings::{ShellCommand, load_or_create_agent_command, load_or_create_shell_command};
use self::workspaces::restore_workspace_accesses;

const ATTACH_SOCKET_FILE: &str = "attach.sock";

#[derive(Debug)]
struct RunningShell {
    runtime_id: RuntimeId,
    session_id: SessionId,
    role: PaneRole,
    pane_id: Option<String>,
    initial_pwd: PathBuf,
    child: Child,
    wait_error_reported: bool,
    master: OwnedFd,
    slave_device: String,
    /// Live terminal attachments. Only Axod's output pump reads `master`.
    attachments: usize,
    output: Arc<TerminalOutput>,
    last_input_sequence: Option<u64>,
    _writer_lock: Option<WriterLock>,
    pi_bridge_socket: Option<BridgeSocketPath>,
    pi_bridge_token: Option<String>,
}

impl RunningShell {
    /// How long this pane's process gets to exit when stopped, before SIGKILL.
    fn stop_grace(&self) -> Duration {
        match self.role {
            PaneRole::Terminal => process::SHELL_STOP_GRACE,
            PaneRole::Pi => axo_pi::STOP_GRACE,
        }
    }
}

/// The one way a pane's process is stopped (close, archive, cancelled recovery, shutdown):
/// SIGHUP/SIGTERM to all at once, SIGKILL to each whose own grace runs out. Takes ownership so
/// a Pi's writer lock and PTY are released only after its process has exited. Blocks for up to
/// the longest grace; never call it under the catalog lock.
fn stop_panes(mut panes: Vec<RunningShell>) {
    process::stop_all(
        panes
            .iter_mut()
            .map(|pane| process::Stopping {
                grace: pane.stop_grace(),
                child: &mut pane.child,
            })
            .collect(),
    );
}

impl PaneProcess for RunningShell {
    fn session_id(&self) -> SessionId {
        self.session_id
    }
}

impl Drop for RunningShell {
    fn drop(&mut self) {
        // Removing a shell from the catalog ends its output stream even if a stray process
        // still holds the PTY slave open.
        self.output.stop();
    }
}

struct SessionState {
    database: Connection,
    agent_command: AgentCommand,
    shell_command: ShellCommand,
    /// Every open pane, running or unavailable; see `panes`.
    panes: Panes<RunningShell>,
    shutting_down: bool,
    pi_activity: HashMap<SessionId, axo_pi::Activity>,
    initial_pwd: PathBuf,
    /// Every shell's output is published here once it enters the catalog.
    events: EventBus,
    /// The latest client's terminal area; panes no client is attached to are sized from it.
    viewport: Option<Viewport>,
}

pub struct SessionManager {
    state: Mutex<SessionState>,
    attach_socket_path: PathBuf,
    pi_session_directory: PathBuf,
    host_id: String,
    host_generation: String,
    stop_workers: Arc<AtomicBool>,
    workers: Mutex<Vec<JoinHandle<()>>>,
    subscriptions: Mutex<HashMap<String, Arc<LocalSubscription>>>,
    subscribers: EventBus,
    next_subscription_id: AtomicU64,
    pending_resume_focus: Mutex<Option<(SessionId, Instant)>>,
    workspace_access: Mutex<HashMap<String, WorkspaceDirectoryAccess>>,
}

impl SessionManager {
    pub fn open(server_directory: &Path) -> Result<Arc<Self>, Box<dyn std::error::Error>> {
        fs::create_dir_all(server_directory)?;
        let server_directory = fs::canonicalize(server_directory)?;
        let database_path = server_directory.join(DATABASE_FILE);
        let attach_socket_path = server_directory.join(ATTACH_SOCKET_FILE);
        let initial_pwd = crate::current_user_home_directory()?;

        let database = axo_store::open(&database_path)?;
        let host_id = load_or_create_host_id(&database)?;
        let agent_command = load_or_create_agent_command(&database)?;
        let shell_command = load_or_create_shell_command(&database)?;
        let viewport = load_viewport(&database)?;
        let host_generation = new_uuid_v4()?;
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory)?;
        fs::set_permissions(&pi_session_directory, fs::Permissions::from_mode(0o700))?;
        ensure_pi_bridge_socket_paths(&database, &pi_session_directory)?;
        remove_abandoned_pi_bridge_sockets(&database)?;

        let workspace_access = restore_workspace_accesses(&database)?;
        let subscribers = EventBus::default();
        let manager = Arc::new(Self {
            state: Mutex::new(SessionState {
                database,
                agent_command,
                shell_command,
                panes: Panes::new(),
                shutting_down: false,
                pi_activity: HashMap::new(),
                initial_pwd,
                events: subscribers.clone(),
                viewport,
            }),
            attach_socket_path,
            pi_session_directory,
            host_id,
            host_generation,
            stop_workers: Arc::new(AtomicBool::new(false)),
            workers: Mutex::new(Vec::new()),
            subscriptions: Mutex::new(HashMap::new()),
            subscribers,
            next_subscription_id: AtomicU64::new(1),
            pending_resume_focus: Mutex::new(None),
            workspace_access: Mutex::new(workspace_access),
        });

        manager.restore_open_sessions()?;
        manager.ensure_open_workspace_sessions()?;
        if let Some(session) = manager.ensure_home_session()? {
            log::info!(
                "event=session.default_created session_id={}",
                session.id.get()
            );
        }
        manager.start_attachment_listener()?;
        manager.start_reaper();
        Ok(manager)
    }

    pub fn shutdown(&self) {
        // Fence in-flight launches before joining workers or draining processes.
        // stop_workers alone is also used to quiesce background fixture workers.
        if let Ok(mut state) = self.state.lock() {
            state.shutting_down = true;
        }
        self.stop_workers.store(true, Ordering::Relaxed);
        let workers = self
            .workers
            .lock()
            .map(|mut workers| std::mem::take(&mut *workers))
            .unwrap_or_default();
        join_session_workers(workers);
        // Slow child cleanup must not monopolize the catalog/PTY lock. Drain
        // runtime ownership once so repeated shutdown (including Drop) is safe.
        let shells = self
            .state
            .lock()
            .map(|mut state| state.panes.drain())
            .unwrap_or_default();
        stop_panes(shells);
    }
}

impl Drop for SessionManager {
    fn drop(&mut self) {
        self.shutdown();
        let _ = fs::remove_file(&self.attach_socket_path);
    }
}

fn join_session_workers(workers: Vec<JoinHandle<()>>) {
    let current_thread = thread::current().id();
    for worker in workers {
        // A worker may release the last upgraded Arc and run SessionManager's
        // destructor itself. Joining that same thread would deadlock/panic.
        if worker.thread().id() != current_thread {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::{
        catalog::*, events::*, pi_bridge::*, pi_recovery::*, settings::*, spawn::*, terminal::*,
    };

    use std::fs;
    use std::io::{self, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread::{self, JoinHandle};
    use std::time::{Duration, Instant};

    fn wait_for_shell_exit(child: &mut Child, timeout: Duration) -> io::Result<bool> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            match child.try_wait()? {
                Some(_) => return Ok(true),
                None => thread::sleep(Duration::from_millis(25)),
            }
        }
        Ok(child.try_wait()?.is_some())
    }

    use crate::panes::{Pane, RuntimeId, UnavailablePane};

    use axo_pi::bridge;
    use axo_pi::takeover::TakeoverPolicy;
    use axo_pi::{AgentCommand, BridgeSocketPath, WriterLock};
    use axo_protocol::rpc;
    use axo_protocol::{
        Availability, Event, Layout, LayoutDirection, LayoutNode, PaneRole, SessionId,
        SessionStatus, ShellId, Viewport, is_uuid, new_uuid_v4,
    };
    use axo_pty::process;
    use axo_pty::{NextOutput, OutputSubscriber, WindowSize};
    use axo_store::Connection;
    use axo_store::{
        DATABASE_FILE, StoredLifecycle, load_or_create_host_id, load_pi_bridge_token,
        load_viewport, store_pi_bridge_token,
    };

    use axo_store::{initialize_database, inserted_session_id, inserted_shell_id, unix_timestamp};

    use rusqlite::params;

    use serde_json::{Value, json};
    use std::fs::OpenOptions;
    use std::io::BufReader;
    use std::io::Read;

    fn sid(value: i64) -> SessionId {
        SessionId::new(value).unwrap()
    }

    fn shid(value: i64) -> ShellId {
        ShellId::new(value).unwrap()
    }

    #[test]
    fn pi_catalog_events_keep_only_valid_titles_and_emoji() {
        let parse = |name: &str, data: Value| format!("{:?}", PiCatalogEvent::parse(name, &data));
        assert_eq!(parse("agent.start", json!({})), "AgentStarted");
        assert_eq!(parse("ui.prompt.end", json!(null)), "PromptEnded");
        assert_eq!(
            parse("session.info", json!({ "name": "Fix the build" })),
            r#"Named { title: "Fix the build" }"#
        );
        assert_eq!(parse("session.info", json!({ "name": "" })), "Ignored");
        assert_eq!(parse("session.info", json!({ "name": 7 })), "Ignored");
        assert_eq!(
            parse(
                "axo.session.metadata",
                json!({ "title": "", "emoji": "🔧" })
            ),
            r#"Described { title: None, emoji: Some("🔧") }"#
        );
        assert_eq!(
            parse(
                "axo.session.metadata",
                json!({ "title": "", "emoji": "not an emoji" })
            ),
            "Ignored"
        );
        assert_eq!(parse("message.delta", json!({ "name": "x" })), "Ignored");
    }

    #[test]
    fn stored_lifecycle_parses_known_states_and_rejects_others() {
        let database = Connection::open_in_memory().unwrap();
        let read = |state: &str| {
            database.query_row("SELECT ?1", params![state], |row| {
                row.get::<_, StoredLifecycle>(0)
            })
        };
        assert_eq!(read("open").unwrap(), StoredLifecycle::Open);
        assert_eq!(read("archived").unwrap(), StoredLifecycle::Archived);
        assert!(read("closed").is_err());
        assert!(read("").is_err());
    }

    /// An event as it goes over the wire.
    fn wire(event: impl std::ops::Deref<Target = Event>) -> Value {
        serde_json::to_value(&*event).unwrap()
    }

    /// A socket file whose listener is gone, as a killed Pi leaves it.
    fn abandoned_socket(path: &Path) {
        drop(UnixListener::bind(path).unwrap());
        assert!(fs::symlink_metadata(path).is_ok());
    }

    fn bridge_socket_directory() -> PathBuf {
        // /tmp, not the per-user temp directory: socket paths are limited to 104 bytes.
        let directory =
            PathBuf::from("/tmp").join(format!("axo-bridge-{}", new_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn startup_reconciliation_keeps_sockets_of_live_pis_only() {
        let directory = bridge_socket_directory();
        let database = Connection::open_in_memory().unwrap();
        database
            .execute_batch(
                "CREATE TABLE sessions (id INTEGER PRIMARY KEY, pi_session_file TEXT, pi_bridge_socket_path TEXT);",
            )
            .unwrap();
        let live_file = directory.join("live.jsonl");
        let live_socket = directory.join("live.sock");
        let dead_file = directory.join("dead.jsonl");
        let dead_socket = directory.join("dead.sock");
        for (id, file, socket) in [(1, &live_file, &live_socket), (2, &dead_file, &dead_socket)] {
            abandoned_socket(socket);
            database
                .execute(
                    "INSERT INTO sessions VALUES (?1, ?2, ?3)",
                    params![id, file.to_string_lossy(), socket.to_string_lossy()],
                )
                .unwrap();
        }
        let live_writer = WriterLock::acquire(&live_file).unwrap();

        remove_abandoned_pi_bridge_sockets(&database).unwrap();

        assert!(live_socket.exists(), "a live Pi keeps its socket");
        assert!(!dead_socket.exists());
        drop(live_writer);
        fs::remove_dir_all(directory).unwrap();
    }
    use std::os::unix::process::CommandExt;
    use std::sync::mpsc;

    struct ChildProcessGuard(Child);

    impl Drop for ChildProcessGuard {
        fn drop(&mut self) {
            if !matches!(self.0.try_wait(), Ok(Some(_))) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
    }

    struct RunningShellGuard(RunningShell);

    impl Drop for RunningShellGuard {
        fn drop(&mut self) {
            process::stop(&mut self.0.child, process::SHELL_STOP_GRACE);
        }
    }

    /// Opens a manager whose shells (the home Session's included) run a silent stand-in for the
    /// login shell: no profile, no history, and no output to race a test's event assertions.
    fn open_with_silent_shell(directory: &Path) -> Arc<SessionManager> {
        let shell = directory.join("silent-shell");
        fs::write(&shell, "#!/bin/sh\nexec /bin/sleep 3600\n").unwrap();
        fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
        let mut database = Connection::open(directory.join(DATABASE_FILE)).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![shell.to_string_lossy()],
            )
            .unwrap();
        drop(database);
        SessionManager::open(directory).unwrap()
    }

    struct LifecycleFixture {
        directory: PathBuf,
        manager: Arc<SessionManager>,
    }

    impl LifecycleFixture {
        fn new() -> Self {
            let directory =
                PathBuf::from("/tmp").join(format!("axo-life-{}", new_uuid_v4().unwrap()));
            fs::create_dir_all(&directory).unwrap();
            // Lifecycle tests must not race real login-profile initialization or
            // read/write the user's shell history. Seed only this private catalog.
            let shell = directory.join("fixture-shell");
            fs::write(
                &shell,
                "#!/bin/sh\nunset ENV BASH_ENV\nexport HISTFILE=/dev/null\nexec /bin/sh -i\n",
            )
            .unwrap();
            fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
            let mut database = Connection::open(directory.join(DATABASE_FILE)).unwrap();
            initialize_database(&mut database).unwrap();
            database
                .execute(
                    "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1)",
                    params![shell.to_string_lossy()],
                )
                .unwrap();
            drop(database);
            let manager = SessionManager::open(&directory).unwrap();
            // Keep state transitions deterministic: these tests drive the reaper
            // explicitly, rather than racing its periodic background tick.
            manager.stop_workers.store(true, Ordering::Relaxed);
            let workers = std::mem::take(&mut *manager.workers.lock().unwrap());
            join_session_workers(workers);
            Self { directory, manager }
        }
    }

    impl Drop for LifecycleFixture {
        fn drop(&mut self) {
            self.manager.shutdown();
            let _ = fs::remove_dir_all(&self.directory);
        }
    }

    struct PiRecoveryFixture {
        lifecycle: LifecycleFixture,
        session_id: SessionId,
        shell_id: ShellId,
        session_uuid: String,
        pane_id: String,
        file: PathBuf,
        socket: BridgeSocketPath,
        token: String,
    }

    impl PiRecoveryFixture {
        fn new() -> Self {
            let lifecycle = LifecycleFixture::new();
            let manager = &lifecycle.manager;
            let session_uuid = new_uuid_v4().unwrap();
            let pane_id = new_uuid_v4().unwrap();
            let token = new_uuid_v4().unwrap();
            let file = manager
                .pi_session_directory
                .join(format!("{session_uuid}.jsonl"));
            let socket =
                BridgeSocketPath::for_session(&manager.pi_session_directory, &session_uuid)
                    .unwrap();
            fs::write(&file, b"original history\n").unwrap();
            let executable = lifecycle.directory.join("fake-pi");
            fs::write(&executable, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
            let (session_id, shell_id) = {
                let mut state = manager.lock_state().unwrap();
                state.agent_command = AgentCommand::parse(executable.to_str().unwrap()).unwrap();
                state.database.execute(
                    "INSERT INTO sessions (initial_pwd, state, created_at, session_uuid, pi_session_file, pi_bridge_socket_path)
                     VALUES (?1, 'open', ?2, ?3, ?4, ?5)",
                    params![lifecycle.directory.to_string_lossy(), unix_timestamp(), session_uuid, file.to_string_lossy(), socket.as_str()],
                ).unwrap();
                let session_id = inserted_session_id(&state.database).unwrap();
                state.database.execute(
                    "INSERT INTO shells (session_id, initial_pwd, state, created_at, role, pane_id) VALUES (?1, ?2, 'open', ?3, 'pi', ?4)",
                    params![session_id.get(), lifecycle.directory.to_string_lossy(), unix_timestamp(), pane_id],
                ).unwrap();
                let shell_id = inserted_shell_id(&state.database).unwrap();
                state
                    .database
                    .execute(
                        "UPDATE sessions SET layout_json = ?1 WHERE id = ?2",
                        params![
                            serde_json::to_string(&Layout::single(shell_id)).unwrap(),
                            session_id.get()
                        ],
                    )
                    .unwrap();
                store_pi_bridge_token(&state.database, &session_uuid, &token).unwrap();
                state
                    .panes
                    .insert_unavailable(
                        shell_id,
                        UnavailablePane::new(
                            session_id,
                            Some(pane_id.clone()),
                            lifecycle.directory.clone(),
                        ),
                    )
                    .unwrap();
                (session_id, shell_id)
            };
            Self {
                lifecycle,
                session_id,
                shell_id,
                session_uuid,
                pane_id,
                file,
                socket,
                token,
            }
        }

        fn begin_recovery(
            &self,
            policy: TakeoverPolicy,
        ) -> (JoinHandle<io::Result<()>>, BufReader<UnixStream>) {
            let session_id = self.session_id;
            let shell_id = self.shell_id;
            self.observe_operation(move |manager| {
                manager
                    .restart_unavailable_pi(session_id, shell_id, policy)
                    .map(|_| ())
            })
        }

        fn observe_operation(
            &self,
            operation: impl FnOnce(Arc<SessionManager>) -> io::Result<()> + Send + 'static,
        ) -> (JoinHandle<io::Result<()>>, BufReader<UnixStream>) {
            let listener = UnixListener::bind(self.socket.as_path()).unwrap();
            listener.set_nonblocking(true).unwrap();
            let manager = Arc::clone(&self.lifecycle.manager);
            let worker = thread::spawn(move || operation(manager));
            let deadline = Instant::now() + Duration::from_secs(3);
            let stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error)
                        if error.kind() == io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(5))
                    }
                    Err(error) => panic!("recovery never reached the fixture bridge: {error}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut reader = BufReader::new(stream);
            let auth = bridge::read_record::<Value>(&mut reader).unwrap();
            assert_eq!(auth["token"], self.token);
            (worker, reader)
        }

        fn accept_shutdown(&self, reader: &mut BufReader<UnixStream>, process_id: u32) {
            bridge::write_record(
                reader.get_mut(),
                &json!({ "type": "authenticated", "protocolVersion": 1 }),
            )
            .unwrap();
            bridge::write_record(reader.get_mut(), &json!({
                "type": "hello", "protocolVersion": 1,
                "identity": { "axoSessionId": self.session_uuid, "axoPaneId": self.pane_id, "piSessionId": "pi-takeover",
                    "sessionFile": self.file, "cwd": self.lifecycle.directory, "processId": process_id }
            })).unwrap();
            let command = bridge::read_record::<Value>(reader).unwrap();
            assert_eq!(command["type"], "command");
            bridge::write_record(reader.get_mut(), &json!({
                "type": "commandResult", "requestId": command["requestId"], "result": { "accepted": true }
            })).unwrap();
        }

        fn assert_preserved(&self) {
            assert_eq!(fs::read(&self.file).unwrap(), b"original history\n");
        }
    }

    #[test]
    fn stalled_pi_recovery_keeps_catalog_and_sibling_ptys_responsive() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        let (worker, _bridge) = fixture.begin_recovery(TakeoverPolicy::PreserveExistingProcess);
        let start = Instant::now();
        assert!(
            manager.state.try_lock().is_ok(),
            "recovery held the shared catalog lock during authentication"
        );
        let home = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id != fixture.session_id)
            .unwrap();
        manager.rename_session(home.id, "Still responsive").unwrap();
        let attachment = manager.attach_shell(home.shells[0].id).unwrap();
        manager.mark_detached(home.shells[0].id, attachment.runtime_id);
        let error = manager
            .restart_unavailable_pi(
                fixture.session_id,
                fixture.shell_id,
                TakeoverPolicy::ExplicitUserRestart,
            )
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(start.elapsed() < Duration::from_secs(1));
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        let state = manager.lock_state().unwrap();
        assert!(
            !state
                .panes
                .unavailable(fixture.shell_id)
                .unwrap()
                .is_recovering()
        );
        assert_eq!(
            load_pi_bridge_token(&state.database, &fixture.session_uuid)
                .unwrap()
                .as_deref(),
            Some(fixture.token.as_str())
        );
        drop(state);
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn closing_a_pi_pane_cancels_pending_takeover_without_escalating() {
        for policy in [
            TakeoverPolicy::PreserveExistingProcess,
            TakeoverPolicy::ExplicitUserRestart,
        ] {
            let fixture = PiRecoveryFixture::new();
            let lock = WriterLock::acquire(&fixture.file).unwrap();
            let mut command = Command::new("/bin/sleep");
            command.arg("60");
            // SAFETY: isolated test child creates its own process group.
            unsafe {
                command.pre_exec(|| {
                    if libc::setsid() == -1 {
                        Err(io::Error::last_os_error())
                    } else {
                        Ok(())
                    }
                });
            }
            let mut old_pi = ChildProcessGuard(command.spawn().unwrap());
            let (worker, mut bridge) = fixture.begin_recovery(policy);
            fixture.accept_shutdown(&mut bridge, old_pi.0.id());
            let start = Instant::now();
            fixture
                .lifecycle
                .manager
                .close_session(fixture.session_id)
                .unwrap();
            assert_eq!(
                worker.join().unwrap().unwrap_err().kind(),
                io::ErrorKind::Interrupted
            );
            assert!(start.elapsed() < Duration::from_secs(1));
            assert!(
                old_pi.0.try_wait().unwrap().is_none(),
                "cancelled recovery signalled the old process"
            );
            let state = fixture.lifecycle.manager.lock_state().unwrap();
            assert!(!state.panes.running(fixture.shell_id).is_some());
            assert!(!state.panes.unavailable(fixture.shell_id).is_some());
            let lifecycle: String = state
                .database
                .query_row(
                    "SELECT state FROM sessions WHERE id = ?1",
                    params![fixture.session_id.get()],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(lifecycle, "archived");
            drop(state);
            drop(lock);
            fixture.assert_preserved();
        }
    }

    #[test]
    fn shutdown_fences_pending_pi_recovery_and_future_restarts() {
        let fixture = PiRecoveryFixture::new();
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        let (worker, _bridge) = fixture.begin_recovery(TakeoverPolicy::PreserveExistingProcess);
        let start = Instant::now();
        fixture.lifecycle.manager.shutdown();
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(
            fixture
                .lifecycle
                .manager
                .lock_state()
                .unwrap()
                .panes
                .running_is_empty()
        );
        assert_eq!(
            fixture
                .lifecycle
                .manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::ExplicitUserRestart
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn failed_pi_exec_releases_recovery_reservation_and_original_writer_lock() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let original_command = manager.lock_state().unwrap().agent_command.clone();
        let broken_executable = fixture.lifecycle.directory.join("broken-pi");
        fs::write(
            &broken_executable,
            "#!/nonexistent/axo-fixture-interpreter\n",
        )
        .unwrap();
        fs::set_permissions(&broken_executable, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(broken_executable.to_str().unwrap()).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::PreserveExistingProcess
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert!(
            !manager
                .lock_state()
                .unwrap()
                .panes
                .unavailable(fixture.shell_id)
                .unwrap()
                .is_recovering()
        );
        // Concurrent forked fixture children may briefly hold CLOEXEC copies
        // until exec. Bound the wait rather than requiring instantaneous release.
        drop(WriterLock::wait(&fixture.file, Duration::from_secs(1), &|| Ok(())).unwrap());
        manager.lock_state().unwrap().agent_command = original_command;
        let recovered = manager
            .restart_unavailable_pi(
                fixture.session_id,
                fixture.shell_id,
                TakeoverPolicy::PreserveExistingProcess,
            )
            .unwrap();
        assert!(
            recovered
                .shells
                .iter()
                .any(|shell| shell.id == fixture.shell_id && shell.is_available())
        );
        assert_eq!(
            WriterLock::acquire(&fixture.file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        fixture.assert_preserved();
    }

    #[test]
    fn cancelled_pi_launch_is_cleaned_up_instead_of_resurrecting_the_pane() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let (recovery_id, pending) = {
            let mut state = manager.lock_state().unwrap();
            let recovery_id = state
                .panes
                .begin_recovery(fixture.session_id, fixture.shell_id)
                .unwrap();
            let pending = spawn_new_pi(
                &state.database,
                &PiLaunchRequest {
                    agent_command: state.agent_command.clone(),
                    session_id: fixture.session_id,
                    initial_pwd: fixture.lifecycle.directory.clone(),
                    session_file: fixture.file.clone(),
                    bridge_socket: fixture.socket.clone(),
                    session_uuid: fixture.session_uuid.clone(),
                    pane_id: fixture.pane_id.clone(),
                    previous_token: None,
                    size: WindowSize::DEFAULT,
                },
            )
            .unwrap();
            (recovery_id, pending)
        };
        let recovery = PiRecoveryLease {
            manager,
            session_id: fixture.session_id,
            shell_id: fixture.shell_id,
            recovery_id,
        };
        manager.close_session(fixture.session_id).unwrap();
        assert_eq!(
            manager
                .commit_pi_recovery(&recovery, pending)
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );
        assert!(
            !manager
                .lock_state()
                .unwrap()
                .panes
                .running(fixture.shell_id)
                .is_some()
        );
        // Both parent and child lock copies must be released by cleanup. Other
        // concurrent fixture forks can retain CLOEXEC copies briefly until exec.
        drop(WriterLock::wait(&fixture.file, Duration::from_secs(1), &|| Ok(())).unwrap());
        fixture.assert_preserved();
    }

    #[test]
    fn pi_recovery_rejects_missing_and_ambiguously_owned_history() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        fs::remove_file(&fixture.file).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::PreserveExistingProcess
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert!(!fixture.file.exists());
        assert!(!fixture.file.with_extension("jsonl.lock").exists());
        fs::write(&fixture.file, b"original history\n").unwrap();
        manager.lock_state().unwrap().database.execute(
            "INSERT INTO sessions (initial_pwd, state, created_at, session_uuid, pi_session_file) VALUES ('/tmp', 'archived', ?1, ?2, ?3)",
            params![unix_timestamp(), new_uuid_v4().unwrap(), fixture.file.to_string_lossy()],
        ).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::ExplicitUserRestart
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert!(!fixture.file.with_extension("jsonl.lock").exists());
        fixture.assert_preserved();
    }

    #[test]
    fn pi_recovery_rejects_history_replaced_during_takeover() {
        let fixture = PiRecoveryFixture::new();
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        let (worker, mut bridge) = fixture.begin_recovery(TakeoverPolicy::PreserveExistingProcess);
        // The unavailable writer's identity must never turn into a different
        // history merely because the path was reused while takeover waited.
        let original = fixture.file.with_extension("saved.jsonl");
        fs::rename(&fixture.file, &original).unwrap();
        fs::write(&fixture.file, b"replacement history\n").unwrap();
        fixture.accept_shutdown(&mut bridge, 2);
        drop(lock);
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(fs::read(&fixture.file).unwrap(), b"replacement history\n");
        assert_eq!(fs::read(&original).unwrap(), b"original history\n");
        let state = fixture.lifecycle.manager.lock_state().unwrap();
        assert!(!state.panes.running(fixture.shell_id).is_some());
        assert!(
            !state
                .panes
                .unavailable(fixture.shell_id)
                .unwrap()
                .is_recovering()
        );
        assert_eq!(
            load_pi_bridge_token(&state.database, &fixture.session_uuid)
                .unwrap()
                .as_deref(),
            Some(fixture.token.as_str())
        );
    }

    #[test]
    fn pi_recovery_rejects_symlinked_and_outside_history_without_touching_it() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let original = fixture.file.with_extension("original.jsonl");
        fs::rename(&fixture.file, &original).unwrap();
        std::os::unix::fs::symlink(&original, &fixture.file).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::PreserveExistingProcess
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(fs::read(&original).unwrap(), b"original history\n");
        assert!(!fixture.file.with_extension("jsonl.lock").exists());
        fs::remove_file(&fixture.file).unwrap();
        fs::rename(&original, &fixture.file).unwrap();
        let outside = fixture.lifecycle.directory.join("outside.jsonl");
        fs::write(&outside, b"not an owned Pi history\n").unwrap();
        manager
            .lock_state()
            .unwrap()
            .database
            .execute(
                "UPDATE sessions SET pi_session_file = ?1 WHERE id = ?2",
                params![outside.to_string_lossy(), fixture.session_id.get()],
            )
            .unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    TakeoverPolicy::ExplicitUserRestart
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(fs::read(&outside).unwrap(), b"not an owned Pi history\n");
        assert!(!outside.with_extension("jsonl.lock").exists());
        fixture.assert_preserved();
    }

    #[test]
    fn session_restore_waits_outside_the_catalog_lock_and_isolates_pi_failure() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let lock = WriterLock::acquire(&fixture.file).unwrap();
        manager.lock_state().unwrap().panes.remove(fixture.shell_id);
        let (worker, mut bridge) =
            fixture.observe_operation(|manager| manager.restore_open_sessions());
        assert!(
            manager.state.try_lock().is_ok(),
            "startup restoration held the shared catalog lock during takeover"
        );
        let home = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id != fixture.session_id)
            .unwrap();
        assert!(home.shells.iter().any(|shell| shell.is_available()));
        bridge::write_record(bridge.get_mut(), &json!({ "type": "protocolError" })).unwrap();
        worker.join().unwrap().unwrap();
        let sessions = manager.list_sessions().unwrap();
        let target = sessions
            .iter()
            .find(|session| session.id == fixture.session_id)
            .unwrap();
        assert!(!target.shells[0].is_available());
        assert!(sessions.iter().any(|session| session.id == home.id));
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn restoring_sessions_does_not_replace_an_existing_runtime() {
        let fixture = LifecycleFixture::new();
        let session = fixture.manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let runtime = fixture
            .manager
            .lock_state()
            .unwrap()
            .panes
            .running(shell_id)
            .unwrap()
            .runtime_id;
        fixture.manager.restore_open_sessions().unwrap();
        assert_eq!(
            fixture
                .manager
                .lock_state()
                .unwrap()
                .panes
                .running(shell_id)
                .unwrap()
                .runtime_id,
            runtime
        );
    }

    #[test]
    fn resume_handoff_preserves_requester_when_target_or_runtime_is_unavailable() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let home = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id != fixture.session_id)
            .unwrap();
        let requester = {
            let mut state = manager.lock_state().unwrap();
            let shell = state.panes.running_mut(home.shells[0].id).unwrap();
            shell.role = PaneRole::Pi;
            PiRuntimeBinding {
                session_id: home.id,
                shell_id: home.shells[0].id,
                runtime_id: shell.runtime_id,
            }
        };
        assert_eq!(
            manager
                .complete_pi_resume(requester, fixture.session_id)
                .unwrap_err()
                .kind(),
            io::ErrorKind::WouldBlock
        );
        manager.close_session(fixture.session_id).unwrap();
        assert!(
            manager
                .complete_pi_resume(requester, fixture.session_id)
                .is_err()
        );
        let stale = PiRuntimeBinding {
            runtime_id: RuntimeId::new(),
            ..requester
        };
        assert_eq!(
            manager
                .complete_pi_resume(stale, home.id)
                .unwrap_err()
                .kind(),
            io::ErrorKind::Interrupted
        );
        assert!(manager.pi_runtime_is_current(requester));
        assert!(
            manager
                .list_sessions()
                .unwrap()
                .iter()
                .any(|session| session.id == home.id)
        );
        assert_eq!(manager.take_pending_resume_focus().unwrap(), None);
        fixture.assert_preserved();
    }

    #[test]
    fn stale_recovery_lease_cannot_release_a_newer_reservation() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let old_id = RuntimeId::new();
        let old = PiRecoveryLease {
            manager,
            session_id: fixture.session_id,
            shell_id: fixture.shell_id,
            recovery_id: old_id,
        };
        let new_id = manager
            .lock_state()
            .unwrap()
            .panes
            .begin_recovery(fixture.session_id, fixture.shell_id)
            .unwrap();
        assert_eq!(
            old.ensure_current().unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
        drop(old);
        assert!(manager.lock_state().unwrap().panes.is_recovering(
            fixture.session_id,
            fixture.shell_id,
            new_id
        ));
    }

    #[test]
    fn stale_runtime_callbacks_cannot_mutate_a_replacement_pi() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let old_runtime = manager
            .lock_state()
            .unwrap()
            .panes
            .running(shell_id)
            .unwrap()
            .runtime_id;
        let old_binding = PiRuntimeBinding {
            session_id: session.id,
            shell_id,
            runtime_id: old_runtime,
        };
        let old_attachment = TerminalAttachmentLease {
            manager,
            shell_id,
            runtime_id: old_runtime,
        };
        let mut replacement = spawn_shell(
            &ShellCommand::parse("/bin/sh").unwrap(),
            session.id,
            &fixture.directory,
            WindowSize::DEFAULT,
        )
        .unwrap();
        replacement.role = PaneRole::Pi;
        replacement.attachments = 1;
        let binding = PiRuntimeBinding {
            runtime_id: replacement.runtime_id,
            ..old_binding
        };
        let mut old = manager
            .lock_state()
            .unwrap()
            .install_running(shell_id, replacement)
            .unwrap();
        process::stop(&mut old.child, process::SHELL_STOP_GRACE);

        manager.set_pi_connection(binding, true).unwrap();
        assert!(
            manager
                .observe_pi_event(binding, "agent.start", &json!({}))
                .unwrap()
        );
        manager
            .persist_pi_session_id(binding, &session.session_uuid, "replacement")
            .unwrap();
        // A stale attachment's release must not detach the replacement's clients.
        drop(old_attachment);
        manager.set_pi_connection(old_binding, false).unwrap();
        assert!(
            !manager
                .observe_pi_event(old_binding, "agent.settled", &json!({}))
                .unwrap()
        );
        assert!(
            !manager
                .observe_pi_event(
                    old_binding,
                    "session.info",
                    &json!({ "name": "stale title" }),
                )
                .unwrap()
        );
        assert_eq!(
            manager
                .persist_pi_session_id(old_binding, &session.session_uuid, "old")
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert!(!manager.pi_runtime_is_current(old_binding));
        assert!(manager.pi_runtime_is_current(binding));
        let history = manager.pi_session_directory.join("resume.jsonl");
        fs::write(&history, b"unchanged transcript").unwrap();
        assert_eq!(
            manager
                .resume_archived_pi_session(old_binding, history.to_str().unwrap())
                .unwrap_err()
                .kind(),
            io::ErrorKind::PermissionDenied
        );

        let state = manager.lock_state().unwrap();
        assert_eq!(state.panes.running(shell_id).unwrap().attachments, 1);
        assert!(state.pi_activity[&session.id].connected);
        assert!(state.pi_activity[&session.id].working);
        let updated = session_metadata(&state, session.id, &manager.attach_socket_path).unwrap();
        assert_eq!(updated.pi_session_id.as_deref(), Some("replacement"));
        assert_eq!(updated.name, session.name);
    }

    #[test]
    fn reaper_isolates_wait_errors_without_guessing_process_exit() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let uncertain = manager.create_session().unwrap();
        let exited = manager.create_session().unwrap();
        let uncertain_shell = uncertain.shells[0].id;
        let exited_shell = exited.shells[0].id;
        {
            let mut state = manager.lock_state().unwrap();
            let child = &mut state.panes.running_mut(uncertain_shell).unwrap().child;
            child.kill().unwrap();
            let mut status = 0;
            // SAFETY: this fixture owns the still-unreaped child. Reaping outside
            // Child deliberately simulates lost wait ownership (ECHILD).
            assert_eq!(
                unsafe { libc::waitpid(child.id() as libc::pid_t, &mut status, 0) },
                child.id() as libc::pid_t
            );
            let child = &mut state.panes.running_mut(exited_shell).unwrap().child;
            child.kill().unwrap();
            assert!(wait_for_shell_exit(child, Duration::from_secs(2)).unwrap());
        }
        manager.reap_exited_sessions().unwrap();
        manager.reap_exited_sessions().unwrap();
        let state = manager.lock_state().unwrap();
        assert!(
            state
                .panes
                .running(uncertain_shell)
                .unwrap()
                .wait_error_reported
        );
        assert!(!state.panes.running(exited_shell).is_some());
        let uncertain_state: String = state
            .database
            .query_row(
                "SELECT state FROM sessions WHERE id = ?",
                params![uncertain.id.get()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(uncertain_state, "open");
        let exited_state: String = state
            .database
            .query_row(
                "SELECT state FROM sessions WHERE id = ?",
                params![exited.id.get()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(exited_state, "archived");
    }

    #[test]
    fn shutdown_does_not_hold_the_catalog_lock_during_child_cleanup() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        {
            let state = manager.lock_state().unwrap();
            let running = &state.panes.running(shell_id).unwrap();
            let (_, output) = running.output.subscribe(None);
            process::write_all(
                running.master.as_raw_fd(),
                b"trap '' TERM; printf '%s%s\\n' AXO_STOP_ READY\n",
                TERMINAL_INPUT_WRITE_TIMEOUT,
            )
            .unwrap();
            assert!(read_until(
                &output,
                b"AXO_STOP_READY",
                Duration::from_secs(3)
            ));
        }
        let (done, completed) = mpsc::channel();
        let owner = Arc::clone(manager);
        let shutdown = thread::spawn(move || {
            owner.shutdown();
            done.send(()).unwrap();
        });
        let deadline = Instant::now() + Duration::from_millis(400);
        loop {
            if let Ok(state) = manager.state.try_lock()
                && state.panes.running_is_empty()
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "shutdown held the catalog lock while stopping a child"
            );
            thread::sleep(Duration::from_millis(5));
        }
        completed.recv_timeout(Duration::from_secs(5)).unwrap();
        shutdown.join().unwrap();
        manager.shutdown(); // Idempotent: no repeat signals or joins.
    }

    #[test]
    fn shutdown_releases_an_idle_terminal_attachment() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        manager.stop_workers.store(false, Ordering::Relaxed);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let (mut client, server) = UnixStream::pair().unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        writeln!(client, "{}", shell_id.get()).unwrap();
        let permit = AttachmentPermit::try_acquire(Arc::new(AtomicUsize::new(0))).unwrap();
        let weak = Arc::downgrade(manager);
        let (done, completed) = mpsc::channel();
        let worker = thread::spawn(move || {
            handle_attachment(server, weak, permit);
            done.send(()).unwrap();
        });
        let mut header = [0; 8];
        client.read_exact(&mut header).unwrap();
        assert_ne!(u64::from_be_bytes(header), u64::MAX);
        manager.shutdown();
        completed.recv_timeout(Duration::from_secs(3)).unwrap();
        worker.join().unwrap();
        assert!(manager.lock_state().unwrap().panes.running_is_empty());
        assert_eq!(Arc::strong_count(manager), 1);
    }

    #[test]
    fn a_stalled_client_is_released_without_blocking_the_shell() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        manager.stop_workers.store(false, Ordering::Relaxed);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let output = Arc::clone(
            &manager
                .lock_state()
                .unwrap()
                .panes
                .running(shell_id)
                .unwrap()
                .output,
        );
        let (mut client, server) = UnixStream::pair().unwrap();
        writeln!(client, "{}", shell_id.get()).unwrap();
        let permit = AttachmentPermit::try_acquire(Arc::new(AtomicUsize::new(0))).unwrap();
        let weak = Arc::downgrade(manager);
        let (done, completed) = mpsc::channel();
        let worker = thread::spawn(move || {
            handle_attachment(server, weak, permit);
            done.send(()).unwrap();
        });
        // Intentionally never read. Output keeps flowing (recording never blocks) until the
        // client's backlog overflows and Axod disconnects it.
        let chunk = vec![b'x'; 64 * 1024];
        let deadline = Instant::now() + Duration::from_secs(10);
        while completed.try_recv().is_err() {
            assert!(
                Instant::now() < deadline,
                "stalled client was never released"
            );
            output.record(&chunk);
        }
        worker.join().unwrap();
        assert_eq!(output.subscriber_count(), 0);
        assert_eq!(
            manager
                .lock_state()
                .unwrap()
                .panes
                .running(shell_id)
                .unwrap()
                .attachments,
            0
        );
        drop(client);
    }

    #[test]
    fn pi_writer_lock_is_inherited_only_by_its_pi_child() {
        let fixture = LifecycleFixture::new();
        let fake_pi = fixture.directory.join("fake-pi");
        fs::write(&fake_pi, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&fake_pi, fs::Permissions::from_mode(0o700)).unwrap();
        let agent = AgentCommand::parse(fake_pi.to_str().unwrap()).unwrap();
        let session_uuid = new_uuid_v4().unwrap();
        let pane_id = new_uuid_v4().unwrap();
        let file = fixture
            .manager
            .pi_session_directory
            .join(format!("{session_uuid}.jsonl"));
        fs::write(&file, b"preserved history").unwrap();
        let socket =
            BridgeSocketPath::for_session(&fixture.manager.pi_session_directory, &session_uuid)
                .unwrap();
        let mut pi = {
            let state = fixture.manager.lock_state().unwrap();
            spawn_new_pi(
                &state.database,
                &PiLaunchRequest {
                    agent_command: agent.clone(),
                    session_id: sid(900),
                    initial_pwd: fixture.directory.clone(),
                    session_file: file.clone(),
                    bridge_socket: socket.clone(),
                    session_uuid: session_uuid.clone(),
                    pane_id: pane_id.clone(),
                    previous_token: None,
                    size: WindowSize::DEFAULT,
                },
            )
            .unwrap()
        };
        // Guard the owned fixture child even if an assertion below fails.
        let lock = pi._writer_lock.take().unwrap();
        let mut child = RunningShellGuard(pi);
        // SAFETY: lock is a live descriptor owned by this fixture.
        assert_ne!(
            unsafe { libc::fcntl(lock.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        let mut unrelated =
            ChildProcessGuard(Command::new("/bin/sleep").arg("60").spawn().unwrap());
        drop(lock);
        assert_eq!(
            WriterLock::acquire(&file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        process::stop(&mut child.0.child, process::SHELL_STOP_GRACE);
        // Concurrent forked fixture children may briefly hold CLOEXEC copies until exec.
        let recovered = WriterLock::wait(&file, Duration::from_secs(1), &|| Ok(())).unwrap();
        assert!(unrelated.0.try_wait().unwrap().is_none());
        assert_eq!(fs::read(&file).unwrap(), b"preserved history");
        drop(recovered);
    }

    #[test]
    fn session_metadata_reads_emoji_workspace_name_and_ignores_a_corrupt_layout() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.create_session().unwrap();
        let workspace_id = new_uuid_v4().unwrap();
        {
            let state = manager.lock_state().unwrap();
            state
                .database
                .execute(
                    "INSERT INTO workspaces (workspace_id, name, directory_path, state, created_at)
                     VALUES (?1, 'Axo', '/tmp', 'open', 0)",
                    params![workspace_id],
                )
                .unwrap();
            state
                .database
                .execute(
                    "UPDATE sessions SET emoji = '🦀', workspace_id = ?1, layout_json = '{\"not\": 1}'
                     WHERE id = ?2",
                    params![workspace_id, session.id.get()],
                )
                .unwrap();
            let record = session_metadata(&state, session.id, &manager.attach_socket_path).unwrap();
            assert_eq!(record.emoji.as_deref(), Some("🦀"));
            assert_eq!(record.workspace_id.as_deref(), Some(workspace_id.as_str()));
            assert_eq!(record.workspace_name.as_deref(), Some("Axo"));
            assert_eq!(record.layout, None, "a corrupt stored layout is ignored");
            assert_eq!(record.shells.len(), 1);

            // A Session whose Workspace is gone is inconsistent, not Workspace-less.
            state
                .database
                .execute(
                    "UPDATE workspaces SET state = 'archived' WHERE workspace_id = ?1",
                    params![workspace_id],
                )
                .unwrap();
            assert!(session_metadata(&state, session.id, &manager.attach_socket_path).is_err());
        }
    }

    #[test]
    fn closing_a_session_stops_every_pane_together_on_one_worker() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.create_session().unwrap();
        manager.create_shell(session.id).unwrap();
        manager.create_shell(session.id).unwrap();
        let process_ids: Vec<libc::pid_t> = {
            let state = manager.lock_state().unwrap();
            state
                .panes
                .in_session(session.id)
                .filter_map(|(_, pane)| match pane {
                    Pane::Running(running) => Some(running.child.id() as libc::pid_t),
                    Pane::Unavailable(_) => None,
                })
                .collect()
        };
        assert_eq!(process_ids.len(), 3);

        let started = Instant::now();
        manager.close_session(session.id).unwrap();
        assert!(
            started.elapsed() < process::SHELL_STOP_GRACE,
            "closing must not wait for its panes to stop"
        );
        assert_eq!(
            manager.workers.lock().unwrap().len(),
            1,
            "one cleanup worker per close, not one per pane"
        );
        let worker = manager.workers.lock().unwrap().pop().unwrap();
        worker.join().unwrap();
        assert!(
            started.elapsed() < process::SHELL_STOP_GRACE + process::KILL_WAIT,
            "panes are stopped together, not one grace after another"
        );
        for process_id in process_ids {
            // SAFETY: signal 0 only checks whether the process still exists.
            let alive = unsafe { libc::kill(process_id, 0) } == 0;
            assert!(
                !alive,
                "pane process {process_id} survived its Session's close"
            );
        }
    }

    #[test]
    fn worker_cleanup_never_joins_itself() {
        let (sender, receiver) = mpsc::channel::<JoinHandle<()>>();
        let (done, completed) = mpsc::channel();
        let worker = thread::spawn(move || {
            join_session_workers(vec![receiver.recv().unwrap()]);
            done.send(()).unwrap();
        });
        sender.send(worker).unwrap();
        completed.recv_timeout(Duration::from_secs(2)).unwrap();
    }

    #[test]
    fn host_identity_persists_while_generation_rotates() {
        let directory =
            std::env::temp_dir().join(format!("axo-host-identity-{}", new_uuid_v4().unwrap()));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("axo.db");

        let first_host_id;
        let first_generation = new_uuid_v4().unwrap();
        {
            let mut database = Connection::open(&path).unwrap();
            initialize_database(&mut database).unwrap();
            first_host_id = load_or_create_host_id(&database).unwrap();
        }

        let second_generation = new_uuid_v4().unwrap();
        let second_host_id;
        {
            let mut database = Connection::open(&path).unwrap();
            initialize_database(&mut database).unwrap();
            second_host_id = load_or_create_host_id(&database).unwrap();
        }

        assert_eq!(first_host_id, second_host_id);
        assert_ne!(first_generation, second_generation);
        assert!(is_uuid(&first_host_id));
        assert_eq!(first_host_id.as_bytes()[14], b'4');
        assert!(matches!(
            first_host_id.as_bytes()[19],
            b'8' | b'9' | b'a' | b'b'
        ));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn local_subscriptions_signal_lag_filter_output_and_expire() {
        let directory = PathBuf::from("/tmp").join(format!("axos-{}", new_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        let manager = open_with_silent_shell(&directory);
        let drain = |id: &str| {
            while manager
                .next_event(id, Duration::from_millis(1))
                .unwrap()
                .is_some()
            {}
        };
        let catalog = manager.subscribe(None, false).unwrap();
        let output = manager.subscribe(None, true).unwrap();
        drain(&catalog);
        drain(&output);

        let terminal_output = Event::TerminalOutput {
            session_id: sid(1),
            shell_id: shid(1),
            sequence: 1,
            data: String::new(),
        };
        manager.publish_event(terminal_output.clone());
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None,
            "catalog subscriptions must not carry terminal bytes"
        );
        assert_eq!(
            manager
                .next_event(&output, Duration::from_millis(1))
                .unwrap()
                .as_deref(),
            Some(&terminal_output)
        );

        let pi_event = Event::PiEvent {
            session_id: sid(1),
            pi_session_id: "pi-session".to_owned(),
            stream_id: "stream".to_owned(),
            sequence: 1,
            name: "message_update".to_owned(),
            data: Value::Null,
        };
        manager.publish_event(pi_event.clone());
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None,
            "catalog subscriptions must not carry Pi stream events"
        );
        assert_eq!(
            manager
                .next_event(&output, Duration::from_millis(1))
                .unwrap()
                .as_deref(),
            Some(&pi_event)
        );

        // A new subscription's initial snapshots must not be rebroadcast to existing subscribers.
        let late = manager.subscribe(None, false).unwrap();
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None,
            "initial snapshots belong to the new subscriber only"
        );
        drain(&late);

        // One subscriber's long-poll must not block another's poll or publishers.
        std::thread::scope(|scope| {
            let waiter = scope.spawn(|| manager.next_event(&late, Duration::from_secs(5)));
            std::thread::sleep(Duration::from_millis(50));
            let started = Instant::now();
            assert_eq!(
                manager
                    .next_event(&catalog, Duration::from_millis(1))
                    .unwrap(),
                None
            );
            assert!(
                started.elapsed() < Duration::from_secs(1),
                "a concurrent long-poll blocked another subscriber"
            );
            manager.publish_workspace_changed("wake");
            let woken = waiter.join().unwrap().unwrap().unwrap();
            assert!(matches!(*woken, Event::WorkspaceChanged { .. }));
        });
        drain(&catalog);
        manager.unsubscribe(&late).unwrap();

        for name in ["a", "b", "c"] {
            manager.publish_workspace_changed(name);
        }
        let batch = manager
            .next_events(&catalog, Duration::from_millis(1), 2)
            .unwrap();
        assert_eq!(batch.len(), 2, "batches are bounded by maxEvents");
        assert_eq!(wire(&*batch[0])["workspaceId"], "a");
        assert_eq!(wire(&*batch[1])["workspaceId"], "b");
        drain(&catalog);
        drain(&output);

        manager.publish_workspace_changed("workspace");
        let changed = manager
            .next_event(&catalog, Duration::from_millis(1))
            .unwrap()
            .unwrap();
        assert_eq!(wire(changed)["workspaceId"], "workspace");
        drain(&output);

        for _ in 0..=MAX_QUEUED_EVENTS_PER_SUBSCRIPTION {
            manager.publish_workspace_changed("flood");
        }
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap()
                .as_deref(),
            Some(&Event::SubscriptionLagged),
            "a full queue must be reported, never silently gapped"
        );
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None
        );
        drain(&output);

        manager.request_session_focus(sid(5)).unwrap();
        let focus = manager
            .next_event(&catalog, Duration::from_millis(1))
            .unwrap()
            .unwrap();
        let focus = wire(focus);
        assert_eq!(focus["type"], "session.focus");
        assert_eq!(focus["sessionId"], 5);
        assert_eq!(manager.take_pending_resume_focus().unwrap(), Some(sid(5)));
        *manager.pending_resume_focus.lock().unwrap() = Some((
            sid(6),
            Instant::now().checked_sub(PENDING_FOCUS_LIFETIME).unwrap(),
        ));
        assert_eq!(
            manager.take_pending_resume_focus().unwrap(),
            None,
            "a stale focus request must not be replayed by a later listing"
        );

        *manager
            .subscriptions
            .lock()
            .unwrap()
            .get(&catalog)
            .unwrap()
            .last_polled
            .lock()
            .unwrap() = Instant::now()
            .checked_sub(SUBSCRIPTION_IDLE_EXPIRY)
            .unwrap();
        let replacement = manager.subscribe(None, false).unwrap();
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound,
            "unpolled subscriptions are reclaimed"
        );
        assert!(
            manager
                .subscribers
                .lock()
                .unwrap()
                .iter()
                .all(|s| s.id != catalog)
        );
        manager.unsubscribe(&replacement).unwrap();
        manager.unsubscribe(&output).unwrap();
        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn manual_session_rename_is_separate_and_workspace_archive_preserves_history() {
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", new_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        let manager = open_with_silent_shell(&directory);
        let workspace_id = new_uuid_v4().unwrap();
        let session_uuid = new_uuid_v4().unwrap();
        let session_id = sid(702);
        let history = directory.join("pi-session.jsonl");
        fs::write(&history, b"canonical Pi history").unwrap();
        {
            let state = manager.lock_state().unwrap();
            state
                .database
                .execute(
                    "INSERT INTO workspaces
                     (workspace_id, name, directory_path, state, created_at)
                     VALUES (?1, 'Original Workspace', '/tmp', 'open', ?2)",
                    params![workspace_id, unix_timestamp()],
                )
                .unwrap();
            state
                .database
                .execute(
                    "INSERT INTO sessions
                     (id, initial_pwd, state, created_at, workspace_id, session_uuid, name, pi_session_file)
                     VALUES (?1, '/tmp', 'open', ?2, ?3, ?4, 'Pi conversation title', ?5)",
                    params![
                        session_id.get(),
                        unix_timestamp(),
                        workspace_id,
                        session_uuid,
                        history.to_string_lossy(),
                    ],
                )
                .unwrap();
        }

        let renamed_session = manager.rename_session(session_id, "Sidebar label").unwrap();
        assert_eq!(renamed_session.name, "Pi conversation title");
        assert_eq!(
            renamed_session.manual_name.as_deref(),
            Some("Sidebar label")
        );
        assert_eq!(
            serde_json::to_value(&renamed_session).unwrap()["manualName"],
            "Sidebar label"
        );

        let renamed_workspace = manager
            .rename_workspace(&workspace_id, "Renamed Workspace")
            .unwrap();
        assert_eq!(renamed_workspace.name, "Renamed Workspace");
        let session_after_workspace_rename =
            manager.rename_session(session_id, "Sidebar label").unwrap();
        assert_eq!(
            session_after_workspace_rename.workspace_name.as_deref(),
            Some("Renamed Workspace")
        );

        let archived_sessions = manager.archive_workspace(&workspace_id).unwrap();
        assert_eq!(archived_sessions, vec![session_id]);
        assert!(manager.list_workspaces().unwrap().is_empty());
        let state = manager.lock_state().unwrap();
        let archived_state: (String, String) = state
            .database
            .query_row(
                "SELECT state, termination_reason FROM sessions WHERE id = ?1",
                params![session_id.get()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            archived_state,
            ("archived".to_owned(), "workspace_archived".to_owned())
        );
        drop(state);
        assert_eq!(fs::read(&history).unwrap(), b"canonical Pi history");

        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn terminal_attachment_permits_are_bounded_and_released() {
        let active = Arc::new(AtomicUsize::new(0));
        let mut permits = Vec::new();
        for _ in 0..MAX_CONCURRENT_TERMINAL_ATTACHMENTS {
            match AttachmentPermit::try_acquire(Arc::clone(&active)) {
                Some(permit) => permits.push(permit),
                None => panic!("attachment capacity should be available"),
            }
        }
        assert!(AttachmentPermit::try_acquire(Arc::clone(&active)).is_none());
        assert_eq!(
            active.load(Ordering::Relaxed),
            MAX_CONCURRENT_TERMINAL_ATTACHMENTS
        );

        drop(permits);
        assert_eq!(active.load(Ordering::Relaxed), 0);
        assert!(AttachmentPermit::try_acquire(active).is_some());
    }

    #[test]
    fn pi_bridge_credential_is_persisted_per_session() {
        let mut database = Connection::open_in_memory().unwrap();
        initialize_database(&mut database).unwrap();
        let session_uuid = new_uuid_v4().unwrap();
        let first_token = new_uuid_v4().unwrap();
        let second_token = new_uuid_v4().unwrap();

        assert_eq!(
            load_pi_bridge_token(&database, &session_uuid).unwrap(),
            None
        );
        store_pi_bridge_token(&database, &session_uuid, &first_token).unwrap();
        assert_eq!(
            load_pi_bridge_token(&database, &session_uuid).unwrap(),
            Some(first_token)
        );
        store_pi_bridge_token(&database, &session_uuid, &second_token).unwrap();
        assert_eq!(
            load_pi_bridge_token(&database, &session_uuid).unwrap(),
            Some(second_token)
        );
    }

    #[test]
    fn automatic_pi_restart_preserves_busy_pi_and_explicit_restart_preserves_history() {
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", new_uuid_v4().unwrap()));
        let server_directory = directory.join("server");
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory).unwrap();

        let session_id = sid(701);
        let shell_id = shid(801);
        let session_uuid = new_uuid_v4().unwrap();
        let pane_id = new_uuid_v4().unwrap();
        let session_file = pi_session_directory.join(format!("{session_uuid}.jsonl"));
        fs::write(&session_file, b"preserved Pi transcript\n").unwrap();
        let lock_path = session_file.with_extension("jsonl.lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)
            .unwrap();
        // SAFETY: lock is a live file descriptor opened by this isolated test.
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        // Make the locked open-file description survive exec so the fixture Pi owns the lock.
        let lock_fd = lock.as_raw_fd();
        let mut old_pi_command = Command::new("/bin/sh");
        old_pi_command.args(["-c", "trap '' TERM; exec /bin/sleep 60"]);
        // SAFETY: the child-only hook clears close-on-exec on the fixture lock descriptor.
        unsafe {
            old_pi_command.pre_exec(move || {
                if libc::setsid() == -1 {
                    return Err(io::Error::last_os_error());
                }
                if libc::fcntl(lock_fd, libc::F_SETFD, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut old_pi = ChildProcessGuard(old_pi_command.spawn().unwrap());
        let old_pi_process_id = old_pi.0.id();
        drop(lock);

        let mut database = Connection::open(server_directory.join(DATABASE_FILE)).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO sessions
                    (id, initial_pwd, state, created_at, layout_json, session_uuid, name, pi_session_file)
                 VALUES (?1, '/tmp', 'open', ?2, ?3, ?4, 'Recovery fixture', ?5)",
                params![
                    session_id.get(),
                    unix_timestamp(),
                    serde_json::to_string(&Layout::single(shell_id)).unwrap(),
                    session_uuid,
                    session_file.to_string_lossy(),
                ],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO shells (id, session_id, initial_pwd, state, created_at, role, pane_id)
                 VALUES (?1, ?2, '/tmp', 'open', ?3, 'pi', ?4)",
                params![shell_id.get(), session_id.get(), unix_timestamp(), pane_id],
            )
            .unwrap();
        let bridge_token = new_uuid_v4().unwrap();
        store_pi_bridge_token(&database, &session_uuid, &bridge_token).unwrap();
        drop(database);

        let bridge_socket =
            BridgeSocketPath::for_session(&pi_session_directory, &session_uuid).unwrap();
        drop(UnixListener::bind(bridge_socket.as_path()).unwrap());

        let manager = open_with_silent_shell(&server_directory);
        let stored_bridge_socket: String = manager
            .lock_state()
            .unwrap()
            .database
            .query_row(
                "SELECT pi_bridge_socket_path FROM sessions WHERE id = ?1",
                params![session_id.get()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(Path::new(&stored_bridge_socket), bridge_socket.as_path());
        let sessions = manager.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session_id);
        assert!(matches!(sessions[0].status, SessionStatus::Unavailable));
        assert_eq!(sessions[0].layout, Some(Layout::single(shell_id)));
        assert_eq!(sessions[0].shells.len(), 1);
        assert_eq!(sessions[0].shells[0].id, shell_id);
        assert!(!sessions[0].shells[0].is_available());
        assert_eq!(sessions[0].shells[0].process_id, 0);
        assert!(matches!(
            sessions[0].shells[0].availability,
            Availability::Unavailable { .. }
        ));
        manager
            .set_layout(session_id, Layout::single(shell_id))
            .unwrap();
        assert!(
            manager
                .restart_unavailable_pi(
                    session_id,
                    shell_id,
                    TakeoverPolicy::PreserveExistingProcess,
                )
                .is_err()
        );
        assert!(old_pi.0.try_wait().unwrap().is_none());

        let restart_error = manager
            .restart_unavailable_pi(session_id, shell_id, TakeoverPolicy::ExplicitUserRestart)
            .unwrap_err();
        assert_eq!(restart_error.kind(), io::ErrorKind::PermissionDenied);
        assert!(old_pi.0.try_wait().unwrap().is_none());
        assert!(!manager.list_sessions().unwrap()[0].shells[0].is_available());

        manager.restore_open_sessions().unwrap();
        assert_eq!(manager.list_sessions().unwrap().len(), 1);
        assert!(!manager.list_sessions().unwrap()[0].shells[0].is_available());

        fs::remove_file(bridge_socket.as_path()).unwrap();
        let listener = UnixListener::bind(bridge_socket.as_path()).unwrap();
        let handshake_session_file = session_file.to_string_lossy().into_owned();
        let handshake_session_uuid = session_uuid.clone();
        let handshake_pane_id = pane_id.clone();
        let handshake_bridge_token = bridge_token.clone();
        let bridge_server = thread::spawn(move || {
            for (expected_action, result_reason) in
                [("shutdownIfIdle", "busy"), ("shutdown", "stale")]
            {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let authentication = bridge::read_record::<Value>(&mut reader).unwrap();
                assert_eq!(authentication["token"], handshake_bridge_token);
                bridge::write_record(
                    reader.get_mut(),
                    &json!({ "type": "authenticated", "protocolVersion": 1 }),
                )
                .unwrap();
                bridge::write_record(
                    reader.get_mut(),
                    &json!({
                        "type": "hello",
                        "protocolVersion": 1,
                        "identity": {
                            "axoSessionId": handshake_session_uuid,
                            "axoPaneId": handshake_pane_id,
                            "piSessionId": "pi-takeover",
                            "sessionFile": handshake_session_file,
                            "cwd": "/tmp",
                            "processId": old_pi_process_id
                        }
                    }),
                )
                .unwrap();
                let shutdown = bridge::read_record::<Value>(&mut reader).unwrap();
                assert_eq!(shutdown["action"]["kind"], expected_action);
                bridge::write_record(
                    reader.get_mut(),
                    &json!({
                        "type": "commandResult",
                        "requestId": shutdown["requestId"],
                        "result": { "accepted": false, "reason": result_reason }
                    }),
                )
                .unwrap();
            }
        });

        let fake_pi = directory.join("fake-pi");
        fs::write(&fake_pi, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&fake_pi, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(fake_pi.to_str().unwrap()).unwrap();

        let automatic_error = manager
            .restart_unavailable_pi(
                session_id,
                shell_id,
                TakeoverPolicy::PreserveExistingProcess,
            )
            .unwrap_err();
        assert_eq!(automatic_error.kind(), io::ErrorKind::WouldBlock);
        assert!(old_pi.0.try_wait().unwrap().is_none());
        assert!(!manager.list_sessions().unwrap()[0].shells[0].is_available());

        let restarted = manager
            .restart_unavailable_pi(session_id, shell_id, TakeoverPolicy::ExplicitUserRestart)
            .unwrap();
        bridge_server.join().unwrap();
        assert_eq!(restarted.id, session_id);
        assert_eq!(restarted.shells.len(), 1);
        assert_eq!(restarted.shells[0].id, shell_id);
        assert!(restarted.shells[0].is_available());
        assert!(restarted.shells[0].process_id > 0);
        assert!(manager.list_sessions().unwrap()[0].shells[0].is_available());
        assert!(old_pi.0.try_wait().unwrap().is_some());
        let terminal_shell = manager.create_shell(session_id).unwrap();
        manager
            .set_layout(
                session_id,
                Layout::try_from(LayoutNode::Split {
                    id: new_uuid_v4().unwrap(),
                    direction: LayoutDirection::Right,
                    ratio: 0.5,
                    first: Box::new(LayoutNode::Pane { shell_id }),
                    second: Box::new(LayoutNode::Pane {
                        shell_id: terminal_shell.id,
                    }),
                })
                .unwrap(),
            )
            .unwrap();
        assert_eq!(
            fs::read(&session_file).unwrap(),
            b"preserved Pi transcript\n"
        );

        {
            let mut state = manager.lock_state().unwrap();
            state
                .panes
                .running_mut(shell_id)
                .unwrap()
                .child
                .kill()
                .unwrap();
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            manager.reap_exited_sessions().unwrap();
            let sessions = manager.list_sessions().unwrap();
            if sessions.len() == 1
                && sessions[0]
                    .shells
                    .iter()
                    .any(|shell| shell.id == shell_id && !shell.is_available())
            {
                break;
            }
            assert!(Instant::now() < deadline, "Pi exit was not reconciled");
            thread::sleep(Duration::from_millis(10));
        }
        let sessions = manager.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session_id);
        assert_eq!(
            sessions[0].pi_session_file.as_deref(),
            Some(session_file.as_path())
        );
        assert_eq!(sessions[0].shells.len(), 2);
        assert!(
            !sessions[0]
                .shells
                .iter()
                .find(|shell| shell.id == shell_id)
                .unwrap()
                .is_available()
        );
        assert!(
            sessions[0]
                .shells
                .iter()
                .find(|shell| shell.id == terminal_shell.id)
                .unwrap()
                .is_available()
        );
        assert_eq!(
            fs::read(&session_file).unwrap(),
            b"preserved Pi transcript\n"
        );
        {
            let state = manager.lock_state().unwrap();
            let session_state: (String, Option<String>) = state
                .database
                .query_row(
                    "SELECT state, termination_reason FROM sessions WHERE id = ?1",
                    params![session_id.get()],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap();
            assert_eq!(session_state, ("open".to_owned(), None));
        }
        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn pi_resume_reopens_archived_axo_session_without_replacing_history() {
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", new_uuid_v4().unwrap()));
        let server_directory = directory.join("server");
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory).unwrap();
        let database_path = server_directory.join(DATABASE_FILE);
        let session_id = sid(901);
        let shell_id = shid(902);
        let session_uuid = new_uuid_v4().unwrap();
        let pane_id = new_uuid_v4().unwrap();
        let workspace_id = new_uuid_v4().unwrap();
        let workspace_root = PathBuf::from("/tmp").canonicalize().unwrap();
        let workspace_root_string = workspace_root.to_string_lossy().into_owned();
        let session_file = pi_session_directory.join(format!("{session_uuid}.jsonl"));
        let history = b"archived Pi conversation must remain canonical\n";
        fs::write(&session_file, history).unwrap();

        let mut database = Connection::open(&database_path).unwrap();
        initialize_database(&mut database).unwrap();
        database
            .execute(
                "INSERT INTO workspaces (workspace_id, name, directory_path, state, created_at, archived_at)
                 VALUES (?1, 'Archived Workspace', ?2, 'archived', ?3, ?4)",
                params![
                    workspace_id,
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp()
                ],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO sessions
                    (id, initial_pwd, state, created_at, archived_at, termination_reason,
                     layout_json, workspace_id, session_uuid, pi_session_file, pi_session_id)
                 VALUES (?1, ?2, 'archived', ?3, ?4, 'pi_exited', ?5, ?6, ?7, ?8, 'pi-session-archived')",
                params![
                    session_id.get(),
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp(),
                    serde_json::to_string(&Layout::single(shell_id)).unwrap(),
                    workspace_id,
                    session_uuid,
                    session_file.to_string_lossy(),
                ],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO shells
                    (id, session_id, initial_pwd, state, created_at, archived_at, termination_reason, role, pane_id)
                 VALUES (?1, ?2, ?3, 'archived', ?4, ?5, 'pi_exited', 'pi', ?6)",
                params![
                    shell_id.get(),
                    session_id.get(),
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp(),
                    pane_id
                ],
            )
            .unwrap();
        drop(database);

        let manager = open_with_silent_shell(&server_directory);
        let fake_pi = directory.join("fake-pi");
        fs::write(&fake_pi, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&fake_pi, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(fake_pi.to_str().unwrap()).unwrap();
        let active_workspace = manager
            .create_workspace(rpc::CreateWorkspace {
                name: "Active Workspace".to_owned(),
                directory_path: PathBuf::from("/tmp").canonicalize().unwrap(),
                directory_bookmark: None,
            })
            .unwrap();
        let requester_session_id = active_workspace.session.id;
        let requester_shell_id = active_workspace.session.shells[0].id;
        let requester = PiRuntimeBinding {
            session_id: requester_session_id,
            shell_id: requester_shell_id,
            runtime_id: manager
                .lock_state()
                .unwrap()
                .panes
                .running(requester_shell_id)
                .unwrap()
                .runtime_id,
        };
        let unrelated_history = directory.join("unowned.jsonl");
        fs::write(&unrelated_history, b"not an Axo transcript").unwrap();
        let rejected = manager
            .resume_archived_pi_session(requester, unrelated_history.to_str().unwrap())
            .unwrap_err();
        assert_eq!(rejected.kind(), io::ErrorKind::PermissionDenied);

        assert_eq!(
            manager
                .resume_archived_pi_session(requester, session_file.to_str().unwrap())
                .unwrap(),
            session_id
        );
        assert_eq!(
            manager.take_pending_resume_focus().unwrap(),
            Some(session_id)
        );
        assert_eq!(manager.take_pending_resume_focus().unwrap(), None);
        let resumed = manager
            .list_sessions()
            .unwrap()
            .into_iter()
            .find(|session| session.id == session_id)
            .unwrap();
        assert_eq!(
            resumed.pi_session_file.as_deref(),
            Some(session_file.as_path())
        );
        assert_eq!(resumed.workspace_id.as_deref(), Some(workspace_id.as_str()));
        assert_eq!(resumed.shells.len(), 1);
        assert_eq!(resumed.shells[0].id, shell_id);
        assert!(resumed.shells[0].is_available());
        assert_eq!(fs::read(&session_file).unwrap(), history);
        assert!(
            manager
                .list_sessions()
                .unwrap()
                .iter()
                .all(|session| session.id != requester_session_id)
        );
        let requester_state: (String, Option<String>) = manager
            .lock_state()
            .unwrap()
            .database
            .query_row(
                "SELECT state, termination_reason FROM sessions WHERE id = ?1",
                params![requester_session_id.get()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            requester_state,
            ("archived".to_owned(), Some("explicit_close".to_owned()))
        );
        let workspace_state: String = manager
            .lock_state()
            .unwrap()
            .database
            .query_row(
                "SELECT state FROM workspaces WHERE workspace_id = ?1",
                params![workspace_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(workspace_state, "open");

        manager.shutdown();
        drop(manager);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn archives_legacy_shell_sessions_during_workspace_cutover() {
        let mut database = Connection::open_in_memory().unwrap();
        database
            .execute_batch(
                "CREATE TABLE sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    initial_pwd TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER,
                    termination_reason TEXT
                );
                INSERT INTO sessions (id, initial_pwd, state, created_at)
                VALUES (7, '/tmp', 'open', 123);",
            )
            .unwrap();

        initialize_database(&mut database).unwrap();

        let session: (i64, String, String) = database
            .query_row(
                "SELECT id, initial_pwd, state FROM sessions WHERE id = 7",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        let shell: (i64, i64, String, String) = database
            .query_row(
                "SELECT id, session_id, initial_pwd, state FROM shells WHERE id = 7",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(session, (7, "/tmp".to_owned(), "archived".to_owned()));
        assert_eq!(shell, (7, 7, "/tmp".to_owned(), "archived".to_owned()));
    }

    #[test]
    fn adds_layout_storage_to_existing_tab_databases() {
        let mut database = Connection::open_in_memory().unwrap();
        database
            .execute_batch(
                "CREATE TABLE sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    initial_pwd TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER,
                    termination_reason TEXT
                );
                CREATE TABLE shells (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    initial_pwd TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
                    created_at INTEGER NOT NULL,
                    archived_at INTEGER,
                    termination_reason TEXT
                );
                INSERT INTO sessions (initial_pwd, state, created_at)
                VALUES ('/tmp', 'open', 123);
                INSERT INTO shells (session_id, initial_pwd, state, created_at)
                VALUES (1, '/tmp', 'open', 123);",
            )
            .unwrap();

        initialize_database(&mut database).unwrap();

        let layout: Option<String> = database
            .query_row("SELECT layout_json FROM sessions WHERE id = 1", [], |row| {
                row.get(0)
            })
            .unwrap();
        let schema_version: i64 = database
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(layout, None);
        assert_eq!(schema_version, 7);
        let manual_name_column: i64 = database
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'manual_name'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(manual_name_column, 1);
        let bridge_socket_column: i64 = database
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'pi_bridge_socket_path'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(bridge_socket_column, 1);
        let session_state: String = database
            .query_row("SELECT state FROM sessions WHERE id = 1", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(session_state, "archived");
    }

    #[test]
    fn creates_a_shell_attached_to_a_real_pty() {
        let home = super::super::current_user_home_directory().unwrap();
        let shell = ShellCommand::parse("/bin/zsh").unwrap();
        let mut session = spawn_shell(&shell, sid(1), &home, WindowSize::DEFAULT).unwrap();
        assert!(session.slave_device.starts_with("/dev/"));
        // The child should receive only the slave as stdio, never the PTY master.
        // SAFETY: the test owns this open PTY master descriptor.
        let master_flags = unsafe { libc::fcntl(session.master.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(master_flags, -1);
        assert_ne!(master_flags & libc::FD_CLOEXEC, 0);

        let master = session.master.as_raw_fd();
        let (_, output) = session.output.subscribe(None);
        let command = b"printf 'AXO_PTY_READY\\n'\n";
        // SAFETY: command points to initialized bytes and master is an open PTY.
        let written = unsafe { libc::write(master, command.as_ptr().cast(), command.len()) };
        assert_eq!(written as usize, command.len());
        assert!(read_until(
            &output,
            b"AXO_PTY_READY",
            Duration::from_secs(3)
        ));
        process::stop(&mut session.child, process::SHELL_STOP_GRACE);
    }

    fn read_until(output: &OutputSubscriber, needle: &[u8], timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let mut received = Vec::new();
        while std::time::Instant::now() < deadline {
            match output.next(Duration::from_millis(100)) {
                NextOutput::Chunks(chunks) => {
                    for chunk in chunks {
                        received.extend_from_slice(&chunk);
                    }
                    if received
                        .windows(needle.len())
                        .any(|window| window == needle)
                    {
                        return true;
                    }
                }
                NextOutput::Idle => {}
                _ => return false,
            }
        }
        false
    }

    fn pty_size(manager: &SessionManager, shell_id: ShellId) -> (u16, u16) {
        let state = manager.lock_state().unwrap();
        let size = process::window_size(&state.panes.running(shell_id).unwrap().master).unwrap();
        (size.rows(), size.columns())
    }

    fn test_viewport(width: f64) -> Viewport {
        serde_json::from_value(json!({
            "terminalArea": { "width": width, "height": 600.0 },
            "backingScale": 2.0,
            "cell": { "width": 16, "height": 34 },
            "padding": { "top": 10, "bottom": 10, "left": 2, "right": 2 },
            "dividerThickness": 1.0
        }))
        .unwrap()
    }

    #[test]
    fn the_latest_viewport_sizes_unattached_panes_and_new_ones() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.list_sessions().unwrap().remove(0);
        let first = session.shells[0].id;
        assert_eq!(pty_size(manager, first), (24, 80));

        manager.set_viewport(test_viewport(1000.0)).unwrap();
        assert_eq!(pty_size(manager, first), (34, 124));

        // A new pane starts at the whole area until the client's layout places it.
        let second = manager.create_shell(session.id).unwrap().id;
        assert_eq!(pty_size(manager, second), (34, 124));
        let split = LayoutNode::Split {
            id: new_uuid_v4().unwrap(),
            direction: LayoutDirection::Right,
            ratio: 0.5,
            first: Box::new(LayoutNode::Pane { shell_id: first }),
            second: Box::new(LayoutNode::Pane { shell_id: second }),
        };
        manager
            .set_layout(session.id, Layout::try_from(split).unwrap())
            .unwrap();
        assert_eq!(pty_size(manager, first), (34, 61));
        assert_eq!(pty_size(manager, second), (34, 61));

        // An attached pane belongs to its client; the latest viewport resizes the rest.
        manager
            .lock_state()
            .unwrap()
            .panes
            .running_mut(first)
            .unwrap()
            .attachments = 1;
        manager.set_viewport(test_viewport(500.0)).unwrap();
        assert_eq!(pty_size(manager, first), (34, 61));
        assert_eq!(pty_size(manager, second), (34, 30));

        let state = manager.lock_state().unwrap();
        assert_eq!(
            load_viewport(&state.database).unwrap(),
            Some(test_viewport(500.0))
        );
    }
}
