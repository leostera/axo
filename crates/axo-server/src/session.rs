use std::collections::{HashMap, HashSet};
use std::ffi::CStr;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, Weak};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use jsonrpc_core::{Error as RpcError, ErrorCode, IoHandler, Params};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const DATABASE_FILE: &str = "axo.db";
const ATTACH_SOCKET_FILE: &str = "attach.sock";
const PTY_ROWS: libc::c_ushort = 24;
const PTY_COLUMNS: libc::c_ushort = 80;
const REAPER_INTERVAL: Duration = Duration::from_millis(100);
const MAX_TERMINAL_OUTPUT_HISTORY_BYTES: usize = 8 * 1024 * 1024;
const ATTACH_REJECTION_MARKER: u64 = u64::MAX;
const MAX_LAYOUT_DEPTH: usize = 64;
const MAX_LAYOUT_NODES: usize = 255;
const MAX_SUBSCRIPTIONS: usize = 64;
const MAX_QUEUED_EVENTS_PER_SUBSCRIPTION: usize = 128;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct SessionId(i64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ShellId(i64);

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
struct SessionSubscribeRequest {
    session_id: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionEventsNextRequest {
    subscription_id: String,
    timeout_ms: u64,
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

#[derive(Debug)]
struct SessionRecord {
    id: SessionId,
    initial_pwd: PathBuf,
    shell_ids: Vec<ShellId>,
}

#[derive(Debug)]
struct RunningShell {
    session_id: SessionId,
    initial_pwd: PathBuf,
    child: Child,
    master: OwnedFd,
    slave_device: String,
    attached: bool,
    output_history: TerminalOutputHistory,
    output_sequence: u64,
    last_input_sequence: Option<u64>,
}

#[derive(Debug)]
struct TerminalOutputHistory {
    bytes: Vec<u8>,
    complete: bool,
}

impl TerminalOutputHistory {
    fn new() -> Self {
        Self {
            bytes: Vec::new(),
            complete: true,
        }
    }

    fn record(&mut self, output: &[u8]) {
        if !self.complete {
            return;
        }

        if self.bytes.len().saturating_add(output.len()) > MAX_TERMINAL_OUTPUT_HISTORY_BYTES {
            self.bytes.clear();
            self.complete = false;
            return;
        }

        self.bytes.extend_from_slice(output);
    }

    fn replay(&self) -> &[u8] {
        if self.complete { &self.bytes } else { &[] }
    }
}

struct SessionState {
    database: Connection,
    running: HashMap<ShellId, RunningShell>,
    initial_pwd: PathBuf,
}

pub struct SessionManager {
    state: Mutex<SessionState>,
    attach_socket_path: PathBuf,
    host_id: String,
    host_generation: String,
    stop_workers: Arc<AtomicBool>,
    workers: Mutex<Vec<JoinHandle<()>>>,
    subscriptions: Mutex<HashMap<String, Receiver<Value>>>,
    subscribers: Mutex<Vec<LocalSubscriber>>,
    next_subscription_id: AtomicU64,
}

struct LocalSubscriber {
    id: String,
    session_id: Option<SessionId>,
    sender: SyncSender<Value>,
}

#[derive(Debug)]
struct ShellMetadata {
    id: ShellId,
    process_id: u32,
    initial_pwd: PathBuf,
    slave_device: String,
    attach_socket_path: PathBuf,
}

impl ShellMetadata {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id.0,
            "processId": self.process_id,
            "initialPwd": self.initial_pwd,
            "ptyDevice": self.slave_device,
            "attachSocketPath": self.attach_socket_path,
        })
    }
}

#[derive(Debug)]
struct SessionMetadata {
    id: SessionId,
    initial_pwd: PathBuf,
    shells: Vec<ShellMetadata>,
    layout: Option<SessionLayout>,
}

