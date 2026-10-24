use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::fs;
use std::fs::OpenOptions;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::process_inspection;
use crate::workspace_access::WorkspaceDirectoryAccess;
use axo_ipc::{BlockingMethods, EventQueue, PushOutcome};
use axo_pty::process::{self, PtyProcess};
use axo_pty::{
    NextOutput, OutputSubscriber, TerminalOutput, TerminalOutputSink, WindowSize, attach,
};
use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler, Params};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const DATABASE_FILE: &str = "axo.db";
const ATTACH_SOCKET_FILE: &str = "attach.sock";
const REAPER_INTERVAL: Duration = Duration::from_millis(100);
const MAX_LAYOUT_DEPTH: usize = 64;
const MAX_LAYOUT_NODES: usize = 255;
const MAX_SUBSCRIPTIONS: usize = 64;
const MAX_QUEUED_EVENTS_PER_SUBSCRIPTION: usize = 128;
const SUBSCRIPTION_IDLE_EXPIRY: Duration = Duration::from_secs(60);
const MAX_EVENTS_PER_POLL: usize = 256;
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
const MAX_COMMAND_LINE_BYTES: usize = 4096;
const MAX_COMMAND_ARGUMENTS: usize = 128;
const PI_TAKEOVER_TIMEOUT: Duration = Duration::from_secs(10);
const PI_BRIDGE_REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const PI_OWNER_INSPECTION_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_PI_LOCK_OWNERS: usize = 32;
const PI_RECOVERY_POLL_INTERVAL: Duration = Duration::from_millis(100);
const PI_RESTART_GRACE_PERIOD: Duration = Duration::from_secs(2);
const PI_TERMINATE_GRACE_PERIOD: Duration = Duration::from_secs(2);
const PI_KILL_WAIT: Duration = Duration::from_secs(5);
const MAX_PI_BRIDGE_RECORD_BYTES: usize = 8 * 1024 * 1024;
const MAX_PI_BRIDGE_SOCKET_PATH_BYTES: usize = 100;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct SessionId(pub(crate) i64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct ShellId(pub(crate) i64);

// A pane survives restarts; its runtime identity does not. Async callbacks must
// carry this identity rather than applying to whichever process now owns a pane.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RuntimeId(u64);

impl RuntimeId {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Self(
            NEXT.try_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
                .expect("runtime identity space exhausted"),
        )
    }
}

#[derive(Clone, Copy, Debug)]
struct PiRuntimeBinding {
    session_id: SessionId,
    shell_id: ShellId,
    runtime_id: RuntimeId,
}

impl PiRuntimeBinding {
    fn is_current(self, state: &SessionState) -> bool {
        state.running.get(&self.shell_id).is_some_and(|shell| {
            shell.session_id == self.session_id
                && shell.role == PaneRole::Pi
                && shell.runtime_id == self.runtime_id
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PiBridgeSocketPath(PathBuf);

impl PiBridgeSocketPath {
    fn parse(path: PathBuf) -> io::Result<Self> {
        let bytes = path.as_os_str().as_encoded_bytes();
        if !path.is_absolute()
            || bytes.len() > MAX_PI_BRIDGE_SOCKET_PATH_BYTES
            || bytes.contains(&0)
            || path.to_str().is_none()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi bridge socket path must be absolute UTF-8 within the supported byte limit",
            ));
        }
        Ok(Self(path))
    }

    fn for_session(pi_session_directory: &Path, session_uuid: &str) -> io::Result<Self> {
        if !is_uuid_string(session_uuid) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi session UUID is invalid",
            ));
        }
        let scoped = pi_session_directory.join(format!("{session_uuid}.sock"));
        if let Ok(path) = Self::parse(scoped) {
            return Ok(path);
        }
        Self::parse(PathBuf::from("/tmp").join(format!("axo-pi-{session_uuid}.sock")))
    }

    fn as_path(&self) -> &Path {
        &self.0
    }

    fn database_value(&self) -> &str {
        self.0
            .to_str()
            .expect("validated Pi bridge socket paths are UTF-8")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct VerifiedPiProcessId(libc::pid_t);

impl VerifiedPiProcessId {
    fn parse(value: &Value) -> io::Result<Self> {
        let Some(pid) = value.as_u64() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi bridge process ID is invalid",
            ));
        };
        if pid <= 1 || pid > libc::pid_t::MAX as u64 || pid == u64::from(std::process::id()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi bridge process ID is outside the permitted range",
            ));
        }
        Ok(Self(pid as libc::pid_t))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PiTakeoverPolicy {
    PreserveExistingProcess,
    ExplicitUserRestart,
}

// Keep the authenticated PID even if Pi rejects or misses the graceful-shutdown response.
// An explicit user restart may still terminate only this verified process group.
struct PiShutdownAttempt {
    process_id: VerifiedPiProcessId,
    graceful_shutdown: io::Result<()>,
}

#[derive(Clone, Debug)]
struct PiLockOwner {
    process_id: libc::pid_t,
    user_id: libc::uid_t,
    process_group_id: libc::pid_t,
    command: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum SessionLayout {
    Pane {
        shell_id: i64,
    },
    Split {
        id: String,
        direction: LayoutDirection,
        ratio: f64,
        first: Box<SessionLayout>,
        second: Box<SessionLayout>,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum LayoutDirection {
    Right,
    Down,
}

impl SessionLayout {
    fn shell_ids(&self) -> io::Result<HashSet<ShellId>> {
        let mut shell_ids = HashSet::new();
        let mut split_ids = HashSet::new();
        let mut node_count = 0;
        self.collect_shell_ids(0, &mut node_count, &mut shell_ids, &mut split_ids)?;
        Ok(shell_ids)
    }

    fn pruned_to(&self, open_shell_ids: &HashSet<ShellId>) -> Option<Self> {
        match self {
            Self::Pane { shell_id } => open_shell_ids
                .contains(&ShellId(*shell_id))
                .then(|| self.clone()),
            Self::Split {
                id,
                direction,
                ratio,
                first,
                second,
            } => match (
                first.pruned_to(open_shell_ids),
                second.pruned_to(open_shell_ids),
            ) {
                (None, None) => None,
                (Some(remaining), None) | (None, Some(remaining)) => Some(remaining),
                (Some(first), Some(second)) => Some(Self::Split {
                    id: id.clone(),
                    direction: *direction,
                    ratio: *ratio,
                    first: Box::new(first),
                    second: Box::new(second),
                }),
            },
        }
    }

    fn collect_shell_ids(
        &self,
        depth: usize,
        node_count: &mut usize,
        shell_ids: &mut HashSet<ShellId>,
        split_ids: &mut HashSet<String>,
    ) -> io::Result<()> {
        *node_count += 1;
        if depth > MAX_LAYOUT_DEPTH || *node_count > MAX_LAYOUT_NODES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "session layout exceeds its structural limits",
            ));
        }

        match self {
            Self::Pane { shell_id } => {
                if *shell_id <= 0 || !shell_ids.insert(ShellId(*shell_id)) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "session layout contains an invalid or duplicate shell ID",
                    ));
                }
            }
            Self::Split {
                id,
                ratio,
                first,
                second,
                ..
            } => {
                if !is_uuid_string(id) || !split_ids.insert(id.clone()) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "session layout contains an invalid or duplicate split ID",
                    ));
                }
                if !ratio.is_finite() || !(0.01..=0.99).contains(ratio) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "session layout split ratio must be between 0.01 and 0.99",
                    ));
                }
                first.collect_shell_ids(depth + 1, node_count, shell_ids, split_ids)?;
                second.collect_shell_ids(depth + 1, node_count, shell_ids, split_ids)?;
            }
        }
        Ok(())
    }
}

fn is_uuid_string(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SetSessionLayoutRequest {
    session_id: i64,
    layout: SessionLayout,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RestartPiSessionRequest {
    session_id: i64,
    shell_id: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionRenameRequest {
    session_id: i64,
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceRenameRequest {
    workspace_id: String,
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceArchiveRequest {
    workspace_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceCreateRequest {
    name: String,
    directory_path: PathBuf,
    directory_bookmark: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceSessionCreateRequest {
    workspace_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConfigGetRequest {
    key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConfigSetRequest {
    key: String,
    value: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionSubscribeRequest {
    session_id: Option<i64>,
    /// Catalog clients pass `false`; terminal bytes would otherwise dominate their queue.
    #[serde(default = "default_true")]
    include_terminal_output: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionEventsNextRequest {
    subscription_id: String,
    timeout_ms: u64,
    max_events: Option<usize>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionUnsubscribeRequest {
    subscription_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalInputRequest {
    session_id: i64,
    shell_id: i64,
    sequence: u64,
    data: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TerminalResizeRequest {
    session_id: i64,
    shell_id: i64,
    rows: u32,
    columns: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShellBusyRequest {
    session_id: i64,
    shell_id: i64,
}

/// Whether closing a shell would interrupt work: a foreground job other than the shell itself
/// (terminal panes) or a Pi turn in progress (Pi panes).
#[derive(Debug, Eq, PartialEq)]
struct ShellBusy {
    busy: bool,
    /// Name of the foreground process when it is not the shell; never authoritative.
    foreground_process: Option<String>,
}

#[derive(Debug)]
struct SessionRecord {
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
    _writer_lock: Option<OwnedFd>,
    pi_bridge_socket: Option<PiBridgeSocketPath>,
    pi_bridge_token: Option<String>,
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
    running: HashMap<ShellId, RunningShell>,
    unavailable_pi_shells: HashMap<ShellId, UnavailablePiShell>,
    shutting_down: bool,
    pi_activity: HashMap<SessionId, PiRuntimeActivity>,
    initial_pwd: PathBuf,
    /// Every shell's output is published here once it enters the catalog.
    events: EventBus,
}

impl SessionState {
    /// The only way a process enters the catalog: binds its output stream to its pane identity
    /// so `terminal.output` events start flowing.
    fn install_running(
        &mut self,
        shell_id: ShellId,
        running: RunningShell,
    ) -> Option<RunningShell> {
        let session_id = running.session_id;
        running.output.bind(
            format!("session_id={} shell_id={}", session_id.0, shell_id.0),
            Arc::new(ShellOutputSink {
                events: self.events.clone(),
                session_id,
                shell_id,
            }),
        );
        self.running.insert(shell_id, running)
    }
}

#[derive(Debug)]
struct UnavailablePiShell {
    session_id: SessionId,
    pane_id: Option<String>,
    initial_pwd: PathBuf,
    recovery_id: Option<RuntimeId>,
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
                .unavailable_pi_shells
                .get(&self.shell_id)
                .is_some_and(|shell| {
                    shell.session_id == self.session_id
                        && shell.recovery_id == Some(self.recovery_id)
                })
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

    fn signal_current(
        &self,
        process_id: VerifiedPiProcessId,
        signal: libc::c_int,
    ) -> io::Result<()> {
        let state = self.manager.lock_state()?;
        self.check_state(&state)?;
        // Only these short syscalls run under the catalog mutex. Cancellation
        // and signal dispatch are ordered, with no socket/child waits here.
        signal_verified_pi_process(process_id, signal)
    }
}

impl Drop for PiRecoveryLease<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.manager.state.lock()
            && let Some(shell) = state.unavailable_pi_shells.get_mut(&self.shell_id)
            && shell.recovery_id == Some(self.recovery_id)
        {
            shell.recovery_id = None;
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
struct PiHistoryIdentity {
    device: u64,
    inode: u64,
}

// Owned launch inputs: waiting/exec must not borrow the catalog or its database.
struct PiLaunchRequest {
    agent_command: AgentCommand,
    session_id: SessionId,
    initial_pwd: PathBuf,
    session_file: PathBuf,
    bridge_socket: PiBridgeSocketPath,
    session_uuid: String,
    pane_id: String,
    previous_token: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CommandLine {
    source: String,
    executable: String,
    arguments: Vec<String>,
}

impl CommandLine {
    fn parse(source: &str) -> io::Result<Self> {
        let source = source.trim();
        if source.is_empty()
            || source.len() > MAX_COMMAND_LINE_BYTES
            || source.chars().any(char::is_control)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "command must be nonempty, control-free, and at most 4096 bytes",
            ));
        }

        let arguments = shlex::split(source).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "command contains unmatched shell-style quotes",
            )
        })?;
        if arguments.is_empty()
            || arguments.len().saturating_sub(1) > MAX_COMMAND_ARGUMENTS
            || arguments[0].is_empty()
            || arguments.iter().any(|argument| argument.contains('\0'))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "command must have an executable and no more than 128 arguments",
            ));
        }

        let executable = arguments[0].clone();
        if executable.contains('/') && !Path::new(&executable).is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "executable paths must be absolute; bare command names are resolved on axod's PATH",
            ));
        }

        Ok(Self {
            source: source.to_owned(),
            executable,
            arguments: arguments.into_iter().skip(1).collect(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AgentCommand(CommandLine);

impl AgentCommand {
    fn parse(source: &str) -> io::Result<Self> {
        let command = CommandLine::parse(source)?;
        if command.arguments.iter().any(|argument| {
            let name = argument
                .split_once('=')
                .map_or(argument.as_str(), |(name, _)| name);
            matches!(
                name,
                "--" | "-c"
                    | "-p"
                    | "-r"
                    | "--continue"
                    | "--fork"
                    | "--mode"
                    | "--no-extensions"
                    | "--no-session"
                    | "--print"
                    | "--resume"
                    | "--rpc"
                    | "--session"
                    | "--session-dir"
                    | "--session-id"
            )
        }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "agent command cannot override Axo's managed Pi session or interactive mode",
            ));
        }
        Ok(Self(command))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ShellCommand(CommandLine);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConfigKey {
    AgentCommand,
    ShellCommand,
}

impl ConfigKey {
    fn parse(value: &str) -> io::Result<Self> {
        match value {
            "agent.command" => Ok(Self::AgentCommand),
            "shell.command" => Ok(Self::ShellCommand),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("unknown configuration key {value:?}"),
            )),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::AgentCommand => "agent.command",
            Self::ShellCommand => "shell.command",
        }
    }

    fn metadata_key(self) -> &'static str {
        match self {
            Self::AgentCommand => "agent_command",
            Self::ShellCommand => "shell_command",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ConfigValue {
    key: ConfigKey,
    value: String,
}

enum ParsedConfigValue {
    AgentCommand(AgentCommand),
    ShellCommand(ShellCommand),
}

impl ConfigValue {
    fn to_json(&self) -> Value {
        json!({ "key": self.key.as_str(), "value": self.value })
    }
}

impl ShellCommand {
    fn parse(source: &str) -> io::Result<Self> {
        CommandLine::parse(source).map(Self)
    }
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
enum SessionStatus {
    Starting,
    Ready,
    Working,
    NeedsAttention,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Default)]
struct PiRuntimeActivity {
    connected: bool,
    working: bool,
    ui_waits: u16,
}

impl PiRuntimeActivity {
    fn status(self) -> SessionStatus {
        if !self.connected {
            SessionStatus::Unavailable
        } else if self.ui_waits > 0 {
            SessionStatus::NeedsAttention
        } else if self.working {
            SessionStatus::Working
        } else {
            SessionStatus::Ready
        }
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

impl axo_relay::RelayHost for RelayHostAdapter {
    fn host_id(&self) -> &str {
        &self.0.host_id
    }

    fn host_generation(&self) -> &str {
        &self.0.host_generation
    }

    fn remote_session_snapshots(&self, updated_at: &str) -> io::Result<Vec<Value>> {
        let sessions = self.0.list_sessions()?;
        if sessions.len() > 256 || sessions.iter().any(|session| session.shells.len() > 256) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "host session snapshot exceeds the protocol limit",
            ));
        }
        Ok(sessions
            .iter()
            .map(|session| session.to_remote_json(&self.0.host_id, updated_at))
            .collect())
    }

    fn subscribe_remote_events(&self) -> io::Result<String> {
        self.0.subscribe(None, true)
    }

    fn next_remote_event(
        &self,
        subscription_id: &str,
        timeout: Duration,
    ) -> io::Result<Option<Value>> {
        self.0.next_event(subscription_id, timeout)
    }

    /// Current snapshots, as local events, for resynchronizing a lagged remote stream.
    fn remote_resync_events(&self) -> io::Result<Vec<Value>> {
        Ok(self
            .0
            .list_sessions()?
            .iter()
            .map(|session| json!({ "type": "session.snapshot", "session": session.to_json() }))
            .collect())
    }

    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()> {
        self.0.unsubscribe(subscription_id)
    }

    fn remote_create_session(&self, updated_at: &str) -> io::Result<Value> {
        let session = self.0.create_session()?;
        self.0
            .publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        Ok(session.to_remote_json(&self.0.host_id, updated_at))
    }

    fn remote_create_workspace_session(
        &self,
        workspace_id: &str,
        updated_at: &str,
    ) -> io::Result<Value> {
        let session = self.0.create_session_in_workspace(workspace_id)?;
        Ok(session.to_remote_json(&self.0.host_id, updated_at))
    }

    fn remote_close_session(&self, session_id: i64, updated_at: &str) -> io::Result<Option<Value>> {
        if session_id <= 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "session ID must be positive",
            ));
        }
        let session_id = SessionId(session_id);
        let replacement = self.0.close_session(session_id)?;
        self.0.publish_session_removed(session_id);
        if let Some(session) = &replacement {
            self.0
                .publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        }
        Ok(replacement.map(|session| session.to_remote_json(&self.0.host_id, updated_at)))
    }

    fn remote_create_shell(&self, session_id: i64) -> io::Result<i64> {
        let session_id = SessionId(session_id);
        let shell = self.0.create_shell(session_id)?;
        self.0.publish_session_snapshot(session_id)?;
        self.0
            .publish_shell_activity(session_id, shell.id, "started");
        Ok(shell.id.0)
    }

    fn remote_close_shell(&self, session_id: i64, shell_id: i64) -> io::Result<()> {
        let (session_id, shell_id) = parse_session_shell_ids(session_id, shell_id)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid shell identity"))?;
        let closed = self.0.close_shell(session_id, shell_id)?;
        if closed.archived_session_id.is_some() {
            self.0.publish_session_removed(session_id);
            if let Some(replacement) = &closed.replacement {
                self.0.publish_event(
                    json!({ "type": "session.snapshot", "session": replacement.to_json() }),
                );
            }
        } else {
            self.0.publish_session_snapshot(session_id)?;
        }
        self.0
            .publish_shell_activity(session_id, shell_id, "exited");
        Ok(())
    }

    fn remote_set_layout(&self, session_id: i64, layout: Value) -> io::Result<()> {
        let session_id = SessionId(session_id);
        let layout: SessionLayout = serde_json::from_value(layout)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid session layout"))?;
        layout.shell_ids()?;
        self.0.set_layout(session_id, layout)?;
        self.0.publish_session_snapshot(session_id)
    }

    fn remote_terminal_input(
        &self,
        session_id: i64,
        shell_id: i64,
        sequence: u64,
        data: &str,
    ) -> io::Result<()> {
        let (session_id, shell_id) = parse_session_shell_ids(session_id, shell_id)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid shell identity"))?;
        self.0
            .write_terminal_input(session_id, shell_id, sequence, data)
    }

    fn remote_terminal_resize(
        &self,
        session_id: i64,
        shell_id: i64,
        rows: u32,
        columns: u32,
    ) -> io::Result<()> {
        let (session_id, shell_id) = parse_session_shell_ids(session_id, shell_id)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid shell identity"))?;
        let size = WindowSize::new(rows, columns).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal dimensions are outside the supported range",
            )
        })?;
        self.0.resize_terminal(session_id, shell_id, size)
    }

    fn publish_relay_status(&self, status: &axo_relay::RelayStatus) {
        self.0
            .publish_event(json!({ "type": "relay.status", "status": status }));
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
    fn publish(&self, event: Value) -> usize {
        let event_type = event["type"].as_str().unwrap_or_default();
        let session_id = event.get("sessionId").and_then(Value::as_i64).or_else(|| {
            event
                .get("session")
                .and_then(|session| session["id"].as_i64())
        });
        let Ok(mut subscribers) = self.lock() else {
            return 0;
        };
        let mut delivered = 0;
        subscribers.retain(|subscriber| {
            if !subscriber.wants(event_type, session_id) {
                return true;
            }
            match subscriber.queue.push(event.clone()) {
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
                .any(|subscriber| subscriber.wants("terminal.output", Some(session_id.0)))
        });
        if !wanted {
            return;
        }
        self.events.publish(json!({
            "type": "terminal.output",
            "sessionId": session_id.0,
            "shellId": shell_id.0,
            "sequence": sequence,
            "data": encode_base64(output),
        }));
    }
}

struct LocalSubscriber {
    id: String,
    session_id: Option<SessionId>,
    scope: EventScope,
    queue: Arc<EventQueue<Value>>,
}

impl LocalSubscriber {
    fn wants(&self, event_type: &str, session_id: Option<i64>) -> bool {
        self.session_id
            .is_none_or(|expected| session_id == Some(expected.0))
            && self.scope.accepts(event_type)
    }
}

/// Which events a subscription carries. High-volume stream events (`terminal.output`, `pi.event`)
/// go only to `Streams` subscribers, so catalog consumers never pay for, or lag on, Pi token
/// streams or terminal bytes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EventScope {
    Catalog,
    Streams,
}

impl EventScope {
    fn from_include_streams(include_streams: bool) -> Self {
        if include_streams {
            Self::Streams
        } else {
            Self::Catalog
        }
    }

    fn accepts(self, event_type: &str) -> bool {
        match self {
            Self::Streams => true,
            Self::Catalog => !matches!(event_type, "terminal.output" | "pi.event"),
        }
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
    queue: Arc<EventQueue<Value>>,
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

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum PaneRole {
    Pi,
    Terminal,
}

#[derive(Debug)]
struct ShellMetadata {
    id: ShellId,
    pane_id: Option<String>,
    role: PaneRole,
    process_id: u32,
    initial_pwd: PathBuf,
    slave_device: String,
    attach_socket_path: PathBuf,
    available: bool,
    availability_reason: Option<&'static str>,
}

impl ShellMetadata {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id.0,
            "paneId": self.pane_id,
            "role": self.role,
            "processId": self.process_id,
            "initialPwd": self.initial_pwd,
            "ptyDevice": self.slave_device,
            "attachSocketPath": self.attach_socket_path,
            "available": self.available,
            "availabilityReason": self.availability_reason,
        })
    }
}

#[derive(Debug)]
struct SessionMetadata {
    id: SessionId,
    session_uuid: String,
    pi_session_file: Option<PathBuf>,
    pi_session_id: Option<String>,
    workspace_id: Option<String>,
    workspace_name: Option<String>,
    name: String,
    manual_name: Option<String>,
    emoji: Option<String>,
    status: SessionStatus,
    initial_pwd: PathBuf,
    shells: Vec<ShellMetadata>,
    layout: Option<SessionLayout>,
}

impl SessionMetadata {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id.0,
            "sessionUuid": self.session_uuid,
            "piSessionFile": self.pi_session_file,
            "piSessionId": self.pi_session_id,
            "workspaceId": self.workspace_id,
            "workspaceName": self.workspace_name,
            "name": self.name,
            "manualName": self.manual_name,
            "emoji": self.emoji,
            "status": self.status,
            "initialPwd": self.initial_pwd,
            "shells": self.shells.iter().map(ShellMetadata::to_json).collect::<Vec<_>>(),
            "layout": self.layout,
        })
    }

    fn to_remote_json(&self, host_id: &str, updated_at: &str) -> Value {
        let terminal_shell_ids: HashSet<_> = self
            .shells
            .iter()
            .filter(|shell| shell.role == PaneRole::Terminal)
            .map(|shell| ShellId(shell.id.0))
            .collect();
        let terminal_layout = self
            .layout
            .as_ref()
            .and_then(|layout| layout.pruned_to(&terminal_shell_ids));
        json!({
            "hostId": host_id,
            "sessionId": self.id.0,
            "sessionUuid": self.session_uuid,
            "workspaceId": self.workspace_id,
            "workspaceName": self.workspace_name,
            "name": self.name,
            "emoji": self.emoji,
            "status": self.status,
            "hasAgent": self.shells.iter().any(|shell| shell.role == PaneRole::Pi),
            "shells": self.shells.iter()
                .filter(|shell| shell.role == PaneRole::Terminal)
                .map(|shell| json!({ "shellId": shell.id.0 })).collect::<Vec<_>>(),
            "layout": terminal_layout,
            "updatedAt": updated_at,
        })
    }
}

