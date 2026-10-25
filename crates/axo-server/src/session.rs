use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::panes::{Pane, PaneProcess, Panes, RecoveryRefused, RuntimeId, UnavailablePane};
use crate::workspace_access::WorkspaceDirectoryAccess;
use axo_ipc::{EventQueue, PushOutcome, TypedMethods};
use axo_pi::takeover::{self, TakeoverPolicy, TakeoverTarget, VerifiedProcessId};
use axo_pi::{
    AgentCommand, BridgeSocketPath, PiLaunch, PiProcess, SocketCleanup, WriterLock, worker,
};
use axo_protocol::rpc::{self, method};
use axo_protocol::{
    Availability, ConfigKey, Event, EventScope, GridSize, Layout, LayoutDirection, LayoutNode,
    PaneRole, RelayStatus, RemoteSessionSnapshot, SessionId, SessionRecord, SessionStatus,
    ShellActivity, ShellId, ShellRecord, Viewport, WorkspaceRecord, WorkspaceState, is_uuid,
    new_uuid_v4,
};
use axo_pty::process::{self, PtyProcess};
use axo_pty::{
    CommandLine, NextOutput, OutputSubscriber, TerminalOutput, TerminalOutputSink, WindowSize,
    attach,
};
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use serde_json::Value;

const DATABASE_FILE: &str = "axo.db";
/// The longest transcript path Pi may ask to resume; the extension enforces the same bound.
const MAX_RESUME_PATH_BYTES: usize = 4096;
const ATTACH_SOCKET_FILE: &str = "attach.sock";
const REAPER_INTERVAL: Duration = Duration::from_millis(100);
const MAX_SUBSCRIPTIONS: usize = 64;
const MAX_QUEUED_EVENTS_PER_SUBSCRIPTION: usize = 128;
const SUBSCRIPTION_IDLE_EXPIRY: Duration = Duration::from_secs(60);
const ATTACH_STOP_POLL_INTERVAL: Duration = Duration::from_millis(100);
const PENDING_FOCUS_LIFETIME: Duration = Duration::from_secs(10);
const MAX_CONCURRENT_TERMINAL_ATTACHMENTS: usize = 256;
/// A client that cannot take its replay this fast is stalled; it can reattach.
const ATTACH_REPLAY_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// Live writes tolerate a briefly busy UI; the backlog cap handles slower clients.
const ATTACH_LIVE_WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const ATTACH_SEND_BUFFER_BYTES: libc::c_int = 256 * 1024;
const TERMINAL_INPUT_WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_AGENT_COMMAND: &str = "pi";

#[derive(Clone, Copy, Debug)]
struct PiRuntimeBinding {
    session_id: SessionId,
    shell_id: ShellId,
    runtime_id: RuntimeId,
}

impl PiRuntimeBinding {
    fn is_current(self, state: &SessionState) -> bool {
        state
            .panes
            .running_in(self.session_id, self.shell_id)
            .is_some_and(|shell| shell.role == PaneRole::Pi && shell.runtime_id == self.runtime_id)
    }
}

/// An open session as stored, before its processes are restored.
#[derive(Debug)]
struct StoredSession {
    id: SessionId,
    initial_pwd: PathBuf,
    shell_ids: Vec<(ShellId, PaneRole, Option<String>)>,
}

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

struct AttachmentPermit(Arc<AtomicUsize>);

impl AttachmentPermit {
    fn try_acquire(active: Arc<AtomicUsize>) -> Option<Self> {
        let mut current = active.load(Ordering::Relaxed);
        loop {
            if current >= MAX_CONCURRENT_TERMINAL_ATTACHMENTS {
                return None;
            }
            match active.compare_exchange_weak(
                current,
                current + 1,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Some(Self(active)),
                Err(actual) => current = actual,
            }
        }
    }
}

impl Drop for AttachmentPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
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

impl SessionState {
    /// The size a pane should start at: its place in the Session's layout, or the whole terminal
    /// area for a pane the layout does not have yet (a new Session's only pane, or a split the
    /// client is about to place).
    fn pane_size(&self, session_id: SessionId, shell_id: ShellId) -> WindowSize {
        let Some(viewport) = self.viewport else {
            return WindowSize::DEFAULT;
        };
        let placed = self.effective_layout(session_id).and_then(|layout| {
            viewport
                .grid_sizes(layout.root())
                .into_iter()
                .find(|(id, _)| *id == shell_id)
        });
        window_size(placed.map_or_else(|| viewport.full_grid(), |(_, grid)| grid))
    }

    /// The layout clients show: the stored one, or, like the client's `defaultLayout`, the
    /// open panes side by side in creation order.
    fn effective_layout(&self, session_id: SessionId) -> Option<Layout> {
        if let Ok(Some(layout)) = read_session_layout(&self.database, session_id) {
            return Some(layout);
        }
        let mut shell_ids: Vec<_> = open_shell_ids(self, session_id).into_iter().collect();
        shell_ids.sort();
        let (first, rest) = shell_ids.split_first()?;
        let root = rest.iter().try_fold(
            LayoutNode::Pane { shell_id: *first },
            |layout, shell_id| -> io::Result<LayoutNode> {
                Ok(LayoutNode::Split {
                    id: new_uuid_v4()?,
                    direction: LayoutDirection::Right,
                    ratio: 0.5,
                    first: Box::new(layout),
                    second: Box::new(LayoutNode::Pane {
                        shell_id: *shell_id,
                    }),
                })
            },
        );
        root.ok().and_then(|root| Layout::try_from(root).ok())
    }

    /// Sizes the Session's panes that no client is attached to from the viewport. Attached
    /// panes are sized by their client, so the two never contend for one PTY.
    fn fit_unattached_panes(&self, session_id: SessionId, layout: &Layout) {
        let Some(viewport) = self.viewport else {
            return;
        };
        for (shell_id, grid) in viewport.grid_sizes(layout.root()) {
            let Some(running) = self
                .panes
                .running_in(session_id, shell_id)
                .filter(|running| running.attachments == 0)
            else {
                continue;
            };
            let size = window_size(grid);
            match process::resize_if_changed(&running.master, &running.child, size) {
                Ok(true) => log::debug!(
                    "event=pane.fitted_to_viewport session_id={} shell_id={} rows={} columns={}",
                    session_id.get(),
                    shell_id.get(),
                    size.rows(),
                    size.columns()
                ),
                Ok(false) => {}
                Err(error) => log::warn!(
                    "event=pane.fit_failed session_id={} shell_id={} error_kind={:?}",
                    session_id.get(),
                    shell_id.get(),
                    error.kind()
                ),
            }
        }
    }

    /// A process enters the catalog, replacing whatever the pane held; returns a replaced
    /// process for the caller to stop.
    fn install_running(
        &mut self,
        shell_id: ShellId,
        running: RunningShell,
    ) -> Option<RunningShell> {
        self.bind_output(shell_id, &running);
        match self.panes.insert_running(shell_id, running) {
            Some(Pane::Running(replaced)) => Some(replaced),
            Some(Pane::Unavailable(_)) | None => None,
        }
    }

    /// A recovered Pi process takes over its unavailable pane, if `recovery` still holds the
    /// pane's reservation; otherwise it is handed back for the caller to stop.
    #[expect(
        clippy::result_large_err,
        reason = "the refused process is handed back by value so the caller stops it"
    )]
    fn commit_recovery(
        &mut self,
        session_id: SessionId,
        shell_id: ShellId,
        recovery: RuntimeId,
        running: RunningShell,
    ) -> Result<(), RunningShell> {
        if self.shutting_down || !self.panes.is_recovering(session_id, shell_id, recovery) {
            return Err(running);
        }
        self.bind_output(shell_id, &running);
        self.panes
            .commit_recovery(session_id, shell_id, recovery, running)
    }

    /// Every way a process enters the catalog goes through here: binding its output stream to
    /// its pane identity starts `terminal.output` events.
    fn bind_output(&self, shell_id: ShellId, running: &RunningShell) {
        let session_id = running.session_id;
        running.output.bind(
            format!(
                "session_id={} shell_id={}",
                session_id.get(),
                shell_id.get()
            ),
            Arc::new(ShellOutputSink {
                events: self.events.clone(),
                session_id,
                shell_id,
            }),
        );
    }
}

// A reservation keeps the unavailable pane in the catalog while recovery waits
// outside its mutex. Close/removal/shutdown invalidates it; failures release it.
struct PiRecoveryLease<'a> {
    manager: &'a SessionManager,
    session_id: SessionId,
    shell_id: ShellId,
    recovery_id: RuntimeId,
}

impl PiRecoveryLease<'_> {
    fn is_current(&self, state: &SessionState) -> bool {
        !state.shutting_down
            && state
                .panes
                .is_recovering(self.session_id, self.shell_id, self.recovery_id)
    }

    fn ensure_current(&self) -> io::Result<()> {
        let state = self.manager.lock_state()?;
        self.check_state(&state)
    }

    fn check_state(&self, state: &SessionState) -> io::Result<()> {
        if self.is_current(state) {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Pi recovery was cancelled",
            ))
        }
    }

    fn signal_current(&self, process_id: VerifiedProcessId, signal: libc::c_int) -> io::Result<()> {
        let state = self.manager.lock_state()?;
        self.check_state(&state)?;
        // Only these short syscalls run under the catalog mutex. Cancellation
        // and signal dispatch are ordered, with no socket/child waits here.
        takeover::signal_verified_process(process_id, signal)
    }
}

impl Drop for PiRecoveryLease<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.manager.state.lock() {
            state
                .panes
                .release_recovery(self.shell_id, self.recovery_id);
        }
    }
}

// Owned launch inputs: waiting/exec must not borrow the catalog or its database.
struct PiLaunchRequest {
    agent_command: AgentCommand,
    session_id: SessionId,
    initial_pwd: PathBuf,
    session_file: PathBuf,
    bridge_socket: BridgeSocketPath,
    session_uuid: String,
    pane_id: String,
    previous_token: Option<String>,
    /// The PTY size Pi starts with.
    size: WindowSize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ShellCommand(CommandLine);

/// Where a setting lives in `daemon_metadata`.
fn config_metadata_key(key: ConfigKey) -> &'static str {
    match key {
        ConfigKey::AgentCommand => "agent_command",
        ConfigKey::ShellCommand => "shell_command",
    }
}

enum ParsedConfigValue {
    AgentCommand(AgentCommand),
    ShellCommand(ShellCommand),
}

impl ShellCommand {
    fn parse(source: &str) -> io::Result<Self> {
        CommandLine::parse(source).map(Self)
    }
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

/// Exposes the session manager to the cloud relay.
pub(crate) struct RelayHostAdapter(pub(crate) Arc<SessionManager>);

impl RelayHostAdapter {
    fn remote(&self, session: &SessionRecord, updated_at: &str) -> RemoteSessionSnapshot {
        RemoteSessionSnapshot::from_record(session, &self.0.host_id, updated_at)
    }
}

impl axo_relay::RelayHost for RelayHostAdapter {
    fn host_id(&self) -> &str {
        &self.0.host_id
    }

    fn host_generation(&self) -> &str {
        &self.0.host_generation
    }

    fn publish_relay_status(&self, status: &RelayStatus) {
        self.0.publish_event(Event::RelayStatus {
            status: status.clone(),
        });
    }

    fn remote_session_snapshots(&self, updated_at: &str) -> io::Result<Vec<RemoteSessionSnapshot>> {
        let sessions = self.0.list_sessions()?;
        if sessions.len() > 256 || sessions.iter().any(|session| session.shells.len() > 256) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "host session snapshot exceeds the protocol limit",
            ));
        }
        Ok(sessions
            .iter()
            .map(|session| self.remote(session, updated_at))
            .collect())
    }

    fn subscribe_remote_events(&self) -> io::Result<String> {
        self.0.subscribe(None, true)
    }

    fn next_remote_event(
        &self,
        subscription_id: &str,
        timeout: Duration,
    ) -> io::Result<Option<Event>> {
        Ok(self
            .0
            .next_event(subscription_id, timeout)?
            .map(Arc::unwrap_or_clone))
    }

    fn remote_resync_events(&self) -> io::Result<Vec<Event>> {
        Ok(self
            .0
            .list_sessions()?
            .into_iter()
            .map(Event::snapshot)
            .collect())
    }

    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()> {
        self.0.unsubscribe(subscription_id)
    }

    fn remote_create_session(&self, updated_at: &str) -> io::Result<RemoteSessionSnapshot> {
        let session = self.0.create_session_and_publish()?;
        Ok(self.remote(&session, updated_at))
    }

    fn remote_create_workspace_session(
        &self,
        workspace_id: &str,
        updated_at: &str,
    ) -> io::Result<RemoteSessionSnapshot> {
        let session = self.0.create_session_in_workspace(workspace_id)?;
        Ok(self.remote(&session, updated_at))
    }

    fn remote_close_session(
        &self,
        session_id: SessionId,
        updated_at: &str,
    ) -> io::Result<Option<RemoteSessionSnapshot>> {
        let replacement = self.0.close_session_and_publish(session_id)?;
        Ok(replacement.map(|session| self.remote(&session, updated_at)))
    }

    fn remote_create_shell(&self, session_id: SessionId) -> io::Result<ShellId> {
        Ok(self.0.create_shell_and_publish(session_id)?.id)
    }

    fn remote_close_shell(&self, session_id: SessionId, shell_id: ShellId) -> io::Result<()> {
        self.0
            .close_shell_and_publish(session_id, shell_id)
            .map(drop)
    }

    fn remote_set_layout(&self, session_id: SessionId, layout: LayoutNode) -> io::Result<()> {
        let layout = Layout::try_from(layout)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        self.0.set_layout_and_publish(session_id, layout)
    }

    fn remote_terminal_input(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        data: &str,
    ) -> io::Result<()> {
        self.0
            .write_terminal_input(session_id, shell_id, sequence, data)
    }

    fn remote_terminal_resize(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        rows: u32,
        columns: u32,
    ) -> io::Result<()> {
        let size = WindowSize::new(rows, columns).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal dimensions are outside the supported range",
            )
        })?;
        self.0.resize_terminal(session_id, shell_id, size)
    }
}

/// Local event subscribers, shared with every shell's output pump.
#[derive(Clone, Default)]
struct EventBus(Arc<Mutex<Vec<LocalSubscriber>>>);

impl EventBus {
    fn lock(&self) -> std::sync::LockResult<std::sync::MutexGuard<'_, Vec<LocalSubscriber>>> {
        self.0.lock()
    }

    /// Returns how many subscribers accepted the event.
    fn publish(&self, event: Event) -> usize {
        let (scope, session_id) = (event.scope(), event.session_id());
        let event = Arc::new(event);
        let Ok(mut subscribers) = self.lock() else {
            return 0;
        };
        let mut delivered = 0;
        subscribers.retain(|subscriber| {
            if !subscriber.wants(scope, session_id) {
                return true;
            }
            match subscriber.queue.push(Arc::clone(&event)) {
                PushOutcome::Queued => {
                    delivered += 1;
                    true
                }
                PushOutcome::Lagged => true,
                PushOutcome::Closed => false,
            }
        });
        delivered
    }
}

/// Publishes one shell's PTY output as `terminal.output` events.
struct ShellOutputSink {
    events: EventBus,
    session_id: SessionId,
    shell_id: ShellId,
}

impl TerminalOutputSink for ShellOutputSink {
    fn publish_terminal_output(&self, sequence: u64, output: &[u8]) {
        let (session_id, shell_id) = (self.session_id, self.shell_id);
        // Most of the time nobody streams terminal bytes; skip the base64 work then.
        let wanted = self.events.lock().is_ok_and(|subscribers| {
            subscribers
                .iter()
                .any(|subscriber| subscriber.wants(EventScope::Streams, Some(session_id)))
        });
        if !wanted {
            return;
        }
        self.events.publish(Event::TerminalOutput {
            session_id,
            shell_id,
            sequence,
            data: encode_base64(output),
        });
    }
}

struct LocalSubscriber {
    id: String,
    session_id: Option<SessionId>,
    scope: EventScope,
    queue: Arc<EventQueue<Arc<Event>>>,
}

impl LocalSubscriber {
    fn wants(&self, scope: EventScope, session_id: Option<SessionId>) -> bool {
        self.session_id
            .is_none_or(|expected| session_id == Some(expected))
            && self.scope.accepts(scope)
    }
}

/// Consumer side of a local event subscription; see `EventQueue` for lag semantics.
/// Subscriptions nobody polls for `SUBSCRIPTION_IDLE_EXPIRY` are reclaimed so crashed clients
/// cannot exhaust capacity.
///
/// The registry mutex only guards membership. A poll clones the `Arc` out and waits on the
/// subscription's own queue, so one long-poll never blocks other subscribers, the relay,
/// `subscribe` or `unsubscribe`.
struct LocalSubscription {
    queue: Arc<EventQueue<Arc<Event>>>,
    last_polled: Mutex<Instant>,
}