impl SessionMetadata {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id.0,
            "initialPwd": self.initial_pwd,
            "shells": self.shells.iter().map(ShellMetadata::to_json).collect::<Vec<_>>(),
            "layout": self.layout,
        })
    }

    fn to_remote_json(&self, host_id: &str, updated_at: &str) -> Value {
        json!({
            "hostId": host_id,
            "sessionId": self.id.0,
            "shells": self.shells.iter().map(|shell| json!({ "shellId": shell.id.0 })).collect::<Vec<_>>(),
            "layout": self.layout,
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
        let host_generation = create_uuid_v4()?;
        fs::set_permissions(&database_path, fs::Permissions::from_mode(0o600))?;

        let manager = Arc::new(Self {
            state: Mutex::new(SessionState {
                database,
                running: HashMap::new(),
                initial_pwd,
            }),
            attach_socket_path,
            host_id,
            host_generation,
            stop_workers: Arc::new(AtomicBool::new(false)),
            workers: Mutex::new(Vec::new()),
            subscriptions: Mutex::new(HashMap::new()),
            subscribers: Mutex::new(Vec::new()),
            next_subscription_id: AtomicU64::new(1),
        });

        manager.restore_open_sessions()?;
        manager.start_attachment_listener()?;
        manager.start_reaper();
        Ok(manager)
    }

    pub(crate) fn host_id(&self) -> &str {
        &self.host_id
    }

    pub(crate) fn host_generation(&self) -> &str {
        &self.host_generation
    }

    pub(crate) fn remote_session_snapshots(&self, updated_at: &str) -> io::Result<Vec<Value>> {
        let sessions = self.list_sessions()?;
        if sessions.len() > 256 || sessions.iter().any(|session| session.shells.len() > 256) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "host session snapshot exceeds the protocol limit",
            ));
        }
        Ok(sessions
            .iter()
            .map(|session| session.to_remote_json(&self.host_id, updated_at))
            .collect())
    }

    pub(crate) fn subscribe_remote_events(&self) -> io::Result<String> {
        self.subscribe(None)
    }

    pub(crate) fn next_remote_event(
        &self,
        subscription_id: &str,
        timeout: Duration,
    ) -> io::Result<Option<Value>> {
        self.next_event(subscription_id, timeout)
    }

    pub(crate) fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()> {
        self.unsubscribe(subscription_id)
    }

    pub(crate) fn remote_create_session(&self, updated_at: &str) -> io::Result<Value> {
        let session = self.create_session()?;
        self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        Ok(session.to_remote_json(&self.host_id, updated_at))
    }

    pub(crate) fn remote_close_session(
        &self,
        session_id: i64,
        updated_at: &str,
    ) -> io::Result<Option<Value>> {
        if session_id <= 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "session ID must be positive",
            ));
        }
        let session_id = SessionId(session_id);
        let replacement = self.close_session(session_id)?;
        self.publish_session_removed(session_id);
        if let Some(session) = &replacement {
            self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        }
        Ok(replacement.map(|session| session.to_remote_json(&self.host_id, updated_at)))
    }

    pub(crate) fn remote_create_shell(&self, session_id: i64) -> io::Result<i64> {
        let session_id = SessionId(session_id);
        let shell = self.create_shell(session_id)?;
        self.publish_session_snapshot(session_id)?;
        self.publish_shell_activity(session_id, shell.id, "started");
        Ok(shell.id.0)
    }

    pub(crate) fn remote_close_shell(&self, session_id: i64, shell_id: i64) -> io::Result<()> {
        let (session_id, shell_id) = parse_session_shell_ids(session_id, shell_id)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid shell identity"))?;
        let closed = self.close_shell(session_id, shell_id)?;
        if closed.archived_session_id.is_some() {
            self.publish_session_removed(session_id);
            if let Some(replacement) = &closed.replacement {
                self.publish_event(
                    json!({ "type": "session.snapshot", "session": replacement.to_json() }),
                );
            }
        } else {
            self.publish_session_snapshot(session_id)?;
        }
        self.publish_shell_activity(session_id, shell_id, "exited");
        Ok(())
    }

    pub(crate) fn remote_set_layout(&self, session_id: i64, layout: Value) -> io::Result<()> {
        let session_id = SessionId(session_id);
        let layout: SessionLayout = serde_json::from_value(layout)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid session layout"))?;
        layout.shell_ids()?;
        self.set_layout(session_id, layout)?;
        self.publish_session_snapshot(session_id)
    }

    pub(crate) fn remote_terminal_input(
        &self,
        session_id: i64,
        shell_id: i64,
        sequence: u64,
        data: &str,
    ) -> io::Result<()> {
        let (session_id, shell_id) = parse_session_shell_ids(session_id, shell_id)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid shell identity"))?;
        self.write_terminal_input(session_id, shell_id, sequence, data)
    }

    pub(crate) fn remote_terminal_resize(
        &self,
        session_id: i64,
        shell_id: i64,
        rows: u32,
        columns: u32,
    ) -> io::Result<()> {
        let (session_id, shell_id) = parse_session_shell_ids(session_id, shell_id)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid shell identity"))?;
        self.resize_terminal(session_id, shell_id, rows, columns)
    }

    pub fn register_rpc_methods(self: &Arc<Self>, handler: &mut IoHandler) {
        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.list", move |_| {
            manager
                .list_sessions()
                .map(|sessions| json!({ "sessions": sessions.iter().map(SessionMetadata::to_json).collect::<Vec<_>>() }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.layout.set", move |params: Params| {
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
        handler.add_sync_method("axo.session.subscribe", move |params: Params| {
            let request: SessionSubscribeRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId?}"))?;
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
                .subscribe(session_id)
                .map(|subscription_id| json!({ "subscriptionId": subscription_id }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.events.next", move |params: Params| {
            let request: SessionEventsNextRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {subscriptionId, timeoutMs}"))?;
            if request.timeout_ms == 0 || request.timeout_ms > 20_000 {
                return Err(invalid_params("timeoutMs must be between 1 and 20000"));
            }
            manager
                .next_event(
                    &request.subscription_id,
                    Duration::from_millis(request.timeout_ms),
                )
                .map(|event| json!({ "event": event }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.unsubscribe", move |params: Params| {
            let request: SessionUnsubscribeRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {subscriptionId}"))?;
            manager
                .unsubscribe(&request.subscription_id)
                .map(|()| json!({ "unsubscribed": true }))
                .map_err(internal_rpc_error)
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.terminal.input", move |params: Params| {
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
        handler.add_sync_method("axo.terminal.resize", move |params: Params| {
            let request: TerminalResizeRequest = params
                .parse()
                .map_err(|_| invalid_params("expected {sessionId, shellId, rows, columns}"))?;
            let (session_id, shell_id) = parse_session_shell_ids(request.session_id, request.shell_id)?;
            manager
                .resize_terminal(session_id, shell_id, request.rows, request.columns)
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
        handler.add_sync_method("axo.session.create", move |_| {
            let session = manager.create_session().map_err(internal_rpc_error)?;
            manager
                .publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
            Ok(session.to_json())
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.session.close", move |params| {
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
        handler.add_sync_method("axo.shell.create", move |params| {
            let id = parse_session_id(params)?;
            let shell = manager.create_shell(id).map_err(internal_rpc_error)?;
            manager
                .publish_session_snapshot(id)
                .map_err(internal_rpc_error)?;
            manager.publish_shell_activity(id, shell.id, "started");
            Ok(shell.to_json())
        });

        let manager = Arc::clone(self);
        handler.add_sync_method("axo.shell.close", move |params| {
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
        let records = read_open_sessions(&state.database)?;
        if records.is_empty() {
            create_session(&mut state, &self.attach_socket_path)?;
        } else {
            for record in records {
                let has_shells = !record.shell_ids.is_empty();
                for shell_id in record.shell_ids {
                    let shell = spawn_shell(record.id, &record.initial_pwd)?;
                    state.running.insert(shell_id, shell);
                }
                if !has_shells {
                    create_shell(&mut state, record.id, &self.attach_socket_path)?;
                }
            }
        }
        Ok(())
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
        let stop_workers = Arc::clone(&self.stop_workers);
        let worker = thread::Builder::new()
            .name("axo-pty-attachments".into())
            .spawn(move || {
                while !stop_workers.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let manager = manager.clone();
                            let _ = thread::Builder::new()
                                .name("axo-pty-attachment".into())
                                .spawn(move || handle_attachment(stream, manager));
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(20));
                        }
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
        let mut sessions: HashMap<SessionId, SessionMetadata> = HashMap::new();
        for (shell_id, running) in &state.running {
            let session = sessions
                .entry(running.session_id)
                .or_insert_with(|| SessionMetadata {
                    id: running.session_id,
                    initial_pwd: running.initial_pwd.clone(),
                    shells: Vec::new(),
                    layout: None,
                });
            session
                .shells
                .push(shell_metadata(*shell_id, running, &self.attach_socket_path));
        }
        let mut sessions: Vec<_> = sessions.into_values().collect();
        for session in &mut sessions {
            session.shells.sort_by_key(|shell| shell.id.0);
            session.layout = read_session_layout(&state.database, session.id)?;
        }
        sessions.sort_by_key(|session| session.id.0);
        Ok(sessions)
    }

    fn create_session(&self) -> io::Result<SessionMetadata> {
        let mut state = self.lock_state()?;
        create_session(&mut state, &self.attach_socket_path)
    }

    fn set_layout(&self, session_id: SessionId, layout: SessionLayout) -> io::Result<()> {
        let shell_ids = layout.shell_ids()?;
        let state = self.lock_state()?;
        let open_shell_ids: HashSet<_> = state
            .running
            .iter()
            .filter_map(|(shell_id, shell)| (shell.session_id == session_id).then_some(*shell_id))
            .collect();
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

    fn subscribe(&self, session_id: Option<SessionId>) -> io::Result<String> {
        if let Some(session_id) = session_id {
            let state = self.lock_state()?;
            session_initial_pwd(&state.database, session_id)?;
        }
        let id = self.next_subscription_id.fetch_add(1, Ordering::Relaxed);
        let subscription_id = format!(
            "00000000-0000-4000-8000-{:012x}",
            ((std::process::id() as u64) << 32 | id) & 0x0000_ffff_ffff_ffff
        );
        let (sender, receiver) = mpsc::sync_channel(MAX_QUEUED_EVENTS_PER_SUBSCRIPTION);
        let mut subscriptions = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?;
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
        subscriptions.insert(subscription_id.clone(), receiver);
        subscribers.push(LocalSubscriber {
            id: subscription_id.clone(),
            session_id,
            sender,
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
        for session in sessions {
            if session_id.is_none_or(|expected| expected == session.id) {
                self.publish_event(
                    json!({ "type": "session.snapshot", "session": session.to_json() }),
                );
            }
        }
        Ok(subscription_id)
    }

    fn next_event(&self, id: &str, timeout: Duration) -> io::Result<Option<Value>> {
        let mut subscriptions = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?;
        let receiver = subscriptions
            .get_mut(id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "subscription is not open"))?;
        match receiver.recv_timeout(timeout) {
            Ok(event) => Ok(Some(event)),
            Err(RecvTimeoutError::Timeout) => Ok(None),
            Err(RecvTimeoutError::Disconnected) => Err(io::Error::new(
                io::ErrorKind::NotFound,
                "subscription is closed",
            )),
        }
    }

    fn unsubscribe(&self, id: &str) -> io::Result<()> {
        let mut subscriptions = self
            .subscriptions
            .lock()
            .map_err(|_| io::Error::other("session subscription lock was poisoned"))?;
        if subscriptions.remove(id).is_none() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "subscription is not open",
            ));
        }
        let mut subscribers = self
            .subscribers
            .lock()
            .map_err(|_| io::Error::other("session subscriber lock was poisoned"))?;
        subscribers.retain(|subscriber| subscriber.id != id);
        Ok(())
    }

    fn publish_event(&self, event: Value) {
        let session_id = event.get("sessionId").and_then(Value::as_i64).or_else(|| {
            event
                .get("session")
                .and_then(|session| session["id"].as_i64())
        });
        let Ok(mut subscribers) = self.subscribers.lock() else {
            return;
        };
        subscribers.retain(|subscriber| {
            if subscriber
                .session_id
                .is_some_and(|expected| session_id != Some(expected.0))
            {
                return true;
            }
            match subscriber.sender.try_send(event.clone()) {
                Ok(()) | Err(TrySendError::Full(_)) => true,
                Err(TrySendError::Disconnected(_)) => false,
            }
        });
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
        write_fd_all(running.master.as_raw_fd(), &input)?;
        running.last_input_sequence = Some(sequence);
        Ok(())
    }

    fn resize_terminal(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        rows: u32,
        columns: u32,
    ) -> io::Result<()> {
        if rows == 0 || columns == 0 || rows > u16::MAX as u32 || columns > u16::MAX as u32 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "terminal dimensions are outside the supported range",
            ));
        }
        let state = self.lock_state()?;
        let running = state
            .running
            .get(&shell_id)
            .filter(|running| running.session_id == session_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        let size = libc::winsize {
            ws_row: rows as libc::c_ushort,
            ws_col: columns as libc::c_ushort,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: size is fully initialized and the PTY master descriptor remains open.
        let result = unsafe {
            libc::ioctl(
                running.master.as_raw_fd(),
                libc::TIOCSWINSZ,
                &size as *const libc::winsize,
            )
        };
        if result == -1 {
            return Err(io::Error::last_os_error());
        }
        let process_id = running.child.id() as libc::pid_t;
        signal_shell(-process_id, process_id, libc::SIGWINCH);
        Ok(())
    }

    fn create_shell(&self, session_id: SessionId) -> io::Result<ShellMetadata> {
        let mut state = self.lock_state()?;
        create_shell(&mut state, session_id, &self.attach_socket_path)
    }

    fn close_session(&self, id: SessionId) -> io::Result<Option<SessionMetadata>> {
        let (replacement, shells_to_terminate) = {
            let mut state = self.lock_state()?;
            close_session(&mut state, id, &self.attach_socket_path)?
        };
        self.terminate_shells_in_background(shells_to_terminate);
        Ok(replacement)
    }

    fn close_shell(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
    ) -> io::Result<ClosedShellMetadata> {
        let (closed, shells_to_terminate) = {
            let mut state = self.lock_state()?;
            close_shell(&mut state, session_id, shell_id, &self.attach_socket_path)?
        };
        self.terminate_shells_in_background(shells_to_terminate);
        Ok(closed)
    }

    fn terminate_shells_in_background(&self, shells: Vec<RunningShell>) {
        for mut shell in shells {
            let process_id = shell.child.id() as libc::pid_t;
            signal_shell(-process_id, process_id, libc::SIGTERM);
            let worker_name = format!("axo-shell-cleanup-{process_id}");
            match thread::Builder::new().name(worker_name).spawn(move || {
                terminate_shell(&mut shell.child);
            }) {
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

    fn reap_exited_sessions(&self) -> io::Result<()> {
        let mut state = self.lock_state()?;
        let exited = state
            .running
            .iter_mut()
            .filter_map(|(shell_id, running)| match running.child.try_wait() {
                Ok(Some(_)) => Some(Ok((*shell_id, running.session_id))),
                Ok(None) => None,
                Err(error) => Some(Err(error)),
            })
            .collect::<io::Result<Vec<_>>>()?;

        let exited_shell_ids: HashSet<_> = exited.iter().map(|(shell_id, _)| *shell_id).collect();
        let mut changed_sessions = HashSet::new();
        let mut removed_sessions = HashSet::new();
        for (shell_id, session_id) in &exited {
            let remaining_shell_ids: HashSet<_> = state
                .running
                .iter()
                .filter_map(|(candidate_id, shell)| {
                    (shell.session_id == *session_id && !exited_shell_ids.contains(candidate_id))
                        .then_some(*candidate_id)
                })
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
                }
            } else {
                changed_sessions.insert(*session_id);
            }
        }
        let replacement = if state.running.is_empty() {
            Some(create_session(&mut state, &self.attach_socket_path)?)
        } else {
            None
        };
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
        if let Some(session) = replacement {
            self.publish_event(json!({ "type": "session.snapshot", "session": session.to_json() }));
        }
        Ok(())
    }

    fn duplicate_master(&self, id: ShellId) -> io::Result<(OwnedFd, Vec<u8>, SessionId)> {
        let mut state = self.lock_state()?;
        let running = state
            .running
            .get_mut(&id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
        if running.attached {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                "shell already has a PTY attachment",
            ));
        }
        let fd = unsafe { libc::fcntl(running.master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd == -1 {
            return Err(io::Error::last_os_error());
        }
        running.attached = true;
        let replay = running.output_history.replay().to_vec();
        let session_id = running.session_id;
        // SAFETY: fcntl returned a new, owned descriptor.
        Ok((unsafe { OwnedFd::from_raw_fd(fd) }, replay, session_id))
    }

    fn record_terminal_output(&self, id: ShellId, output: &[u8]) {
        let event = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            let Some(running) = state.running.get_mut(&id) else {
                return;
            };
            running.output_history.record(output);
            let sequence = running.output_sequence;
            running.output_sequence = running.output_sequence.saturating_add(1);
            json!({
                "type": "terminal.output",
                "sessionId": running.session_id.0,
                "shellId": id.0,
                "sequence": sequence,
                "data": encode_base64(output),
            })
        };
        self.publish_event(event);
    }

    fn mark_detached(&self, id: ShellId) {
        let session_id = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            let Some(running) = state.running.get_mut(&id) else {
                return;
            };
            running.attached = false;
            running.session_id
        };
        self.publish_shell_activity(session_id, id, "detached");
    }

    pub fn shutdown(&self) {
        self.stop_workers.store(true, Ordering::Relaxed);
        let workers = self
            .workers
            .lock()
            .map(|mut workers| std::mem::take(&mut *workers))
            .unwrap_or_default();
        for worker in workers {
            let _ = worker.join();
        }
        if let Ok(mut state) = self.state.lock() {
            for running in state.running.values_mut() {
                terminate_shell(&mut running.child);
            }
        }
    }

    fn lock_state(&self) -> io::Result<std::sync::MutexGuard<'_, SessionState>> {
        self.state
            .lock()
            .map_err(|_| io::Error::other("session state lock was poisoned"))
    }
}

impl Drop for SessionManager {
    fn drop(&mut self) {
        self.stop_workers.store(true, Ordering::Relaxed);
        let workers = self
            .workers
            .get_mut()
            .map(std::mem::take)
            .unwrap_or_default();
        for worker in workers {
            let _ = worker.join();
        }
        if let Ok(state) = self.state.get_mut() {
            for running in state.running.values_mut() {
                terminate_shell(&mut running.child);
            }
        }
        let _ = fs::remove_file(&self.attach_socket_path);
    }
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

    transaction.pragma_update(None, "user_version", 3)?;
    transaction.commit()
}

fn create_tables(transaction: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT,
            layout_json TEXT
        );
        CREATE TABLE IF NOT EXISTS shells (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id),
            initial_pwd TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('open', 'archived')),
            created_at INTEGER NOT NULL,
            archived_at INTEGER,
            termination_reason TEXT
        );
        CREATE INDEX IF NOT EXISTS shells_by_session_state
            ON shells(session_id, state, id);
        CREATE TABLE IF NOT EXISTS daemon_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );",
    )
}

fn create_session(
    state: &mut SessionState,
    attach_socket_path: &Path,
) -> io::Result<SessionMetadata> {
    let initial_pwd = state.initial_pwd.clone();
    state
        .database
        .execute(
            "INSERT INTO sessions (initial_pwd, state, created_at) VALUES (?1, 'open', ?2)",
            params![initial_pwd.to_string_lossy(), unix_timestamp()],
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

    let running = match spawn_shell(session_id, &initial_pwd) {
        Ok(running) => running,
        Err(error) => {
            archive_shell(&state.database, shell_id, "spawn_failed")?;
            return Err(error);
        }
    };
    let metadata = shell_metadata(shell_id, &running, attach_socket_path);
    state.running.insert(shell_id, running);
    Ok(metadata)
}

fn close_session(
    state: &mut SessionState,
    id: SessionId,
    attach_socket_path: &Path,
) -> io::Result<(Option<SessionMetadata>, Vec<RunningShell>)> {
    if !state.running.values().any(|shell| shell.session_id == id) {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "session is not open",
        ));
    }

    let open_session_ids: std::collections::HashSet<_> = state
        .running
        .values()
        .map(|shell| shell.session_id)
        .collect();
    let replacement = if open_session_ids.len() == 1 {
        Some(create_session(state, attach_socket_path)?)
    } else {
        None
    };

    archive_session(&mut state.database, id, "explicit_close")?;
    let shells = remove_session_shells(state, id);
    Ok((replacement, shells))
}

fn close_shell(
    state: &mut SessionState,
    session_id: SessionId,
    shell_id: ShellId,
    attach_socket_path: &Path,
) -> io::Result<(ClosedShellMetadata, Vec<RunningShell>)> {
    let shell = state
        .running
        .get(&shell_id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "shell is not open"))?;
    if shell.session_id != session_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "shell does not belong to this session",
        ));
    }

    let sibling_count = state
        .running
        .values()
        .filter(|shell| shell.session_id == session_id)
        .count();
    if sibling_count == 1 {
        let (replacement, shells) = close_session(state, session_id, attach_socket_path)?;
        return Ok((
            ClosedShellMetadata {
                archived_shell_id: shell_id,
                archived_session_id: Some(session_id),
                replacement,
            },
            shells,
        ));
    }

    let remaining_shell_ids: HashSet<_> = state
        .running
        .iter()
        .filter_map(|(candidate_id, shell)| {
            (shell.session_id == session_id && *candidate_id != shell_id).then_some(*candidate_id)
        })
        .collect();
    archive_shell_and_prune_layout(
        &mut state.database,
        shell_id,
        session_id,
        "explicit_close",
        &remaining_shell_ids,
    )?;
    let shell = state.running.remove(&shell_id).into_iter().collect();
    Ok((
        ClosedShellMetadata {
            archived_shell_id: shell_id,
            archived_session_id: None,
            replacement: None,
        },
        shell,
    ))
}