#[derive(Debug)]
struct ClosedShellMetadata {
    archived_shell_id: ShellId,
    archived_session_id: Option<SessionId>,
    replacement: Option<SessionMetadata>,
}

impl ClosedShellMetadata {
    fn to_json(&self) -> Value {
        json!({
            "archivedShellId": self.archived_shell_id.0,
            "archivedSessionId": self.archived_session_id.map(|id| id.0),
            "replacement": self.replacement.as_ref().map(SessionMetadata::to_json),
        })
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
        let host_generation = create_uuid_v4()?;
        fs::set_permissions(&database_path, fs::Permissions::from_mode(0o600))?;
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory)?;
        fs::set_permissions(&pi_session_directory, fs::Permissions::from_mode(0o700))?;
        ensure_pi_bridge_socket_paths(&database, &pi_session_directory)?;

        let workspace_access = restore_workspace_accesses(&database)?;
        let subscribers = EventBus::default();
        let manager = Arc::new(Self {
            state: Mutex::new(SessionState {
                database,
                agent_command,
                shell_command,
                running: HashMap::new(),
                unavailable_pi_shells: HashMap::new(),
                shutting_down: false,
                pi_activity: HashMap::new(),
                initial_pwd,
                events: subscribers.clone(),
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
            log::info!("event=session.default_created session_id={}", session.id.0);
        }
        manager.start_attachment_listener()?;
        manager.start_reaper();
        Ok(manager)
    }

    pub fn register_rpc_methods(self: &Arc<Self>, handler: &mut IoHandler) {
        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.list", move |_| {
            manager
                .list_sessions()
                .and_then(|sessions| {
                    let resume_session_id = manager.take_pending_resume_focus()?;
                    Ok(json!({
                        "sessions": sessions.iter().map(SessionMetadata::to_json).collect::<Vec<_>>(),
                        "resumeSessionId": resume_session_id.map(|id| id.0),
                    }))
                })
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.config.get", move |params: Params| {
            let request: ConfigGetRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {key}"))?;
            manager
                .config_value(&request.key)
                .map(|value| value.to_json())
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params(&error.to_string())
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.config.set", move |params: Params| {
            let request: ConfigSetRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {key, value}"))?;
            manager
                .set_config_value(&request.key, &request.value)
                .map(|value| value.to_json())
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params(&error.to_string())
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.layout.set", move |params: Params| {
            let request: SetSessionLayoutRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, layout}"))?;
            if request.session_id <= 0 {
                return Err(invalid_params("sessionId must be a positive integer"));
            }
            request
                .layout
                .shell_ids()
                .map_err(|_| invalid_params("layout is malformed or exceeds its limits"))?;
            manager
                .set_layout(SessionId(request.session_id), request.layout)
                .and_then(|()| manager.publish_session_snapshot(SessionId(request.session_id)))
                .map(|()| json!({ "saved": true }))
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params("layout must contain each open session shell exactly once")
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.subscribe", move |params: Params| {
            let request: SessionSubscribeRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId?, includeTerminalOutput?}"))?;
            let session_id = request
                .session_id
                .map(|id| {
                    if id <= 0 {
                        Err(invalid_params("sessionId must be a positive integer"))
                    } else {
                        Ok(SessionId(id))
                    }
                })
                .transpose()?;
            manager
                .subscribe(session_id, request.include_terminal_output)
                .map(|subscription_id| json!({ "subscriptionId": subscription_id }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        // Long-polls wait as futures, never on a thread (see `ipc`).
        handler.add_method("axo.session.events.next", move |params: Params| {
            let manager = Arc::clone(&manager);
            async move {
                let request: SessionEventsNextRequest = params.parse().map_err(|_| {
                    invalid_params("expected {subscriptionId, timeoutMs, maxEvents?}")
                })?;
                if request.timeout_ms == 0 || request.timeout_ms > 20_000 {
                    return Err(invalid_params("timeoutMs must be between 1 and 20000"));
                }
                let timeout = Duration::from_millis(request.timeout_ms);
                let max_events = match request.max_events {
                    None => 1,
                    Some(max_events) if (1..=MAX_EVENTS_PER_POLL).contains(&max_events) => {
                        max_events
                    }
                    Some(_) => return Err(invalid_params("maxEvents must be between 1 and 256")),
                };
                let events = manager
                    .next_events_async(&request.subscription_id, timeout, max_events)
                    .await
                    .map_err(internal_rpc_error)?;
                Ok(match request.max_events {
                    None => json!({ "event": events.into_iter().next() }),
                    Some(_) => json!({ "events": events }),
                })
            }
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.unsubscribe", move |params: Params| {
            let request: SessionUnsubscribeRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {subscriptionId}"))?;
            manager
                .unsubscribe(&request.subscription_id)
                .map(|()| json!({ "unsubscribed": true }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.terminal.input", move |params: Params| {
            let request: TerminalInputRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, shellId, sequence, data}"))?;
            let (session_id, shell_id) =
                parse_session_shell_ids(request.session_id, request.shell_id)?;
            manager
                .write_terminal_input(session_id, shell_id, request.sequence, &request.data)
                .map(|()| json!({ "accepted": true, "sequence": request.sequence }))
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params("terminal input is invalid or out of sequence")
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.terminal.resize", move |params: Params| {
            let request: TerminalResizeRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, shellId, rows, columns}"))?;
            let (session_id, shell_id) = parse_session_shell_ids(request.session_id, request.shell_id)?;
            let size = WindowSize::new(request.rows, request.columns)
                .ok_or_else(|| invalid_params("terminal dimensions are invalid"))?;
            manager
                .resize_terminal(session_id, shell_id, size)
                .map(|()| json!({ "accepted": true, "rows": request.rows, "columns": request.columns }))
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params("terminal dimensions are invalid")
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.shell.busy", move |params: Params| {
            let request: ShellBusyRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, shellId}"))?;
            let (session_id, shell_id) =
                parse_session_shell_ids(request.session_id, request.shell_id)?;
            manager
                .shell_busy(session_id, shell_id)
                .map(|busy| {
                    json!({ "busy": busy.busy, "foregroundProcess": busy.foreground_process })
                })
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.workspace.list", move |_| {
            manager
                .list_workspaces()
                .map(|workspaces| json!({ "workspaces": workspaces }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.workspace.rename", move |params: Params| {
            let request: WorkspaceRenameRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {workspaceId, name}"))?;
            manager
                .rename_workspace(&request.workspace_id, &request.name)
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params("Workspace ID or name is invalid")
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.workspace.archive", move |params: Params| {
            let request: WorkspaceArchiveRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {workspaceId}"))?;
            let workspace_id = request.workspace_id;
            manager
                .archive_workspace(&workspace_id)
                .map(|session_ids| {
                    json!({
                        "archivedWorkspaceId": workspace_id,
                        "archivedSessionIds": session_ids.iter().map(|id| id.0).collect::<Vec<_>>(),
                    })
                })
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params("Workspace ID is invalid")
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.workspace.create", move |params: Params| {
            let request: WorkspaceCreateRequest = params
                .parse()
                .map_err(|_| {
                    invalid_params("expected {name, directoryPath, optional directoryBookmark}")
                })?;
            manager
                .create_workspace(request)
                .map_err(|error| match error.kind() {
                    io::ErrorKind::InvalidInput => invalid_params(&error.to_string()),
                    io::ErrorKind::NotFound => {
                        invalid_params("Workspace directory no longer exists or is unavailable")
                    }
                    io::ErrorKind::PermissionDenied => invalid_params(
                        "Axo cannot access the selected folder; choose it again in the folder picker",
                    ),
                    _ => internal_rpc_error(error),
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.workspace.session.create", move |params: Params| {
            let request: WorkspaceSessionCreateRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {workspaceId}"))?;
            manager
                .create_session_in_workspace(&request.workspace_id)
                .map(|session| session.to_json())
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params("Workspace ID is invalid")
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.create", move |_| {
            let session = manager.create_session().map_err(internal_rpc_error)?;
            manager
                .publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
            Ok(session.to_json())
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.close", move |params| {
            let id = parse_session_id(params)?;
            let replacement = manager.close_session(id).map_err(internal_rpc_error)?;
            manager.publish_session_removed(id);
            if let Some(session) = &replacement {
                manager.publish_event(
                    json!({ "type": "session.snapshot", "session": session.to_json() }),
                );
            }
            Ok(json!({
                "archivedSessionId": id.0,
                "replacement": replacement.map(|session| session.to_json()),
            }))
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.rename", move |params: Params| {
            let request: SessionRenameRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, name}"))?;
            if request.session_id <= 0 {
                return Err(invalid_params("sessionId must be a positive integer"));
            }
            manager
                .rename_session(SessionId(request.session_id), &request.name)
                .map(|session| session.to_json())
                .map_err(|error| {
                    if error.kind() == io::ErrorKind::InvalidInput {
                        invalid_params("Session name is invalid")
                    } else {
                        internal_rpc_error(error)
                    }
                })
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.pi.restart.auto.v1", move |params: Params| {
            let request: RestartPiSessionRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, shellId}"))?;
            let (session_id, shell_id) =
                parse_session_shell_ids(request.session_id, request.shell_id)?;
            manager
                .restart_unavailable_pi(
                    session_id,
                    shell_id,
                    PiTakeoverPolicy::PreserveExistingProcess,
                )
                .map(|session| session.to_json())
                .map_err(|error| automatic_pi_restart_rpc_error(session_id, shell_id, error))
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.session.pi.restart.force.v2", move |params: Params| {
            let request: RestartPiSessionRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, shellId}"))?;
            let (session_id, shell_id) =
                parse_session_shell_ids(request.session_id, request.shell_id)?;
            manager
                .restart_unavailable_pi(session_id, shell_id, PiTakeoverPolicy::ExplicitUserRestart)
                .map(|session| session.to_json())
                .map_err(|error| pi_restart_rpc_error(session_id, shell_id, error))
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.shell.create", move |params| {
            let id = parse_session_id(params)?;
            let shell = manager.create_shell(id).map_err(internal_rpc_error)?;
            manager
                .publish_session_snapshot(id)
                .map_err(internal_rpc_error)?;
            manager.publish_shell_activity(id, shell.id, "started");
            Ok(shell.to_json())
        });

        let manager = Arc::clone(self);
        handler.add_blocking_method("axo.shell.close", move |params| {
            let (session_id, shell_id) = parse_shell_ids(params)?;
            let closed = manager
                .close_shell(session_id, shell_id)
                .map_err(internal_rpc_error)?;
            if closed.archived_session_id.is_some() {
                manager.publish_session_removed(session_id);
                if let Some(replacement) = &closed.replacement {
                    manager.publish_event(json!({
                        "type": "session.snapshot",
                        "session": replacement.to_json(),
                    }));
                }
            } else {
                manager
                    .publish_session_snapshot(session_id)
                    .map_err(internal_rpc_error)?;
            }
            manager.publish_shell_activity(session_id, shell_id, "exited");
            Ok(closed.to_json())
        });
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
                if state.running.contains_key(&shell_id)
                    || state.unavailable_pi_shells.contains_key(&shell_id)
                {
                    continue;
                }

                let running = match role {
                    PaneRole::Terminal => Some(spawn_shell(
                        &state.shell_command,
                        record.id,
                        &record.initial_pwd,
                    )?),
                    PaneRole::Pi => {
                        state.unavailable_pi_shells.insert(
                            shell_id,
                            UnavailablePiShell {
                                session_id: record.id,
                                pane_id,
                                initial_pwd: record.initial_pwd.clone(),
                                recovery_id: None,
                            },
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
                PiTakeoverPolicy::PreserveExistingProcess,
            ) {
                log::warn!(
                    "event=session.pi_restore_unavailable session_id={} shell_id={} error_kind={:?}",
                    session_id.0,
                    shell_id.0,
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

    fn list_sessions(&self) -> io::Result<Vec<SessionMetadata>> {
        let state = self.lock_state()?;
        let ids: HashSet<_> = state
            .running
            .values()
            .map(|running| running.session_id)
            .chain(
                state
                    .unavailable_pi_shells
                    .values()
                    .map(|shell| shell.session_id),
            )
            .collect();
        let mut sessions = ids
            .into_iter()
            .map(|id| session_metadata(&state, id, &self.attach_socket_path))
            .collect::<io::Result<Vec<_>>>()?;
        sessions.sort_by_key(|session| session.id.0);
        Ok(sessions)
    }

    fn create_session(&self) -> io::Result<SessionMetadata> {
        let mut state = self.lock_state()?;
        create_session(&mut state, &self.attach_socket_path)
    }

    fn ensure_home_session(&self) -> io::Result<Option<SessionMetadata>> {
        let mut state = self.lock_state()?;
        if open_standalone_session_count(&state.database)? == 0 {
            create_session(&mut state, &self.attach_socket_path).map(Some)
        } else {
            Ok(None)
        }
    }

    fn set_layout(&self, session_id: SessionId, layout: SessionLayout) -> io::Result<()> {
        let shell_ids = layout.shell_ids()?;
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
                params![layout_json, session_id.0],
            )
            .map_err(io::Error::other)?;
        if changed != 1 {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "session record is missing",
            ));
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
        let queue = Arc::new(EventQueue::new(
            MAX_QUEUED_EVENTS_PER_SUBSCRIPTION,
            || json!({ "type": "subscription.lagged" }),
        ));
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
            scope: EventScope::from_include_streams(include_streams),
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
                let snapshot = json!({ "type": "session.snapshot", "session": session.to_json() });
                if queue.push(snapshot) != PushOutcome::Queued {
                    break;
                }
            }
        }
        Ok(subscription_id)
    }

    fn next_event(&self, id: &str, timeout: Duration) -> io::Result<Option<Value>> {
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
    ) -> io::Result<Vec<Value>> {
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
    ) -> io::Result<Vec<Value>> {
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
    fn publish_event(&self, event: Value) -> usize {
        self.subscribers.publish(event)
    }

    /// Remote-access state changed; a catalog event so Settings never polls for it.
    fn publish_workspace_changed(&self, workspace_id: &str) {
        self.publish_event(json!({ "type": "workspace.changed", "workspaceId": workspace_id }));
    }

    fn publish_session_snapshot(&self, session_id: SessionId) -> io::Result<()> {
        let session = {
            let state = self.lock_state()?;
            session_metadata(&state, session_id, &self.attach_socket_path)?
        };
        self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        Ok(())
    }

    fn publish_session_removed(&self, session_id: SessionId) {
        self.publish_event(json!({ "type": "session.removed", "sessionId": session_id.0 }));
    }

    fn publish_shell_activity(&self, session_id: SessionId, shell_id: ShellId, activity: &str) {
        self.publish_event(json!({
            "type": "shell.activity",
            "sessionId": session_id.0,
            "shellId": shell_id.0,
            "activity": activity,
        }));
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
            .running
            .get_mut(&shell_id)
            .filter(|running| running.session_id == session_id)
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
            .running
            .get(&shell_id)
            .filter(|running| running.session_id == session_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        process::resize(&running.master, &running.child, size)
    }

    fn shell_busy(&self, session_id: SessionId, shell_id: ShellId) -> io::Result<ShellBusy> {
        let state = self.lock_state()?;
        let running = state
            .running
            .get(&shell_id)
            .filter(|running| running.session_id == session_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        if running.role == PaneRole::Pi {
            let working = state
                .pi_activity
                .get(&session_id)
                .is_some_and(|activity| activity.working);
            return Ok(ShellBusy {
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
            return Ok(ShellBusy {
                busy: false,
                foreground_process: None,
            });
        }
        Ok(ShellBusy {
            busy: true,
            foreground_process: process_name(foreground),
        })
    }

    fn create_shell(&self, session_id: SessionId) -> io::Result<ShellMetadata> {
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
                .running
                .get(&shell_id)
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi pane is not running"))?;
            let session_uuid: String = state
                .database
                .query_row(
                    "SELECT session_uuid FROM sessions WHERE id = ? AND state = 'open'",
                    params![running.session_id.0],
                    |row| row.get(0),
                )
                .map_err(io::Error::other)?;
            let session_file = state
                .database
                .query_row(
                    "SELECT pi_session_file FROM sessions WHERE id = ?",
                    params![running.session_id.0],
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
        let manager = Arc::downgrade(self);
        let stop = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name(format!("axo-pi-bridge-{}", shell_id.0))
            .spawn(move || {
                run_pi_bridge_worker(
                    manager,
                    stop,
                    PiRuntimeBinding {
                        session_id,
                        shell_id,
                        runtime_id,
                    },
                    PiBridgeWorkerConfig {
                        session_uuid,
                        pane_id,
                        initial_pwd,
                        session_file,
                        bridge_socket,
                        bridge_token,
                        process_id,
                    },
                );
            })?;
        self.workers
            .lock()
            .map_err(|_| io::Error::other("session worker lock was poisoned"))?
            .push(worker);
        Ok(())
    }

    fn list_workspaces(&self) -> io::Result<Vec<Value>> {
        let state = self.lock_state()?;
        let mut statement = state.database.prepare(
            "SELECT workspace_id, name, directory_path FROM workspaces WHERE state = 'open' ORDER BY name, workspace_id",
        ).map_err(io::Error::other)?;
        let rows = statement
            .query_map([], |row| {
                Ok(json!({
                    "workspaceId": row.get::<_, String>(0)?,
                    "name": row.get::<_, String>(1)?,
                    "directoryPath": row.get::<_, String>(2)?,
                }))
            })
            .map_err(io::Error::other)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)
    }

    fn rename_session(&self, session_id: SessionId, name: &str) -> io::Result<SessionMetadata> {
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
                    params![name, session_id.0],
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
        self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        Ok(session)
    }

    fn rename_workspace(&self, workspace_id: &str, name: &str) -> io::Result<Value> {
        if !is_uuid_string(workspace_id) {
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
                    .map(|id| id.map(SessionId))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(io::Error::other)?
            };
            (
                json!({
                    "workspaceId": workspace_id,
                    "name": name,
                    "directoryPath": directory_path,
                }),
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
        if !is_uuid_string(workspace_id) {
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
            self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        }
        Ok(())
    }

    fn create_workspace(self: &Arc<Self>, request: WorkspaceCreateRequest) -> io::Result<Value> {
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
        let workspace_id = create_uuid_v4()?;
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
        let workspace = json!({
            "workspaceId": workspace_id,
            "name": request.name,
            "directoryPath": directory,
            "state": "open",
        });
        self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        self.publish_workspace_changed(&workspace_id);
        Ok(json!({ "workspace": workspace, "session": session.to_json() }))
    }

    fn create_session_in_workspace(
        self: &Arc<Self>,
        workspace_id: &str,
    ) -> io::Result<SessionMetadata> {
        if !is_uuid_string(workspace_id) {
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
        self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        Ok(session)
    }

    fn restart_unavailable_pi(
        self: &Arc<Self>,
        session_id: SessionId,
        shell_id: ShellId,
        takeover_policy: PiTakeoverPolicy,
    ) -> io::Result<SessionMetadata> {
        let (request, recovery) = {
            let mut state = self.lock_state()?;
            if state.shutting_down {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Axod is shutting down",
                ));
            }
            let unavailable = state
                .unavailable_pi_shells
                .get(&shell_id)
                .filter(|shell| shell.session_id == session_id)
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::NotFound,
                        "the requested Pi pane is not unavailable",
                    )
                })?;
            if unavailable.recovery_id.is_some() {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "Pi recovery is already in progress",
                ));
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
                    params![session_id.0],
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
                PiBridgeSocketPath::parse(PathBuf::from(bridge_socket_path.ok_or_else(|| {
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
            };
            let recovery_id = RuntimeId::new();
            state
                .unavailable_pi_shells
                .get_mut(&shell_id)
                .expect("checked pane")
                .recovery_id = Some(recovery_id);
            let recovery = PiRecoveryLease {
                manager: self,
                session_id,
                shell_id,
                recovery_id,
            };
            (request, recovery)
        };

        let check_current = || recovery.ensure_current();
        let history = request.ensure_existing_history(&self.pi_session_directory)?;
        let lock = request.acquire_writer_lock(takeover_policy, &recovery)?;
        if request.ensure_existing_history(&self.pi_session_directory)? != history {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi history changed while recovery was waiting",
            ));
        }
        let bridge_token = create_uuid_v4()?;
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
    ) -> io::Result<SessionMetadata> {
        let PiRecoveryLease {
            session_id,
            shell_id,
            ..
        } = *recovery;
        let mut pending = Some(running);
        let result = (|| {
            let mut state = self.lock_state()?;
            if !recovery.is_current(&state) {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi recovery was cancelled",
                ));
            }
            // Build metadata after installing the process; only this reservation
            // may replace the unavailable entry, never a concurrent newer launch.
            state.unavailable_pi_shells.remove(&shell_id);
            state.install_running(shell_id, pending.take().expect("pending Pi launch"));
            state.pi_activity.remove(&session_id);
            session_metadata(&state, session_id, &self.attach_socket_path)
        })();
        if let Some(mut cancelled) = pending {
            // A close/shutdown may win during exec. Keep cleanup outside the
            // catalog lock and retain the writer lock until the child exits.
            process::stop(&mut cancelled.child);
        }
        result
    }

    fn close_session(self: &Arc<Self>, id: SessionId) -> io::Result<Option<SessionMetadata>> {
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
    ) -> io::Result<ClosedShellMetadata> {
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

    fn start_pi_bridge_for_session(self: &Arc<Self>, session: &SessionMetadata) -> io::Result<()> {
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
            .running
            .iter_mut()
            .filter_map(|(shell_id, running)| match running.child.try_wait() {
                Ok(Some(status)) => {
                    log::info!("event=session.child_exited session_id={} shell_id={} runtime_id={} pid={} status={status}",
                        running.session_id.0, shell_id.0, running.runtime_id.0, running.child.id());
                    Some((*shell_id, running.session_id))
                }
                Ok(None) => None,
                Err(error) => {
                    if !running.wait_error_reported {
                        log::error!("event=session.child_wait_failed session_id={} shell_id={} runtime_id={} pid={} error_kind={:?}",
                            running.session_id.0, shell_id.0, running.runtime_id.0, running.child.id(), error.kind());
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
                    .running
                    .get(shell_id)
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
            if let Some(shell) = state.running.remove(shell_id) {
                state.unavailable_pi_shells.insert(
                    *shell_id,
                    UnavailablePiShell {
                        session_id: *session_id,
                        pane_id: shell.pane_id.clone(),
                        initial_pwd: shell.initial_pwd.clone(),
                        recovery_id: None,
                    },
                );
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
            state.running.remove(shell_id);
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
            self.publish_shell_activity(session_id, shell_id, "exited");
        }
        for session_id in removed_sessions {
            self.publish_session_removed(session_id);
        }
        for session_id in changed_sessions {
            self.publish_session_snapshot(session_id)?;
        }
        self.ensure_open_workspace_sessions()?;
        if let Some(session) = self.ensure_home_session()? {
            self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        }
        Ok(())
    }

    /// Registers one more attachment and hands out a PTY descriptor for input, resizing, and
    /// termios/foreground queries. Output comes from `TerminalOutput`, never from this descriptor.
    fn attach_shell(&self, id: ShellId) -> io::Result<ShellAttachment> {
        let mut state = self.lock_state()?;
        let running = state
            .running
            .get_mut(&id)
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
            let Some(running) = state.running.get_mut(&id) else {
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
        self.publish_shell_activity(session_id, id, "detached");
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
        let running = self
            .state
            .lock()
            .map(|mut state| std::mem::take(&mut state.running))
            .unwrap_or_default();
        let mut shells: Vec<RunningShell> = running.into_values().collect();
        let mut children: Vec<&mut Child> =
            shells.iter_mut().map(|shell| &mut shell.child).collect();
        process::stop_all(&mut children);
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
            || requested_session_file.len() > MAX_COMMAND_LINE_BYTES
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

        let (session_id, state_name, initial_pwd, workspace_id) = {
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
                        SessionId(row.get(0)?),
                        row.get::<_, String>(1)?,
                        PathBuf::from(row.get::<_, String>(2)?),
                        row.get::<_, Option<String>>(3)?,
                    ))
                })
                .map_err(io::Error::other)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(io::Error::other)?;
            drop(statement);
            if records.len() != 1 {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "no unique Axo Session owns this Pi history",
                ));
            }
            records.into_iter().next().expect("one matching Session")
        };

        if state_name == "open" {
            return self.complete_pi_resume(requester, session_id);
        }
        if state_name != "archived" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi Session has an unsupported lifecycle state",
            ));
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
                    params![session_id.0],
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
            if state
                .running
                .values()
                .any(|shell| shell.session_id == session_id)
                || state
                    .unavailable_pi_shells
                    .values()
                    .any(|shell| shell.session_id == session_id)
            {
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
                    params![session_id.0],
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
                    params![session_id.0],
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
                        match spawn_shell(&state.shell_command, session_id, &record.initial_pwd) {
                            Ok(shell) => {
                                state.install_running(shell_id, shell);
                            }
                            Err(error) => {
                                log::warn!(
                                    "event=session.terminal_restore_unavailable session_id={} shell_id={} error_kind={:?}",
                                    session_id.0,
                                    shell_id.0,
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
                        state.unavailable_pi_shells.insert(
                            shell_id,
                            UnavailablePiShell {
                                session_id,
                                pane_id,
                                initial_pwd: record.initial_pwd.clone(),
                                recovery_id: None,
                            },
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
                .any(|shell| shell.role == PaneRole::Pi && shell.available)
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
                self.publish_event(json!({
                    "type": "session.snapshot",
                    "session": replacement.to_json(),
                }));
            }
        }

        self.request_session_focus(target_session_id)?;
        self.publish_session_snapshot(target_session_id)?;
        log::info!(
            "event=session.pi_resume_completed session_id={}",
            target_session_id.0
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

            match name {
                "agent.start" => {
                    let activity = state.pi_activity.entry(session_id).or_default();
                    let changed = !activity.working;
                    activity.working = true;
                    changed
                }
                "agent.settled" => {
                    let activity = state.pi_activity.entry(session_id).or_default();
                    let changed = activity.working;
                    activity.working = false;
                    changed
                }
                "ui.prompt.start" => {
                    let activity = state.pi_activity.entry(session_id).or_default();
                    let previous_waits = activity.ui_waits;
                    activity.ui_waits = activity.ui_waits.saturating_add(1);
                    activity.ui_waits != previous_waits
                }
                "ui.prompt.end" => {
                    let activity = state.pi_activity.entry(session_id).or_default();
                    let previous_waits = activity.ui_waits;
                    activity.ui_waits = activity.ui_waits.saturating_sub(1);
                    activity.ui_waits != previous_waits
                }
                "session.info" => {
                    let Some(title) = data["name"]
                        .as_str()
                        .filter(|title| valid_session_title(title))
                    else {
                        return Ok(true);
                    };
                    state
                        .database
                        .execute(
                            "UPDATE sessions SET name = ?1 WHERE id = ?2 AND state = 'open'",
                            params![title, session_id.0],
                        )
                        .map_err(io::Error::other)?
                        > 0
                }
                "axo.session.metadata" => {
                    let title = data["title"]
                        .as_str()
                        .filter(|title| valid_session_title(title));
                    let emoji = data["emoji"]
                        .as_str()
                        .filter(|emoji| valid_session_emoji(emoji));
                    if title.is_none() && emoji.is_none() {
                        return Ok(true);
                    }
                    state.database.execute(
                        "UPDATE sessions SET name = COALESCE(?1, name), emoji = COALESCE(?2, emoji) \
                         WHERE id = ?3 AND state = 'open'",
                        params![title, emoji, session_id.0],
                    ).map_err(io::Error::other)? > 0
                }
                _ => false,
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
            params![pi_session_id, session_id.0, session_uuid],
        ).map_err(io::Error::other)?;
        if changed != 1 {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi Session binding changed",
            ));
        }
        Ok(())
    }

    fn config_value(&self, key: &str) -> io::Result<ConfigValue> {
        let key = ConfigKey::parse(key)?;
        let state = self.lock_state()?;
        let value = match key {
            ConfigKey::AgentCommand => state.agent_command.0.source.clone(),
            ConfigKey::ShellCommand => state.shell_command.0.source.clone(),
        };
        Ok(ConfigValue { key, value })
    }

    fn set_config_value(&self, key: &str, value: &str) -> io::Result<ConfigValue> {
        let key = ConfigKey::parse(key)?;
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
            ParsedConfigValue::AgentCommand(command) => command.0.source.clone(),
            ParsedConfigValue::ShellCommand(command) => command.0.source.clone(),
        };

        let mut state = self.lock_state()?;
        state
            .database
            .execute(
                "INSERT INTO daemon_metadata (key, value) VALUES (?1, ?2) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key.metadata_key(), value],
            )
            .map_err(io::Error::other)?;
        match parsed {
            ParsedConfigValue::AgentCommand(command) => state.agent_command = command,
            ParsedConfigValue::ShellCommand(command) => state.shell_command = command,
        }
        Ok(ConfigValue { key, value })
    }

    fn request_session_focus(&self, session_id: SessionId) -> io::Result<()> {
        // Live catalog subscribers focus immediately. Listing clients get the same request for a
        // short window only, so a much later resync cannot replay a stale focus change.
        self.publish_event(json!({ "type": "session.focus", "sessionId": session_id.0 }));
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

    fn lock_state(&self) -> io::Result<std::sync::MutexGuard<'_, SessionState>> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("session state lock was poisoned"))
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
        .filter(|path| path.is_absolute() && path.is_file() && is_executable(path))
        .or_else(|| {
            super::current_user_login_shell()
                .ok()
                .filter(|path| path.is_file() && is_executable(path))
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
        if !is_uuid_string(&host_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "stored host identity is malformed",
            ));
        }
        return Ok(host_id);
    }

    let host_id = create_uuid_v4()?;
    database
        .execute(
            "INSERT INTO daemon_metadata (key, value) VALUES ('host_id', ?1)",
            params![host_id],
        )
        .map_err(io::Error::other)?;
    Ok(host_id)
}

fn create_uuid_v4() -> io::Result<String> {
    let mut bytes = [0_u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
    ))
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
) -> io::Result<SessionMetadata> {
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
    let session_uuid = create_uuid_v4()?;
    let pane_id = create_uuid_v4()?;
    let pi_directory = pi_session_directory.join(workspace_id);
    fs::create_dir_all(&pi_directory)?;
    fs::set_permissions(&pi_directory, fs::Permissions::from_mode(0o700))?;
    let pi_session_file = pi_directory.join(format!("{session_uuid}.jsonl"));
    let bridge_socket = PiBridgeSocketPath::for_session(pi_session_directory, &session_uuid)?;
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
            bridge_socket.database_value(),
        ],
    ).map_err(io::Error::other)?;
    let session_id = SessionId(state.database.last_insert_rowid());
    state
        .database
        .execute(
            "INSERT INTO shells (session_id, initial_pwd, state, created_at, role, pane_id)
         VALUES (?, ?, 'open', ?, 'pi', ?)",
            params![
                session_id.0,
                initial_pwd.to_string_lossy(),
                unix_timestamp(),
                pane_id
            ],
        )
        .map_err(io::Error::other)?;
    let pane = ShellId(state.database.last_insert_rowid());
    let layout = SessionLayout::Pane { shell_id: pane.0 };
    state
        .database
        .execute(
            "UPDATE sessions SET layout_json = ? WHERE id = ?",
            params![
                serde_json::to_string(&layout).map_err(io::Error::other)?,
                session_id.0
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
) -> io::Result<SessionMetadata> {
    let initial_pwd = state.initial_pwd.clone();
    let session_uuid = create_uuid_v4()?;
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
    let id = SessionId(state.database.last_insert_rowid());

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
) -> io::Result<ShellMetadata> {
    let initial_pwd = session_initial_pwd(&state.database, session_id)?;
    state
        .database
        .execute(
            "INSERT INTO shells (session_id, initial_pwd, state, created_at)
             VALUES (?1, ?2, 'open', ?3)",
            params![
                session_id.0,
                initial_pwd.to_string_lossy(),
                unix_timestamp()
            ],
        )
        .map_err(io::Error::other)?;
    let shell_id = ShellId(state.database.last_insert_rowid());

    let running = match spawn_shell(&state.shell_command, session_id, &initial_pwd) {
        Ok(running) => running,
        Err(error) => {
            archive_shell(&state.database, shell_id, "spawn_failed")?;
            return Err(error);
        }
    };
    let metadata = shell_metadata(shell_id, &running, attach_socket_path);
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
) -> io::Result<(Option<SessionMetadata>, Vec<RunningShell>)> {
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
            params![id.0],
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
) -> io::Result<(ClosedShellMetadata, Vec<RunningShell>)> {
    let role = if let Some(shell) = state.running.get(&shell_id) {
        if shell.session_id != session_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "shell does not belong to this session",
            ));
        }
        shell.role
    } else if let Some(shell) = state.unavailable_pi_shells.get(&shell_id) {
        if shell.session_id != session_id {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "shell does not belong to this session",
            ));
        }
        PaneRole::Pi
    } else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "shell is not open"));
    };

    let sibling_count = open_shell_ids(state, session_id).len();
    if sibling_count == 1 || role == PaneRole::Pi {
        let (replacement, shells) =
            close_session(state, session_id, attach_socket_path, pi_session_directory)?;
        return Ok((
            ClosedShellMetadata {
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
    let shell = state.running.remove(&shell_id).into_iter().collect();
    state.unavailable_pi_shells.remove(&shell_id);
    Ok((
        ClosedShellMetadata {
            archived_shell_id: shell_id,
            archived_session_id: None,
            replacement: None,
        },
        shell,
    ))
}

fn open_shell_ids(state: &SessionState, session_id: SessionId) -> HashSet<ShellId> {
    state
        .running
        .iter()
        .filter_map(|(shell_id, shell)| (shell.session_id == session_id).then_some(*shell_id))
        .chain(
            state
                .unavailable_pi_shells
                .iter()
                .filter_map(|(shell_id, shell)| {
                    (shell.session_id == session_id).then_some(*shell_id)
                }),
        )
        .collect()
}

fn remove_session_shells(state: &mut SessionState, session_id: SessionId) -> Vec<RunningShell> {
    let shell_ids: Vec<_> = state
        .running
        .iter()
        .filter_map(|(shell_id, shell)| (shell.session_id == session_id).then_some(*shell_id))
        .collect();
    state
        .unavailable_pi_shells
        .retain(|_, shell| shell.session_id != session_id);
    shell_ids
        .into_iter()
        .filter_map(|shell_id| state.running.remove(&shell_id))
        .collect()
}

fn session_metadata(
    state: &SessionState,
    id: SessionId,
    attach_socket_path: &Path,
) -> io::Result<SessionMetadata> {
    let (
        initial_pwd,
        session_uuid,
        workspace_id,
        name,
        manual_name,
        pi_session_file,
        pi_session_id,
    ) = state.database.query_row(
        "SELECT initial_pwd, session_uuid, workspace_id, name, manual_name, pi_session_file, pi_session_id
         FROM sessions WHERE id = ?1 AND state = 'open'",
        params![id.0],
        |row| {
            Ok((
                PathBuf::from(row.get::<_, String>(0)?),
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?.map(PathBuf::from),
                row.get::<_, Option<String>>(6)?,
            ))
        },
    )
    .map_err(io::Error::other)?;
    let emoji = state
        .database
        .query_row(
            "SELECT emoji FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.0],
            |row| row.get::<_, Option<String>>(0),
        )
        .map_err(io::Error::other)?;
    let workspace_name = workspace_id
        .as_ref()
        .map(|workspace_id| {
            state.database.query_row(
                "SELECT name FROM workspaces WHERE workspace_id = ?1 AND state = 'open'",
                params![workspace_id],
                |row| row.get::<_, String>(0),
            )
        })
        .transpose()
        .map_err(io::Error::other)?;
    let mut shells: Vec<_> = state
        .running
        .iter()
        .filter(|&(_, running)| running.session_id == id)
        .map(|(shell_id, running)| shell_metadata(*shell_id, running, attach_socket_path))
        .collect();
    shells.extend(
        state
            .unavailable_pi_shells
            .iter()
            .filter(|&(_, shell)| shell.session_id == id)
            .map(|(shell_id, shell)| {
                unavailable_pi_shell_metadata(*shell_id, shell, attach_socket_path)
            }),
    );
    shells.sort_by_key(|shell| shell.id.0);
    let status = if shells.iter().any(|shell| !shell.available) {
        SessionStatus::Unavailable
    } else if shells.iter().any(|shell| shell.role == PaneRole::Pi) {
        state
            .pi_activity
            .get(&id)
            .map_or(SessionStatus::Starting, |activity| activity.status())
    } else {
        SessionStatus::Ready
    };
    Ok(SessionMetadata {
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
        layout: read_session_layout(&state.database, id)?,
    })
}

fn shell_metadata(id: ShellId, running: &RunningShell, attach_socket_path: &Path) -> ShellMetadata {
    ShellMetadata {
        id,
        pane_id: running.pane_id.clone(),
        role: running.role,
        process_id: running.child.id(),
        initial_pwd: running.initial_pwd.clone(),
        slave_device: running.slave_device.clone(),
        attach_socket_path: attach_socket_path.to_path_buf(),
        available: true,
        availability_reason: None,
    }
}

fn unavailable_pi_shell_metadata(
    id: ShellId,
    shell: &UnavailablePiShell,
    attach_socket_path: &Path,
) -> ShellMetadata {
    ShellMetadata {
        id,
        pane_id: shell.pane_id.clone(),
        role: PaneRole::Pi,
        process_id: 0,
        initial_pwd: shell.initial_pwd.clone(),
        slave_device: String::new(),
        attach_socket_path: attach_socket_path.to_path_buf(),
        available: false,
        availability_reason: Some(
            "Axo could not recover this Pi session. Its conversation history is preserved.",
        ),
    }
}

fn read_open_sessions(database: &Connection) -> io::Result<Vec<SessionRecord>> {
    let mut statement = database
        .prepare("SELECT id, initial_pwd FROM sessions WHERE state = 'open' ORDER BY id")
        .map_err(io::Error::other)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                SessionId(row.get(0)?),
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
            .query_map(params![id.0], |row| {
                let role: String = row.get(1)?;
                let role = match role.as_str() {
                    "pi" => PaneRole::Pi,
                    "terminal" => PaneRole::Terminal,
                    _ => return Err(rusqlite::Error::InvalidQuery),
                };
                Ok((ShellId(row.get(0)?), role, row.get(2)?))
            })
            .map_err(io::Error::other)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?;
        records.push(SessionRecord {
            id,
            initial_pwd,
            shell_ids,
        });
    }
    Ok(records)
}

fn read_session_layout(database: &Connection, id: SessionId) -> io::Result<Option<SessionLayout>> {
    let stored_layout = database
        .query_row(
            "SELECT layout_json FROM sessions WHERE id = ?1 AND state = 'open'",
            params![id.0],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(io::Error::other)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "session record is missing"))?;
    let Some(stored_layout) = stored_layout else {
        return Ok(None);
    };

    let layout: SessionLayout = match serde_json::from_str(&stored_layout) {
        Ok(layout) => layout,
        Err(error) => {
            log::warn!(
                "event=session.layout_invalid session_id={} reason={error}",
                id.0
            );
            return Ok(None);
        }
    };
    if let Err(error) = layout.shell_ids() {
        log::warn!(
            "event=session.layout_invalid session_id={} reason={error}",
            id.0
        );
        return Ok(None);
    }
    Ok(Some(layout))
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
                PiBridgeSocketPath::parse(PathBuf::from(path)).map_err(|error| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("stored Pi bridge socket path for session {session_id} is invalid: {error}"),
                    )
                })?;
            }
            None => {
                let socket_path =
                    PiBridgeSocketPath::for_session(pi_session_directory, &session_uuid)?;
                let changed = database
                    .execute(
                        "UPDATE sessions SET pi_bridge_socket_path = ?1
                         WHERE id = ?2 AND pi_bridge_socket_path IS NULL",
                        params![socket_path.database_value(), session_id],
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
            params![id.0],
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
            params![unix_timestamp(), reason, id.0],
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
            params![unix_timestamp(), reason, shell_id.0],
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
                params![layout_json, session_id.0],
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
            .map(|id| id.map(SessionId))
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
            params![archived_at, reason, id.0],
        )
        .map_err(io::Error::other)?;
    let changed = transaction
        .execute(
            "UPDATE sessions SET state = 'archived', archived_at = ?1, termination_reason = ?2
             WHERE id = ?3 AND state = 'open'",
            params![archived_at, reason, id.0],
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
fn set_terminal_resources(command: &mut Command) {
    if let Some(resources_directory) = bundled_ghostty_resources_directory() {
        command.env("GHOSTTY_RESOURCES_DIR", resources_directory);
    }
    if let Some(terminfo_directory) = bundled_terminfo_directory() {
        command.env("TERMINFO", terminfo_directory);
    }
}

fn spawn_shell(
    shell_command: &ShellCommand,
    session_id: SessionId,
    initial_pwd: &Path,
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
    } = process::spawn(command, WindowSize::DEFAULT, &[])?;
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

#[cfg(test)]
fn read_pi_bridge_record(reader: &mut BufReader<UnixStream>) -> io::Result<Value> {
    let mut line = Vec::new();
    let mut limited = reader.take((MAX_PI_BRIDGE_RECORD_BYTES + 1) as u64);
    let length = limited.read_until(b'\n', &mut line)?;
    if length == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "Pi bridge closed before completing its response",
        ));
    }
    if length > MAX_PI_BRIDGE_RECORD_BYTES || line.last() != Some(&b'\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi bridge record exceeds its size limit",
        ));
    }
    serde_json::from_slice(&line[..line.len() - 1]).map_err(io::Error::other)
}