impl LocalSubscription {
    fn last_polled(&self) -> Instant {
        self.last_polled
            .lock()
            .map(|instant| *instant)
            .unwrap_or_else(|poisoned| *poisoned.into_inner())
    }

    fn mark_polled(&self) {
        let now = Instant::now();
        match self.last_polled.lock() {
            Ok(mut instant) => *instant = now,
            Err(poisoned) => *poisoned.into_inner() = now,
        }
    }
}

impl SessionManager {
    pub fn open(server_directory: &Path) -> Result<Arc<Self>, Box<dyn std::error::Error>> {
        fs::create_dir_all(server_directory)?;
        let server_directory = fs::canonicalize(server_directory)?;
        let database_path = server_directory.join(DATABASE_FILE);
        let attach_socket_path = server_directory.join(ATTACH_SOCKET_FILE);
        let initial_pwd = super::current_user_home_directory()?;

        let mut database = Connection::open(&database_path)?;
        database.busy_timeout(Duration::from_secs(3))?;
        database.pragma_update(None, "journal_mode", "WAL")?;
        database.pragma_update(None, "synchronous", "FULL")?;
        database.pragma_update(None, "foreign_keys", "ON")?;
        initialize_database(&mut database)?;
        let host_id = load_or_create_host_id(&database)?;
        let agent_command = load_or_create_agent_command(&database)?;
        let shell_command = load_or_create_shell_command(&database)?;
        let viewport = load_viewport(&database)?;
        let host_generation = new_uuid_v4()?;
        fs::set_permissions(&database_path, fs::Permissions::from_mode(0o600))?;
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

    pub fn register_rpc_methods(self: &Arc<Self>, handler: &mut IoHandler) {
        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_LIST,
            "expected no parameters",
            move |_: rpc::NoParams| {
                let sessions = manager.list_sessions().map_err(internal_rpc_error)?;
                let resume_session_id = manager
                    .take_pending_resume_focus()
                    .map_err(internal_rpc_error)?;
                Ok(rpc::SessionList {
                    sessions,
                    resume_session_id,
                })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::CONFIG_GET,
            "expected {key}",
            move |request: rpc::GetConfig| Ok(manager.config_value(request.key)),
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::CONFIG_SET,
            "expected {key, value}",
            move |request: rpc::SetConfig| {
                manager
                    .set_config_value(request.key, &request.value)
                    .map_err(|error| invalid_input_or_internal(error, None))
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_LAYOUT_SET,
            "expected {sessionId, layout}",
            move |request: rpc::SetLayout| {
                let layout = Layout::try_from(request.layout)
                    .map_err(|_| invalid_params("layout is malformed or exceeds its limits"))?;
                manager
                    .set_layout_and_publish(request.session_id, layout)
                    .map(|()| rpc::Saved { saved: true })
                    .map_err(|error| {
                        invalid_input_or_internal(
                            error,
                            Some("layout must contain each open session shell exactly once"),
                        )
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_SUBSCRIBE,
            "expected {sessionId?, includeTerminalOutput?}",
            move |request: rpc::Subscribe| {
                manager
                    .subscribe(request.session_id, request.include_terminal_output)
                    .map(|subscription_id| rpc::Subscribed { subscription_id })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        // Long-polls wait as futures, never on a thread (see `axo_ipc`).
        handler.add_typed_async(
            method::SESSION_EVENTS_NEXT,
            "expected {subscriptionId, timeoutMs, maxEvents?}",
            move |request: rpc::NextEvents| {
                let manager = Arc::clone(&manager);
                async move { manager.next_events_for_rpc(request).await }
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_UNSUBSCRIBE,
            "expected {subscriptionId}",
            move |request: rpc::Unsubscribe| {
                manager
                    .unsubscribe(&request.subscription_id)
                    .map(|()| rpc::Unsubscribed { unsubscribed: true })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::TERMINAL_INPUT,
            "expected {sessionId, shellId, sequence, data}",
            move |request: rpc::TerminalInput| {
                manager
                    .write_terminal_input(
                        request.session_id,
                        request.shell_id,
                        request.sequence,
                        &request.data,
                    )
                    .map(|()| rpc::InputAccepted {
                        accepted: true,
                        sequence: request.sequence,
                    })
                    .map_err(|error| {
                        invalid_input_or_internal(
                            error,
                            Some("terminal input is invalid or out of sequence"),
                        )
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::TERMINAL_RESIZE,
            "expected {sessionId, shellId, rows, columns}",
            move |request: rpc::TerminalResize| {
                let size = WindowSize::new(request.rows, request.columns)
                    .ok_or_else(|| invalid_params("terminal dimensions are invalid"))?;
                manager
                    .resize_terminal(request.session_id, request.shell_id, size)
                    .map(|()| rpc::ResizeAccepted {
                        accepted: true,
                        rows: request.rows,
                        columns: request.columns,
                    })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::CLIENT_VIEWPORT_SET,
            "expected {terminalArea, backingScale, cell, padding, dividerThickness} in range",
            move |viewport: Viewport| {
                manager
                    .set_viewport(viewport)
                    .map(|()| rpc::ViewportAccepted { accepted: true })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SHELL_BUSY,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                manager
                    .shell_busy(request.session_id, request.shell_id)
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_LIST,
            "expected no parameters",
            move |_: rpc::NoParams| {
                manager
                    .list_workspaces()
                    .map(|workspaces| rpc::WorkspaceList { workspaces })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_RENAME,
            "expected {workspaceId, name}",
            move |request: rpc::RenameWorkspace| {
                manager
                    .rename_workspace(&request.workspace_id, &request.name)
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Workspace ID or name is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_ARCHIVE,
            "expected {workspaceId}",
            move |request: rpc::WorkspaceRef| {
                manager
                    .archive_workspace(&request.workspace_id)
                    .map(|archived_session_ids| rpc::WorkspaceArchived {
                        archived_workspace_id: request.workspace_id,
                        archived_session_ids,
                    })
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Workspace ID is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_CREATE,
            "expected {name, directoryPath, optional directoryBookmark}",
            move |request: rpc::CreateWorkspace| {
                manager.create_workspace(request).map_err(|error| match error.kind() {
                    io::ErrorKind::InvalidInput => invalid_params(&error.to_string()),
                    io::ErrorKind::NotFound => invalid_params("Workspace directory no longer exists or is unavailable"),
                    io::ErrorKind::PermissionDenied => invalid_params(
                        "Axo cannot access the selected folder; choose it again in the folder picker",
                    ),
                    _ => internal_rpc_error(error),
                })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::WORKSPACE_SESSION_CREATE,
            "expected {workspaceId}",
            move |request: rpc::WorkspaceRef| {
                manager
                    .create_session_in_workspace(&request.workspace_id)
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Workspace ID is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_CREATE,
            "expected no parameters",
            move |_: rpc::NoParams| {
                manager
                    .create_session_and_publish()
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_CLOSE,
            "expected {sessionId}",
            move |request: rpc::SessionRef| {
                manager
                    .close_session_and_publish(request.session_id)
                    .map(|replacement| rpc::SessionClosed {
                        archived_session_id: request.session_id,
                        replacement,
                    })
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_RENAME,
            "expected {sessionId, name}",
            move |request: rpc::RenameSession| {
                manager
                    .rename_session(request.session_id, &request.name)
                    .map_err(|error| {
                        invalid_input_or_internal(error, Some("Session name is invalid"))
                    })
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_PI_RESTART_AUTO,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                let rpc::ShellRef {
                    session_id,
                    shell_id,
                } = request;
                manager
                    .restart_unavailable_pi(
                        session_id,
                        shell_id,
                        TakeoverPolicy::PreserveExistingProcess,
                    )
                    .map_err(|error| automatic_pi_restart_rpc_error(session_id, shell_id, error))
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SESSION_PI_RESTART_FORCE,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                let rpc::ShellRef {
                    session_id,
                    shell_id,
                } = request;
                manager
                    .restart_unavailable_pi(
                        session_id,
                        shell_id,
                        TakeoverPolicy::ExplicitUserRestart,
                    )
                    .map_err(|error| pi_restart_rpc_error(session_id, shell_id, error))
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SHELL_CREATE,
            "expected {sessionId}",
            move |request: rpc::SessionRef| {
                manager
                    .create_shell_and_publish(request.session_id)
                    .map_err(internal_rpc_error)
            },
        );

        let manager = Arc::clone(self);
        handler.add_typed(
            method::SHELL_CLOSE,
            "expected {sessionId, shellId}",
            move |request: rpc::ShellRef| {
                manager
                    .close_shell_and_publish(request.session_id, request.shell_id)
                    .map_err(internal_rpc_error)
            },
        );
    }

    // Catalog commands shared by local RPC and the relay: each performs the change and publishes
    // the events that describe it, so every client sees the same sequence.

    fn create_session_and_publish(&self) -> io::Result<SessionRecord> {
        let session = self.create_session()?;
        self.publish_event(Event::snapshot(session.clone()));
        Ok(session)
    }

    /// Returns the replacement session created when the last one closes.
    fn close_session_and_publish(
        self: &Arc<Self>,
        session_id: SessionId,
    ) -> io::Result<Option<SessionRecord>> {
        let replacement = self.close_session(session_id)?;
        self.publish_session_removed(session_id);
        if let Some(session) = &replacement {
            self.publish_event(Event::snapshot(session.clone()));
        }
        Ok(replacement)
    }

    fn create_shell_and_publish(&self, session_id: SessionId) -> io::Result<ShellRecord> {
        let shell = self.create_shell(session_id)?;
        self.publish_session_snapshot(session_id)?;
        self.publish_shell_activity(session_id, shell.id, ShellActivity::Started);
        Ok(shell)
    }

    fn close_shell_and_publish(
        self: &Arc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> io::Result<rpc::ShellClosed> {
        let closed = self.close_shell(session_id, shell_id)?;
        if closed.archived_session_id.is_some() {
            self.publish_session_removed(session_id);
            if let Some(replacement) = &closed.replacement {
                self.publish_event(Event::snapshot(replacement.clone()));
            }
        } else {
            self.publish_session_snapshot(session_id)?;
        }
        self.publish_shell_activity(session_id, shell_id, ShellActivity::Exited);
        Ok(closed)
    }

    fn set_layout_and_publish(&self, session_id: SessionId, layout: Layout) -> io::Result<()> {
        self.set_layout(session_id, layout)?;
        self.publish_session_snapshot(session_id)
    }

    async fn next_events_for_rpc(
        &self,
        request: rpc::NextEvents,
    ) -> Result<rpc::EventsNext<SharedEvent>, RpcError> {
        if !(1..=rpc::MAX_EVENTS_TIMEOUT_MS).contains(&request.timeout_ms) {
            return Err(invalid_params("timeoutMs must be between 1 and 20000"));
        }
        let max_events = match request.max_events {
            None => 1,
            Some(max_events) if (1..=rpc::MAX_EVENTS_PER_POLL).contains(&max_events) => max_events,
            Some(_) => return Err(invalid_params("maxEvents must be between 1 and 256")),
        };
        let timeout = Duration::from_millis(request.timeout_ms);
        let events = self
            .next_events_async(&request.subscription_id, timeout, max_events)
            .await
            .map_err(internal_rpc_error)?
            .into_iter()
            .map(SharedEvent);
        Ok(match request.max_events {
            None => rpc::EventsNext::Single {
                event: events.into_iter().next(),
            },
            Some(_) => rpc::EventsNext::Batch {
                events: events.collect(),
            },
        })
    }

    fn restore_open_sessions(self: &Arc<Self>) -> io::Result<()> {
        let mut state = self.lock_state()?;
        if state.shutting_down {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Axod is shutting down",
            ));
        }
        let records = read_open_sessions(&state.database)?;
        let mut pi_shells = Vec::new();
        for record in records {
            if record.shell_ids.is_empty() {
                archive_session(&mut state.database, record.id, "missing_open_pane")?;
                continue;
            }
            for (shell_id, role, pane_id) in record.shell_ids {
                if state.panes.contains(shell_id) {
                    continue;
                }

                let running = match role {
                    PaneRole::Terminal => Some(spawn_shell(
                        &state.shell_command,
                        record.id,
                        &record.initial_pwd,
                        state.pane_size(record.id, shell_id),
                    )?),
                    PaneRole::Pi => {
                        // Not open (checked above), so this cannot be refused.
                        let _ = state.panes.insert_unavailable(
                            shell_id,
                            UnavailablePane::new(record.id, pane_id, record.initial_pwd.clone()),
                        );
                        pi_shells.push((record.id, shell_id));
                        None
                    }
                };
                if let Some(running) = running {
                    state.install_running(shell_id, running);
                }
            }
        }
        drop(state);
        self.recover_pi_shells(pi_shells);
        Ok(())
    }

    fn recover_pi_shells(self: &Arc<Self>, panes: Vec<(SessionId, ShellId)>) {
        for (session_id, shell_id) in panes {
            if let Err(error) = self.restart_unavailable_pi(
                session_id,
                shell_id,
                TakeoverPolicy::PreserveExistingProcess,
            ) {
                log::warn!(
                    "event=session.pi_restore_unavailable session_id={} shell_id={} error_kind={:?}",
                    session_id.get(),
                    shell_id.get(),
                    error.kind()
                );
            }
        }
    }

    fn start_attachment_listener(self: &Arc<Self>) -> io::Result<()> {
        let socket_path = &self.attach_socket_path;
        super::SocketPath::parse(socket_path.clone())
            .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))?;
        super::remove_stale_socket(socket_path)?;

        let listener = UnixListener::bind(socket_path)?;
        fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;

        let manager = Arc::downgrade(self);
        let active_attachments = Arc::new(AtomicUsize::new(0));
        let stop_workers = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name("axo-pty-attachments".into())
            .spawn(move || {
                while !stop_workers.load(Ordering::Relaxed) {
                    // Wake as soon as a client connects; the timeout only bounds the stop check.
                    if !wait_until_readable(listener.as_raw_fd(), ATTACH_STOP_POLL_INTERVAL) {
                        continue;
                    }
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            let Some(permit) =
                                AttachmentPermit::try_acquire(Arc::clone(&active_attachments))
                            else {
                                log::warn!("event=session.attach_rejected reason=capacity");
                                let _ = attach::write_rejection(&mut stream, attach::Rejection::DaemonBusy);
                                continue;
                            };
                            let mut rejection_stream = match stream.try_clone() {
                                Ok(stream) => stream,
                                Err(error) => {
                                    log::error!(
                                        "event=session.attach_worker_start_failed phase=clone_socket error_kind={:?}",
                                        error.kind()
                                    );
                                    let _ = attach::write_rejection(&mut stream, attach::Rejection::Other);
                                    continue;
                                }
                            };
                            let manager = manager.clone();
                            if let Err(error) = thread::Builder::new()
                                .name("axo-pty-attachment".into())
                                .spawn(move || handle_attachment(stream, manager, permit))
                            {
                                log::error!(
                                    "event=session.attach_worker_start_failed phase=spawn error_kind={:?}",
                                    error.kind()
                                );
                                let _ = attach::write_rejection(&mut rejection_stream, attach::Rejection::DaemonBusy);
                            }
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                        Err(_) => thread::sleep(Duration::from_millis(50)),
                    }
                }
            })?;
        self.workers
            .lock()
            .map_err(|_| io::Error::other("session worker lock was poisoned"))?
            .push(worker);
        Ok(())
    }

    fn start_reaper(self: &Arc<Self>) {
        let manager = Arc::downgrade(self);
        let stop_workers = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name("axo-session-reaper".into())
            .spawn(move || {
                while !stop_workers.load(Ordering::Relaxed) {
                    thread::sleep(REAPER_INTERVAL);
                    let Some(manager) = manager.upgrade() else {
                        break;
                    };
                    if let Err(error) = manager.reap_exited_sessions() {
                        log::error!("event=session.reap_failed reason={error}");
                    }
                }
            });
        if let Ok(worker) = worker
            && let Ok(mut workers) = self.workers.lock()
        {
            workers.push(worker);
        }
    }

    fn list_sessions(&self) -> io::Result<Vec<SessionRecord>> {
        let state = self.lock_state()?;
        let mut sessions = state
            .panes
            .session_ids()
            .into_iter()
            .map(|id| session_metadata(&state, id, &self.attach_socket_path))
            .collect::<io::Result<Vec<_>>>()?;
        sessions.sort_by_key(|session| session.id.get());
        Ok(sessions)
    }

    fn create_session(&self) -> io::Result<SessionRecord> {
        let mut state = self.lock_state()?;
        create_session(&mut state, &self.attach_socket_path)
    }

    fn ensure_home_session(&self) -> io::Result<Option<SessionRecord>> {
        let mut state = self.lock_state()?;
        if open_standalone_session_count(&state.database)? == 0 {
            create_session(&mut state, &self.attach_socket_path).map(Some)
        } else {
            Ok(None)
        }
    }

    fn set_layout(&self, session_id: SessionId, layout: Layout) -> io::Result<()> {
        let shell_ids = layout.shell_ids().clone();
        let state = self.lock_state()?;
        let open_shell_ids = open_shell_ids(&state, session_id);
        if open_shell_ids.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "session is not open",
            ));
        }
        if shell_ids != open_shell_ids {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "layout does not match the session's open shells",
            ));
        }

        let layout_json = serde_json::to_string(&layout).map_err(io::Error::other)?;
        let changed = state
            .database
            .execute(
                "UPDATE sessions SET layout_json = ?1 WHERE id = ?2 AND state = 'open'",
                params![layout_json, session_id.get()],
            )
            .map_err(io::Error::other)?;
        if changed != 1 {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "session record is missing",
            ));
        }
        state.fit_unattached_panes(session_id, &layout);
        Ok(())
    }

    /// Records the latest client's viewport and sizes every pane no client is attached to.
    fn set_viewport(&self, viewport: Viewport) -> io::Result<()> {
        let mut state = self.lock_state()?;
        if state.viewport == Some(viewport) {
            return Ok(());
        }
        store_viewport(&state.database, &viewport)?;
        state.viewport = Some(viewport);
        let session_ids = read_open_sessions(&state.database)?
            .into_iter()
            .map(|record| record.id);
        for session_id in session_ids {
            if let Some(layout) = state.effective_layout(session_id) {
                state.fit_unattached_panes(session_id, &layout);
            }
        }
        Ok(())
    }

    fn subscribe(
        &self,
        session_id: Option<SessionId>,
        include_streams: bool,
    ) -> io::Result<String> {
        if let Some(session_id) = session_id {
            let state = self.lock_state()?;
            session_initial_pwd(&state.database, session_id)?;
        }
        let id = self.next_subscription_id.fetch_add(1, Ordering::Relaxed);
        let subscription_id = format!(
            "00000000-0000-4000-8000-{:012x}",
            ((std::process::id() as u64) << 32 | id) & 0x0000_ffff_ffff_ffff
        );
        let queue = Arc::new(EventQueue::new(MAX_QUEUED_EVENTS_PER_SUBSCRIPTION, || {
            Arc::new(Event::SubscriptionLagged)
        }));
        let mut subscriptions = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?;
        let now = Instant::now();
        let expired: Vec<String> = subscriptions
            .iter()
            .filter(|(_, subscription)| {
                now.duration_since(subscription.last_polled()) >= SUBSCRIPTION_IDLE_EXPIRY
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in &expired {
            if let Some(subscription) = subscriptions.remove(id) {
                subscription.queue.close();
            }
        }
        if subscriptions.len() >= MAX_SUBSCRIPTIONS {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "session subscription capacity reached",
            ));
        }
        let mut subscribers = self
            .subscribers
            .lock()
            .map_err(|_| io::Error::other("session subscriber lock was poisoned"))?;
        if !expired.is_empty() {
            subscribers.retain(|subscriber| !expired.contains(&subscriber.id));
            log::info!(
                "event=session.subscriptions_expired count={}",
                expired.len()
            );
        }
        subscriptions.insert(
            subscription_id.clone(),
            Arc::new(LocalSubscription {
                queue: Arc::clone(&queue),
                last_polled: Mutex::new(now),
            }),
        );
        subscribers.push(LocalSubscriber {
            id: subscription_id.clone(),
            session_id,
            scope: if include_streams {
                EventScope::Streams
            } else {
                EventScope::Catalog
            },
            queue: Arc::clone(&queue),
        });
        drop(subscribers);
        drop(subscriptions);
        let sessions = match self.list_sessions() {
            Ok(sessions) => sessions,
            Err(error) => {
                let _ = self.unsubscribe(&subscription_id);
                return Err(error);
            }
        };
        // Initial snapshots go to this subscriber only; other subscribers already have them.
        for session in sessions {
            if session_id.is_none_or(|expected| expected == session.id) {
                let snapshot = Arc::new(Event::snapshot(session.clone()));
                if queue.push(snapshot) != PushOutcome::Queued {
                    break;
                }
            }
        }
        Ok(subscription_id)
    }

    fn next_event(&self, id: &str, timeout: Duration) -> io::Result<Option<Arc<Event>>> {
        Ok(self.next_events(id, timeout, 1)?.into_iter().next())
    }

    fn subscription(&self, id: &str) -> io::Result<Arc<LocalSubscription>> {
        let subscription = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?
            .get(id)
            .cloned()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "subscription is not open"))?;
        subscription.mark_polled();
        Ok(subscription)
    }

    /// Blocks up to `timeout` for the first event, then drains up to `max_events` already queued.
    /// For the relay thread and tests; RPC uses `next_events_async`.
    fn next_events(
        &self,
        id: &str,
        timeout: Duration,
        max_events: usize,
    ) -> io::Result<Vec<Arc<Event>>> {
        let subscription = self.subscription(id)?;
        let events = subscription.queue.wait_blocking(timeout, max_events);
        subscription.mark_polled();
        events
    }

    /// Like `next_events`, but waits without occupying a thread.
    pub(crate) async fn next_events_async(
        &self,
        id: &str,
        timeout: Duration,
        max_events: usize,
    ) -> io::Result<Vec<Arc<Event>>> {
        let subscription = self.subscription(id)?;
        let events = subscription.queue.wait(timeout, max_events).await;
        subscription.mark_polled();
        events
    }

    fn unsubscribe(&self, id: &str) -> io::Result<()> {
        let mut subscriptions = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?;
        let Some(subscription) = subscriptions.remove(id) else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "subscription is not open",
            ));
        };
        subscription.queue.close();
        let mut subscribers = self
            .subscribers
            .lock()
            .map_err(|_| io::Error::other("session subscriber lock was poisoned"))?;
        subscribers.retain(|subscriber| subscriber.id != id);
        Ok(())
    }

    /// Returns how many subscribers accepted the event.
    fn publish_event(&self, event: Event) -> usize {
        self.subscribers.publish(event)
    }

    /// Remote-access state changed; a catalog event so Settings never polls for it.
    fn publish_workspace_changed(&self, workspace_id: &str) {
        self.publish_event(Event::WorkspaceChanged {
            workspace_id: workspace_id.to_owned(),
        });
    }

    fn publish_session_snapshot(&self, session_id: SessionId) -> io::Result<()> {
        let session = {
            let state = self.lock_state()?;
            session_metadata(&state, session_id, &self.attach_socket_path)?
        };
        self.publish_event(Event::snapshot(session.clone()));
        Ok(())
    }

    fn publish_session_removed(&self, session_id: SessionId) {
        self.publish_event(Event::SessionRemoved { session_id });
    }

    fn publish_shell_activity(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        activity: ShellActivity,
    ) {
        self.publish_event(Event::ShellActivity {
            session_id,
            shell_id,
            activity,
        });
    }

    fn write_terminal_input(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        encoded_input: &str,
    ) -> io::Result<()> {
        let input = decode_base64(encoded_input)?;
        if input.is_empty() || input.len() > 49_152 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal input must contain 1 to 49152 bytes",
            ));
        }
        let mut state = self.lock_state()?;
        let running = state
            .panes
            .running_in_mut(session_id, shell_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        if running.last_input_sequence == Some(sequence) {
            return Ok(());
        }
        let expected_sequence = running
            .last_input_sequence
            .map_or(Some(0), |last| last.checked_add(1))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "terminal input sequence exhausted",
                )
            })?;
        if sequence != expected_sequence {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal input sequence is out of order",
            ));
        }
        process::write_all(
            running.master.as_raw_fd(),
            &input,
            TERMINAL_INPUT_WRITE_TIMEOUT,
        )?;
        running.last_input_sequence = Some(sequence);
        Ok(())
    }

    fn resize_terminal(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        size: WindowSize,
    ) -> io::Result<()> {
        let state = self.lock_state()?;
        let running = state
            .panes
            .running_in(session_id, shell_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        process::resize(&running.master, &running.child, size)
    }

    fn shell_busy(&self, session_id: SessionId, shell_id: ShellId) -> io::Result<rpc::ShellBusy> {
        let state = self.lock_state()?;
        let running = state
            .panes
            .running_in(session_id, shell_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        if running.role == PaneRole::Pi {
            let working = state
                .pi_activity
                .get(&session_id)
                .is_some_and(|activity| activity.working);
            return Ok(rpc::ShellBusy {
                busy: working,
                foreground_process: None,
            });
        }
        // SAFETY: the PTY master descriptor stays open while the shell is running.
        let foreground = unsafe { libc::tcgetpgrp(running.master.as_raw_fd()) };
        if foreground == -1 {
            return Err(io::Error::last_os_error());
        }
        let shell_process = running.child.id() as libc::pid_t;
        if foreground == shell_process {
            return Ok(rpc::ShellBusy {
                busy: false,
                foreground_process: None,
            });
        }
        Ok(rpc::ShellBusy {
            busy: true,
            foreground_process: process_name(foreground),
        })
    }

    fn create_shell(&self, session_id: SessionId) -> io::Result<ShellRecord> {
        let mut state = self.lock_state()?;
        create_shell(&mut state, session_id, &self.attach_socket_path)
    }

    fn start_pi_bridge_worker(self: &Arc<Self>, shell_id: ShellId) -> io::Result<()> {
        let (
            session_id,
            session_uuid,
            pane_id,
            initial_pwd,
            session_file,
            bridge_socket,
            bridge_token,
            process_id,
            runtime_id,
        ) = {
            let state = self.lock_state()?;
            let running = state
                .panes
                .running(shell_id)
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi pane is not running"))?;
            let session_uuid: String = state
                .database
                .query_row(
                    "SELECT session_uuid FROM sessions WHERE id = ? AND state = 'open'",
                    params![running.session_id.get()],
                    |row| row.get(0),
                )
                .map_err(io::Error::other)?;
            let session_file = state
                .database
                .query_row(
                    "SELECT pi_session_file FROM sessions WHERE id = ?",
                    params![running.session_id.get()],
                    |row| row.get::<_, Option<String>>(0),
                )
                .map_err(io::Error::other)?
                .map(PathBuf::from)
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "Pi history path is missing")
                })?;
            (
                running.session_id,
                session_uuid,
                running.pane_id.clone().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "Pi pane ID is missing")
                })?,
                running.initial_pwd.clone(),
                session_file,
                running.pi_bridge_socket.clone().ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Pi bridge socket path is missing",
                    )
                })?,
                running.pi_bridge_token.clone().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "Pi bridge token is missing")
                })?,
                running.child.id(),
                running.runtime_id,
            )
        };
        let host = PiBridgeHost {
            manager: Arc::downgrade(self),
            binding: PiRuntimeBinding {
                session_id,
                shell_id,
                runtime_id,
            },
            session_uuid: session_uuid.clone(),
        };
        let config = worker::WorkerConfig {
            log_context: host.log_context(),
            session_uuid,
            pane_id,
            initial_pwd,
            session_file,
            bridge_socket,
            bridge_token,
            process_id,
        };
        let stop = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name(format!("axo-pi-bridge-{}", shell_id.get()))
            .spawn(move || worker::run(&host, &stop, &config))?;
        self.workers
            .lock()
            .map_err(|_| io::Error::other("session worker lock was poisoned"))?
            .push(worker);
        Ok(())
    }

    fn list_workspaces(&self) -> io::Result<Vec<WorkspaceRecord>> {
        let state = self.lock_state()?;
        let mut statement = state.database.prepare(
            "SELECT workspace_id, name, directory_path FROM workspaces WHERE state = 'open' ORDER BY name, workspace_id",
        ).map_err(io::Error::other)?;
        let rows = statement
            .query_map([], |row| {
                Ok(WorkspaceRecord {
                    workspace_id: row.get(0)?,
                    name: row.get(1)?,
                    directory_path: row.get(2)?,
                    state: None,
                })
            })
            .map_err(io::Error::other)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)
    }

    fn rename_session(&self, session_id: SessionId, name: &str) -> io::Result<SessionRecord> {
        if !valid_session_title(name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Session name must be between 1 and 80 characters",
            ));
        }
        let session = {
            let state = self.lock_state()?;
            let changed = state
                .database
                .execute(
                    "UPDATE sessions SET manual_name = ?1 WHERE id = ?2 AND state = 'open'",
                    params![name, session_id.get()],
                )
                .map_err(io::Error::other)?;
            if changed != 1 {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "Session is not open",
                ));
            }
            session_metadata(&state, session_id, &self.attach_socket_path)?
        };
        self.publish_event(Event::snapshot(session.clone()));
        Ok(session)
    }

    fn rename_workspace(&self, workspace_id: &str, name: &str) -> io::Result<WorkspaceRecord> {
        if !is_uuid(workspace_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace ID is invalid",
            ));
        }
        validate_workspace_name(name)?;
        let (workspace, session_ids) = {
            let state = self.lock_state()?;
            let changed = state
                .database
                .execute(
                    "UPDATE workspaces SET name = ?1 WHERE workspace_id = ?2 AND state = 'open'",
                    params![name, workspace_id],
                )
                .map_err(io::Error::other)?;
            if changed != 1 {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "Workspace is not open",
                ));
            }
            let directory_path: String = state
                .database
                .query_row(
                    "SELECT directory_path FROM workspaces WHERE workspace_id = ?1",
                    params![workspace_id],
                    |row| row.get(0),
                )
                .map_err(io::Error::other)?;
            let session_ids = {
                let mut statement = state
                    .database
                    .prepare("SELECT id FROM sessions WHERE workspace_id = ?1 AND state = 'open'")
                    .map_err(io::Error::other)?;
                statement
                    .query_map(params![workspace_id], |row| row.get::<_, i64>(0))
                    .map_err(io::Error::other)?
                    .map(|id| id.and_then(stored_session_id))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(io::Error::other)?
            };
            (
                WorkspaceRecord {
                    workspace_id: workspace_id.to_owned(),
                    name: name.to_owned(),
                    directory_path,
                    state: None,
                },
                session_ids,
            )
        };
        for session_id in session_ids {
            self.publish_session_snapshot(session_id)?;
        }
        self.publish_workspace_changed(workspace_id);
        Ok(workspace)
    }

    fn archive_workspace(self: &Arc<Self>, workspace_id: &str) -> io::Result<Vec<SessionId>> {
        if !is_uuid(workspace_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace ID is invalid",
            ));
        }
        let (session_ids, shells) = {
            let mut state = self.lock_state()?;
            let session_ids = archive_workspace_records(&mut state.database, workspace_id)?;
            let mut shells = Vec::new();
            for session_id in &session_ids {
                state.pi_activity.remove(session_id);
                shells.extend(remove_session_shells(&mut state, *session_id));
            }
            (session_ids, shells)
        };
        self.terminate_shells_in_background(shells);
        match self.workspace_access.lock() {
            Ok(mut access) => {
                access.remove(workspace_id);
            }
            Err(_) => log::error!(
                "event=workspace.archive_access_release_failed workspace_id={workspace_id}"
            ),
        }
        for session_id in &session_ids {
            self.publish_session_removed(*session_id);
        }
        self.publish_workspace_changed(workspace_id);
        Ok(session_ids)
    }

    fn ensure_open_workspace_sessions(self: &Arc<Self>) -> io::Result<()> {
        let sessions = {
            let mut state = self.lock_state()?;
            let workspace_ids = {
                let mut statement = state
                    .database
                    .prepare(
                        "SELECT w.workspace_id FROM workspaces w WHERE w.state = 'open' \
                         AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.workspace_id = w.workspace_id \
                         AND s.state = 'open') ORDER BY w.workspace_id",
                    )
                    .map_err(io::Error::other)?;
                statement
                    .query_map([], |row| row.get::<_, String>(0))
                    .map_err(io::Error::other)?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(io::Error::other)?
            };
            workspace_ids
                .iter()
                .map(|workspace_id| {
                    create_workspace_session(
                        &mut state,
                        &self.attach_socket_path,
                        &self.pi_session_directory,
                        workspace_id,
                    )
                })
                .collect::<io::Result<Vec<_>>>()?
        };

        for session in sessions {
            self.start_pi_bridge_for_session(&session)?;
            self.publish_event(Event::snapshot(session.clone()));
        }
        Ok(())
    }

    fn create_workspace(
        self: &Arc<Self>,
        request: rpc::CreateWorkspace,
    ) -> io::Result<rpc::WorkspaceCreated> {
        validate_workspace_name(&request.name)?;
        if !request.directory_path.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace root must be an absolute path",
            ));
        }
        let directory_access = WorkspaceDirectoryAccess::open(
            &request.directory_path,
            request.directory_bookmark.as_deref(),
        )?;
        let directory = directory_access.path().to_path_buf();
        let workspace_id = new_uuid_v4()?;
        let mut state = self.lock_state()?;
        state.database.execute(
            "INSERT INTO workspaces (workspace_id, name, directory_path, directory_bookmark, state, created_at) VALUES (?, ?, ?, ?, 'open', ?)",
            params![
                workspace_id,
                request.name,
                directory.to_string_lossy(),
                request.directory_bookmark,
                unix_timestamp()
            ],
        ).map_err(io::Error::other)?;
        let session = match create_workspace_session(
            &mut state,
            &self.attach_socket_path,
            &self.pi_session_directory,
            &workspace_id,
        ) {
            Ok(session) => session,
            Err(error) => {
                let _ = state.database.execute(
                    "UPDATE workspaces SET state = 'archived', archived_at = ? WHERE workspace_id = ?",
                    params![unix_timestamp(), workspace_id],
                );
                return Err(io::Error::other(error));
            }
        };
        let pi_shell_id = session
            .shells
            .iter()
            .find(|shell| shell.role == PaneRole::Pi)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Workspace Session has no Pi pane",
                )
            })?
            .id;
        drop(state);
        self.workspace_access
            .lock()
            .map_err(|_| io::Error::other("Workspace access registry is unavailable"))?
            .insert(workspace_id.clone(), directory_access);
        self.start_pi_bridge_worker(pi_shell_id)
            .map_err(io::Error::other)?;
        let workspace = WorkspaceRecord {
            workspace_id: workspace_id.clone(),
            name: request.name,
            directory_path: directory.to_string_lossy().into_owned(),
            state: Some(WorkspaceState::Open),
        };
        self.publish_event(Event::snapshot(session.clone()));
        self.publish_workspace_changed(&workspace_id);
        Ok(rpc::WorkspaceCreated { workspace, session })
    }

    fn create_session_in_workspace(
        self: &Arc<Self>,
        workspace_id: &str,
    ) -> io::Result<SessionRecord> {
        if !is_uuid(workspace_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Workspace ID is invalid",
            ));
        }
        let mut state = self.lock_state()?;
        let session = create_workspace_session(
            &mut state,
            &self.attach_socket_path,
            &self.pi_session_directory,
            workspace_id,
        )?;
        let pi_shell_id = session
            .shells
            .iter()
            .find(|shell| shell.role == PaneRole::Pi)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Workspace Session has no Pi pane",
                )
            })?
            .id;
        drop(state);
        self.start_pi_bridge_worker(pi_shell_id)?;
        self.publish_event(Event::snapshot(session.clone()));
        Ok(session)
    }

    fn restart_unavailable_pi(
        self: &Arc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
        takeover_policy: TakeoverPolicy,
    ) -> io::Result<SessionRecord> {
        let (request, recovery) = {
            let mut state = self.lock_state()?;
            if state.shutting_down {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Axod is shutting down",
                ));
            }
            let unavailable = state
                .panes
                .unavailable(shell_id)
                .filter(|shell| shell.session_id == session_id)
                .ok_or_else(|| recovery_refused(RecoveryRefused::NotUnavailable))?;
            if unavailable.is_recovering() {
                return Err(recovery_refused(RecoveryRefused::AlreadyRecovering));
            }
            let pane_id = unavailable.pane_id.clone().ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "Pi pane ID is missing")
            })?;
            let initial_pwd = unavailable.initial_pwd.clone();
            let (session_uuid, session_file, bridge_socket_path) = state
                .database
                .query_row(
                    "SELECT session_uuid, pi_session_file, pi_bridge_socket_path FROM sessions
                     WHERE id = ?1 AND state = 'open'",
                    params![session_id.get()],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, Option<String>>(1)?.map(PathBuf::from),
                            row.get::<_, Option<String>>(2)?,
                        ))
                    },
                )
                .map_err(io::Error::other)?;
            let session_file = session_file.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Pi Session is missing its persisted history path",
                )
            })?;
            let bridge_socket =
                BridgeSocketPath::parse(PathBuf::from(bridge_socket_path.ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Pi Session is missing its persisted bridge socket path",
                    )
                })?))?;
            let owner_count: i64 = state
                .database
                .query_row(
                    "SELECT COUNT(*) FROM sessions WHERE pi_session_file = ?1",
                    params![session_file.to_string_lossy()],
                    |row| row.get(0),
                )
                .map_err(io::Error::other)?;
            if owner_count != 1 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Pi history has ambiguous Session ownership",
                ));
            }
            let request = PiLaunchRequest {
                agent_command: state.agent_command.clone(),
                session_id,
                initial_pwd,
                session_file,
                bridge_socket,
                previous_token: load_pi_bridge_token(&state.database, &session_uuid)?,
                session_uuid,
                pane_id,
                size: state.pane_size(session_id, shell_id),
            };
            // Reserved last, so no failure above leaves a reservation behind.
            let recovery_id = state
                .panes
                .begin_recovery(session_id, shell_id)
                .map_err(recovery_refused)?;
            let recovery = PiRecoveryLease {
                manager: self,
                session_id,
                shell_id,
                recovery_id,
            };
            (request, recovery)
        };

        let check_current = || recovery.ensure_current();
        let history =
            axo_pi::ensure_existing_history(&request.session_file, &self.pi_session_directory)?;
        let lock = takeover::take_over(
            request.takeover_target(),
            takeover_policy,
            &|| recovery.ensure_current(),
            &|process_id, signal| recovery.signal_current(process_id, signal),
        )?;
        if axo_pi::ensure_existing_history(&request.session_file, &self.pi_session_directory)?
            != history
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi history changed while recovery was waiting",
            ));
        }
        let bridge_token = new_uuid_v4()?;
        {
            let state = self.lock_state()?;
            if !recovery.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi recovery was cancelled",
                ));
            }
            // Rotate only while owning the original exclusive transcript lock.
            store_pi_bridge_token(&state.database, &request.session_uuid, &bridge_token)?;
        }
        check_current()?;
        let pending = spawn_pi(&request, lock, bridge_token)?;
        let session = self.commit_pi_recovery(&recovery, pending)?;
        self.start_pi_bridge_worker(shell_id)?;
        self.publish_session_snapshot(session_id)?;
        Ok(session)
    }

    fn commit_pi_recovery(
        &self,
        recovery: &PiRecoveryLease<'_>,
        running: RunningShell,
    ) -> io::Result<SessionRecord> {
        let PiRecoveryLease {
            session_id,
            shell_id,
            recovery_id,
            ..
        } = *recovery;
        let committed = match self.lock_state() {
            Ok(mut state) => {
                // Only this reservation may replace the unavailable pane, never a concurrent
                // newer launch; metadata is built after installing the process.
                match state.commit_recovery(session_id, shell_id, recovery_id, running) {
                    Ok(()) => {
                        state.pi_activity.remove(&session_id);
                        Ok(session_metadata(
                            &state,
                            session_id,
                            &self.attach_socket_path,
                        ))
                    }
                    Err(cancelled) => Err((
                        cancelled,
                        io::Error::new(io::ErrorKind::Interrupted, "Pi recovery was cancelled"),
                    )),
                }
            }
            Err(error) => Err((running, error)),
        };
        match committed {
            Ok(metadata) => metadata,
            Err((mut cancelled, error)) => {
                // A close/shutdown may win during exec. Clean up outside the catalog lock and
                // keep the writer lock until the child exits.
                let grace = cancelled.stop_grace();
                process::stop(&mut cancelled.child, grace);
                Err(error)
            }
        }
    }

    fn close_session(self: &Arc<Self>, id: SessionId) -> io::Result<Option<SessionRecord>> {
        let (replacement, shells_to_terminate) = {
            let mut state = self.lock_state()?;
            close_session(
                &mut state,
                id,
                &self.attach_socket_path,
                &self.pi_session_directory,
            )?
        };
        self.terminate_shells_in_background(shells_to_terminate);
        if let Some(session) = &replacement {
            self.start_pi_bridge_for_session(session)?;
        }
        Ok(replacement)
    }

    fn close_shell(
        self: &Arc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> io::Result<rpc::ShellClosed> {
        let (closed, shells_to_terminate) = {
            let mut state = self.lock_state()?;
            close_shell(
                &mut state,
                session_id,
                shell_id,
                &self.attach_socket_path,
                &self.pi_session_directory,
            )?
        };
        self.terminate_shells_in_background(shells_to_terminate);
        if let Some(session) = &closed.replacement {
            self.start_pi_bridge_for_session(session)?;
        }
        Ok(closed)
    }

    fn start_pi_bridge_for_session(self: &Arc<Self>, session: &SessionRecord) -> io::Result<()> {
        if let Some(pi_shell) = session
            .shells
            .iter()
            .find(|shell| shell.role == PaneRole::Pi)
        {
            self.start_pi_bridge_worker(pi_shell.id)?;
        }
        Ok(())
    }

    fn terminate_shells_in_background(&self, shells: Vec<RunningShell>) {
        for shell in shells {
            let process_id = shell.child.id() as libc::pid_t;
            let cleanup = ShellCleanup(shell);
            let worker_name = format!("axo-shell-cleanup-{process_id}");
            // The guard also cleans up if spawning fails and drops the closure.
            match thread::Builder::new()
                .name(worker_name)
                .spawn(move || drop(cleanup))
            {
                Ok(worker) => match self.workers.lock() {
                    Ok(mut workers) => {
                        let previous_workers = std::mem::take(&mut *workers);
                        for previous in previous_workers {
                            if previous.is_finished() {
                                let _ = previous.join();
                            } else {
                                workers.push(previous);
                            }
                        }
                        workers.push(worker);
                    }
                    Err(_) => {
                        let _ = worker.join();
                    }
                },
                Err(error) => {
                    log::error!(
                        "event=session.shell_cleanup_start_failed pid={process_id} reason={error}"
                    );
                }
            }
        }
    }

    fn reap_exited_sessions(self: &Arc<Self>) -> io::Result<()> {
        let mut state = self.lock_state()?;
        let exited = state
            .panes
            .running_iter_mut()
            .filter_map(|(shell_id, running)| match running.child.try_wait() {
                Ok(Some(status)) => {
                    log::info!("event=session.child_exited session_id={} shell_id={} runtime_id={} pid={} status={status}",
                        running.session_id.get(), shell_id.get(), running.runtime_id.0, running.child.id());
                    Some((shell_id, running.session_id))
                }
                Ok(None) => None,
                Err(error) => {
                    if !running.wait_error_reported {
                        log::error!("event=session.child_wait_failed session_id={} shell_id={} runtime_id={} pid={} error_kind={:?}",
                            running.session_id.get(), shell_id.get(), running.runtime_id.0, running.child.id(), error.kind());
                        running.wait_error_reported = true;
                    }
                    // Do not guess that the child exited or signal a potentially
                    // reused PID. One uncertain child must not stop other reaping.
                    None
                }
            })
            .collect::<Vec<_>>();

        let exited_pi_shells: Vec<_> = exited
            .iter()
            .filter_map(|(shell_id, session_id)| {
                state
                    .panes
                    .running(*shell_id)
                    .is_some_and(|shell| shell.role == PaneRole::Pi)
                    .then_some((*shell_id, *session_id))
            })
            .collect();
        let exited_pi_shell_ids: HashSet<_> = exited_pi_shells
            .iter()
            .map(|(shell_id, _)| *shell_id)
            .collect();
        let exited_non_pi_shell_ids: HashSet<_> = exited
            .iter()
            .filter_map(|(shell_id, _)| {
                (!exited_pi_shell_ids.contains(shell_id)).then_some(*shell_id)
            })
            .collect();
        let mut changed_sessions = HashSet::new();
        let mut removed_sessions = HashSet::new();
        for (shell_id, session_id) in &exited_pi_shells {
            let exited = state.panes.process_exited(*shell_id, |shell| {
                UnavailablePane::new(
                    shell.session_id,
                    shell.pane_id.clone(),
                    shell.initial_pwd.clone(),
                )
            });
            if exited.is_some() {
                state.pi_activity.remove(session_id);
                changed_sessions.insert(*session_id);
            }
        }
        for (shell_id, session_id) in &exited {
            if exited_pi_shell_ids.contains(shell_id) {
                continue;
            }
            let remaining_shell_ids: HashSet<_> = open_shell_ids(&state, *session_id)
                .into_iter()
                .filter(|candidate_id| !exited_non_pi_shell_ids.contains(candidate_id))
                .collect();
            archive_shell_and_prune_layout(
                &mut state.database,
                *shell_id,
                *session_id,
                "shell_exited",
                &remaining_shell_ids,
            )?;
            state.panes.remove(*shell_id);
            if remaining_shell_ids.is_empty() {
                if removed_sessions.insert(*session_id) {
                    archive_session(&mut state.database, *session_id, "shell_exited")?;
                    state.pi_activity.remove(session_id);
                }
            } else {
                changed_sessions.insert(*session_id);
            }
        }
        drop(state);

        for (shell_id, session_id) in exited {
            self.publish_shell_activity(session_id, shell_id, ShellActivity::Exited);
        }
        for session_id in removed_sessions {
            self.publish_session_removed(session_id);
        }
        for session_id in changed_sessions {
            self.publish_session_snapshot(session_id)?;
        }
        self.ensure_open_workspace_sessions()?;
        if let Some(session) = self.ensure_home_session()? {
            self.publish_event(Event::snapshot(session.clone()));
        }
        Ok(())
    }

    /// Registers one more attachment and hands out a PTY descriptor for input, resizing, and
    /// termios/foreground queries. Output comes from `TerminalOutput`, never from this descriptor.
    fn attach_shell(&self, id: ShellId) -> io::Result<ShellAttachment> {
        let mut state = self.lock_state()?;
        let running = state
            .panes
            .running_mut(id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        // SAFETY: fcntl duplicates the live PTY master; the result is owned below.
        let fd = unsafe { libc::fcntl(running.master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd == -1 {
            return Err(io::Error::last_os_error());
        }
        running.attachments += 1;
        Ok(ShellAttachment {
            // SAFETY: fcntl returned a new, owned descriptor.
            master: unsafe { OwnedFd::from_raw_fd(fd) },
            output: Arc::clone(&running.output),
            session_id: running.session_id,
            runtime_id: running.runtime_id,
            first: running.attachments == 1,
        })
    }

    fn mark_detached(&self, id: ShellId, runtime_id: RuntimeId) {
        let session_id = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            let Some(running) = state.panes.running_mut(id) else {
                return;
            };
            if running.runtime_id != runtime_id {
                return;
            }
            running.attachments = running.attachments.saturating_sub(1);
            if running.attachments > 0 {
                return;
            }
            running.session_id
        };
        self.publish_shell_activity(session_id, id, ShellActivity::Detached);
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
        let mut shells = self
            .state
            .lock()
            .map(|mut state| state.panes.drain())
            .unwrap_or_default();
        process::stop_all(
            shells
                .iter_mut()
                .map(|shell| process::Stopping {
                    grace: shell.stop_grace(),
                    child: &mut shell.child,
                })
                .collect(),
        );
    }

    fn pi_runtime_is_current(&self, binding: PiRuntimeBinding) -> bool {
        self.state
            .lock()
            .map(|state| binding.is_current(&state))
            .unwrap_or(false)
    }

    fn set_pi_connection(&self, binding: PiRuntimeBinding, connected: bool) -> io::Result<()> {
        let mut state = self.lock_state()?;
        if !binding.is_current(&state) {
            return Ok(());
        }
        let session_id = binding.session_id;
        let activity = state.pi_activity.entry(session_id).or_default();
        let changed = activity.connected != connected;
        activity.connected = connected;
        drop(state);
        if changed {
            self.publish_session_snapshot(session_id)?;
        }
        Ok(())
    }

    fn resume_archived_pi_session(
        self: &Arc<Self>,
        requester: PiRuntimeBinding,
        requested_session_file: &str,
    ) -> io::Result<SessionId> {
        if requested_session_file.is_empty()
            || requested_session_file.len() > MAX_RESUME_PATH_BYTES
            || requested_session_file.contains('\0')
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi session path is invalid",
            ));
        }
        let session_file = PathBuf::from(requested_session_file);
        let canonical_directory = fs::canonicalize(&self.pi_session_directory)?;
        let canonical_file = fs::canonicalize(&session_file)?;
        if !canonical_file.starts_with(&canonical_directory)
            || !fs::metadata(&canonical_file)?.is_file()
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Pi session is not an Axo-owned history file",
            ));
        }

        let (session_id, lifecycle, initial_pwd, workspace_id) = {
            let state = self.lock_state()?;
            if !requester.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Pi resume request came from a stale pane",
                ));
            }
            let mut statement = state
                .database
                .prepare(
                    "SELECT id, state, initial_pwd, workspace_id FROM sessions WHERE pi_session_file = ?1",
                )
                .map_err(io::Error::other)?;
            let records = statement
                .query_map(params![requested_session_file], |row| {
                    Ok((
                        stored_session_id(row.get(0)?)?,
                        row.get::<_, StoredLifecycle>(1)?,
                        PathBuf::from(row.get::<_, String>(2)?),
                        row.get::<_, Option<String>>(3)?,
                    ))
                })
                .map_err(io::Error::other)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(io::Error::other)?;
            drop(statement);
            let Ok([record]) = <[_; 1]>::try_from(records) else {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "no unique Axo Session owns this Pi history",
                ));
            };
            record
        };

        if lifecycle == StoredLifecycle::Open {
            return self.complete_pi_resume(requester, session_id);
        }
        let workspace_access = if let Some(workspace_id) = &workspace_id {
            let (directory_path, bookmark) = {
                let state = self.lock_state()?;
                state
                    .database
                    .query_row(
                        "SELECT directory_path, directory_bookmark FROM workspaces WHERE workspace_id = ?1",
                        params![workspace_id],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                    )
                    .map_err(io::Error::other)?
            };
            let access =
                WorkspaceDirectoryAccess::open(Path::new(&directory_path), bookmark.as_deref())?;
            if !initial_pwd.starts_with(access.path()) {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Session working directory is outside its Workspace",
                ));
            }
            Some((workspace_id.clone(), access))
        } else {
            if !initial_pwd.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "the Session's working directory is unavailable",
                ));
            }
            None
        };

        let pi_shell_count: i64 = {
            let state = self.lock_state()?;
            state
                .database
                .query_row(
                    "SELECT COUNT(*) FROM shells WHERE session_id = ?1 AND role = 'pi' AND state = 'archived'",
                    params![session_id.get()],
                    |row| row.get(0),
                )
                .map_err(io::Error::other)?
        };
        if pi_shell_count != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "archived Session does not have exactly one Pi pane",
            ));
        }

        let pi_shells = {
            let mut state = self.lock_state()?;
            if state.shutting_down || !requester.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi resume request is no longer current",
                ));
            }
            if state.panes.has_session(session_id) {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "archived Session still has live Axo process state",
                ));
            }

            let transaction = state.database.transaction().map_err(io::Error::other)?;
            if let Some(workspace_id) = &workspace_id {
                let workspace_exists: bool = transaction
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM workspaces WHERE workspace_id = ?1)",
                        params![workspace_id],
                        |row| row.get(0),
                    )
                    .map_err(io::Error::other)?;
                if !workspace_exists {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        "archived Session's Workspace is missing",
                    ));
                }
                transaction
                    .execute(
                        "UPDATE workspaces SET state = 'open', archived_at = NULL WHERE workspace_id = ?1",
                        params![workspace_id],
                    )
                    .map_err(io::Error::other)?;
            }
            let changed = transaction
                .execute(
                    "UPDATE sessions SET state = 'open', archived_at = NULL, termination_reason = NULL
                     WHERE id = ?1 AND state = 'archived'",
                    params![session_id.get()],
                )
                .map_err(io::Error::other)?;
            if changed != 1 {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "Session changed while it was being resumed",
                ));
            }
            transaction
                .execute(
                    "UPDATE shells SET state = 'open', archived_at = NULL, termination_reason = NULL
                     WHERE session_id = ?1 AND state = 'archived'",
                    params![session_id.get()],
                )
                .map_err(io::Error::other)?;
            transaction.commit().map_err(io::Error::other)?;
            if let Some((workspace_id, access)) = workspace_access {
                self.workspace_access
                    .lock()
                    .map_err(|_| io::Error::other("Workspace access lock was poisoned"))?
                    .insert(workspace_id, access);
            }

            let record = read_open_sessions(&state.database)?
                .into_iter()
                .find(|record| record.id == session_id)
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "resumed Session record is missing")
                })?;
            let mut remaining_shell_ids: HashSet<_> = record
                .shell_ids
                .iter()
                .map(|(shell_id, _, _)| *shell_id)
                .collect();
            let mut pi_shells = Vec::new();
            for (shell_id, role, pane_id) in record.shell_ids {
                match role {
                    PaneRole::Terminal => {
                        let size = state.pane_size(session_id, shell_id);
                        match spawn_shell(
                            &state.shell_command,
                            session_id,
                            &record.initial_pwd,
                            size,
                        ) {
                            Ok(shell) => {
                                state.install_running(shell_id, shell);
                            }
                            Err(error) => {
                                log::warn!(
                                    "event=session.terminal_restore_unavailable session_id={} shell_id={} error_kind={:?}",
                                    session_id.get(),
                                    shell_id.get(),
                                    error.kind()
                                );
                                remaining_shell_ids.remove(&shell_id);
                                archive_shell_and_prune_layout(
                                    &mut state.database,
                                    shell_id,
                                    session_id,
                                    "resume_spawn_failed",
                                    &remaining_shell_ids,
                                )?;
                            }
                        }
                    }
                    PaneRole::Pi => {
                        // The Session had no live panes (checked above).
                        let _ = state.panes.insert_unavailable(
                            shell_id,
                            UnavailablePane::new(session_id, pane_id, record.initial_pwd.clone()),
                        );
                        pi_shells.push((session_id, shell_id));
                    }
                }
            }
            pi_shells
        };

        self.recover_pi_shells(pi_shells);
        self.complete_pi_resume(requester, session_id)
    }

    fn complete_pi_resume(
        self: &Arc<Self>,
        requester: PiRuntimeBinding,
        target_session_id: SessionId,
    ) -> io::Result<SessionId> {
        let requester_session_id = requester.session_id;
        let (replacement, shells) = {
            let mut state = self.lock_state()?;
            if state.shutting_down || !requester.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "requesting Pi runtime is no longer current",
                ));
            }
            // Target readiness and requester archival are one catalog transition.
            // A concurrent target close/recovery cannot slip between these checks.
            let target = session_metadata(&state, target_session_id, &self.attach_socket_path)?;
            if !target
                .shells
                .iter()
                .any(|shell| shell.role == PaneRole::Pi && shell.is_available())
            {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "resumed Pi pane is not available",
                ));
            }
            if requester_session_id != target_session_id {
                close_session(
                    &mut state,
                    requester_session_id,
                    &self.attach_socket_path,
                    &self.pi_session_directory,
                )?
            } else {
                (None, Vec::new())
            }
        };

        if requester_session_id != target_session_id {
            self.terminate_shells_in_background(shells);
            if let Some(session) = &replacement {
                self.start_pi_bridge_for_session(session)?;
            }
            self.publish_session_removed(requester_session_id);
            if let Some(replacement) = replacement {
                self.publish_event(Event::snapshot(replacement.clone()));
            }
        }

        self.request_session_focus(target_session_id)?;
        self.publish_session_snapshot(target_session_id)?;
        log::info!(
            "event=session.pi_resume_completed session_id={}",
            target_session_id.get()
        );
        Ok(target_session_id)
    }

    fn observe_pi_event(
        &self,
        binding: PiRuntimeBinding,
        name: &str,
        data: &Value,
    ) -> io::Result<bool> {
        let session_id = binding.session_id;
        let changed = {
            let mut state = self.lock_state()?;
            if !binding.is_current(&state) {
                return Ok(false);
            }

            match PiCatalogEvent::parse(name, data) {
                PiCatalogEvent::AgentStarted => !std::mem::replace(&mut state.pi_activity.entry(session_id).or_default().working, true),
                PiCatalogEvent::AgentSettled => std::mem::replace(&mut state.pi_activity.entry(session_id).or_default().working, false),
                PiCatalogEvent::PromptStarted => {
                    let waits = &mut state.pi_activity.entry(session_id).or_default().ui_waits;
                    let previous = *waits;
                    *waits = waits.saturating_add(1);
                    *waits != previous
                }
                PiCatalogEvent::PromptEnded => {
                    let waits = &mut state.pi_activity.entry(session_id).or_default().ui_waits;
                    let previous = *waits;
                    *waits = waits.saturating_sub(1);
                    *waits != previous
                }
                PiCatalogEvent::Named { title } => {
                    state
                        .database
                        .execute(
                            "UPDATE sessions SET name = ?1 WHERE id = ?2 AND state = 'open'",
                            params![title, session_id.get()],
                        )
                        .map_err(io::Error::other)?
                        > 0
                }
                PiCatalogEvent::Described { title, emoji } => {
                    state.database.execute(
                        "UPDATE sessions SET name = COALESCE(?1, name), emoji = COALESCE(?2, emoji) \
                         WHERE id = ?3 AND state = 'open'",
                        params![title, emoji, session_id.get()],
                    ).map_err(io::Error::other)? > 0
                }
                PiCatalogEvent::Ignored => false,
            }
        };
        if changed {
            self.publish_session_snapshot(session_id)?;
        }
        Ok(true)
    }

    fn persist_pi_session_id(
        &self,
        binding: PiRuntimeBinding,
        session_uuid: &str,
        pi_session_id: &str,
    ) -> io::Result<()> {
        let state = self.lock_state()?;
        if !binding.is_current(&state) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi runtime was replaced",
            ));
        }
        let session_id = binding.session_id;
        let changed = state.database.execute(
            "UPDATE sessions SET pi_session_id = ? WHERE id = ? AND session_uuid = ? AND state = 'open'",
            params![pi_session_id, session_id.get(), session_uuid],
        ).map_err(io::Error::other)?;
        if changed != 1 {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi Session binding changed",
            ));
        }
        Ok(())
    }

    fn config_value(&self, key: ConfigKey) -> rpc::ConfigValue {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let value = match key {
            ConfigKey::AgentCommand => state.agent_command.command().source.clone(),
            ConfigKey::ShellCommand => state.shell_command.0.source.clone(),
        };
        rpc::ConfigValue { key, value }
    }

    fn set_config_value(&self, key: ConfigKey, value: &str) -> io::Result<rpc::ConfigValue> {
        let parsed = match key {
            ConfigKey::AgentCommand => {
                let command = AgentCommand::parse(value)?;
                ParsedConfigValue::AgentCommand(command)
            }
            ConfigKey::ShellCommand => {
                let command = ShellCommand::parse(value)?;
                ParsedConfigValue::ShellCommand(command)
            }
        };
        let value = match &parsed {
            ParsedConfigValue::AgentCommand(command) => command.command().source.clone(),
            ParsedConfigValue::ShellCommand(command) => command.0.source.clone(),
        };

        let mut state = self.lock_state()?;
        state
            .database
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![config_metadata_key(key), value],
            )
            .map_err(io::Error::other)?;
        match parsed {
            ParsedConfigValue::AgentCommand(command) => state.agent_command = command,
            ParsedConfigValue::ShellCommand(command) => state.shell_command = command,
        }
        Ok(rpc::ConfigValue { key, value })
    }

    fn request_session_focus(&self, session_id: SessionId) -> io::Result<()> {
        // Live catalog subscribers focus immediately. Listing clients get the same request for a
        // short window only, so a much later resync cannot replay a stale focus change.
        self.publish_event(Event::SessionFocus { session_id });
        *self
            .pending_resume_focus
            .lock()
            .map_err(|_| io::Error::other("pending resume focus lock was poisoned"))? =
            Some((session_id, Instant::now()));
        Ok(())
    }

    fn take_pending_resume_focus(&self) -> io::Result<Option<SessionId>> {
        Ok(self
            .pending_resume_focus
            .lock()
            .map_err(|_| io::Error::other("pending resume focus lock was poisoned"))?
            .take()
            .filter(|(_, requested)| requested.elapsed() < PENDING_FOCUS_LIFETIME)
            .map(|(session_id, _)| session_id))
    }

    /// Every RPC, attach and event path goes through this one lock, so holding it across slow
    /// work (spawning, SQLite, signalling) stalls every client. Long waits and long holds are
    /// logged with the caller's source location; see `CatalogGuard`.
    #[track_caller]
    fn lock_state(&self) -> io::Result<CatalogGuard<'_>> {
        let caller = std::panic::Location::caller();
        let requested = Instant::now();
        let guard = self
            .state
            .lock()
            .map_err(|_| io::Error::other("session state lock was poisoned"))?;
        let acquired = Instant::now();
        let waited = acquired - requested;
        if waited >= CATALOG_LOCK_REPORT_THRESHOLD {
            log::warn!(
                "event=catalog.lock_wait_long caller={}:{} waited_ms={}",
                caller.file(),
                caller.line(),
                waited.as_millis()
            );
        }
        Ok(CatalogGuard {
            guard,
            caller,
            acquired,
        })
    }
}