fn remove_session_shells(state: &mut SessionState, session_id: SessionId) -> Vec<RunningShell> {
    let shell_ids: Vec<_> = state
        .running
        .iter()
        .filter_map(|(shell_id, shell)| (shell.session_id == session_id).then_some(*shell_id))
        .collect();
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
    let initial_pwd = session_initial_pwd(&state.database, id)?;
    let mut shells: Vec<_> = state
        .running
        .iter()
        .filter(|&(_, running)| running.session_id == id)
        .map(|(shell_id, running)| shell_metadata(*shell_id, running, attach_socket_path))
        .collect();
    shells.sort_by_key(|shell| shell.id.0);
    Ok(SessionMetadata {
        id,
        initial_pwd,
        shells,
        layout: read_session_layout(&state.database, id)?,
    })
}

fn shell_metadata(id: ShellId, running: &RunningShell, attach_socket_path: &Path) -> ShellMetadata {
    ShellMetadata {
        id,
        process_id: running.child.id(),
        initial_pwd: running.initial_pwd.clone(),
        slave_device: running.slave_device.clone(),
        attach_socket_path: attach_socket_path.to_path_buf(),
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
        let mut shell_statement = database
            .prepare("SELECT id FROM shells WHERE session_id = ?1 AND state = 'open' ORDER BY id")
            .map_err(io::Error::other)?;
        let shell_ids = shell_statement
            .query_map(params![id.0], |row| Ok(ShellId(row.get(0)?)))
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

fn spawn_shell(session_id: SessionId, initial_pwd: &Path) -> io::Result<RunningShell> {
    let mut master_fd: RawFd = -1;
    let mut slave_fd: RawFd = -1;
    let mut size = libc::winsize {
        ws_row: PTY_ROWS,
        ws_col: PTY_COLUMNS,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: openpty initializes both descriptors and receives a valid winsize pointer.
    if unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size,
        )
    } == -1
    {
        return Err(io::Error::last_os_error());
    }

    // SAFETY: openpty returned two new owned descriptors.
    let master = unsafe { OwnedFd::from_raw_fd(master_fd) };
    // SAFETY: openpty returned two new owned descriptors.
    let slave = unsafe { OwnedFd::from_raw_fd(slave_fd) };
    let slave_device = tty_device_path(slave.as_raw_fd())?;

    let shell = std::env::var_os("SHELL")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute() && path.is_file())
        .unwrap_or_else(|| PathBuf::from("/bin/zsh"));
    let home = super::current_user_home_directory()?;
    let slave_raw_fd = slave.as_raw_fd();
    let mut command = Command::new(shell);
    command
        .arg("-l")
        .current_dir(initial_pwd)
        .env("HOME", &home)
        .env("PWD", initial_pwd)
        .env("TERM", "xterm-ghostty")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(resources_directory) = bundled_ghostty_resources_directory() {
        command.env("GHOSTTY_RESOURCES_DIR", resources_directory);
    }
    if let Some(terminfo_directory) = bundled_terminfo_directory() {
        command.env("TERMINFO", terminfo_directory);
    }

    // SAFETY: this child-only setup creates a session, assigns the PTY as its
    // controlling terminal, and connects all standard streams before exec.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(slave_raw_fd, libc::TIOCSCTTY as libc::c_ulong, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::tcsetpgrp(slave_raw_fd, libc::getpgrp()) == -1 {
                return Err(io::Error::last_os_error());
            }
            for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
                if libc::dup2(slave_raw_fd, target) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            libc::close(slave_raw_fd);
            Ok(())
        });
    }

    let child = command.spawn()?;
    drop(slave);
    Ok(RunningShell {
        session_id,
        initial_pwd: initial_pwd.to_path_buf(),
        child,
        master,
        slave_device,
        attached: false,
        output_history: TerminalOutputHistory::new(),
        output_sequence: 0,
        last_input_sequence: None,
    })
}