// A socket read timeout alone restarts on every byte/event. Recovery must have
// one deadline even when a bridge dribbles bytes or streams unrelated events.
fn read_pi_bridge_record_until(
    reader: &mut BufReader<UnixStream>,
    deadline: Instant,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<Value> {
    let mut line = Vec::new();
    loop {
        check_current()?;
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|time| !time.is_zero())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Pi bridge recovery request timed out",
                )
            })?;
        reader
            .get_ref()
            .set_read_timeout(Some(remaining.min(PI_RECOVERY_POLL_INTERVAL)))?;
        let buffer = match reader.fill_buf() {
            Ok([]) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "Pi bridge closed before completing its response",
                ));
            }
            Ok(buffer) => buffer,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        };
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let length = newline.map_or(buffer.len(), |index| index + 1);
        if line.len().saturating_add(length) > MAX_PI_BRIDGE_RECORD_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi bridge record exceeds its size limit",
            ));
        }
        line.extend_from_slice(&buffer[..length]);
        reader.consume(length);
        if newline.is_some() {
            return serde_json::from_slice(&line[..line.len() - 1]).map_err(io::Error::other);
        }
    }
}

fn connect_pi_socket_until(
    path: &Path,
    deadline: Instant,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<UnixStream> {
    // Nonblocking connect matters too: an unresponsive listener with a full
    // accept queue can otherwise pin recovery (or a worker join) in the kernel.
    check_current()?;
    let bytes = path.as_os_str().as_encoded_bytes();
    // SAFETY: sockaddr_un is plain data and zeroing supplies the NUL terminator.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Pi socket path is invalid",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    #[cfg(target_os = "macos")]
    {
        address.sun_len = std::mem::size_of_val(&address) as u8;
    }
    for (target, byte) in address.sun_path.iter_mut().zip(bytes) {
        *target = *byte as libc::c_char;
    }
    // SAFETY: socket returns a fresh descriptor, owned immediately below.
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if raw == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: raw is the newly created descriptor.
    let socket = unsafe { OwnedFd::from_raw_fd(raw) };
    process::set_cloexec(raw)?;
    // SAFETY: these fcntl calls only inspect/update this owned descriptor.
    let flags = unsafe { libc::fcntl(raw, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(raw, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: address is initialized and has the specified sockaddr_un length.
    if unsafe {
        libc::connect(
            raw,
            &address as *const _ as *const libc::sockaddr,
            std::mem::size_of_val(&address) as libc::socklen_t,
        )
    } == -1
    {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINPROGRESS) {
            return Err(error);
        }
        loop {
            check_current()?;
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .filter(|time| !time.is_zero())
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::TimedOut, "Pi bridge connection timed out")
                })?;
            let mut poll = libc::pollfd {
                fd: raw,
                events: libc::POLLOUT,
                revents: 0,
            };
            let timeout =
                remaining.min(PI_RECOVERY_POLL_INTERVAL).as_millis().max(1) as libc::c_int;
            // SAFETY: poll receives one initialized descriptor record.
            let ready = unsafe { libc::poll(&mut poll, 1, timeout) };
            if ready == -1 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                continue;
            }
            let mut error = 0 as libc::c_int;
            let mut length = std::mem::size_of_val(&error) as libc::socklen_t;
            // SAFETY: SO_ERROR writes one int to the correctly sized output.
            if unsafe {
                libc::getsockopt(
                    raw,
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    &mut error as *mut _ as *mut libc::c_void,
                    &mut length,
                )
            } == -1
            {
                return Err(io::Error::last_os_error());
            }
            if error != 0 {
                return Err(io::Error::from_raw_os_error(error));
            }
            break;
        }
    }
    check_current()?;
    // SAFETY: restore blocking mode on our connected, still-owned descriptor.
    if unsafe { libc::fcntl(raw, libc::F_SETFL, flags) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(UnixStream::from(socket))
}