/// How long the catalog lock may be waited for or held before it is reported.
const CATALOG_LOCK_REPORT_THRESHOLD: Duration = Duration::from_millis(50);

/// The catalog lock, held. Reports holds longer than `CATALOG_LOCK_REPORT_THRESHOLD` with the
/// source location that took the lock, so a slow request in `ipc.slow_request` can be traced to
/// whoever made it wait. Source locations are bounded; nothing user-controlled is logged.
struct CatalogGuard<'a> {
    guard: std::sync::MutexGuard<'a, SessionState>,
    caller: &'static std::panic::Location<'static>,
    acquired: Instant,
}

impl std::ops::Deref for CatalogGuard<'_> {
    type Target = SessionState;

    fn deref(&self) -> &SessionState {
        &self.guard
    }
}

impl std::ops::DerefMut for CatalogGuard<'_> {
    fn deref_mut(&mut self) -> &mut SessionState {
        &mut self.guard
    }
}

impl Drop for CatalogGuard<'_> {
    fn drop(&mut self) {
        let held = self.acquired.elapsed();
        if held >= CATALOG_LOCK_REPORT_THRESHOLD {
            log::warn!(
                "event=catalog.lock_held_long caller={}:{} held_ms={}",
                self.caller.file(),
                self.caller.line(),
                held.as_millis()
            );
        }
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

fn load_or_create_agent_command(database: &Connection) -> io::Result<AgentCommand> {
    database
        .execute(
            "INSERT OR IGNORE INTO daemon_metadata (key, value) VALUES ('agent_command', ?1)",
            params![DEFAULT_AGENT_COMMAND],
        )
        .map_err(io::Error::other)?;
    let source = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = 'agent_command'",
            [],
            |row| row.get::<_, String>(0),
        )
        .map_err(io::Error::other)?;
    AgentCommand::parse(&source).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("stored default agent command is invalid: {error}"),
        )
    })
}