fn tty_device_path(slave_fd: RawFd) -> io::Result<String> {
    let mut bytes = vec![0_i8; libc::PATH_MAX as usize];
    // SAFETY: bytes is writable storage and slave_fd is an open PTY slave.
    let error = unsafe { libc::ttyname_r(slave_fd, bytes.as_mut_ptr(), bytes.len()) };
    if error != 0 {
        return Err(io::Error::from_raw_os_error(error));
    }
    // SAFETY: ttyname_r wrote a NUL-terminated device path into bytes.
    let device = unsafe { CStr::from_ptr(bytes.as_ptr()) };
    device
        .to_str()
        .map(str::to_owned)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "PTY path is not UTF-8"))
}

fn terminate_shell(child: &mut Child) {
    if child.try_wait().ok().flatten().is_some() {
        return;
    }
    let process_id = child.id() as libc::pid_t;
    let process_group = -process_id;
    log::info!("event=session.shell_stop_started pid={process_id}");
    // The process-group signal covers foreground jobs; the direct signal also
    // covers a shell that changed its process group for interactive job control.
    signal_shell(process_group, process_id, libc::SIGTERM);

    if wait_for_shell_exit(child, Duration::from_millis(500)) {
        log::info!("event=session.shell_stopped pid={process_id}");
        return;
    }

    signal_shell(process_group, process_id, libc::SIGKILL);
    if wait_for_shell_exit(child, Duration::from_secs(2)) {
        log::info!("event=session.shell_stopped pid={process_id}");
    } else {
        log::error!("event=session.shell_stop_timed_out pid={process_id}");
    }
}

