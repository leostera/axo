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
use axo_pi::takeover::TakeoverGrace;
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
#[cfg(test)]
mod test_support;
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
    /// How long an explicit Pi restart waits before escalating; shortened by tests.
    takeover_grace: TakeoverGrace,
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
                takeover_grace: TakeoverGrace::default(),
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
    use super::{terminal::*, test_support::*};

    use axo_protocol::{is_uuid, new_uuid_v4};
    use axo_pty::process;

    use axo_store::Connection;
    use axo_store::initialize_database;
    use axo_store::load_or_create_host_id;

    use std::fs;

    use std::io::Read;
    use std::io::Write;
    use std::os::fd::AsRawFd;

    use std::os::unix::net::UnixStream;

    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::thread::{self, JoinHandle};
    use std::time::{Duration, Instant};

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
}