fn load_or_create_shell_command(database: &Connection) -> io::Result<ShellCommand> {
    let existing = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = 'shell_command'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    let source = match existing {
        Some(source) => source,
        None => {
            let source = default_shell_command()?;
            database
                .execute(
                    "INSERT INTO daemon_metadata (key, value) VALUES ('shell_command', ?1)",
                    params![source],
                )
                .map_err(io::Error::other)?;
            source
        }
    };
    ShellCommand::parse(&source).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("stored default shell command is invalid: {error}"),
        )
    })
}

fn default_shell_command() -> io::Result<String> {
    let configured = std::env::var_os("SHELL").map(PathBuf::from);
    let shell = configured
        .filter(|path| {
            path.is_absolute() && path.is_file() && axo_pty::command::is_executable(path)
        })
        .or_else(|| {
            super::current_user_login_shell()
                .ok()
                .filter(|path| path.is_file() && axo_pty::command::is_executable(path))
        })
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "could not determine an executable shell for the current user",
            )
        })?;
    shell.to_str().map(str::to_owned).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "the current user's shell path is not valid UTF-8",
        )
    })
}

fn load_or_create_host_id(database: &Connection) -> io::Result<String> {
    let existing = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = 'host_id'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    if let Some(host_id) = existing {
        if !is_uuid(&host_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "stored host identity is malformed",
            ));
        }
        return Ok(host_id);
    }

    let host_id = new_uuid_v4()?;
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES ('host_id', ?1)",
            params![host_id],
        )
        .map_err(io::Error::other)?;
    Ok(host_id)
}