fn signal_shell(process_group: libc::pid_t, process_id: libc::pid_t, signal: libc::c_int) {
    // SAFETY: process_group and process_id come from the child this manager spawned.
    unsafe {
        libc::kill(process_group, signal);
        libc::kill(process_id, signal);
    }
}

fn wait_for_shell_exit(child: &mut Child, timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => thread::sleep(Duration::from_millis(25)),
            Err(_) => return false,
        }
    }
    child.try_wait().ok().flatten().is_some()
}

fn handle_attachment(mut stream: UnixStream, manager: Weak<SessionManager>) {
    let mut request = Vec::new();
    let mut byte = [0_u8; 1];
    while request.len() <= 20 {
        match stream.read(&mut byte) {
            Ok(0) => return,
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) if byte[0].is_ascii_digit() => request.push(byte[0]),
            Ok(_) => return,
            Err(_) => return,
        }
    }
    let Ok(text) = std::str::from_utf8(&request) else {
        return;
    };
    let Ok(raw_id) = text.parse::<i64>() else {
        return;
    };
    let id = ShellId(raw_id);
    let Some(manager) = manager.upgrade() else {
        return;
    };
    let (master, replay, session_id) = match manager.duplicate_master(id) {
        Ok(attachment) => attachment,
        Err(error) => {
            log::warn!(
                "event=session.attach_rejected shell_id={} reason={error}",
                id.0
            );
            if let Err(write_error) = write_attachment_rejection(&mut stream, &error) {
                log::debug!(
                    "event=session.attach_rejection_write_failed shell_id={} reason={write_error}",
                    id.0
                );
            }
            return;
        }
    };

    manager.publish_shell_activity(session_id, id, "attached");
    let replay_length = (replay.len() as u64).to_be_bytes();
    if stream
        .write_all(&replay_length)
        .and_then(|()| stream.write_all(&replay))
        .and_then(|()| send_file_descriptor(stream.as_raw_fd(), master.as_raw_fd()))
        .is_err()
    {
        manager.mark_detached(id);
        return;
    }

    // The attachment helper tees PTY output back over this control connection
    // so the next Ghostty surface can replay the terminal's complete VT stream.
    let mut output = [0_u8; 8192];
    loop {
        match stream.read(&mut output) {
            Ok(0) => break,
            Ok(count) => manager.record_terminal_output(id, &output[..count]),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted
                        | io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                ) =>
            {
                thread::sleep(Duration::from_millis(20));
            }
            Err(_) => break,
        }
    }
    manager.mark_detached(id);
}