/// The exact Pi pane a bridge connection must prove it serves, and how to reach it.
#[derive(Clone, Copy)]
struct PiBridgeTarget<'a> {
    bridge_socket: &'a Path,
    token: &'a str,
    session_uuid: &'a str,
    pane_id: &'a str,
    initial_pwd: &'a Path,
    session_file: &'a Path,
}

fn connect_to_pi_bridge(
    target: PiBridgeTarget<'_>,
    deadline: Instant,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<(BufReader<UnixStream>, VerifiedPiProcessId)> {
    let PiBridgeTarget {
        bridge_socket,
        token,
        session_uuid,
        pane_id,
        initial_pwd,
        session_file,
    } = target;
    let mut stream = connect_pi_socket_until(bridge_socket, deadline, check_current)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    write_json_line(
        &mut stream,
        &json!({ "type": "authenticate", "protocolVersion": 1, "token": token }),
    )?;
    let mut reader = BufReader::new(stream);
    let mut authenticated = false;
    loop {
        let record = read_pi_bridge_record_until(&mut reader, deadline, check_current)?;
        match record["type"].as_str() {
            Some("authenticated") if record["protocolVersion"] == 1 => authenticated = true,
            Some("hello") if authenticated && record["protocolVersion"] == 1 => {
                let identity = &record["identity"];
                let process_id = VerifiedPiProcessId::parse(&identity["processId"])?;
                let exact_identity = identity["axoSessionId"] == session_uuid
                    && identity["axoPaneId"] == pane_id
                    && identity["sessionFile"] == session_file.to_string_lossy().as_ref()
                    && identity["cwd"] == initial_pwd.to_string_lossy().as_ref();
                if !exact_identity {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "Pi bridge identity did not match the Session being taken over",
                    ));
                }
                return Ok((reader, process_id));
            }
            Some("protocolError") => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Pi bridge rejected takeover authentication",
                ));
            }
            Some("event") => {}
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Pi bridge sent an invalid takeover handshake",
                ));
            }
        }
    }
}