fn initialize_database(database: &mut Connection) -> rusqlite::Result<()> {
    let old_version = database.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
    let sessions_exist = database.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sessions')",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    let shells_exist = database.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'shells')",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    let transaction = database.transaction()?;

    if sessions_exist && !shells_exist {
        transaction.execute_batch("ALTER TABLE sessions RENAME TO legacy_sessions;")?;
        create_tables(&transaction)?;
        transaction.execute_batch(
            "INSERT INTO sessions (id, initial_pwd, state, created_at, archived_at, termination_reason)
             SELECT id, initial_pwd, state, created_at, archived_at, termination_reason
             FROM legacy_sessions;
             INSERT INTO shells (id, session_id, initial_pwd, state, created_at, archived_at, termination_reason)
             SELECT id, id, initial_pwd, state, created_at, archived_at, termination_reason
             FROM legacy_sessions;
             DROP TABLE legacy_sessions;",
        )?;
    } else {
        create_tables(&transaction)?;
    }
    ensure_session_layout_column(&transaction)?;
    ensure_workspace_columns(&transaction)?;
    if old_version < 4 {
        transaction.execute(
            "UPDATE shells SET state = 'archived', archived_at = ?, termination_reason = 'workspace_clean_cutover' WHERE state = 'open'",
            params![unix_timestamp()],
        )?;
        transaction.execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?, termination_reason = 'workspace_clean_cutover' WHERE state = 'open'",
            params![unix_timestamp()],
        )?;
    }

    transaction.pragma_update(None, "user_version", 7)?;
    transaction.commit()
}