fn write_attachment_rejection(stream: &mut UnixStream, error: &io::Error) -> io::Result<()> {
    let code = match error.kind() {
        io::ErrorKind::AddrInUse => 1,
        io::ErrorKind::NotFound => 2,
        _ => 3,
    };
    stream.write_all(&ATTACH_REJECTION_MARKER.to_be_bytes())?;
    stream.write_all(&[code])
}

fn send_file_descriptor(socket_fd: RawFd, descriptor: RawFd) -> io::Result<()> {
    let mut byte = b'1';
    let mut vector = libc::iovec {
        iov_base: (&mut byte as *mut u8).cast(),
        iov_len: 1,
    };
    let control_size = unsafe { libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32) } as usize;
    let mut control = vec![0_usize; control_size.div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: zeroed msghdr is a valid starting point before its fields are initialized.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = control_size as _;

    // SAFETY: message points to valid iovec and control storage sized for one descriptor.
    let header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    if header.is_null() {
        return Err(io::Error::other(
            "could not allocate PTY descriptor message",
        ));
    }
    // SAFETY: header points into message's control buffer with enough SCM_RIGHTS capacity.
    unsafe {
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32) as _;
        std::ptr::copy_nonoverlapping(
            &descriptor as *const RawFd as *const u8,
            libc::CMSG_DATA(header).cast(),
            std::mem::size_of::<RawFd>(),
        );
    }

    // SAFETY: sendmsg reads the initialized message and descriptor; both remain alive here.
    let sent = unsafe { libc::sendmsg(socket_fd, &message, 0) };
    if sent == -1 {
        return Err(io::Error::last_os_error());
    }
    if sent != 1 {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "short PTY descriptor message",
        ));
    }
    Ok(())
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