fn request_pi_shutdown(
    target: PiBridgeTarget<'_>,
    takeover_policy: PiTakeoverPolicy,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<PiShutdownAttempt> {
    let session_uuid = target.session_uuid;
    check_current()?;
    let deadline = Instant::now() + PI_BRIDGE_REQUEST_TIMEOUT;
    let (mut reader, process_id) = connect_to_pi_bridge(target, deadline, check_current)?;
    check_current()?;
    let request_id = format!("takeover-{}", create_uuid_v4()?);
    let graceful_shutdown = write_json_line(
        reader.get_mut(),
        &json!({
            "type": "command",
            "requestId": request_id,
            "axoSessionId": session_uuid,
            "action": {
                "kind": if takeover_policy == PiTakeoverPolicy::PreserveExistingProcess {
                    "shutdownIfIdle"
                } else {
                    "shutdown"
                }
            }
        }),
    )
    .and_then(|()| {
        loop {
            let record = match read_pi_bridge_record_until(&mut reader, deadline, check_current) {
                Ok(record) => record,
                Err(error) => break Err(error),
            };
            if record["type"] != "commandResult" || record["requestId"] != request_id {
                continue;
            }
            if record["result"]["accepted"] == true {
                break Ok(());
            }
            break Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "Pi did not accept the graceful takeover request",
            ));
        }
    });
    Ok(PiShutdownAttempt {
        process_id,
        graceful_shutdown,
    })
}

fn wait_for_pi_writer_lock(
    session_file: &Path,
    timeout: Duration,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<OwnedFd> {
    let deadline = Instant::now() + timeout;
    loop {
        check_current()?;
        match acquire_pi_writer_lock(session_file) {
            Ok(lock) => return Ok(lock),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "Pi did not release its transcript lock",
                    ));
                }
                thread::sleep(Duration::from_millis(100));
            }
            Err(error) => return Err(error),
        }
    }
}

fn wait_then_terminate_verified_pi(
    session_file: &Path,
    process_id: VerifiedPiProcessId,
    recovery: &PiRecoveryLease<'_>,
) -> io::Result<OwnedFd> {
    let check_current = &|| recovery.ensure_current();
    match wait_for_pi_writer_lock(session_file, PI_RESTART_GRACE_PERIOD, check_current) {
        Ok(lock) => return Ok(lock),
        Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
        Err(error) => return Err(error),
    }
    match acquire_pi_writer_lock(session_file) {
        Ok(lock) => return Ok(lock),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
        Err(error) => return Err(error),
    }

    log::warn!(
        "event=session.pi_force_termination_started pid={}",
        process_id.0
    );
    recovery.signal_current(process_id, libc::SIGTERM)?;
    match wait_for_pi_writer_lock(session_file, PI_TERMINATE_GRACE_PERIOD, check_current) {
        Ok(lock) => {
            log::info!("event=session.pi_force_termination_completed signal=term");
            return Ok(lock);
        }
        Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
        Err(error) => return Err(error),
    }
    match acquire_pi_writer_lock(session_file) {
        Ok(lock) => return Ok(lock),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
        Err(error) => return Err(error),
    }

    recovery.signal_current(process_id, libc::SIGKILL)?;
    let lock =
        wait_for_pi_writer_lock(session_file, PI_KILL_WAIT, check_current).map_err(|error| {
            if error.kind() == io::ErrorKind::TimedOut {
                io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Pi still holds its transcript lock after termination",
                )
            } else {
                error
            }
        })?;
    log::info!("event=session.pi_force_termination_completed signal=kill");
    Ok(lock)
}

fn signal_verified_pi_process(
    process_id: VerifiedPiProcessId,
    signal: libc::c_int,
) -> io::Result<()> {
    // Pi is launched as a new session, so its authenticated PID must still lead its own group.
    // SAFETY: getpgid only inspects the validated PID returned by the Pi bridge.
    let process_group = unsafe { libc::getpgid(process_id.0) };
    if process_group == -1 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            return Ok(());
        }
        return Err(error);
    }
    if process_group != process_id.0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "authenticated Pi process is no longer its own session leader",
        ));
    }

    // SAFETY: the group ID equals the PID from the exact authenticated session/pane identity.
    if unsafe { libc::kill(-process_id.0, signal) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Ok(());
    }
    Err(error)
}

fn pi_shutdown_attempt_from_lock(
    session_id: SessionId,
    session_file: &Path,
    error: io::Error,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<PiShutdownAttempt> {
    let started = Instant::now();
    let process_id = pi_writer_process_id_from_lock(session_file, check_current).inspect_err(|error| {
        log::info!(
            "event=session.pi_lock_inspection_rejected session_id={} elapsed_ms={} error_kind={:?}",
            session_id.0, started.elapsed().as_millis(), error.kind()
        );
    })?;
    log::warn!(
        "event=session.pi_process_verified_by_lock session_id={} pid={} elapsed_ms={}",
        session_id.0,
        process_id.0,
        started.elapsed().as_millis()
    );
    Ok(PiShutdownAttempt {
        process_id,
        graceful_shutdown: Err(error),
    })
}

fn pi_bridge_unavailable_for_restart(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionRefused
            | io::ErrorKind::TimedOut
            | io::ErrorKind::WouldBlock
            | io::ErrorKind::UnexpectedEof
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::NotFound
    )
}

fn pi_writer_process_id_from_lock(
    session_file: &Path,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<VerifiedPiProcessId> {
    let deadline = Instant::now() + PI_OWNER_INSPECTION_TIMEOUT;
    let lock_path = session_file.with_extension("jsonl.lock");
    let output = process_inspection::run(
        Command::new("/usr/sbin/lsof")
            .args(["-n", "-P", "-t"])
            .arg(&lock_path),
        deadline,
        check_current,
    )?;
    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no process owns the Pi transcript lock",
        ));
    }

    let process_ids = parse_pi_lock_process_ids(&output.stdout)?;

    let mut owners = Vec::with_capacity(process_ids.len());
    for process_id in process_ids {
        let output = process_inspection::run(
            Command::new("/bin/ps").args([
                "-p",
                &process_id.to_string(),
                "-o",
                "uid=",
                "-o",
                "pgid=",
                "-o",
                "comm=",
            ]),
            deadline,
            check_current,
        )?;
        if !output.status.success() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi transcript lock owner exited during verification",
            ));
        }
        owners.push(parse_pi_lock_owner(process_id, &output.stdout)?);
    }

    check_current()?;
    if Instant::now() >= deadline {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "Pi owner inspection timed out",
        ));
    }
    let process_id = verified_pi_lock_owner(&owners, unsafe { libc::getuid() })?;
    // SAFETY: getpgid inspects the process that lsof and ps identified as this user's Pi lock owner.
    if unsafe { libc::getpgid(process_id.0) } != process_id.0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Pi transcript lock owner is no longer its own process-group leader",
        ));
    }
    match acquire_pi_writer_lock(session_file) {
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(process_id),
        Ok(lock) => {
            drop(lock);
            Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi released its transcript lock during process verification",
            ))
        }
        Err(error) => Err(error),
    }
}

fn parse_pi_lock_process_ids(output: &[u8]) -> io::Result<HashSet<libc::pid_t>> {
    if output.len() > process_inspection::MAX_INSPECTION_OUTPUT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner list exceeds its size limit",
        ));
    }
    let output = std::str::from_utf8(output)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Pi owner list is not UTF-8"))?;
    let mut process_ids = HashSet::new();
    for line in output.lines() {
        let process_id = line
            .parse::<libc::pid_t>()
            .ok()
            .filter(|pid| *pid > 1 && *pid != std::process::id() as libc::pid_t)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "lsof returned an invalid process ID",
                )
            })?;
        process_ids.insert(process_id);
        if process_ids.len() > MAX_PI_LOCK_OWNERS {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi transcript has too many lock owners",
            ));
        }
    }
    if process_ids.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no process owns the Pi transcript lock",
        ));
    }
    Ok(process_ids)
}

fn parse_pi_lock_owner(process_id: libc::pid_t, output: &[u8]) -> io::Result<PiLockOwner> {
    if output.len() > process_inspection::MAX_INSPECTION_OUTPUT_BYTES || output.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner record is invalid",
        ));
    }
    let output = std::str::from_utf8(output)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Pi owner record is not UTF-8"))?
        .trim();
    if output.lines().count() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner record must contain exactly one process",
        ));
    }
    let mut fields = output.split_whitespace();
    let user_id = fields
        .next()
        .and_then(|value| value.parse::<libc::uid_t>().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Pi owner UID is invalid"))?;
    let process_group_id = fields
        .next()
        .and_then(|value| value.parse::<libc::pid_t>().ok())
        .filter(|pid| *pid > 1)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi owner process group is invalid",
            )
        })?;
    let command = fields.collect::<Vec<_>>().join(" ");
    if command.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi owner command is missing",
        ));
    }
    Ok(PiLockOwner {
        process_id,
        user_id,
        process_group_id,
        command,
    })
}

fn verified_pi_lock_owner(
    owners: &[PiLockOwner],
    current_user_id: libc::uid_t,
) -> io::Result<VerifiedPiProcessId> {
    let mut process_groups = owners.iter().map(|owner| owner.process_group_id);
    let Some(process_group) = process_groups.next() else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no Pi process owns the transcript lock",
        ));
    };
    if owners
        .iter()
        .any(|owner| owner.user_id != current_user_id || owner.process_group_id != process_group)
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "transcript lock is shared outside one user-owned process group",
        ));
    }
    let leaders = owners.iter().filter(|owner| {
        owner.process_id == process_group
            && Path::new(&owner.command).file_name() == Some(OsStr::new("pi"))
    });
    let mut leaders = leaders;
    let Some(leader) = leaders.next() else {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "transcript lock owner is not a Pi process-group leader",
        ));
    };
    if leaders.next().is_some() || process_group <= 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "transcript lock has an ambiguous Pi process-group owner",
        ));
    }
    Ok(VerifiedPiProcessId(leader.process_id))
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
    if token.as_ref().is_some_and(|token| !is_uuid_string(token)) {
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

fn acquire_pi_writer_lock(session_file: &Path) -> io::Result<OwnedFd> {
    let lock_path = session_file.with_extension("jsonl.lock");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(lock_path)?;
    if !lock.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi writer lock is not a regular file",
        ));
    }
    // SAFETY: lock is a valid file descriptor and flock only changes its advisory lock.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == -1 {
        let error = io::Error::last_os_error();
        return Err(if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
            io::Error::new(
                io::ErrorKind::WouldBlock,
                "Pi transcript is already owned by a writer",
            )
        } else {
            error
        });
    }
    Ok(OwnedFd::from(lock))
}

impl PiLaunchRequest {
    fn ensure_existing_history(&self, directory: &Path) -> io::Result<PiHistoryIdentity> {
        let directory = fs::canonicalize(directory)?;
        let canonical = fs::canonicalize(&self.session_file)?;
        let metadata = fs::metadata(&canonical)?;
        if fs::symlink_metadata(&self.session_file)?
            .file_type()
            .is_symlink()
            || !canonical.starts_with(directory)
            || !metadata.is_file()
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Pi recovery requires its original Axo-owned history file",
            ));
        }
        Ok(PiHistoryIdentity {
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }

    fn acquire_writer_lock(
        &self,
        takeover_policy: PiTakeoverPolicy,
        recovery: &PiRecoveryLease<'_>,
    ) -> io::Result<OwnedFd> {
        let check_current = &|| recovery.ensure_current();
        let Self {
            session_id,
            initial_pwd,
            session_file,
            bridge_socket,
            session_uuid,
            pane_id,
            previous_token,
            ..
        } = self;
        check_current()?;
        match acquire_pi_writer_lock(session_file) {
            Ok(lock) => Ok(lock),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                log::info!(
                    "event=session.pi_takeover_requested session_id={}",
                    session_id.0
                );
                let shutdown_attempt = match previous_token.as_deref() {
                    Some(token) => match request_pi_shutdown(
                        PiBridgeTarget {
                            bridge_socket: bridge_socket.as_path(),
                            token,
                            session_uuid,
                            pane_id,
                            initial_pwd,
                            session_file,
                        },
                        takeover_policy,
                        check_current,
                    ) {
                        Ok(attempt) => attempt,
                        Err(error)
                            if takeover_policy == PiTakeoverPolicy::ExplicitUserRestart
                                && pi_bridge_unavailable_for_restart(&error) =>
                        {
                            check_current()?;
                            pi_shutdown_attempt_from_lock(
                                *session_id,
                                session_file,
                                error,
                                check_current,
                            )?
                        }
                        Err(error) => return Err(error),
                    },
                    None if takeover_policy == PiTakeoverPolicy::ExplicitUserRestart => {
                        check_current()?;
                        pi_shutdown_attempt_from_lock(
                            *session_id,
                            session_file,
                            io::Error::new(
                                io::ErrorKind::ConnectionRefused,
                                "Pi bridge credential is unavailable",
                            ),
                            check_current,
                        )?
                    }
                    None => {
                        return Err(io::Error::new(
                            io::ErrorKind::WouldBlock,
                            "Pi transcript is held by a legacy writer that cannot be controlled by RPC",
                        ));
                    }
                };
                let lock = match takeover_policy {
                    PiTakeoverPolicy::PreserveExistingProcess => {
                        shutdown_attempt.graceful_shutdown?;
                        wait_for_pi_writer_lock(session_file, PI_TAKEOVER_TIMEOUT, check_current)?
                    }
                    PiTakeoverPolicy::ExplicitUserRestart => {
                        if let Err(error) = &shutdown_attempt.graceful_shutdown {
                            log::warn!(
                                "event=session.pi_shutdown_unconfirmed session_id={} error_kind={:?}",
                                session_id.0,
                                error.kind()
                            );
                        }
                        wait_then_terminate_verified_pi(
                            session_file,
                            shutdown_attempt.process_id,
                            recovery,
                        )?
                    }
                };
                log::info!(
                    "event=session.pi_takeover_completed session_id={}",
                    session_id.0
                );
                Ok(lock)
            }
            Err(error) => Err(error),
        }
    }
}

// New Session admission never takes over an existing writer. Recovery has a
// separate reservation/commit path, so no takeover wait can hide under its lock.
/// Starts Pi for a pane with no previous process (`request.previous_token` is ignored).
fn spawn_new_pi(database: &Connection, request: &PiLaunchRequest) -> io::Result<RunningShell> {
    let lock = acquire_pi_writer_lock(&request.session_file)?;
    let bridge_token = create_uuid_v4()?;
    store_pi_bridge_token(database, &request.session_uuid, &bridge_token)?;
    spawn_pi(request, lock, bridge_token)
}