fn create_tables(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspaces (
            workspace_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            directory_path TEXT NOT NULL,
            directory_bookmark TEXT,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            layout_json TEXT,
            workspace_id TEXT REFERENCES workspaces(workspace_id),
            session_uuid TEXT,
            name TEXT NOT NULL DEFAULT 'Session',
            manual_name TEXT,
            pi_session_file TEXT,
            pi_session_id TEXT,
            pi_bridge_socket_path TEXT
        );
        CREATE TABLE IF NOT EXISTS shells (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id),
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            role TEXT NOT NULL DEFAULT 'terminal' CHECK (role IN ('pi', 'terminal')),
            pane_id TEXT
        );
        CREATE INDEX IF NOT EXISTS shells_by_session_state
            ON shells(session_id, state, id);
        CREATE TABLE IF NOT EXISTS daemon_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );",
    )
}

fn valid_session_title(title: &str) -> bool {
    !title.is_empty()
        && title.trim() == title
        && title.encode_utf16().count() <= 80
        && !title.chars().any(char::is_control)
}

fn valid_session_emoji(emoji: &str) -> bool {
    !emoji.is_empty()
        && emoji.chars().count() <= 16
        && emoji.trim() == emoji
        && !emoji.chars().any(char::is_whitespace)
        && !emoji.chars().any(char::is_control)
}

fn validate_workspace_name(name: &str) -> io::Result<()> {
    if name.is_empty()
        || name.len() > 80
        || name.trim() != name
        || name.chars().any(char::is_control)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Workspace name is invalid",
        ));
    }
    Ok(())
}

fn create_workspace_session(
    state: &mut SessionState,
    attach_socket_path: &Path,
    pi_session_directory: &Path,
    workspace_id: &str,
) -> io::Result<SessionRecord> {
    let initial_pwd = state
        .database
        .query_row(
            "SELECT directory_path FROM workspaces WHERE workspace_id = ? AND state = 'open'",
            params![workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Workspace is not open"))?;
    let ordinal: i64 = state
        .database
        .query_row(
            "SELECT COUNT(*) + 1 FROM sessions WHERE workspace_id = ? AND state = 'open'",
            params![workspace_id],
            |row| row.get(0),
        )
        .map_err(io::Error::other)?;
    let session_uuid = new_uuid_v4()?;
    let pane_id = new_uuid_v4()?;
    let pi_directory = pi_session_directory.join(workspace_id);
    fs::create_dir_all(&pi_directory)?;
    fs::set_permissions(&pi_directory, fs::Permissions::from_mode(0o700))?;
    let pi_session_file = pi_directory.join(format!("{session_uuid}.jsonl"));
    let bridge_socket = BridgeSocketPath::for_session(pi_session_directory, &session_uuid)?;
    let session_name = format!("Session {ordinal}");
    state.database.execute(
        "INSERT INTO sessions
            (initial_pwd, state, created_at, workspace_id, session_uuid, name, pi_session_file, pi_bridge_socket_path)
         VALUES (?, 'open', ?, ?, ?, ?, ?, ?)",
        params![
            initial_pwd.to_string_lossy(),
            unix_timestamp(),
            workspace_id,
            session_uuid,
            session_name,
            pi_session_file.to_string_lossy(),
            bridge_socket.as_str(),
        ],
    ).map_err(io::Error::other)?;
    let session_id = inserted_session_id(&state.database)?;
    state
        .database
        .execute(
            "INSERT INTO shells (session_id, initial_pwd, state, created_at, role, pane_id)
         VALUES (?, ?, 'open', ?, 'pi', ?)",
            params![
                session_id.get(),
                initial_pwd.to_string_lossy(),
                unix_timestamp(),
                pane_id
            ],
        )
        .map_err(io::Error::other)?;
    let pane = inserted_shell_id(&state.database)?;
    let layout = Layout::single(pane);
    state
        .database
        .execute(
            "UPDATE sessions SET layout_json = ? WHERE id = ?",
            params![
                serde_json::to_string(&layout).map_err(io::Error::other)?,
                session_id.get()
            ],
        )
        .map_err(io::Error::other)?;
    let request = PiLaunchRequest {
        agent_command: state.agent_command.clone(),
        session_id,
        initial_pwd: initial_pwd.clone(),
        session_file: pi_session_file.clone(),
        bridge_socket: bridge_socket.clone(),
        session_uuid: session_uuid.clone(),
        pane_id: pane_id.clone(),
        previous_token: None,
        size: state.pane_size(session_id, pane),
    };
    let running = match spawn_new_pi(&state.database, &request) {
        Ok(running) => running,
        Err(error) => {
            archive_session(&mut state.database, session_id, "pi_spawn_failed")?;
            return Err(error);
        }
    };
    state.install_running(pane, running);
    session_metadata(state, session_id, attach_socket_path)
}

fn create_session(
    state: &mut SessionState,
    attach_socket_path: &Path,
) -> io::Result<SessionRecord> {
    let initial_pwd = state.initial_pwd.clone();
    let session_uuid = new_uuid_v4()?;
    let ordinal: i64 = state
        .database
        .query_row(
            "SELECT COUNT(*) + 1 FROM sessions WHERE workspace_id IS NULL AND state = 'open'",
            [],
            |row| row.get(0),
        )
        .map_err(io::Error::other)?;
    let session_name = format!("Session {ordinal}");
    state
        .database
        .execute(
            "INSERT INTO sessions (initial_pwd, state, created_at, session_uuid, name) VALUES (?1, 'open', ?2, ?3, ?4)",
            params![initial_pwd.to_string_lossy(), unix_timestamp(), session_uuid, session_name],
        )
        .map_err(io::Error::other)?;
    let id = inserted_session_id(&state.database)?;

    if let Err(error) = create_shell(state, id, attach_socket_path) {
        archive_session(&mut state.database, id, "spawn_failed")?;
        return Err(error);
    }
    session_metadata(state, id, attach_socket_path)
}

fn create_shell(
    state: &mut SessionState,
    session_id: SessionId,
    attach_socket_path: &Path,
) -> io::Result<ShellRecord> {
    let initial_pwd = session_initial_pwd(&state.database, session_id)?;
    state
        .database
        .execute(
            "INSERT INTO shells (session_id, initial_pwd, state, created_at)
             VALUES (?1, ?2, 'open', ?3)",
            params![
                session_id.get(),
                initial_pwd.to_string_lossy(),
                unix_timestamp()
            ],
        )
        .map_err(io::Error::other)?;
    let shell_id = inserted_shell_id(&state.database)?;

    let size = state.pane_size(session_id, shell_id);
    let running = match spawn_shell(&state.shell_command, session_id, &initial_pwd, size) {
        Ok(running) => running,
        Err(error) => {
            archive_shell(&state.database, shell_id, "spawn_failed")?;
            return Err(error);
        }
    };
    let metadata = running_shell_record(shell_id, &running, attach_socket_path);
    state.install_running(shell_id, running);
    Ok(metadata)
}

fn open_standalone_session_count(database: &Connection) -> io::Result<i64> {
    database
        .query_row(
            "SELECT COUNT(*) FROM sessions WHERE workspace_id IS NULL AND state = 'open'",
            [],
            |row| row.get(0),
        )
        .map_err(io::Error::other)
}

fn close_session(
    state: &mut SessionState,
    id: SessionId,
    attach_socket_path: &Path,
    pi_session_directory: &Path,
) -> io::Result<(Option<SessionRecord>, Vec<RunningShell>)> {
    if open_shell_ids(state, id).is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "session is not open",
        ));
    }

    let workspace_id: Option<String> = state
        .database
        .query_row(
            "SELECT workspace_id FROM sessions WHERE id = ? AND state = 'open'",
            params![id.get()],
            |row| row.get(0),
        )
        .map_err(io::Error::other)?;
    let replacement = if let Some(workspace_id) = workspace_id {
        let workspace_session_count: i64 = state
            .database
            .query_row(
                "SELECT COUNT(*) FROM sessions WHERE workspace_id = ? AND state = 'open'",
                params![workspace_id],
                |row| row.get(0),
            )
            .map_err(io::Error::other)?;
        (workspace_session_count == 1)
            .then(|| {
                create_workspace_session(
                    state,
                    attach_socket_path,
                    pi_session_directory,
                    &workspace_id,
                )
            })
            .transpose()?
    } else if open_standalone_session_count(&state.database)? == 1 {
        // Workspace Sessions do not replace the standalone home Session.
        Some(create_session(state, attach_socket_path)?)
    } else {
        None
    };

    archive_session(&mut state.database, id, "explicit_close")?;
    state.pi_activity.remove(&id);
    let shells = remove_session_shells(state, id);
    Ok((replacement, shells))
}

fn close_shell(
    state: &mut SessionState,
    session_id: SessionId,
    shell_id: ShellId,
    attach_socket_path: &Path,
    pi_session_directory: &Path,
) -> io::Result<(rpc::ShellClosed, Vec<RunningShell>)> {
    let Some(pane) = state.panes.get(shell_id) else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "shell is not open"));
    };
    if pane.session_id() != session_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "shell does not belong to this session",
        ));
    }
    let role = match pane {
        Pane::Running(shell) => shell.role,
        Pane::Unavailable(_) => PaneRole::Pi,
    };

    let sibling_count = open_shell_ids(state, session_id).len();
    if sibling_count == 1 || role == PaneRole::Pi {
        let (replacement, shells) =
            close_session(state, session_id, attach_socket_path, pi_session_directory)?;
        return Ok((
            rpc::ShellClosed {
                archived_shell_id: shell_id,
                archived_session_id: Some(session_id),
                replacement,
            },
            shells,
        ));
    }

    let remaining_shell_ids = open_shell_ids(state, session_id)
        .into_iter()
        .filter(|candidate_id| *candidate_id != shell_id)
        .collect();
    archive_shell_and_prune_layout(
        &mut state.database,
        shell_id,
        session_id,
        "explicit_close",
        &remaining_shell_ids,
    )?;
    let shell = state.panes.remove(shell_id).into_iter().collect();
    Ok((
        rpc::ShellClosed {
            archived_shell_id: shell_id,
            archived_session_id: None,
            replacement: None,
        },
        shell,
    ))
}

fn open_shell_ids(state: &SessionState, session_id: SessionId) -> HashSet<ShellId> {
    state.panes.shell_ids_in(session_id)
}

fn remove_session_shells(state: &mut SessionState, session_id: SessionId) -> Vec<RunningShell> {
    state.panes.remove_session(session_id)
}

fn session_metadata(
    state: &SessionState,
    id: SessionId,
    attach_socket_path: &Path,
) -> io::Result<SessionRecord> {
    // One row per Session: this runs for every listing and snapshot, under the catalog lock.
    let (
        initial_pwd,
        session_uuid,
        workspace_id,
        workspace_name,
        name,
        manual_name,
        emoji,
        pi_session_file,
        pi_session_id,
        stored_layout,
    ) = state
        .database
        .prepare_cached(
            "SELECT s.initial_pwd, s.session_uuid, s.workspace_id, w.name, s.name, s.manual_name,
                    s.emoji, s.pi_session_file, s.pi_session_id, s.layout_json
             FROM sessions s
             LEFT JOIN workspaces w ON w.workspace_id = s.workspace_id AND w.state = 'open'
             WHERE s.id = ?1 AND s.state = 'open'",
        )
        .and_then(|mut statement| {
            statement.query_row(params![id.get()], |row| {
                Ok((
                    PathBuf::from(row.get::<_, String>(0)?),
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<String>>(7)?.map(PathBuf::from),
                    row.get::<_, Option<String>>(8)?,
                    row.get::<_, Option<String>>(9)?,
                ))
            })
        })
        .map_err(io::Error::other)?;
    if workspace_id.is_some() && workspace_name.is_none() {
        return Err(io::Error::other("Session's Workspace is not open"));
    }
    let mut shells: Vec<_> = state
        .panes
        .in_session(id)
        .map(|(shell_id, pane)| match pane {
            Pane::Running(running) => running_shell_record(shell_id, running, attach_socket_path),
            Pane::Unavailable(shell) => {
                unavailable_pi_shell_record(shell_id, shell, attach_socket_path)
            }
        })
        .collect();
    shells.sort_by_key(|shell| shell.id.get());
    let status = if shells.iter().any(|shell| !shell.is_available()) {
        SessionStatus::Unavailable
    } else if shells.iter().any(|shell| shell.role == PaneRole::Pi) {
        state
            .pi_activity
            .get(&id)
            .map_or(SessionStatus::Starting, |activity| activity.status())
    } else {
        SessionStatus::Ready
    };
    Ok(SessionRecord {
        id,
        session_uuid,
        pi_session_file,
        pi_session_id,
        workspace_id,
        workspace_name,
        name,
        manual_name,
        emoji,
        status,
        initial_pwd,
        shells,
        layout: stored_layout.and_then(|json| parse_stored_layout(id, &json)),
    })
}

fn running_shell_record(
    id: ShellId,
    running: &RunningShell,
    attach_socket_path: &Path,
) -> ShellRecord {
    ShellRecord {
        id,
        pane_id: running.pane_id.clone(),
        role: running.role,
        process_id: running.child.id(),
        initial_pwd: running.initial_pwd.clone(),
        pty_device: running.slave_device.clone(),
        attach_socket_path: attach_socket_path.to_path_buf(),
        availability: Availability::Available,
    }
}

/// Shown on a Pi pane whose process could not be recovered.
const UNRECOVERABLE_PI_REASON: &str =
    "Axo could not recover this Pi session. Its conversation history is preserved.";

fn unavailable_pi_shell_record(
    id: ShellId,
    shell: &UnavailablePane,
    attach_socket_path: &Path,
) -> ShellRecord {
    ShellRecord {
        id,
        pane_id: shell.pane_id.clone(),
        role: PaneRole::Pi,
        process_id: 0,
        initial_pwd: shell.initial_pwd.clone(),
        pty_device: String::new(),
        attach_socket_path: attach_socket_path.to_path_buf(),
        availability: Availability::Unavailable {
            reason: UNRECOVERABLE_PI_REASON.to_owned(),
        },
    }
}