fn write_fd_all(fd: RawFd, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        // SAFETY: bytes points to initialized memory and fd remains open for this call.
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written == -1 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if written == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "terminal input write returned zero",
            ));
        }
        bytes = &bytes[written as usize..];
    }
    Ok(())
}

fn unix_timestamp() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

impl Drop for RunningShell {
    fn drop(&mut self) {
        // Closing the master PTY sends SIGHUP to its controlling session, so a
        // daemon restart tears down the shell without archiving its DB record.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn remote_session_snapshots_exclude_local_process_and_filesystem_details() {
        let session = SessionMetadata {
            id: SessionId(9),
            initial_pwd: PathBuf::from("/private/path"),
            shells: vec![ShellMetadata {
                id: ShellId(12),
                process_id: 1234,
                initial_pwd: PathBuf::from("/private/path"),
                slave_device: "/dev/ttys001".to_owned(),
                attach_socket_path: PathBuf::from("/private/path/attach.sock"),
            }],
            layout: Some(SessionLayout::Pane { shell_id: 12 }),
        };
        let remote = session.to_remote_json(
            "18355f00-95fd-4c93-8586-a71a8a52bf73",
            "2026-10-16T00:00:00Z",
        );
        let object = remote.as_object().unwrap();
        assert_eq!(object.len(), 5);
        assert_eq!(object["sessionId"], 9);
        assert_eq!(object["shells"], json!([{ "shellId": 12 }]));
        let serialized = remote.to_string();
        assert!(!serialized.contains("/private/path"));
        assert!(!serialized.contains("/dev/ttys001"));
        assert!(!serialized.contains("1234"));
    }