fn spawn_pi(
    request: &PiLaunchRequest,
    lock: OwnedFd,
    bridge_token: String,
) -> io::Result<RunningShell> {
    let PiLaunchRequest {
        agent_command,
        session_id,
        initial_pwd,
        session_file,
        bridge_socket,
        session_uuid,
        pane_id,
        ..
    } = request;
    let extension = resolve_pi_extension_path()?;
    let executable = resolve_pi_executable(&agent_command.0.executable)?;
    let home = super::current_user_home_directory()?;
    let mut command = Command::new(executable);
    command
        .args(&agent_command.0.arguments)
        .arg("--session")
        .arg(session_file)
        .arg("--extension")
        .arg(extension)
        .current_dir(initial_pwd)
        .env("HOME", &home)
        .env("PWD", initial_pwd)
        .env("TERM", "xterm-ghostty")
        .env("AXO_SESSION_ID", session_uuid)
        .env("AXO_PANE_ID", pane_id)
        .env("AXO_PI_SESSION_FILE", session_file)
        .env("AXO_PI_BRIDGE_SOCKET", bridge_socket.as_path())
        .env("AXO_PI_BRIDGE_TOKEN", &bridge_token);
    set_terminal_resources(&mut command);
    // Pi inherits only its own writer lock and keeps it even if Axod crashes. The parent copy
    // stays close-on-exec so concurrent launches never leak it.
    let PtyProcess {
        child,
        master,
        device: slave_device,
        output,
    } = process::spawn(command, WindowSize::DEFAULT, &[lock.as_raw_fd()])?;
    Ok(RunningShell {
        runtime_id: RuntimeId::new(),
        session_id: *session_id,
        role: PaneRole::Pi,
        pane_id: Some(pane_id.to_owned()),
        initial_pwd: initial_pwd.to_path_buf(),
        child,
        wait_error_reported: false,
        master,
        slave_device,
        attachments: 0,
        output,
        last_input_sequence: None,
        _writer_lock: Some(lock),
        pi_bridge_socket: Some(bridge_socket.clone()),
        pi_bridge_token: Some(bridge_token),
    })
}

fn resolve_pi_executable(program: &str) -> io::Result<PathBuf> {
    resolve_command_executable(program, Some("AXO_PI_EXECUTABLE"), "agent")
}

fn resolve_shell_executable(program: &str) -> io::Result<PathBuf> {
    resolve_command_executable(program, None, "shell")
}

fn resolve_command_executable(
    program: &str,
    override_variable: Option<&str>,
    command_kind: &str,
) -> io::Result<PathBuf> {
    let explicit = override_variable
        .and_then(std::env::var_os)
        .map(PathBuf::from);
    let candidate = if let Some(path) = explicit {
        path
    } else if Path::new(program).is_absolute() {
        PathBuf::from(program)
    } else {
        let path = std::env::var_os("PATH").unwrap_or_default();
        std::env::split_paths(&path)
            .chain([
                PathBuf::from("/opt/homebrew/bin"),
                PathBuf::from("/usr/local/bin"),
            ])
            .map(|directory| directory.join(program))
            .find(|candidate| candidate.is_file() && is_executable(candidate))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("{command_kind} executable {program:?} was not found on axod's PATH"),
                )
            })?
    };
    if candidate.is_file() && is_executable(&candidate) {
        Ok(candidate)
    } else {
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("configured {command_kind} executable {program:?} is not executable"),
        ))
    }
}

fn resolve_pi_extension_path() -> io::Result<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("AXO_PI_EXTENSION_PATH") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(resources) = std::env::var_os("AXO_RESOURCES_DIR") {
        candidates.push(PathBuf::from(resources).join("AxoPi/index.js"));
    }
    if let Ok(executable) = std::env::current_exe()
        && let Some(contents_directory) = executable.parent().and_then(Path::parent)
    {
        candidates.push(contents_directory.join("Resources/AxoPi/index.js"));
    }
    candidates.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../packages/pi-axo/dist/index.js"),
    );
    let path = candidates
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "bundled Pi Axo extension was not found",
            )
        })?;
    // Pi runs in the Workspace, not Axod's cwd. Resolve relative resource
    // overrides before handing them across that process boundary.
    fs::canonicalize(path)
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Everything a bridge worker needs to reach and verify one running Pi.
struct PiBridgeWorkerConfig {
    session_uuid: String,
    pane_id: String,
    initial_pwd: PathBuf,
    session_file: PathBuf,
    bridge_socket: PiBridgeSocketPath,
    bridge_token: String,
    process_id: u32,
}