fn read_open_sessions(database: &Connection) -> io::Result<Vec<StoredSession>> {
    let mut statement = database
        .prepare("SELECT id, initial_pwd FROM sessions WHERE state = 'open' ORDER BY id")
        .map_err(io::Error::other)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                stored_session_id(row.get(0)?)?,
                PathBuf::from(row.get::<_, String>(1)?),
            ))
        })
        .map_err(io::Error::other)?;
    let mut records = Vec::new();
    for row in rows {
        let (id, initial_pwd) = row.map_err(io::Error::other)?;
        let mut shell_statement = database.prepare(
            "SELECT id, role, pane_id FROM shells WHERE session_id = ?1 AND state = 'open' ORDER BY id",
        ).map_err(io::Error::other)?;
        let shell_ids = shell_statement
            .query_map(params![id.get()], |row| {
                let role: String = row.get(1)?;
                let role = match role.as_str() {
                    "pi" => PaneRole::Pi,
                    "terminal" => PaneRole::Terminal,
                    _ => return Err(rusqlite::Error::InvalidQuery),
                };
                Ok((stored_shell_id(row.get(0)?)?, role, row.get(2)?))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?;
        records.push(StoredSession {
            id,
            initial_pwd,
            shell_ids,
        });
    }
    Ok(records)
}

fn read_session_layout(database: &Connection, id: SessionId) -> io::Result<Option<Layout>> {
    let stored_layout = database
        .query_row(
            "SELECT layout_json FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.get()],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))?;
    Ok(stored_layout.and_then(|json| parse_stored_layout(id, &json)))
}

/// Parsing validates the layout's structure; a stored layout that fails is ignored.
fn parse_stored_layout(id: SessionId, json: &str) -> Option<Layout> {
    serde_json::from_str(json)
        .inspect_err(|error| {
            log::warn!(
                "event=session.layout_invalid session_id={} reason={error}",
                id.get()
            );
        })
        .ok()
}

fn restore_workspace_accesses(
    database: &Connection,
) -> io::Result<HashMap<String, WorkspaceDirectoryAccess>> {
    let workspace_records = {
        let mut statement = database
            .prepare(
                "SELECT workspace_id, directory_path, directory_bookmark FROM workspaces \
                 WHERE state = 'open'",
            )
            .map_err(io::Error::other)?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };

    let mut accesses = HashMap::new();
    for (workspace_id, path, bookmark) in workspace_records {
        match WorkspaceDirectoryAccess::open(Path::new(&path), bookmark.as_deref()) {
            Ok(access) => {
                accesses.insert(workspace_id, access);
            }
            Err(_) => {
                log::warn!(
                    "event=workspace.access_restore_failed workspace_id={} reason=directory_unavailable",
                    workspace_id
                );
            }
        }
    }
    Ok(accesses)
}

fn ensure_workspace_columns(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspaces (
            workspace_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            directory_path TEXT NOT NULL,
            directory_bookmark TEXT,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER
        );",
    )?;
    for (table, column, definition) in [
        ("workspaces", "directory_bookmark", "TEXT"),
        (
            "sessions",
            "workspace_id",
            "TEXT REFERENCES workspaces(workspace_id)",
        ),
        ("sessions", "session_uuid", "TEXT"),
        ("sessions", "name", "TEXT NOT NULL DEFAULT 'Session'"),
        ("sessions", "manual_name", "TEXT"),
        ("sessions", "emoji", "TEXT"),
        ("sessions", "pi_session_file", "TEXT"),
        ("sessions", "pi_session_id", "TEXT"),
        ("sessions", "pi_bridge_socket_path", "TEXT"),
        (
            "shells",
            "role",
            "TEXT NOT NULL DEFAULT 'terminal' CHECK (role IN ('pi', 'terminal'))",
        ),
        ("shells", "pane_id", "TEXT"),
    ] {
        let columns = transaction
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?;
        if !columns.iter().any(|existing| existing == column) {
            transaction.execute(
                &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
                [],
            )?;
        }
    }
    transaction.execute_batch(
        "CREATE INDEX IF NOT EXISTS sessions_by_workspace_state ON sessions(workspace_id, state, id);",
    )?;
    Ok(())
}

fn ensure_pi_bridge_socket_paths(
    database: &Connection,
    pi_session_directory: &Path,
) -> io::Result<()> {
    let records = {
        let mut statement = database
            .prepare(
                "SELECT id, session_uuid, pi_bridge_socket_path FROM sessions
                 WHERE session_uuid IS NOT NULL",
            )
            .map_err(io::Error::other)?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };

    for (session_id, session_uuid, stored_path) in records {
        match stored_path {
            Some(path) => {
                BridgeSocketPath::parse(PathBuf::from(path)).map_err(|error| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("stored Pi bridge socket path for session {session_id} is invalid: {error}"),
                    )
                })?;
            }
            None => {
                let socket_path =
                    BridgeSocketPath::for_session(pi_session_directory, &session_uuid)?;
                let changed = database
                    .execute(
                        "UPDATE sessions SET pi_bridge_socket_path = ?1
                         WHERE id = ?2 AND pi_bridge_socket_path IS NULL",
                        params![socket_path.as_str(), session_id],
                    )
                    .map_err(io::Error::other)?;
                if changed != 1 {
                    return Err(io::Error::other(
                        "could not persist the Pi bridge socket address",
                    ));
                }
            }
        }
    }
    Ok(())
}

fn ensure_session_layout_column(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    let has_layout_column = {
        let mut statement = transaction.prepare("PRAGMA table_info(sessions)")?;
        let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
        columns
            .collect::<Result<Vec<_>, _>>()?
            .iter()
            .any(|column| column == "layout_json")
    };
    if !has_layout_column {
        transaction.execute("ALTER TABLE sessions ADD COLUMN layout_json TEXT", [])?;
    }
    Ok(())
}

fn session_initial_pwd(database: &Connection, id: SessionId) -> io::Result<PathBuf> {
    database
        .query_row(
            "SELECT initial_pwd FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.get()],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))
}

fn archive_shell(database: &Connection, id: ShellId, reason: &str) -> io::Result<()> {
    let changed = database
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![unix_timestamp(), reason, id.get()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "shell was not open in the database",
        ));
    }
    Ok(())
}

fn archive_shell_and_prune_layout(
    database: &mut Connection,
    shell_id: ShellId,
    session_id: SessionId,
    reason: &str,
    remaining_shell_ids: &HashSet<ShellId>,
) -> io::Result<()> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![unix_timestamp(), reason, shell_id.get()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "shell was not open in the database",
        ));
    }

    if let Some(layout) = read_session_layout(&transaction, session_id)? {
        let pruned_layout = layout.pruned_to(remaining_shell_ids);
        let layout_json = pruned_layout
            .as_ref()
            .map(serde_json::to_string)
            .transpose()
            .map_err(io::Error::other)?;
        transaction
            .execute(
                "UPDATE sessions SET layout_json = ?1 WHERE id = ?2 AND state = 'open'",
                params![layout_json, session_id.get()],
            )
            .map_err(io::Error::other)?;
    }

    transaction.commit().map_err(io::Error::other)
}

fn archive_workspace_records(
    database: &mut Connection,
    workspace_id: &str,
) -> io::Result<Vec<SessionId>> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let session_ids = {
        let mut statement = transaction
            .prepare("SELECT id FROM sessions WHERE workspace_id = ?1 AND state = 'open'")
            .map_err(io::Error::other)?;
        statement
            .query_map(params![workspace_id], |row| row.get::<_, i64>(0))
            .map_err(io::Error::other)?
            .map(|id| id.and_then(stored_session_id))
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };
    let archived_at = unix_timestamp();
    transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = 'workspace_archived'
             WHERE state = 'open' AND session_id IN (
                 SELECT id FROM sessions WHERE workspace_id = ?2 AND state = 'open'
             )",
            params![archived_at, workspace_id],
        )
        .map_err(io::Error::other)?;
    transaction
        .execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?1, termination_reason = 'workspace_archived'
             WHERE workspace_id = ?2 AND state = 'open'",
            params![archived_at, workspace_id],
        )
        .map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE workspaces SET state = 'archived', archived_at = ?1
             WHERE workspace_id = ?2 AND state = 'open'",
            params![archived_at, workspace_id],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Workspace is not open",
        ));
    }
    transaction.commit().map_err(io::Error::other)?;
    Ok(session_ids)
}

fn archive_session(database: &mut Connection, id: SessionId, reason: &str) -> io::Result<()> {
    let transaction = database.transaction().map_err(io::Error::other)?;
    let archived_at = unix_timestamp();
    transaction
        .execute(
            "UPDATE shells SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE session_id = ?3 AND state = 'open'",
            params![archived_at, reason, id.get()],
        )
        .map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![archived_at, reason, id.get()],
        )
        .map_err(io::Error::other)?;
    if changed != 1 {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "session was not open in the database",
        ));
    }
    transaction.commit().map_err(io::Error::other)
}

fn app_resources_directory() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    Some(executable.parent()?.parent()?.join("Resources"))
}

fn bundled_ghostty_resources_directory() -> Option<PathBuf> {
    let resources_directory = app_resources_directory()?.join("ghostty-resources");
    resources_directory
        .join("shell-integration")
        .is_dir()
        .then_some(resources_directory)
}

fn bundled_terminfo_directory() -> Option<PathBuf> {
    let terminfo_directory = app_resources_directory()?.join("terminfo");
    terminfo_directory
        .join("78/xterm-ghostty")
        .is_file()
        .then_some(terminfo_directory)
}

/// Points terminal programs at the app's bundled Ghostty shell integration and terminfo.
fn terminal_environment() -> Vec<(&'static str, PathBuf)> {
    let mut environment = Vec::new();
    if let Some(resources_directory) = bundled_ghostty_resources_directory() {
        environment.push(("GHOSTTY_RESOURCES_DIR", resources_directory));
    }
    if let Some(terminfo_directory) = bundled_terminfo_directory() {
        environment.push(("TERMINFO", terminfo_directory));
    }
    environment
}

fn set_terminal_resources(command: &mut Command) {
    for (name, value) in terminal_environment() {
        command.env(name, value);
    }
}

fn spawn_shell(
    shell_command: &ShellCommand,
    session_id: SessionId,
    initial_pwd: &Path,
    size: WindowSize,
) -> io::Result<RunningShell> {
    let shell = resolve_shell_executable(&shell_command.0.executable)?;
    let home = super::current_user_home_directory()?;
    let mut command = Command::new(&shell);
    command
        .args(&shell_command.0.arguments)
        .arg("-l")
        .current_dir(initial_pwd)
        .env("HOME", &home)
        .env("SHELL", &shell)
        .env("PWD", initial_pwd)
        .env("TERM", "xterm-ghostty");
    set_terminal_resources(&mut command);
    let PtyProcess {
        child,
        master,
        device: slave_device,
        output,
    } = process::spawn(command, size, &[])?;
    Ok(RunningShell {
        runtime_id: RuntimeId::new(),
        session_id,
        role: PaneRole::Terminal,
        pane_id: None,
        initial_pwd: initial_pwd.to_path_buf(),
        child,
        wait_error_reported: false,
        master,
        slave_device,
        attachments: 0,
        output,
        last_input_sequence: None,
        _writer_lock: None,
        pi_bridge_socket: None,
        pi_bridge_token: None,
    })
}

fn pi_bridge_token_key(session_uuid: &str) -> String {
    format!("pi_bridge_token:{session_uuid}")
}

fn load_pi_bridge_token(database: &Connection, session_uuid: &str) -> io::Result<Option<String>> {
    let token = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![pi_bridge_token_key(session_uuid)],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    if token.as_ref().is_some_and(|token| !is_uuid(token)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi bridge credential is invalid",
        ));
    }
    Ok(token)
}

fn store_pi_bridge_token(database: &Connection, session_uuid: &str, token: &str) -> io::Result<()> {
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![pi_bridge_token_key(session_uuid), token],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

// New Session admission never takes over an existing writer. Recovery has a
// separate reservation/commit path, so no takeover wait can hide under its lock.
/// Starts Pi for a pane with no previous process (`request.previous_token` is ignored).
fn spawn_new_pi(database: &Connection, request: &PiLaunchRequest) -> io::Result<RunningShell> {
    let lock = WriterLock::acquire(&request.session_file)?;
    let bridge_token = new_uuid_v4()?;
    store_pi_bridge_token(database, &request.session_uuid, &bridge_token)?;
    spawn_pi(request, lock, bridge_token)
}

fn spawn_pi(
    request: &PiLaunchRequest,
    lock: WriterLock,
    bridge_token: String,
) -> io::Result<RunningShell> {
    let home = super::current_user_home_directory()?;
    let environment = terminal_environment();
    let PiProcess {
        pty:
            PtyProcess {
                child,
                master,
                device: slave_device,
                output,
            },
        writer_lock,
        socket_cleanup,
    } = axo_pi::spawn(
        &request.launch(&home, &environment),
        lock,
        &bridge_token,
        request.size,
    )?;
    log_socket_cleanup(request.session_id, socket_cleanup);
    Ok(RunningShell {
        runtime_id: RuntimeId::new(),
        session_id: request.session_id,
        role: PaneRole::Pi,
        pane_id: Some(request.pane_id.clone()),
        initial_pwd: request.initial_pwd.clone(),
        child,
        wait_error_reported: false,
        master,
        slave_device,
        attachments: 0,
        output,
        last_input_sequence: None,
        _writer_lock: Some(writer_lock),
        pi_bridge_socket: Some(request.bridge_socket.clone()),
        pi_bridge_token: Some(bridge_token),
    })
}

fn log_socket_cleanup(session_id: SessionId, cleanup: SocketCleanup) {
    match cleanup {
        SocketCleanup::Removed => log::info!(
            "event=pi.bridge_socket_removed session_id={} reason=abandoned",
            session_id.get()
        ),
        SocketCleanup::NotASocket => log::warn!(
            "event=pi.bridge_socket_blocked session_id={} reason=not_a_socket",
            session_id.get()
        ),
        SocketCleanup::Absent | SocketCleanup::InUse => {}
    }
}

/// Startup reconciliation: removes the bridge socket of every Session whose writer lock no Pi
/// holds. Sessions whose Pi is still alive (an orphan of a crashed Axod) keep theirs. Failures
/// are logged and skipped; they must not keep Axod from starting.
fn remove_abandoned_pi_bridge_sockets(database: &Connection) -> io::Result<()> {
    let records = {
        let mut statement = database
            .prepare(
                "SELECT id, pi_session_file, pi_bridge_socket_path FROM sessions
                 WHERE pi_session_file IS NOT NULL AND pi_bridge_socket_path IS NOT NULL",
            )
            .map_err(io::Error::other)?;
        statement
            .query_map([], |row| {
                Ok((
                    stored_session_id(row.get(0)?)?,
                    PathBuf::from(row.get::<_, String>(1)?),
                    PathBuf::from(row.get::<_, String>(2)?),
                ))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?
    };
    for (session_id, session_file, socket_path) in records {
        match BridgeSocketPath::parse(socket_path)
            .and_then(|socket| socket.reconcile(&session_file))
        {
            Ok(cleanup) => log_socket_cleanup(session_id, cleanup),
            Err(error) => log::warn!(
                "event=pi.bridge_socket_reconcile_failed session_id={} error_kind={:?}",
                session_id.get(),
                error.kind()
            ),
        }
    }
    Ok(())
}

impl PiLaunchRequest {
    fn launch<'a>(
        &'a self,
        home: &'a Path,
        environment: &'a [(&'static str, PathBuf)],
    ) -> PiLaunch<'a> {
        PiLaunch {
            agent_command: &self.agent_command,
            initial_pwd: &self.initial_pwd,
            session_file: &self.session_file,
            bridge_socket: &self.bridge_socket,
            session_uuid: &self.session_uuid,
            pane_id: &self.pane_id,
            home,
            environment,
        }
    }

    fn takeover_target(&self) -> TakeoverTarget<'_> {
        TakeoverTarget {
            session_id: self.session_id,
            initial_pwd: &self.initial_pwd,
            session_file: &self.session_file,
            bridge_socket: &self.bridge_socket,
            session_uuid: &self.session_uuid,
            pane_id: &self.pane_id,
            previous_token: self.previous_token.as_deref(),
        }
    }
}

fn window_size(grid: GridSize) -> WindowSize {
    // A grid is at least 1x1 and fits u16, so this always succeeds.
    WindowSize::new(u32::from(grid.rows()), u32::from(grid.columns()))
        .unwrap_or(WindowSize::DEFAULT)
}

/// Where the latest client's viewport is kept across restarts, so restored panes start at
/// the size they will be shown at.
const VIEWPORT_METADATA_KEY: &str = "client_viewport";

fn load_viewport(database: &Connection) -> io::Result<Option<Viewport>> {
    let stored: Option<String> = database
        .query_row(
            "SELECT value FROM daemon_metadata WHERE key = ?1",
            params![VIEWPORT_METADATA_KEY],
            |row| row.get(0),
        )
        .optional()
        .map_err(io::Error::other)?;
    Ok(
        stored.and_then(|stored| match serde_json::from_str(&stored) {
            Ok(viewport) => Some(viewport),
            Err(error) => {
                log::warn!("event=viewport.stored_invalid reason={error}");
                None
            }
        }),
    )
}

fn store_viewport(database: &Connection, viewport: &Viewport) -> io::Result<()> {
    let value = serde_json::to_string(viewport).map_err(io::Error::other)?;
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![VIEWPORT_METADATA_KEY, value],
        )
        .map_err(io::Error::other)?;
    Ok(())
}

fn resolve_shell_executable(program: &str) -> io::Result<PathBuf> {
    axo_pty::command::resolve_executable(program, None, "shell")
}

/// Connects one running Pi's bridge to the catalog while it is the pane's current process.
struct PiBridgeHost {
    manager: Weak<SessionManager>,
    binding: PiRuntimeBinding,
    session_uuid: String,
}

impl PiBridgeHost {
    fn log_context(&self) -> String {
        format!(
            "session_id={} shell_id={}",
            self.binding.session_id.get(),
            self.binding.shell_id.get()
        )
    }
}

impl worker::BridgeHost for PiBridgeHost {
    fn is_current(&self) -> bool {
        self.manager
            .upgrade()
            .is_some_and(|owner| owner.pi_runtime_is_current(self.binding))
    }

    fn bound(&self, pi_session_id: &str) -> io::Result<()> {
        let owner = self
            .manager
            .upgrade()
            .ok_or_else(|| io::Error::new(io::ErrorKind::Interrupted, "Axod is stopping"))?;
        owner.persist_pi_session_id(self.binding, &self.session_uuid, pi_session_id)?;
        owner.set_pi_connection(self.binding, true)
    }

    fn disconnected(&self) {
        if let Some(owner) = self.manager.upgrade() {
            let _ = owner.set_pi_connection(self.binding, false);
        }
    }

    fn resume_requested(&self, target_session_file: Option<&str>) {
        let context = self.log_context();
        let Some(target_session_file) = target_session_file else {
            log::warn!("event=session.pi_resume_rejected {context} reason=invalid_request");
            return;
        };
        let Some(owner) = self.manager.upgrade() else {
            return;
        };
        if let Err(error) = owner.resume_archived_pi_session(self.binding, target_session_file) {
            log::warn!(
                "event=session.pi_resume_rejected {context} error_kind={:?}",
                error.kind()
            );
        }
    }