    #[test]
    fn terminal_output_history_replays_only_complete_streams() {
        let mut history = TerminalOutputHistory::new();
        history.record(b"initial screen");
        assert_eq!(history.replay(), b"initial screen");

        history.record(&vec![b'x'; MAX_TERMINAL_OUTPUT_HISTORY_BYTES]);
        assert!(history.replay().is_empty());

        history.record(b"later output");
        assert!(history.replay().is_empty());
    }

    #[test]
    fn migrates_legacy_shell_sessions_into_tabs() {
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

        let (session_id, initial_pwd): (i64, String) = database
            .query_row(
                "SELECT id, initial_pwd FROM sessions WHERE state = 'open'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        let (shell_id, shell_session_id, shell_pwd): (i64, i64, String) = database
            .query_row(
                "SELECT id, session_id, initial_pwd FROM shells WHERE state = 'open'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();

        assert_eq!(session_id, 7);
        assert_eq!(initial_pwd, "/tmp");
        assert_eq!(shell_id, 7);
        assert_eq!(shell_session_id, session_id);
        assert_eq!(shell_pwd, initial_pwd);
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
        assert_eq!(schema_version, 3);
    }

    #[test]
    fn creates_a_shell_attached_to_a_real_pty() {
        let home = super::super::current_user_home_directory().unwrap();
        let mut session = spawn_shell(SessionId(1), &home).unwrap();
        assert!(session.slave_device.starts_with("/dev/"));

        let master = session.master.as_raw_fd();
        let command = b"printf 'AXO_PTY_READY\\n'\n";
        // SAFETY: command points to initialized bytes and master is an open PTY.
        let written = unsafe { libc::write(master, command.as_ptr().cast(), command.len()) };
        assert_eq!(written as usize, command.len());
        assert!(read_until(master, b"AXO_PTY_READY", Duration::from_secs(3)));
        terminate_shell(&mut session.child);
    }

    fn read_until(master: RawFd, needle: &[u8], timeout: Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let mut received = Vec::new();
        while std::time::Instant::now() < deadline {
            let mut descriptor = libc::pollfd {
                fd: master,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: descriptor is a valid one-element poll array.
            let ready = unsafe { libc::poll(&mut descriptor, 1, 100) };
            if ready <= 0 {
                continue;
            }
            let mut bytes = [0_u8; 1024];
            // SAFETY: bytes is writable and master is open.
            let count = unsafe { libc::read(master, bytes.as_mut_ptr().cast(), bytes.len()) };
            if count > 0 {
                received.extend_from_slice(&bytes[..count as usize]);
                if received
                    .windows(needle.len())
                    .any(|window| window == needle)
                {
                    return true;
                }
            }
        }
        false
    }
}