fn run_pi_bridge_worker(
    manager: Weak<SessionManager>,
    stop: Arc<AtomicBool>,
    binding: PiRuntimeBinding,
    config: PiBridgeWorkerConfig,
) {
    let PiBridgeWorkerConfig {
        session_uuid,
        pane_id,
        initial_pwd,
        session_file,
        bridge_socket,
        bridge_token,
        process_id,
    } = config;
    let PiRuntimeBinding {
        session_id,
        shell_id,
        ..
    } = binding;
    let mut has_connected = false;
    while !stop.load(Ordering::Relaxed) {
        let Some(owner) = manager.upgrade() else {
            return;
        };
        if !owner.pi_runtime_is_current(binding) {
            return;
        }
        drop(owner);

        let check_current = || {
            if stop.load(Ordering::Relaxed)
                || !manager
                    .upgrade()
                    .is_some_and(|owner| owner.pi_runtime_is_current(binding))
            {
                Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Pi bridge runtime is no longer current",
                ))
            } else {
                Ok(())
            }
        };
        let mut stream = match connect_pi_socket_until(
            bridge_socket.as_path(),
            Instant::now() + PI_BRIDGE_REQUEST_TIMEOUT,
            &check_current,
        ) {
            Ok(stream) => {
                if !has_connected {
                    log::info!(
                        "event=pi.bridge_connected session_id={} shell_id={}",
                        session_id.0,
                        shell_id.0
                    );
                    has_connected = true;
                }
                stream
            }
            Err(_) => {
                thread::sleep(Duration::from_millis(100));
                continue;
            }
        };
        if stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .and_then(|()| stream.set_write_timeout(Some(Duration::from_secs(2))))
            .is_err()
        {
            return;
        }
        let auth = json!({ "type": "authenticate", "protocolVersion": 1, "token": bridge_token });
        if write_json_line(&mut stream, &auth).is_err() {
            continue;
        }

        let mut phase = 0_u8;
        let mut buffer = Vec::new();
        let mut pi_session_id: Option<String> = None;
        let mut active_stream_id: Option<String> = None;
        let mut last_sequence = 0_u64;
        let mut connection_valid = true;
        while connection_valid && !stop.load(Ordering::Relaxed) {
            let Some(owner) = manager.upgrade() else {
                return;
            };
            if !owner.pi_runtime_is_current(binding) {
                return;
            }
            drop(owner);
            let mut chunk = [0_u8; 8192];
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(length) => {
                    buffer.extend_from_slice(&chunk[..length]);
                    if buffer.len() > 8 * 1024 * 1024 && !buffer.contains(&b'\n') {
                        break;
                    }
                    while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
                        let line: Vec<_> = buffer.drain(..=newline).collect();
                        if line.len() > 8 * 1024 * 1024 {
                            connection_valid = false;
                            break;
                        }
                        let Ok(record) = serde_json::from_slice::<Value>(&line[..line.len() - 1])
                        else {
                            connection_valid = false;
                            break;
                        };
                        match phase {
                            0 if record["type"] == "authenticated"
                                && record["protocolVersion"] == 1 =>
                            {
                                phase = 1;
                                log::info!(
                                    "event=pi.bridge_authenticated session_id={} shell_id={}",
                                    session_id.0,
                                    shell_id.0
                                );
                            }
                            1 if record["type"] == "hello" && record["protocolVersion"] == 1 => {
                                let identity = &record["identity"];
                                let file = session_file.to_string_lossy();
                                let cwd = identity["cwd"].as_str();
                                let expected_cwd = initial_pwd.to_string_lossy();
                                let session_matches = identity["axoSessionId"] == session_uuid;
                                let pane_matches = identity["axoPaneId"] == pane_id;
                                let file_matches =
                                    identity["sessionFile"].as_str() == Some(file.as_ref());
                                let process_matches =
                                    identity["processId"].as_u64() == Some(process_id as u64);
                                let cwd_matches = cwd == Some(expected_cwd.as_ref());
                                let exact = session_matches
                                    && pane_matches
                                    && file_matches
                                    && process_matches
                                    && cwd_matches;
                                let Some(id) = identity["piSessionId"]
                                    .as_str()
                                    .filter(|id| !id.is_empty() && id.len() <= 128)
                                else {
                                    log::warn!(
                                        "event=pi.binding_rejected session_id={} shell_id={} reason=invalid_pi_session_id",
                                        session_id.0,
                                        shell_id.0
                                    );
                                    connection_valid = false;
                                    break;
                                };
                                if !exact {
                                    log::warn!(
                                        "event=pi.binding_rejected session_id={} shell_id={} session_match={} pane_match={} file_match={} process_match={} cwd_match={}",
                                        session_id.0,
                                        shell_id.0,
                                        session_matches,
                                        pane_matches,
                                        file_matches,
                                        process_matches,
                                        cwd_matches
                                    );
                                    connection_valid = false;
                                    break;
                                }
                                pi_session_id = Some(id.to_owned());
                                if let Some(owner) = manager.upgrade() {
                                    if owner
                                        .persist_pi_session_id(binding, &session_uuid, id)
                                        .and_then(|()| owner.set_pi_connection(binding, true))
                                        .is_err()
                                    {
                                        connection_valid = false;
                                        break;
                                    }
                                } else {
                                    return;
                                }
                                phase = 2;
                                log::info!(
                                    "event=pi.session_binding_verified session_id={} shell_id={}",
                                    session_id.0,
                                    shell_id.0
                                );
                            }
                            2 if record["type"] == "event" => {
                                let Some(owner) = manager.upgrade() else {
                                    return;
                                };
                                let Some(stream_id) =
                                    record["streamId"].as_str().filter(|id| is_uuid_string(id))
                                else {
                                    connection_valid = false;
                                    break;
                                };
                                let Some(sequence) =
                                    record["sequence"].as_u64().filter(|sequence| {
                                        *sequence > last_sequence
                                            && *sequence <= 9_007_199_254_740_991
                                    })
                                else {
                                    connection_valid = false;
                                    break;
                                };
                                let Some(name) = record["name"].as_str().filter(|name| {
                                    !name.is_empty()
                                        && name.len() <= 128
                                        && !name.chars().any(char::is_control)
                                }) else {
                                    connection_valid = false;
                                    break;
                                };
                                let data = &record["data"];
                                if serde_json::to_vec(data)
                                    .map(|encoded| encoded.len() > 60_000)
                                    .unwrap_or(true)
                                {
                                    connection_valid = false;
                                    break;
                                }
                                if active_stream_id
                                    .as_deref()
                                    .is_some_and(|active| active != stream_id)
                                {
                                    connection_valid = false;
                                    break;
                                }
                                active_stream_id = Some(stream_id.to_owned());
                                last_sequence = sequence;
                                if name == "session.resume.requested" {
                                    let target_session_file = data
                                        .as_object()
                                        .filter(|record| record.len() == 1)
                                        .and_then(|record| record.get("targetSessionFile"))
                                        .and_then(Value::as_str);
                                    let Some(target_session_file) = target_session_file else {
                                        log::warn!(
                                            "event=session.pi_resume_rejected session_id={} shell_id={} reason=invalid_request",
                                            session_id.0,
                                            shell_id.0
                                        );
                                        continue;
                                    };
                                    if let Err(error) = owner
                                        .resume_archived_pi_session(binding, target_session_file)
                                    {
                                        log::warn!(
                                            "event=session.pi_resume_rejected session_id={} shell_id={} error_kind={:?}",
                                            session_id.0,
                                            shell_id.0,
                                            error.kind()
                                        );
                                    }
                                    continue;
                                }
                                if !matches!(owner.observe_pi_event(binding, name, data), Ok(true))
                                {
                                    connection_valid = false;
                                    break;
                                }
                                owner.publish_event(json!({
                                    "type": "pi.event",
                                    "sessionId": session_id.0,
                                    "piSessionId": pi_session_id.as_deref().unwrap_or(""),
                                    "streamId": stream_id,
                                    "sequence": sequence,
                                    "name": name,
                                    "data": data,
                                }));
                            }
                            _ => {
                                log::warn!(
                                    "event=pi.bridge_protocol_rejected session_id={} shell_id={} phase={}",
                                    session_id.0,
                                    shell_id.0,
                                    phase
                                );
                                connection_valid = false;
                                break;
                            }
                        }
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                            | io::ErrorKind::Interrupted
                    ) =>
                {
                    continue;
                }
                Err(_) => break,
            }
        }
        if phase == 2
            && let Some(owner) = manager.upgrade()
        {
            let _ = owner.set_pi_connection(binding, false);
        }
        if !connection_valid {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn write_json_line(stream: &mut UnixStream, value: &Value) -> io::Result<()> {
    let mut encoded = serde_json::to_vec(value).map_err(io::Error::other)?;
    encoded.push(b'\n');
    stream.write_all(&encoded)
}

struct ShellCleanup(RunningShell);

impl Drop for ShellCleanup {
    fn drop(&mut self) {
        process::stop(&mut self.0.child);
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
    let id = match attach::read_request(&mut stream) {
        Ok(id) => ShellId(id),
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
                id.0,
                error.kind()
            );
            if let Err(write_error) = attach::write_rejection(&mut stream, attach_rejection(&error))
            {
                log::debug!(
                    "event=session.attach_rejection_write_failed shell_id={} error_kind={:?}",
                    id.0,
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
        manager.publish_shell_activity(session_id, id, "attached");
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
            session_id.0,
            id.0,
            phase,
            replay.len(),
            started_at.elapsed().as_millis(),
            error.kind()
        );
        return;
    }
    log::info!(
        "event=session.attach_ready session_id={} shell_id={} replay_bytes={} elapsed_ms={}",
        session_id.0,
        id.0,
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
        session_id.0,
        id.0,
        reason,
        delivered,
        started_at.elapsed().as_millis()
    );
}

fn parse_session_id(params: Params) -> Result<SessionId, RpcError> {
    let value: Value = params
        .parse()
        .map_err(|_| invalid_params("expected {sessionId}"))?;
    let id = value
        .get("sessionId")
        .and_then(Value::as_i64)
        .filter(|id| *id > 0)
        .ok_or_else(|| invalid_params("sessionId must be a positive integer"))?;
    Ok(SessionId(id))
}

fn parse_shell_ids(params: Params) -> Result<(SessionId, ShellId), RpcError> {
    let value: Value = params
        .parse()
        .map_err(|_| invalid_params("expected {sessionId, shellId}"))?;
    let session_id = value
        .get("sessionId")
        .and_then(Value::as_i64)
        .filter(|id| *id > 0)
        .ok_or_else(|| invalid_params("sessionId must be a positive integer"))?;
    let shell_id = value
        .get("shellId")
        .and_then(Value::as_i64)
        .filter(|id| *id > 0)
        .ok_or_else(|| invalid_params("shellId must be a positive integer"))?;
    parse_session_shell_ids(session_id, shell_id)
}

fn parse_session_shell_ids(
    session_id: i64,
    shell_id: i64,
) -> Result<(SessionId, ShellId), RpcError> {
    if session_id <= 0 {
        return Err(invalid_params("sessionId must be a positive integer"));
    }
    if shell_id <= 0 {
        return Err(invalid_params("shellId must be a positive integer"));
    }
    Ok((SessionId(session_id), ShellId(shell_id)))
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
        session_id.0,
        shell_id.0,
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
        session_id.0,
        shell_id.0,
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

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
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
            process::stop(&mut self.0.child);
        }
    }

    struct LifecycleFixture {
        directory: PathBuf,
        manager: Arc<SessionManager>,
    }

    impl LifecycleFixture {
        fn new() -> Self {
            let directory =
                PathBuf::from("/tmp").join(format!("axo-life-{}", create_uuid_v4().unwrap()));
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
        socket: PiBridgeSocketPath,
        token: String,
    }

    impl PiRecoveryFixture {
        fn new() -> Self {
            let lifecycle = LifecycleFixture::new();
            let manager = &lifecycle.manager;
            let session_uuid = create_uuid_v4().unwrap();
            let pane_id = create_uuid_v4().unwrap();
            let token = create_uuid_v4().unwrap();
            let file = manager
                .pi_session_directory
                .join(format!("{session_uuid}.jsonl"));
            let socket =
                PiBridgeSocketPath::for_session(&manager.pi_session_directory, &session_uuid)
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
                    params![lifecycle.directory.to_string_lossy(), unix_timestamp(), session_uuid, file.to_string_lossy(), socket.database_value()],
                ).unwrap();
                let session_id = SessionId(state.database.last_insert_rowid());
                state.database.execute(
                    "INSERT INTO shells (session_id, initial_pwd, state, created_at, role, pane_id) VALUES (?1, ?2, 'open', ?3, 'pi', ?4)",
                    params![session_id.0, lifecycle.directory.to_string_lossy(), unix_timestamp(), pane_id],
                ).unwrap();
                let shell_id = ShellId(state.database.last_insert_rowid());
                state
                    .database
                    .execute(
                        "UPDATE sessions SET layout_json = ?1 WHERE id = ?2",
                        params![
                            serde_json::to_string(&SessionLayout::Pane {
                                shell_id: shell_id.0
                            })
                            .unwrap(),
                            session_id.0
                        ],
                    )
                    .unwrap();
                store_pi_bridge_token(&state.database, &session_uuid, &token).unwrap();
                state.unavailable_pi_shells.insert(
                    shell_id,
                    UnavailablePiShell {
                        session_id,
                        pane_id: Some(pane_id.clone()),
                        initial_pwd: lifecycle.directory.clone(),
                        recovery_id: None,
                    },
                );
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
            policy: PiTakeoverPolicy,
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
            let auth = read_pi_bridge_record(&mut reader).unwrap();
            assert_eq!(auth["token"], self.token);
            (worker, reader)
        }

        fn accept_shutdown(&self, reader: &mut BufReader<UnixStream>, process_id: u32) {
            write_json_line(
                reader.get_mut(),
                &json!({ "type": "authenticated", "protocolVersion": 1 }),
            )
            .unwrap();
            write_json_line(reader.get_mut(), &json!({
                "type": "hello", "protocolVersion": 1,
                "identity": { "axoSessionId": self.session_uuid, "axoPaneId": self.pane_id,
                    "sessionFile": self.file, "cwd": self.lifecycle.directory, "processId": process_id }
            })).unwrap();
            let command = read_pi_bridge_record(reader).unwrap();
            assert_eq!(command["type"], "command");
            write_json_line(reader.get_mut(), &json!({
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
        let lock = acquire_pi_writer_lock(&fixture.file).unwrap();
        let (worker, _bridge) = fixture.begin_recovery(PiTakeoverPolicy::PreserveExistingProcess);
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
                PiTakeoverPolicy::ExplicitUserRestart,
            )
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(start.elapsed() < Duration::from_secs(1));
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        let state = manager.lock_state().unwrap();
        assert_eq!(
            state.unavailable_pi_shells[&fixture.shell_id].recovery_id,
            None
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
            PiTakeoverPolicy::PreserveExistingProcess,
            PiTakeoverPolicy::ExplicitUserRestart,
        ] {
            let fixture = PiRecoveryFixture::new();
            let lock = acquire_pi_writer_lock(&fixture.file).unwrap();
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
            assert!(!state.running.contains_key(&fixture.shell_id));
            assert!(!state.unavailable_pi_shells.contains_key(&fixture.shell_id));
            let lifecycle: String = state
                .database
                .query_row(
                    "SELECT state FROM sessions WHERE id = ?1",
                    params![fixture.session_id.0],
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
        let lock = acquire_pi_writer_lock(&fixture.file).unwrap();
        let (worker, _bridge) = fixture.begin_recovery(PiTakeoverPolicy::PreserveExistingProcess);
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
                .running
                .is_empty()
        );
        assert_eq!(
            fixture
                .lifecycle
                .manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    PiTakeoverPolicy::ExplicitUserRestart
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
                    PiTakeoverPolicy::PreserveExistingProcess
                )
                .unwrap_err()
                .kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(
            manager.lock_state().unwrap().unavailable_pi_shells[&fixture.shell_id].recovery_id,
            None
        );
        // Concurrent forked fixture children may briefly hold CLOEXEC copies
        // until exec. Bound the wait rather than requiring instantaneous release.
        drop(wait_for_pi_writer_lock(&fixture.file, Duration::from_secs(1), &|| Ok(())).unwrap());
        manager.lock_state().unwrap().agent_command = original_command;
        let recovered = manager
            .restart_unavailable_pi(
                fixture.session_id,
                fixture.shell_id,
                PiTakeoverPolicy::PreserveExistingProcess,
            )
            .unwrap();
        assert!(
            recovered
                .shells
                .iter()
                .any(|shell| shell.id == fixture.shell_id && shell.available)
        );
        assert_eq!(
            acquire_pi_writer_lock(&fixture.file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        fixture.assert_preserved();
    }

    #[test]
    fn cancelled_pi_launch_is_cleaned_up_instead_of_resurrecting_the_pane() {
        let fixture = PiRecoveryFixture::new();
        let manager = &fixture.lifecycle.manager;
        let recovery_id = RuntimeId::new();
        let pending = {
            let mut state = manager.lock_state().unwrap();
            state
                .unavailable_pi_shells
                .get_mut(&fixture.shell_id)
                .unwrap()
                .recovery_id = Some(recovery_id);
            spawn_new_pi(
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
                },
            )
            .unwrap()
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
                .running
                .contains_key(&fixture.shell_id)
        );
        // Both parent and child lock copies must be released by cleanup. Other
        // concurrent fixture forks can retain CLOEXEC copies briefly until exec.
        drop(wait_for_pi_writer_lock(&fixture.file, Duration::from_secs(1), &|| Ok(())).unwrap());
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
                    PiTakeoverPolicy::PreserveExistingProcess
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
            params![unix_timestamp(), create_uuid_v4().unwrap(), fixture.file.to_string_lossy()],
        ).unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    PiTakeoverPolicy::ExplicitUserRestart
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
        let lock = acquire_pi_writer_lock(&fixture.file).unwrap();
        let (worker, mut bridge) =
            fixture.begin_recovery(PiTakeoverPolicy::PreserveExistingProcess);
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
        assert!(!state.running.contains_key(&fixture.shell_id));
        assert_eq!(
            state.unavailable_pi_shells[&fixture.shell_id].recovery_id,
            None
        );
        assert_eq!(
            load_pi_bridge_token(&state.database, &fixture.session_uuid)
                .unwrap()
                .as_deref(),
            Some(fixture.token.as_str())
        );
    }

    #[test]
    fn pi_writer_lock_rejects_symlink_without_touching_its_target() {
        let fixture = PiRecoveryFixture::new();
        let target = fixture.lifecycle.directory.join("not-a-lock");
        fs::write(&target, b"untouched lock target\n").unwrap();
        std::os::unix::fs::symlink(&target, fixture.file.with_extension("jsonl.lock")).unwrap();
        assert!(acquire_pi_writer_lock(&fixture.file).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"untouched lock target\n");
        fixture.assert_preserved();
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
                    PiTakeoverPolicy::PreserveExistingProcess
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
                params![outside.to_string_lossy(), fixture.session_id.0],
            )
            .unwrap();
        assert_eq!(
            manager
                .restart_unavailable_pi(
                    fixture.session_id,
                    fixture.shell_id,
                    PiTakeoverPolicy::ExplicitUserRestart
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
        let lock = acquire_pi_writer_lock(&fixture.file).unwrap();
        manager
            .lock_state()
            .unwrap()
            .unavailable_pi_shells
            .remove(&fixture.shell_id);
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
        assert!(home.shells.iter().any(|shell| shell.available));
        write_json_line(bridge.get_mut(), &json!({ "type": "protocolError" })).unwrap();
        worker.join().unwrap().unwrap();
        let sessions = manager.list_sessions().unwrap();
        let target = sessions
            .iter()
            .find(|session| session.id == fixture.session_id)
            .unwrap();
        assert!(!target.shells[0].available);
        assert!(sessions.iter().any(|session| session.id == home.id));
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn restoring_sessions_does_not_replace_an_existing_runtime() {
        let fixture = LifecycleFixture::new();
        let session = fixture.manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let runtime = fixture.manager.lock_state().unwrap().running[&shell_id].runtime_id;
        fixture.manager.restore_open_sessions().unwrap();
        assert_eq!(
            fixture.manager.lock_state().unwrap().running[&shell_id].runtime_id,
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
            let shell = state.running.get_mut(&home.shells[0].id).unwrap();
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
        let new_id = RuntimeId::new();
        let old = PiRecoveryLease {
            manager,
            session_id: fixture.session_id,
            shell_id: fixture.shell_id,
            recovery_id: old_id,
        };
        manager
            .lock_state()
            .unwrap()
            .unavailable_pi_shells
            .get_mut(&fixture.shell_id)
            .unwrap()
            .recovery_id = Some(new_id);
        assert_eq!(
            old.ensure_current().unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
        drop(old);
        assert_eq!(
            manager.lock_state().unwrap().unavailable_pi_shells[&fixture.shell_id].recovery_id,
            Some(new_id)
        );
    }

    #[test]
    fn recovery_connect_is_bounded_when_the_accept_queue_is_full() {
        let fixture = LifecycleFixture::new();
        let path = fixture.directory.join("full.sock");
        let listener = UnixListener::bind(&path).unwrap();
        // SAFETY: reset the backlog only on this test's owned listener.
        assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 1) }, 0);
        let mut connections = Vec::new();
        let mut full = false;
        let start = Instant::now();
        for _ in 0..16 {
            match connect_pi_socket_until(
                &path,
                Instant::now() + Duration::from_millis(50),
                &|| Ok(()),
            ) {
                Ok(stream) => connections.push(stream),
                Err(error) => {
                    assert!(
                        matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock
                                | io::ErrorKind::TimedOut
                                | io::ErrorKind::ConnectionRefused
                        ),
                        "unexpected full-backlog error: {error}"
                    );
                    full = true;
                    break;
                }
            }
        }
        assert!(
            !connections.is_empty(),
            "fixture listener never accepted a connection"
        );
        assert!(full, "fixture never filled its bounded accept queue");
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(
            connect_pi_socket_until(&path, Instant::now() + Duration::from_secs(2), &|| Err(
                io::Error::from(io::ErrorKind::Interrupted)
            ))
            .unwrap_err()
            .kind(),
            io::ErrorKind::Interrupted
        );
    }

    #[test]
    fn recovery_deadline_bounds_a_dribbling_partial_record() {
        let (mut writer, reader) = UnixStream::pair().unwrap();
        let producer = thread::spawn(move || {
            for _ in 0..100 {
                if writer.write_all(b" ").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        });
        let mut reader = BufReader::new(reader);
        let start = Instant::now();
        let error = read_pi_bridge_record_until(
            &mut reader,
            start + Duration::from_millis(150),
            &|| Ok(()),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(reader);
        producer.join().unwrap();
    }

    #[test]
    fn recovery_deadline_bounds_a_stream_of_unrelated_events() {
        let (mut writer, reader) = UnixStream::pair().unwrap();
        let producer = thread::spawn(move || {
            for _ in 0..100 {
                if write_json_line(&mut writer, &json!({ "type": "event" })).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        });
        let mut reader = BufReader::new(reader);
        let start = Instant::now();
        let deadline = start + Duration::from_millis(150);
        loop {
            match read_pi_bridge_record_until(&mut reader, deadline, &|| Ok(())) {
                Ok(record) => assert_eq!(record["type"], "event"),
                Err(error) => {
                    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
                    break;
                }
            }
        }
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(reader);
        producer.join().unwrap();
    }

    #[test]
    fn stale_runtime_callbacks_cannot_mutate_a_replacement_pi() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let old_runtime = manager.lock_state().unwrap().running[&shell_id].runtime_id;
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
        process::stop(&mut old.child);

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
        assert_eq!(state.running[&shell_id].attachments, 1);
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
            let child = &mut state.running.get_mut(&uncertain_shell).unwrap().child;
            child.kill().unwrap();
            let mut status = 0;
            // SAFETY: this fixture owns the still-unreaped child. Reaping outside
            // Child deliberately simulates lost wait ownership (ECHILD).
            assert_eq!(
                unsafe { libc::waitpid(child.id() as libc::pid_t, &mut status, 0) },
                child.id() as libc::pid_t
            );
            let child = &mut state.running.get_mut(&exited_shell).unwrap().child;
            child.kill().unwrap();
            assert!(wait_for_shell_exit(child, Duration::from_secs(2)).unwrap());
        }
        manager.reap_exited_sessions().unwrap();
        manager.reap_exited_sessions().unwrap();
        let state = manager.lock_state().unwrap();
        assert!(state.running[&uncertain_shell].wait_error_reported);
        assert!(!state.running.contains_key(&exited_shell));
        let uncertain_state: String = state
            .database
            .query_row(
                "SELECT state FROM sessions WHERE id = ?",
                params![uncertain.id.0],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(uncertain_state, "open");
        let exited_state: String = state
            .database
            .query_row(
                "SELECT state FROM sessions WHERE id = ?",
                params![exited.id.0],
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
            let running = &state.running[&shell_id];
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
                && state.running.is_empty()
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
        writeln!(client, "{}", shell_id.0).unwrap();
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
        assert!(manager.lock_state().unwrap().running.is_empty());
        assert_eq!(Arc::strong_count(manager), 1);
    }

    #[test]
    fn a_stalled_client_is_released_without_blocking_the_shell() {
        let fixture = LifecycleFixture::new();
        let manager = &fixture.manager;
        manager.stop_workers.store(false, Ordering::Relaxed);
        let session = manager.list_sessions().unwrap().remove(0);
        let shell_id = session.shells[0].id;
        let output = Arc::clone(&manager.lock_state().unwrap().running[&shell_id].output);
        let (mut client, server) = UnixStream::pair().unwrap();
        writeln!(client, "{}", shell_id.0).unwrap();
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
            manager.lock_state().unwrap().running[&shell_id].attachments,
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
        let session_uuid = create_uuid_v4().unwrap();
        let pane_id = create_uuid_v4().unwrap();
        let file = fixture
            .manager
            .pi_session_directory
            .join(format!("{session_uuid}.jsonl"));
        fs::write(&file, b"preserved history").unwrap();
        let socket =
            PiBridgeSocketPath::for_session(&fixture.manager.pi_session_directory, &session_uuid)
                .unwrap();
        let mut pi = {
            let state = fixture.manager.lock_state().unwrap();
            spawn_new_pi(
                &state.database,
                &PiLaunchRequest {
                    agent_command: agent.clone(),
                    session_id: SessionId(900),
                    initial_pwd: fixture.directory.clone(),
                    session_file: file.clone(),
                    bridge_socket: socket.clone(),
                    session_uuid: session_uuid.clone(),
                    pane_id: pane_id.clone(),
                    previous_token: None,
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
            acquire_pi_writer_lock(&file).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        process::stop(&mut child.0.child);
        let recovered = acquire_pi_writer_lock(&file).unwrap();
        assert!(unrelated.0.try_wait().unwrap().is_none());
        assert_eq!(fs::read(&file).unwrap(), b"preserved history");
        drop(recovered);
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
            std::env::temp_dir().join(format!("axo-host-identity-{}", create_uuid_v4().unwrap()));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("axo.db");

        let first_host_id;
        let first_generation = create_uuid_v4().unwrap();
        {
            let mut database = Connection::open(&path).unwrap();
            initialize_database(&mut database).unwrap();
            first_host_id = load_or_create_host_id(&database).unwrap();
        }

        let second_generation = create_uuid_v4().unwrap();
        let second_host_id;
        {
            let mut database = Connection::open(&path).unwrap();
            initialize_database(&mut database).unwrap();
            second_host_id = load_or_create_host_id(&database).unwrap();
        }

        assert_eq!(first_host_id, second_host_id);
        assert_ne!(first_generation, second_generation);
        assert!(is_uuid_string(&first_host_id));
        assert_eq!(first_host_id.as_bytes()[14], b'4');
        assert!(matches!(
            first_host_id.as_bytes()[19],
            b'8' | b'9' | b'a' | b'b'
        ));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn local_subscriptions_signal_lag_filter_output_and_expire() {
        let directory = PathBuf::from("/tmp").join(format!("axos-{}", create_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        let manager = SessionManager::open(&directory).unwrap();
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

        let terminal_output = json!({ "type": "terminal.output", "sessionId": 1, "shellId": 1 });
        manager.publish_event(terminal_output);
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
                .unwrap()["type"],
            "terminal.output"
        );

        manager
            .publish_event(json!({ "type": "pi.event", "sessionId": 1, "name": "message_update" }));
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
                .unwrap()["type"],
            "pi.event"
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
            assert_eq!(woken["type"], "workspace.changed");
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
        assert_eq!(batch[0]["workspaceId"], "a");
        assert_eq!(batch[1]["workspaceId"], "b");
        drain(&catalog);
        drain(&output);

        manager.publish_workspace_changed("workspace");
        let changed = manager
            .next_event(&catalog, Duration::from_millis(1))
            .unwrap()
            .unwrap();
        assert_eq!(changed["type"], "workspace.changed");
        assert_eq!(changed["workspaceId"], "workspace");
        drain(&output);

        for _ in 0..=MAX_QUEUED_EVENTS_PER_SUBSCRIPTION {
            manager.publish_workspace_changed("flood");
        }
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap()
                .unwrap()["type"],
            "subscription.lagged",
            "a full queue must be reported, never silently gapped"
        );
        assert_eq!(
            manager
                .next_event(&catalog, Duration::from_millis(1))
                .unwrap(),
            None
        );
        drain(&output);

        manager.request_session_focus(SessionId(5)).unwrap();
        let focus = manager
            .next_event(&catalog, Duration::from_millis(1))
            .unwrap()
            .unwrap();
        assert_eq!(focus["type"], "session.focus");
        assert_eq!(focus["sessionId"], 5);
        assert_eq!(
            manager.take_pending_resume_focus().unwrap(),
            Some(SessionId(5))
        );
        *manager.pending_resume_focus.lock().unwrap() = Some((
            SessionId(6),
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
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", create_uuid_v4().unwrap()));
        fs::create_dir_all(&directory).unwrap();
        let manager = SessionManager::open(&directory).unwrap();
        let workspace_id = create_uuid_v4().unwrap();
        let session_uuid = create_uuid_v4().unwrap();
        let session_id = SessionId(702);
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
                        session_id.0,
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
        assert_eq!(renamed_session.to_json()["manualName"], "Sidebar label");

        let renamed_workspace = manager
            .rename_workspace(&workspace_id, "Renamed Workspace")
            .unwrap();
        assert_eq!(renamed_workspace["name"], "Renamed Workspace");
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
                params![session_id.0],
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
    fn remote_session_snapshots_exclude_local_process_and_filesystem_details() {
        let session = SessionMetadata {
            id: SessionId(9),
            session_uuid: "a0b7d77a-5551-4cbc-8dfc-75b2d466dece".to_owned(),
            pi_session_file: Some(PathBuf::from("/private/path/transcript.jsonl")),
            pi_session_id: Some("pi-session-example".to_owned()),
            workspace_id: Some("a0b7d77a-5551-4cbc-8dfc-75b2d466dece".to_owned()),
            workspace_name: Some("private".to_owned()),
            name: "Session 1".to_owned(),
            manual_name: Some("Manual label".to_owned()),
            emoji: Some("🦀".to_owned()),
            status: SessionStatus::Ready,
            initial_pwd: PathBuf::from("/private/path"),
            shells: vec![ShellMetadata {
                id: ShellId(12),
                pane_id: None,
                role: PaneRole::Terminal,
                process_id: 1234,
                initial_pwd: PathBuf::from("/private/path"),
                slave_device: "/dev/ttys001".to_owned(),
                attach_socket_path: PathBuf::from("/private/path/attach.sock"),
                available: true,
                availability_reason: None,
            }],
            layout: Some(SessionLayout::Pane { shell_id: 12 }),
        };
        let remote = session.to_remote_json(
            "18355f00-95fd-4c93-8586-a71a8a52bf73",
            "2026-10-16T00:00:00Z",
        );
        let object = remote.as_object().unwrap();
        assert_eq!(object.len(), 12);
        assert_eq!(object["sessionId"], 9);
        assert_eq!(
            object["sessionUuid"],
            "a0b7d77a-5551-4cbc-8dfc-75b2d466dece"
        );
        assert_eq!(object["workspaceName"], "private");
        assert_eq!(object["emoji"], "🦀");
        assert_eq!(object["status"], "ready");
        assert_eq!(object["hasAgent"], false);
        assert_eq!(object["shells"], json!([{ "shellId": 12 }]));
        let serialized = remote.to_string();
        assert!(!serialized.contains("/private/path"));
        assert!(!serialized.contains("/dev/ttys001"));
        assert!(!serialized.contains("1234"));
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
        let session_uuid = create_uuid_v4().unwrap();
        let first_token = create_uuid_v4().unwrap();
        let second_token = create_uuid_v4().unwrap();

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
    fn pi_bridge_socket_path_is_stable_and_within_the_shared_byte_limit() {
        let session_uuid = "82cfd1e8-1cc6-4473-a16d-6f0e77476311";
        let exact_limit_directory = PathBuf::from(format!("/{}", "d".repeat(57)));
        let exact_limit =
            PiBridgeSocketPath::for_session(&exact_limit_directory, session_uuid).unwrap();
        assert_eq!(
            exact_limit.0.as_os_str().as_encoded_bytes().len(),
            MAX_PI_BRIDGE_SOCKET_PATH_BYTES
        );

        let too_long_directory = PathBuf::from(format!("/{}", "d".repeat(58)));
        let fallback = PiBridgeSocketPath::for_session(&too_long_directory, session_uuid).unwrap();
        assert_eq!(
            fallback.as_path(),
            Path::new(&format!("/tmp/axo-pi-{session_uuid}.sock"))
        );
        assert!(
            fallback.as_path().as_os_str().as_encoded_bytes().len()
                <= MAX_PI_BRIDGE_SOCKET_PATH_BYTES
        );

        assert!(PiBridgeSocketPath::parse(PathBuf::from(format!("/{}", "x".repeat(100)))).is_err());
        assert!(PiBridgeSocketPath::parse(PathBuf::from("relative.sock")).is_err());
        assert!(PiBridgeSocketPath::for_session(&too_long_directory, "not-a-uuid").is_err());
    }

    #[test]
    fn authenticated_pi_process_ids_reject_invalid_or_self_targets() {
        for value in [
            json!(0),
            json!(1),
            json!(-1),
            json!(u64::MAX),
            json!(std::process::id()),
        ] {
            assert!(VerifiedPiProcessId::parse(&value).is_err());
        }
    }

    #[test]
    fn pi_lock_owner_pid_parser_is_bounded_and_rejects_unsafe_values() {
        let ids = (0..MAX_PI_LOCK_OWNERS)
            .map(|index| format!("{}\n", 1_000_000 + index))
            .collect::<String>();
        assert_eq!(
            parse_pi_lock_process_ids(ids.as_bytes()).unwrap().len(),
            MAX_PI_LOCK_OWNERS
        );
        assert_eq!(
            parse_pi_lock_process_ids(b"2000000\n2000000\n")
                .unwrap()
                .len(),
            1
        );
        let too_many = format!("{ids}2000000\n");
        assert_eq!(
            parse_pi_lock_process_ids(too_many.as_bytes())
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        let self_id = std::process::id().to_string();
        for input in [
            b"0".as_slice(),
            b"1",
            b"-2",
            b"2147483648",
            b"pid",
            b"2\n\n3",
            b"2\0",
            &[0xff],
            self_id.as_bytes(),
        ] {
            assert_eq!(
                parse_pi_lock_process_ids(input).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
        assert_eq!(
            parse_pi_lock_process_ids(b"").unwrap_err().kind(),
            io::ErrorKind::NotFound
        );
        assert_eq!(
            parse_pi_lock_process_ids(&vec![
                b'2';
                process_inspection::MAX_INSPECTION_OUTPUT_BYTES + 1
            ])
            .unwrap_err()
            .kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn pi_lock_owner_record_parser_requires_one_complete_process_record() {
        let owner = parse_pi_lock_owner(123, b"  501  123 /fixture/My Tools/pi\n").unwrap();
        assert_eq!(owner.user_id, 501);
        assert_eq!(owner.process_group_id, 123);
        assert_eq!(
            Path::new(&owner.command).file_name(),
            Some(OsStr::new("pi"))
        );
        for input in [
            b"".as_slice(),
            b"501",
            b"501 123",
            b"x 123 pi",
            b"501 -1 pi",
            b"501 0 pi",
            b"501 1 pi",
            b"501 123 pi\n501 123 other",
            b"501 123 pi\0",
            &[0xff],
        ] {
            assert_eq!(
                parse_pi_lock_owner(123, input).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
        assert!(
            parse_pi_lock_owner(
                123,
                &vec![b' '; process_inspection::MAX_INSPECTION_OUTPUT_BYTES + 1]
            )
            .is_err()
        );
    }

    #[test]
    fn pi_lock_owner_inspection_cancellation_cannot_authorize_takeover() {
        let fixture = PiRecoveryFixture::new();
        let lock = acquire_pi_writer_lock(&fixture.file).unwrap();
        let checks = AtomicUsize::new(0);
        let error = pi_writer_process_id_from_lock(&fixture.file, &|| {
            if checks.fetch_add(1, Ordering::Relaxed) == 0 {
                Ok(())
            } else {
                Err(io::Error::from(io::ErrorKind::Interrupted))
            }
        })
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert!(checks.load(Ordering::Relaxed) >= 2);
        assert_eq!(
            fixture
                .lifecycle
                .manager
                .lock_state()
                .unwrap()
                .unavailable_pi_shells[&fixture.shell_id]
                .recovery_id,
            None
        );
        drop(lock);
        fixture.assert_preserved();
    }

    #[test]
    fn pi_lock_fallback_requires_one_user_owned_pi_process_group() {
        let owners = [
            PiLockOwner {
                process_id: 42,
                user_id: 501,
                process_group_id: 42,
                command: "/opt/homebrew/bin/pi".to_owned(),
            },
            PiLockOwner {
                process_id: 43,
                user_id: 501,
                process_group_id: 42,
                command: "node".to_owned(),
            },
        ];
        assert_eq!(verified_pi_lock_owner(&owners, 501).unwrap().0, 42);

        let mut foreign_group = owners.clone();
        foreign_group[1].process_group_id = 44;
        assert!(verified_pi_lock_owner(&foreign_group, 501).is_err());

        let mut foreign_user = owners.clone();
        foreign_user[0].user_id = 502;
        assert!(verified_pi_lock_owner(&foreign_user, 501).is_err());

        let mut non_pi_leader = owners;
        non_pi_leader[0].command = "shell".to_owned();
        assert!(verified_pi_lock_owner(&non_pi_leader, 501).is_err());
    }

    #[test]
    fn bridge_fallback_is_limited_to_unavailable_transport_errors() {
        for kind in [
            io::ErrorKind::ConnectionRefused,
            io::ErrorKind::TimedOut,
            io::ErrorKind::WouldBlock,
            io::ErrorKind::UnexpectedEof,
            io::ErrorKind::BrokenPipe,
            io::ErrorKind::ConnectionReset,
            io::ErrorKind::NotFound,
        ] {
            assert!(pi_bridge_unavailable_for_restart(&io::Error::from(kind)));
        }
        assert!(!pi_bridge_unavailable_for_restart(&io::Error::from(
            io::ErrorKind::PermissionDenied
        )));
        assert!(!pi_bridge_unavailable_for_restart(&io::Error::from(
            io::ErrorKind::InvalidData
        )));
    }

    #[test]
    fn automatic_pi_restart_preserves_busy_pi_and_explicit_restart_preserves_history() {
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", create_uuid_v4().unwrap()));
        let server_directory = directory.join("server");
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory).unwrap();

        let session_id = SessionId(701);
        let shell_id = ShellId(801);
        let session_uuid = create_uuid_v4().unwrap();
        let pane_id = create_uuid_v4().unwrap();
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
                    session_id.0,
                    unix_timestamp(),
                    serde_json::to_string(&SessionLayout::Pane { shell_id: shell_id.0 }).unwrap(),
                    session_uuid,
                    session_file.to_string_lossy(),
                ],
            )
            .unwrap();
        database
            .execute(
                "INSERT INTO shells (id, session_id, initial_pwd, state, created_at, role, pane_id)
                 VALUES (?1, ?2, '/tmp', 'open', ?3, 'pi', ?4)",
                params![shell_id.0, session_id.0, unix_timestamp(), pane_id],
            )
            .unwrap();
        let bridge_token = create_uuid_v4().unwrap();
        store_pi_bridge_token(&database, &session_uuid, &bridge_token).unwrap();
        drop(database);

        let bridge_socket =
            PiBridgeSocketPath::for_session(&pi_session_directory, &session_uuid).unwrap();
        drop(UnixListener::bind(bridge_socket.as_path()).unwrap());

        let manager = SessionManager::open(&server_directory).unwrap();
        let stored_bridge_socket: String = manager
            .lock_state()
            .unwrap()
            .database
            .query_row(
                "SELECT pi_bridge_socket_path FROM sessions WHERE id = ?1",
                params![session_id.0],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(PathBuf::from(stored_bridge_socket), bridge_socket.0);
        let sessions = manager.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session_id);
        assert!(matches!(sessions[0].status, SessionStatus::Unavailable));
        assert_eq!(
            sessions[0].layout,
            Some(SessionLayout::Pane {
                shell_id: shell_id.0
            })
        );
        assert_eq!(sessions[0].shells.len(), 1);
        assert_eq!(sessions[0].shells[0].id, shell_id);
        assert!(!sessions[0].shells[0].available);
        assert_eq!(sessions[0].shells[0].process_id, 0);
        assert!(sessions[0].shells[0].availability_reason.is_some());
        assert_eq!(sessions[0].to_json()["shells"][0]["available"], false);
        manager
            .set_layout(
                session_id,
                SessionLayout::Pane {
                    shell_id: shell_id.0,
                },
            )
            .unwrap();
        assert!(
            manager
                .restart_unavailable_pi(
                    session_id,
                    shell_id,
                    PiTakeoverPolicy::PreserveExistingProcess,
                )
                .is_err()
        );
        assert!(old_pi.0.try_wait().unwrap().is_none());

        let restart_error = manager
            .restart_unavailable_pi(session_id, shell_id, PiTakeoverPolicy::ExplicitUserRestart)
            .unwrap_err();
        assert_eq!(restart_error.kind(), io::ErrorKind::PermissionDenied);
        assert!(old_pi.0.try_wait().unwrap().is_none());
        assert!(!manager.list_sessions().unwrap()[0].shells[0].available);

        manager.restore_open_sessions().unwrap();
        assert_eq!(manager.list_sessions().unwrap().len(), 1);
        assert!(!manager.list_sessions().unwrap()[0].shells[0].available);

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
                let authentication = read_pi_bridge_record(&mut reader).unwrap();
                assert_eq!(authentication["token"], handshake_bridge_token);
                write_json_line(
                    reader.get_mut(),
                    &json!({ "type": "authenticated", "protocolVersion": 1 }),
                )
                .unwrap();
                write_json_line(
                    reader.get_mut(),
                    &json!({
                        "type": "hello",
                        "protocolVersion": 1,
                        "identity": {
                            "axoSessionId": handshake_session_uuid,
                            "axoPaneId": handshake_pane_id,
                            "sessionFile": handshake_session_file,
                            "cwd": "/tmp",
                            "processId": old_pi_process_id
                        }
                    }),
                )
                .unwrap();
                let shutdown = read_pi_bridge_record(&mut reader).unwrap();
                assert_eq!(shutdown["action"]["kind"], expected_action);
                write_json_line(
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
                PiTakeoverPolicy::PreserveExistingProcess,
            )
            .unwrap_err();
        assert_eq!(automatic_error.kind(), io::ErrorKind::WouldBlock);
        assert!(old_pi.0.try_wait().unwrap().is_none());
        assert!(!manager.list_sessions().unwrap()[0].shells[0].available);

        let restarted = manager
            .restart_unavailable_pi(session_id, shell_id, PiTakeoverPolicy::ExplicitUserRestart)
            .unwrap();
        bridge_server.join().unwrap();
        assert_eq!(restarted.id, session_id);
        assert_eq!(restarted.shells.len(), 1);
        assert_eq!(restarted.shells[0].id, shell_id);
        assert!(restarted.shells[0].available);
        assert!(restarted.shells[0].process_id > 0);
        assert!(manager.list_sessions().unwrap()[0].shells[0].available);
        assert!(old_pi.0.try_wait().unwrap().is_some());
        let terminal_shell = manager.create_shell(session_id).unwrap();
        manager
            .set_layout(
                session_id,
                SessionLayout::Split {
                    id: create_uuid_v4().unwrap(),
                    direction: LayoutDirection::Right,
                    ratio: 0.5,
                    first: Box::new(SessionLayout::Pane {
                        shell_id: shell_id.0,
                    }),
                    second: Box::new(SessionLayout::Pane {
                        shell_id: terminal_shell.id.0,
                    }),
                },
            )
            .unwrap();
        assert_eq!(
            fs::read(&session_file).unwrap(),
            b"preserved Pi transcript\n"
        );

        {
            let mut state = manager.lock_state().unwrap();
            state
                .running
                .get_mut(&shell_id)
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
                    .any(|shell| shell.id == shell_id && !shell.available)
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
                .available
        );
        assert!(
            sessions[0]
                .shells
                .iter()
                .find(|shell| shell.id == terminal_shell.id)
                .unwrap()
                .available
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
                    params![session_id.0],
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
        let directory = PathBuf::from("/tmp").join(format!("axor-{}", create_uuid_v4().unwrap()));
        let server_directory = directory.join("server");
        let pi_session_directory = server_directory.join("pi-sessions");
        fs::create_dir_all(&pi_session_directory).unwrap();
        let database_path = server_directory.join(DATABASE_FILE);
        let session_id = SessionId(901);
        let shell_id = ShellId(902);
        let session_uuid = create_uuid_v4().unwrap();
        let pane_id = create_uuid_v4().unwrap();
        let workspace_id = create_uuid_v4().unwrap();
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
                    session_id.0,
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp(),
                    serde_json::to_string(&SessionLayout::Pane { shell_id: shell_id.0 }).unwrap(),
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
                    shell_id.0,
                    session_id.0,
                    workspace_root_string,
                    unix_timestamp(),
                    unix_timestamp(),
                    pane_id
                ],
            )
            .unwrap();
        drop(database);

        let manager = SessionManager::open(&server_directory).unwrap();
        let fake_pi = directory.join("fake-pi");
        fs::write(&fake_pi, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        fs::set_permissions(&fake_pi, fs::Permissions::from_mode(0o700)).unwrap();
        manager.lock_state().unwrap().agent_command =
            AgentCommand::parse(fake_pi.to_str().unwrap()).unwrap();
        let active_workspace = manager
            .create_workspace(WorkspaceCreateRequest {
                name: "Active Workspace".to_owned(),
                directory_path: PathBuf::from("/tmp").canonicalize().unwrap(),
                directory_bookmark: None,
            })
            .unwrap();
        let requester_session_id = SessionId(active_workspace["session"]["id"].as_i64().unwrap());
        let requester_shell_id = ShellId(
            active_workspace["session"]["shells"][0]["id"]
                .as_i64()
                .unwrap(),
        );
        let requester = PiRuntimeBinding {
            session_id: requester_session_id,
            shell_id: requester_shell_id,
            runtime_id: manager.lock_state().unwrap().running[&requester_shell_id].runtime_id,
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
        assert!(resumed.shells[0].available);
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
                params![requester_session_id.0],
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
        let mut session = spawn_shell(&shell, SessionId(1), &home).unwrap();
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
        process::stop(&mut session.child);
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
}