    fn event(
        &self,
        pi_session_id: &str,
        stream_id: &str,
        sequence: u64,
        name: &str,
        data: Value,
    ) -> bool {
        let Some(owner) = self.manager.upgrade() else {
            return false;
        };
        if !matches!(owner.observe_pi_event(self.binding, name, &data), Ok(true)) {
            return false;
        }
        owner.publish_event(Event::PiEvent {
            session_id: self.binding.session_id,
            pi_session_id: pi_session_id.to_owned(),
            stream_id: stream_id.to_owned(),
            sequence,
            name: name.to_owned(),
            data,
        });
        true
    }
}

struct ShellCleanup(RunningShell);

impl Drop for ShellCleanup {
    fn drop(&mut self) {
        let grace = self.0.stop_grace();
        process::stop(&mut self.0.child, grace);
    }
}

#[cfg(target_vendor = "apple")]
fn process_name(process_id: libc::pid_t) -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is writable for its full length; proc_name NUL-terminates within it.
    let length =
        unsafe { libc::proc_name(process_id, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if length <= 0 {
        return None;
    }
    let name = String::from_utf8_lossy(&buffer[..length as usize]).into_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(not(target_vendor = "apple"))]
fn process_name(_process_id: libc::pid_t) -> Option<String> {
    None
}

/// Waits until `descriptor` is readable or `timeout` passes. Errors count as readable so the
/// caller's own call reports them.
fn wait_until_readable(descriptor: RawFd, timeout: Duration) -> bool {
    let mut poll_descriptor = libc::pollfd {
        fd: descriptor,
        events: libc::POLLIN,
        revents: 0,
    };
    let timeout_millis = timeout.as_millis().clamp(1, libc::c_int::MAX as u128) as libc::c_int;
    // SAFETY: poll reads one initialized pollfd for the duration of the call.
    let ready = unsafe { libc::poll(&mut poll_descriptor, 1, timeout_millis) };
    ready != 0
}

#[cfg(test)]
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

struct ShellAttachment {
    master: OwnedFd,
    output: Arc<TerminalOutput>,
    session_id: SessionId,
    runtime_id: RuntimeId,
    first: bool,
}

/// Detaches the subscriber when the attachment worker exits for any reason.
struct OutputSubscription(Arc<OutputSubscriber>);

impl Drop for OutputSubscription {
    fn drop(&mut self) {
        self.0.detach();
    }
}

struct TerminalAttachmentLease<'a> {
    manager: &'a SessionManager,
    shell_id: ShellId,
    runtime_id: RuntimeId,
}

impl Drop for TerminalAttachmentLease<'_> {
    fn drop(&mut self) {
        self.manager.mark_detached(self.shell_id, self.runtime_id);
    }
}

/// Maps why `attach_shell` failed to the attach protocol's rejection codes.
fn attach_rejection(error: &io::Error) -> attach::Rejection {
    match error.kind() {
        io::ErrorKind::NotFound => attach::Rejection::ShellNotOpen,
        io::ErrorKind::WouldBlock => attach::Rejection::DaemonBusy,
        _ => attach::Rejection::Other,
    }
}

/// Serves one attachment (see `axo_pty::attach` for the protocol): registers it with the shell,
/// subscribes to the shell's output, then streams replay and live output until either side ends.
fn handle_attachment(
    mut stream: UnixStream,
    manager: Weak<SessionManager>,
    _permit: AttachmentPermit,
) {
    let started_at = Instant::now();
    // Accepted sockets can inherit nonblocking mode on macOS. Use bounded blocking I/O; any
    // failed write ends the attachment, so a partial write can never corrupt a live stream.
    if stream
        .set_nonblocking(false)
        .and_then(|()| stream.set_read_timeout(Some(Duration::from_millis(200))))
        .and_then(|()| stream.set_write_timeout(Some(ATTACH_REPLAY_WRITE_TIMEOUT)))
        .is_err()
    {
        log::warn!("event=session.attach_rejected reason=socket_setup");
        return;
    }
    attach::set_send_buffer(&stream, ATTACH_SEND_BUFFER_BYTES);
    let request = attach::read_request(&mut stream).and_then(|id| {
        ShellId::new(id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "shell ID must be positive"))
    });
    let id = match request {
        Ok(id) => id,
        Err(error) => {
            log::debug!(
                "event=session.attach_rejected reason=invalid_request error_kind={:?}",
                error.kind()
            );
            let _ = attach::write_rejection(&mut stream, attach_rejection(&error));
            return;
        }
    };
    let Some(manager) = manager.upgrade() else {
        return;
    };
    let attachment = match manager.attach_shell(id) {
        Ok(attachment) => attachment,
        Err(error) => {
            log::warn!(
                "event=session.attach_rejected shell_id={} error_kind={:?}",
                id.get(),
                error.kind()
            );
            if let Err(write_error) = attach::write_rejection(&mut stream, attach_rejection(&error))
            {
                log::debug!(
                    "event=session.attach_rejection_write_failed shell_id={} error_kind={:?}",
                    id.get(),
                    write_error.kind()
                );
            }
            return;
        }
    };
    let ShellAttachment {
        master,
        output,
        session_id,
        runtime_id,
        first,
    } = attachment;
    let _attachment_lease = TerminalAttachmentLease {
        manager: &manager,
        shell_id: id,
        runtime_id,
    };
    // Subscribe before replying: the replay plus queued chunks are then exactly the PTY stream.
    let overflow_shutdown = stream.try_clone().ok().map(OwnedFd::from);
    let (replay, subscriber) = output.subscribe(overflow_shutdown);
    let subscription = OutputSubscription(subscriber);
    drop(output);
    if first {
        manager.publish_shell_activity(session_id, id, ShellActivity::Attached);
    }

    let response = attach::write_acceptance(&mut stream, replay.len(), &master)
        .map_err(|(phase, error)| (phase.as_str(), error))
        .and_then(|()| stream.write_all(&replay).map_err(|error| ("replay", error)))
        .and_then(|()| {
            stream
                .set_write_timeout(Some(ATTACH_LIVE_WRITE_TIMEOUT))
                .map_err(|error| ("live_timeout", error))
        });
    drop(master);
    if let Err((phase, error)) = response {
        log::warn!(
            "event=session.attach_failed session_id={} shell_id={} phase={} replay_bytes={} elapsed_ms={} error_kind={:?}",
            session_id.get(),
            id.get(),
            phase,
            replay.len(),
            started_at.elapsed().as_millis(),
            error.kind()
        );
        return;
    }
    log::info!(
        "event=session.attach_ready session_id={} shell_id={} replay_bytes={} elapsed_ms={}",
        session_id.get(),
        id.get(),
        replay.len(),
        started_at.elapsed().as_millis()
    );
    drop(replay);

    let mut delivered = 0_u64;
    let reason = 'stream: loop {
        if manager.stop_workers.load(Ordering::Relaxed) {
            break "shutdown";
        }
        match subscription.0.next(ATTACH_STOP_POLL_INTERVAL) {
            NextOutput::Chunks(chunks) => {
                for chunk in chunks {
                    if stream.write_all(&chunk).is_err() {
                        break 'stream "client_write_failed";
                    }
                    delivered = delivered.saturating_add(chunk.len() as u64);
                }
            }
            NextOutput::Idle => {
                if attach::peer_closed(&mut stream) {
                    break "client_closed";
                }
            }
            NextOutput::Ended => break "shell_output_ended",
            NextOutput::Overflowed => break "client_overflowed",
            NextOutput::Detached => break "detached",
        }
    };
    let _ = stream.shutdown(std::net::Shutdown::Both);
    let level = if reason == "client_overflowed" {
        log::Level::Warn
    } else {
        log::Level::Info
    };
    log::log!(
        level,
        "event=session.attach_ended session_id={} shell_id={} reason={} bytes={} elapsed_ms={}",
        session_id.get(),
        id.get(),
        reason,
        delivered,
        started_at.elapsed().as_millis()
    );
}

/// A queued event shared by every subscriber that received it; serializes as the event.
struct SharedEvent(Arc<Event>);

impl Serialize for SharedEvent {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(serializer)
    }
}

/// `InvalidInput` errors are the caller's fault: answered as invalid params with `message`, or
/// with the error's own text. Anything else is internal.
fn invalid_input_or_internal(error: io::Error, message: Option<&str>) -> RpcError {
    if error.kind() == io::ErrorKind::InvalidInput {
        invalid_params(message.unwrap_or(&error.to_string()))
    } else {
        internal_rpc_error(error)
    }
}

fn invalid_params(message: &str) -> RpcError {
    RpcError {
        code: ErrorCode::InvalidParams,
        message: message.to_owned(),
        data: None,
    }
}

fn internal_rpc_error(error: io::Error) -> RpcError {
    RpcError {
        code: ErrorCode::InternalError,
        message: error.to_string(),
        data: None,
    }
}

fn automatic_pi_restart_rpc_error(
    session_id: SessionId,
    shell_id: ShellId,
    error: io::Error,
) -> RpcError {
    log::debug!(
        "event=session.pi_auto_restart_deferred session_id={} shell_id={} error_kind={:?}",
        session_id.get(),
        shell_id.get(),
        error.kind()
    );
    RpcError {
        code: ErrorCode::InternalError,
        message: "Automatic Pi restart is waiting for a safe opportunity; the existing process was not force-stopped."
            .to_owned(),
        data: None,
    }
}

fn pi_restart_rpc_error(session_id: SessionId, shell_id: ShellId, error: io::Error) -> RpcError {
    log::error!(
        "event=session.pi_restart_failed session_id={} shell_id={} error_kind={:?}",
        session_id.get(),
        shell_id.get(),
        error.kind()
    );
    let message = match error.kind() {
        io::ErrorKind::ConnectionRefused => {
            "The previous Pi process is not accepting control connections. Its transcript was left untouched."
        }
        io::ErrorKind::PermissionDenied => {
            "Axo could not verify the previous Pi process for this pane, so it was not terminated."
        }
        io::ErrorKind::WouldBlock => {
            "Axo could not establish safe control of the previous Pi process, so it was not terminated."
        }
        io::ErrorKind::TimedOut => {
            "Axo could not acquire the Pi conversation lock after stopping the pane's process. Its history was left untouched."
        }
        io::ErrorKind::NotFound => "This Pi pane is no longer available to restart.",
        _ => "Axo could not restart this Pi session. Its conversation history was preserved.",
    };
    RpcError {
        code: ErrorCode::InternalError,
        message: message.to_owned(),
        data: None,
    }
}

fn decode_base64(input: &str) -> io::Result<Vec<u8>> {
    let (chunks, trailing_bytes) = input.as_bytes().as_chunks::<4>();
    if input.is_empty() || input.len() > 65_536 || !trailing_bytes.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "terminal input is not bounded, padded base64",
        ));
    }
    let mut decoded = Vec::with_capacity(input.len() / 4 * 3);
    let chunk_count = chunks.len();
    for (index, chunk) in chunks.iter().enumerate() {
        let a = base64_value(chunk[0])?;
        let b = base64_value(chunk[1])?;
        let last = index + 1 == chunk_count;
        let c = if chunk[2] == b'=' && last {
            None
        } else {
            Some(base64_value(chunk[2])?)
        };
        let d = if chunk[3] == b'=' && last {
            None
        } else {
            Some(base64_value(chunk[3])?)
        };
        if c.is_none() && d.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid base64 padding",
            ));
        }
        if (c.is_none() && b & 0x0f != 0)
            || (d.is_none() && c.is_some_and(|value| value & 0x03 != 0))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "non-canonical base64 padding bits",
            ));
        }
        let value = ((a as u32) << 18)
            | ((b as u32) << 12)
            | ((c.unwrap_or(0) as u32) << 6)
            | d.unwrap_or(0) as u32;
        decoded.push((value >> 16) as u8);
        if c.is_some() {
            decoded.push((value >> 8) as u8);
        }
        if d.is_some() {
            decoded.push(value as u8);
        }
    }
    Ok(decoded)
}

fn base64_value(byte: u8) -> io::Result<u8> {
    match byte {
        b'A'..=b'Z' => Ok(byte - b'A'),
        b'a'..=b'z' => Ok(byte - b'a' + 26),
        b'0'..=b'9' => Ok(byte - b'0' + 52),
        b'+' => Ok(62),
        b'/' => Ok(63),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid base64 input",
        )),
    }
}

fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let a = chunk[0] as u32;
        let b = chunk.get(1).copied().unwrap_or(0) as u32;
        let c = chunk.get(2).copied().unwrap_or(0) as u32;
        let value = (a << 16) | (b << 8) | c;
        encoded.push(TABLE[((value >> 18) & 63) as usize] as char);
        encoded.push(TABLE[((value >> 12) & 63) as usize] as char);
        encoded.push(if chunk.len() > 1 {
            TABLE[((value >> 6) & 63) as usize] as char
        } else {
            '='
        });
        encoded.push(if chunk.len() > 2 {
            TABLE[(value & 63) as usize] as char
        } else {
            '='
        });
    }
    encoded
}

/// What a Pi event changes in the catalog, parsed from its name and payload once. Invalid
/// titles and emoji are dropped here, so the catalog only ever stores valid ones. Every Pi event
/// is still forwarded to clients as is; this is only the part axod acts on.
#[derive(Debug, Eq, PartialEq)]
enum PiCatalogEvent<'a> {
    AgentStarted,
    AgentSettled,
    PromptStarted,
    PromptEnded,
    /// Pi named its session (`session.info`).
    Named {
        title: &'a str,
    },
    /// The Axo extension described the session; at least one field is set.
    Described {
        title: Option<&'a str>,
        emoji: Option<&'a str>,
    },
    /// Not a catalog change, or a payload with nothing valid in it.
    Ignored,
}

impl<'a> PiCatalogEvent<'a> {
    fn parse(name: &str, data: &'a Value) -> Self {
        let field =
            |key: &str, valid: fn(&str) -> bool| data[key].as_str().filter(|value| valid(value));
        match name {
            "agent.start" => PiCatalogEvent::AgentStarted,
            "agent.settled" => PiCatalogEvent::AgentSettled,
            "ui.prompt.start" => PiCatalogEvent::PromptStarted,
            "ui.prompt.end" => PiCatalogEvent::PromptEnded,
            "session.info" => match field("name", valid_session_title) {
                Some(title) => PiCatalogEvent::Named { title },
                None => PiCatalogEvent::Ignored,
            },
            "axo.session.metadata" => {
                match (
                    field("title", valid_session_title),
                    field("emoji", valid_session_emoji),
                ) {
                    (None, None) => PiCatalogEvent::Ignored,
                    (title, emoji) => PiCatalogEvent::Described { title, emoji },
                }
            }
            _ => PiCatalogEvent::Ignored,
        }
    }
}

/// The RPC error for a recovery that could not be reserved.
fn recovery_refused(refused: RecoveryRefused) -> io::Error {
    match refused {
        RecoveryRefused::NotUnavailable => io::Error::new(
            io::ErrorKind::NotFound,
            "the requested Pi pane is not unavailable",
        ),
        RecoveryRefused::AlreadyRecovering => io::Error::new(
            io::ErrorKind::WouldBlock,
            "Pi recovery is already in progress",
        ),
    }
}

/// The `state` column of a Session, shell or Workspace row. Parsed when read, so a corrupt or
/// unknown state fails the query instead of being compared as a string downstream.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StoredLifecycle {
    Open,
    Archived,
}

impl rusqlite::types::FromSql for StoredLifecycle {
    fn column_result(value: rusqlite::types::ValueRef<'_>) -> rusqlite::types::FromSqlResult<Self> {
        match value.as_str()? {
            "open" => Ok(StoredLifecycle::Open),
            "archived" => Ok(StoredLifecycle::Archived),
            other => Err(rusqlite::types::FromSqlError::Other(
                format!("unknown lifecycle state {other:?}").into(),
            )),
        }
    }
}

/// Catalog IDs come from `AUTOINCREMENT` columns, so a stored ID is positive unless the database
/// is corrupt; reading one that is not fails instead of producing an invalid ID.
fn stored_session_id(value: i64) -> rusqlite::Result<SessionId> {
    SessionId::new(value).ok_or(rusqlite::Error::IntegralValueOutOfRange(0, value))
}

fn stored_shell_id(value: i64) -> rusqlite::Result<ShellId> {
    ShellId::new(value).ok_or(rusqlite::Error::IntegralValueOutOfRange(0, value))
}

fn inserted_session_id(database: &Connection) -> io::Result<SessionId> {
    stored_session_id(database.last_insert_rowid()).map_err(io::Error::other)
}

fn inserted_shell_id(database: &Connection) -> io::Result<ShellId> {
    stored_shell_id(database.last_insert_rowid()).map_err(io::Error::other)
}

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use axo_pi::bridge;
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
