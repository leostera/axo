//! Local Windows vertical slice of axod. Shares Axo IDs, workspaces and SQLite sessions,
//! with a Codex app-server agent and a per-user named-pipe transport. Apple-only extensions
//! are deliberately absent from negotiation. No listener is exposed to the network.
mod credentials;
mod relay;
mod security;
mod terminal;

use axo_agent::codex::{Codex, message_text};
use axo_protocol::rpc::{self, method};
use axo_protocol::{Event, EventScope, SessionId, SessionStatus};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::windows::named_pipe::NamedPipeServer;

const MAX_REQUEST: u64 = 1024 * 1024;
const MAX_EVENTS: usize = 2048;
const MAX_EVENT_BYTES: usize = 4 * 1024 * 1024;
const METHODS: &[&str] = &[
    method::PROTOCOL_NEGOTIATE,
    method::DAEMON_HEALTH,
    method::WORKSPACE_LIST,
    method::WORKSPACE_CREATE,
    method::WORKSPACE_RENAME,
    method::WORKSPACE_SESSION_CREATE,
    method::SESSION_LIST,
    method::SESSION_RENAME,
    method::SESSION_CLOSE,
    method::SESSION_REOPEN,
    method::SESSION_PROMPT,
    "axo.session.open",
    "axo.session.messages",
    "axo.session.interrupt",
    "axo.session.events.poll",
    "axo.session.approval.respond",
    "axo.terminal.open",
    "axo.daemon.stop",
    method::RELAY_LINK,
    method::RELAY_STATUS,
    method::RELAY_CONNECT,
    method::SESSION_SUBSCRIBE,
    method::SESSION_EVENTS_NEXT,
    method::SESSION_UNSUBSCRIBE,
    "axo.terminal.create",
    "axo.terminal.replay",
    "axo.terminal.close",
    method::TERMINAL_INPUT,
    method::TERMINAL_RESIZE,
];

#[derive(Default)]
struct Runtime {
    generation: u64,
    agent: Option<Arc<Codex>>,
    status: Option<SessionStatus>,
    turn: Option<String>,
    pending: HashMap<String, Value>,
    events: VecDeque<Value>,
    sequence: u64,
    event_bytes: usize,
    error: Option<String>,
    terminal: Option<Child>,
    pseudoconsole: Option<Arc<terminal::Terminal>>,
    remote_command: Option<String>,
    turn_entries: Vec<String>,
    progress: HashMap<String, String>,
    remote_questions: HashMap<String, (String, axo_protocol::elicitation::Elicitation)>,
}

#[derive(Default)]
struct LiveSession {
    /// A start, prompt, interrupt or close cannot race another lifecycle operation.
    operation: Mutex<()>,
    runtime: Mutex<Runtime>,
}

struct Backend {
    database: Mutex<axo_store::Connection>,
    sessions: Mutex<HashMap<SessionId, Arc<LiveSession>>>,
    codex: PathBuf,
    stop: tokio::sync::Notify,
    directory: PathBuf,
    relay: Mutex<Option<Arc<relay::Relay>>>,
    subscriptions: Mutex<HashMap<String, Subscription>>,
    next_shell: std::sync::atomic::AtomicU32,
}

struct Subscription {
    session: Option<SessionId>,
    scope: EventScope,
    queue: Arc<axo_ipc::EventQueue<Event>>,
    touched: std::time::Instant,
}

pub fn serve(
    directory: Option<PathBuf>,
    pipe: Option<String>,
    codex: PathBuf,
    relay_url: Option<String>,
) -> io::Result<()> {
    let sid = security::current_sid()?;
    let directory = match directory {
        Some(path) if path.is_absolute() => path,
        Some(_) => return Err(invalid("server directory must be absolute")),
        None => PathBuf::from(
            std::env::var_os("LOCALAPPDATA").ok_or_else(|| invalid("LOCALAPPDATA is missing"))?,
        )
        .join("Axo/server"),
    };
    std::fs::create_dir_all(&directory)?;
    security::protect_directory(&directory, &sid)?;
    let pipe = pipe.unwrap_or_else(|| format!(r"\\.\pipe\Axo-{sid}"));
    if !pipe.starts_with(r"\\.\pipe\") {
        return Err(invalid("pipe must be a local Windows named pipe"));
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(async {
        // Reserve the pipe before opening or migrating the catalog, excluding duplicate daemons.
        let mut listener = security::create_pipe(&pipe, &sid, true)?;
        let database = axo_store::open(&directory.join(axo_store::DATABASE_FILE))?;
        axo_store::coding::initialize(&database)?;
        let backend = Arc::new(Backend {
            database: Mutex::new(database),
            sessions: Mutex::new(HashMap::new()),
            codex,
            stop: tokio::sync::Notify::new(),
            directory,
            relay: Mutex::new(None),
            subscriptions: Mutex::new(HashMap::new()),
            next_shell: std::sync::atomic::AtomicU32::new(1),
        });
        let endpoint = match relay_url {
            Some(url) => axo_relay::RelayEndpoint::parse(&url)?,
            None => axo_relay::RelayEndpoint::production(),
        };
        let relay = Arc::new(relay::Relay::start(&backend, endpoint)?);
        *backend.relay.lock().unwrap() = Some(relay.clone());
        log::info!("event=daemon.ready platform=windows");
        loop {
            tokio::select! {
                result = listener.connect() => { result?; }
                _ = backend.stop.notified() => break,
                _ = tokio::signal::ctrl_c() => break,
            }
            // There is always a listener, even while the last connected client disconnects.
            let connected = listener;
            listener = security::create_pipe(&pipe, &sid, false)?;
            let state = backend.clone();
            tokio::spawn(async move {
                if let Err(error) = connection(connected, state).await {
                    log::debug!("event=ipc.disconnected kind={:?}", error.kind());
                }
            });
        }
        // Relay workers join tasks using the runtime handle, so drop them on the blocking
        // pool while that runtime is still alive.
        tokio::task::spawn_blocking(move || relay.shutdown())
            .await
            .map_err(io::Error::other)?;
        for session in backend.sessions.lock().unwrap().values() {
            let mut runtime = session.runtime.lock().unwrap();
            if let Some(agent) = runtime.agent.take() {
                agent.stop();
            }
            if let Some(pty) = runtime.pseudoconsole.take() {
                pty.stop();
            }
            if let Some(mut terminal) = runtime.terminal.take() {
                let _ = terminal.kill();
                let _ = terminal.wait();
            }
        }
        Ok(())
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    jsonrpc: String,
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

async fn connection(pipe: NamedPipeServer, backend: Arc<Backend>) -> io::Result<()> {
    let mut reader = BufReader::new(pipe);
    loop {
        let mut line = Vec::new();
        let mut limited = (&mut reader).take(MAX_REQUEST + 1);
        let n = tokio::time::timeout(
            std::time::Duration::from_secs(90),
            limited.read_until(b'\n', &mut line),
        )
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "IPC request timed out"))??;
        if n == 0 {
            return Ok(());
        }
        if n as u64 > MAX_REQUEST {
            return Err(invalid("IPC request is too large"));
        }
        let mut should_stop = false;
        let reply = match serde_json::from_slice::<Request>(&line) {
            Ok(request)
                if request.jsonrpc == "2.0"
                    && (request.id.is_number() || request.id.is_string()) =>
            {
                let state = backend.clone();
                let id = request.id.clone();
                let stopping = request.method == "axo.daemon.stop";
                let result = if request.method == method::SESSION_EVENTS_NEXT {
                    Ok(state.next_events(request.params).await)
                } else {
                    tokio::task::spawn_blocking(move || {
                        state.dispatch(&request.method, request.params)
                    })
                    .await
                };
                match result {
                    Ok(Ok(result)) => {
                        should_stop = stopping;
                        json!({"jsonrpc":"2.0","id":id,"result":result})
                    }
                    Ok(Err(error)) => {
                        json!({"jsonrpc":"2.0","id":id,"error":{"code":error.code,"message":error.message}})
                    }
                    Err(_) => {
                        json!({"jsonrpc":"2.0","id":id,"error":{"code":-32603,"message":"Internal daemon error"}})
                    }
                }
            }
            _ => {
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid JSON-RPC request"}})
            }
        };
        let mut output = serde_json::to_vec(&reply)?;
        output.push(b'\n');
        reader.get_mut().write_all(&output).await?;
        reader.get_mut().flush().await?;
        if should_stop {
            backend.stop.notify_one();
            return Ok(());
        }
    }
}

struct RpcError {
    code: i32,
    message: String,
}
impl From<io::Error> for RpcError {
    fn from(error: io::Error) -> Self {
        Self {
            code: if error.kind() == io::ErrorKind::InvalidInput {
                -32602
            } else {
                -32000
            },
            message: error.to_string(),
        }
    }
}
impl From<serde_json::Error> for RpcError {
    fn from(error: serde_json::Error) -> Self {
        Self {
            code: -32602,
            message: error.to_string(),
        }
    }
}
fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
fn parse<T: serde::de::DeserializeOwned>(params: Value) -> Result<T, RpcError> {
    Ok(serde_json::from_value(params)?)
}
fn sid(params: Value) -> Result<SessionId, RpcError> {
    Ok(parse::<rpc::SessionRef>(params)?.session_id)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Poll {
    session_id: SessionId,
    #[serde(default)]
    after: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Messages {
    session_id: SessionId,
    #[serde(default)]
    after: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Approval {
    session_id: SessionId,
    request_id: String,
    decision: String,
    #[serde(default)]
    answers: Option<Value>,
}

impl Backend {
    async fn next_events(&self, params: Value) -> Result<Value, RpcError> {
        let p: rpc::NextEvents = parse(params)?;
        if !(1..=30000).contains(&p.timeout_ms) || p.max_events.is_some_and(|n| n == 0 || n > 128) {
            return Err(invalid("Invalid event batch bounds").into());
        }
        let events = self
            .queue(&p.subscription_id)?
            .wait(
                std::time::Duration::from_millis(p.timeout_ms),
                p.max_events.unwrap_or(1),
            )
            .await?;
        Ok(json!({"events":events}))
    }
    fn subscribe(&self, session: Option<SessionId>, streams: bool) -> io::Result<String> {
        let mut subscriptions = self.subscriptions.lock().unwrap();
        subscriptions.retain(|_, s| {
            let keep = s.touched.elapsed() < std::time::Duration::from_secs(90);
            if !keep {
                s.queue.close();
            }
            keep
        });
        if subscriptions.len() >= 128 {
            return Err(io::Error::other("Too many event subscriptions"));
        }
        let id = axo_protocol::new_uuid_v4()?;
        subscriptions.insert(
            id.clone(),
            Subscription {
                session,
                scope: if streams {
                    EventScope::Streams
                } else {
                    EventScope::Catalog
                },
                queue: Arc::new(
                    axo_ipc::EventQueue::new(512, || Event::SubscriptionLagged)
                        .with_byte_limit(4 * 1024 * 1024, |event| {
                            serde_json::to_vec(event).map_or(0, |v| v.len())
                        }),
                ),
                touched: std::time::Instant::now(),
            },
        );
        Ok(id)
    }
    fn queue(&self, id: &str) -> io::Result<Arc<axo_ipc::EventQueue<Event>>> {
        self.subscriptions
            .lock()
            .unwrap()
            .get_mut(id)
            .map(|s| {
                s.touched = std::time::Instant::now();
                s.queue.clone()
            })
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Subscription not found"))
    }
    fn unsubscribe(&self, id: &str) -> io::Result<()> {
        if let Some(s) = self.subscriptions.lock().unwrap().remove(id) {
            s.queue.close();
        }
        Ok(())
    }
    fn publish(&self, event: Event) {
        for s in self.subscriptions.lock().unwrap().values() {
            if s.scope.accepts(event.scope())
                && (s.session.is_none() || s.session == event.session_id())
            {
                s.queue.push(event.clone());
            }
        }
    }
    fn publish_snapshot(&self, id: SessionId) {
        if let Ok(value) = self.record(id) {
            if let Ok(record) = serde_json::from_value(value) {
                self.publish(Event::snapshot(record));
            }
        }
    }
    fn session(&self, id: SessionId) -> io::Result<Arc<LiveSession>> {
        if !axo_store::coding::session_exists(&self.database.lock().unwrap(), id)? {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Open Codex session not found",
            ));
        }
        Ok(self.sessions.lock().unwrap().entry(id).or_default().clone())
    }

    fn record(&self, id: SessionId) -> io::Result<Value> {
        let row = axo_store::open_session_row(&self.database.lock().unwrap(), id)?;
        let session = self.session(id)?;
        let thread = axo_store::coding::thread_id(&self.database.lock().unwrap(), id)?;
        let runtime = session.runtime.lock().unwrap();
        let shells=runtime.pseudoconsole.as_ref().map(|t| json!({"id":t.shell,"paneId":null,"role":"terminal","processId":t.pid,"initialPwd":row.initial_pwd,"ptyDevice":"ConPTY","attachSocketPath":"","available":t.is_alive(),"availabilityReason":if t.is_alive() {Value::Null} else {json!("Terminal exited")}})).into_iter().collect::<Vec<_>>();
        Ok(
            json!({"id":id,"agent":"codex","name":row.manual_name.clone().unwrap_or(row.name),
            "manualName":row.manual_name,"emoji":row.emoji,"piSessionFile":null,"piSessionId":null,"shells":shells,"layout":null,
            "initialPwd":row.initial_pwd,"workspaceId":row.workspace_id,"workspaceName":row.workspace_name,
            "createdAt":row.created_at,"lastMessageAt":row.last_message_at,
            "status":runtime.status.unwrap_or(SessionStatus::Ready),"error":runtime.error,
            "connected":runtime.agent.as_ref().is_some_and(|a| a.is_alive()),
            "agentProcessId":runtime.agent.as_ref().map(|a|a.process_id()),
            "threadId":thread,
            "pendingRequests":runtime.pending.values().collect::<Vec<_>>(),"eventSequence":runtime.sequence}),
        )
    }

    fn create_session(&self, workspace: &str) -> io::Result<Value> {
        let mut db = self.database.lock().unwrap();
        let cwd = axo_store::open_workspace_directory(&db, workspace)?;
        if !cwd.is_dir() {
            return Err(invalid("Workspace directory does not exist"));
        }
        let id = SessionId::new_v4()?;
        let workspace_name = axo_store::list_open_workspaces(&db)?
            .into_iter()
            .find(|w| w.workspace_id == workspace)
            .map(|w| w.name)
            .ok_or_else(|| invalid("Workspace not found"))?;
        let name = format!(
            "{workspace_name} · Codex {}",
            axo_store::next_session_ordinal(&db, workspace)?
        );
        axo_store::coding::insert_session(&mut db, id, workspace, &cwd, &name)?;
        drop(db);
        self.record(id)
    }

    fn dispatch(self: &Arc<Self>, name: &str, params: Value) -> Result<Value, RpcError> {
        let id = params
            .get("sessionId")
            .and_then(|v| serde_json::from_value::<SessionId>(v.clone()).ok());
        let result = self.dispatch_inner(name, params)?;
        match name {
            method::SESSION_CLOSE => {
                if let Some(session_id) = id {
                    self.publish(Event::SessionRemoved { session_id });
                }
            }
            method::WORKSPACE_CREATE => {
                if let Some(workspace_id) = result["workspace"]["workspaceId"].as_str() {
                    self.publish(Event::WorkspaceChanged {
                        workspace_id: workspace_id.into(),
                    });
                }
                if let Ok(id) = serde_json::from_value(result["session"]["id"].clone()) {
                    self.publish_snapshot(id);
                }
            }
            method::WORKSPACE_SESSION_CREATE => {
                if let Ok(id) = serde_json::from_value(result["id"].clone()) {
                    self.publish_snapshot(id);
                }
            }
            method::SESSION_RENAME
            | method::SESSION_REOPEN
            | method::SESSION_PROMPT
            | "axo.session.open"
            | "axo.session.approval.respond"
            | "axo.session.interrupt"
            | "axo.terminal.create"
            | "axo.terminal.close" => {
                if let Some(id) = id {
                    self.publish_snapshot(id);
                }
            }
            _ => {}
        }
        Ok(result)
    }

    fn dispatch_inner(self: &Arc<Self>, name: &str, params: Value) -> Result<Value, RpcError> {
        match name {
            "axo.terminal.create" => {
                let id = sid(params)?;
                let session = self.session(id)?;
                let _operation = session.operation.lock().unwrap();
                if let Some(t) = session
                    .runtime
                    .lock()
                    .unwrap()
                    .pseudoconsole
                    .as_ref()
                    .filter(|t| t.is_alive())
                {
                    return Ok(t.replay());
                }
                let cwd = axo_store::session_initial_pwd(&self.database.lock().unwrap(), id)?;
                let shell = axo_protocol::ShellId::new(
                    self.next_shell
                        .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                        .into(),
                )
                .ok_or_else(|| io::Error::other("Shell ID exhausted"))?;
                let output = Arc::downgrade(self);
                let exited = Arc::downgrade(self);
                let pty = terminal::Terminal::spawn(
                    &cwd,
                    shell,
                    move |sequence, bytes| {
                        if let Some(b) = output.upgrade() {
                            b.publish(Event::TerminalOutput {
                                session_id: id,
                                shell_id: shell,
                                sequence,
                                data: axo_protocol::base64::encode(&bytes),
                            });
                        }
                    },
                    move || {
                        if let Some(b) = exited.upgrade() {
                            b.publish(Event::ShellActivity {
                                session_id: id,
                                shell_id: shell,
                                activity: axo_protocol::ShellActivity::Exited,
                            });
                        }
                    },
                )?;
                let replay = pty.replay();
                session.runtime.lock().unwrap().pseudoconsole = Some(pty);
                Ok(replay)
            }
            "axo.terminal.replay"
            | "axo.terminal.close"
            | method::TERMINAL_INPUT
            | method::TERMINAL_RESIZE => {
                #[derive(Deserialize)]
                #[serde(rename_all = "camelCase", deny_unknown_fields)]
                struct Ref {
                    session_id: SessionId,
                    shell_id: axo_protocol::ShellId,
                }
                let (id, shell) = match name {
                    method::TERMINAL_INPUT => {
                        let p: rpc::TerminalInput = parse(params.clone())?;
                        (p.session_id, p.shell_id)
                    }
                    method::TERMINAL_RESIZE => {
                        let p: rpc::TerminalResize = parse(params.clone())?;
                        (p.session_id, p.shell_id)
                    }
                    _ => {
                        let p: Ref = parse(params.clone())?;
                        (p.session_id, p.shell_id)
                    }
                };
                let session = self.session(id)?;
                let pty = session
                    .runtime
                    .lock()
                    .unwrap()
                    .pseudoconsole
                    .as_ref()
                    .filter(|t| t.shell == shell)
                    .cloned()
                    .ok_or_else(|| {
                        io::Error::new(io::ErrorKind::NotFound, "Terminal pane not found")
                    })?;
                match name {
                    "axo.terminal.replay" => Ok(pty.replay()),
                    "axo.terminal.close" => {
                        pty.stop();
                        session.runtime.lock().unwrap().pseudoconsole.take();
                        Ok(json!({"closed":true}))
                    }
                    method::TERMINAL_INPUT => {
                        let p: rpc::TerminalInput = parse(params)?;
                        let bytes = axo_protocol::base64::decode_terminal_input(&p.data)?;
                        pty.write(p.sequence, &bytes)?;
                        Ok(json!({"written":true}))
                    }
                    _ => {
                        let p: rpc::TerminalResize = parse(params)?;
                        pty.resize(p.rows, p.columns)?;
                        Ok(json!({"resized":true}))
                    }
                }
            }
            method::SESSION_SUBSCRIBE => {
                let p: rpc::Subscribe = parse(params)?;
                if let Some(id) = p.session_id {
                    self.session(id)?;
                }
                Ok(
                    json!({"subscriptionId":self.subscribe(p.session_id,p.include_terminal_output)?}),
                )
            }
            method::SESSION_UNSUBSCRIBE => {
                let p: rpc::Unsubscribe = parse(params)?;
                self.unsubscribe(&p.subscription_id)?;
                Ok(json!({"unsubscribed":true}))
            }
            method::RELAY_STATUS | method::RELAY_CONNECT | method::RELAY_LINK => {
                let relay = self
                    .relay
                    .lock()
                    .unwrap()
                    .clone()
                    .ok_or_else(|| io::Error::other("Relay unavailable"))?;
                if name == method::RELAY_LINK {
                    let p: rpc::LinkHost = parse(params)?;
                    let _link = relay.link_lock.lock().unwrap();
                    let label = axo_relay::link_host(
                        &relay.endpoint,
                        &p.code,
                        relay.host.as_ref(),
                        relay.host.as_ref(),
                        relay.credentials.as_ref(),
                    )?;
                    relay.control.request_connect()?;
                    Ok(json!({"linked":true,"hostLabel":label}))
                } else {
                    if name == method::RELAY_CONNECT {
                        relay.control.request_connect()?;
                    }
                    Ok(serde_json::to_value(relay.control.snapshot()?)?)
                }
            }
            method::PROTOCOL_NEGOTIATE => {
                let p: rpc::NegotiateProtocol = parse(params)?;
                if p.protocol_version != 1 && p.protocol_version != rpc::PROTOCOL_VERSION {
                    return Err(invalid("Unsupported protocol version").into());
                }
                Ok(
                    json!({"protocolVersion":p.protocol_version,"methods":METHODS,"platform":"windows","agent":"codex"}),
                )
            }
            method::DAEMON_HEALTH => Ok(
                json!({"version":env!("CARGO_PKG_VERSION"),"buildNumber":option_env!("AXO_BUILD_NUMBER").unwrap_or("1").parse::<u64>().unwrap_or(1),"status":"running","ready":true,"platform":"windows","agent":"codex","codexExecutable":self.codex}),
            ),
            method::WORKSPACE_LIST => Ok(
                json!({"workspaces":axo_store::list_open_workspaces(&self.database.lock().unwrap())?}),
            ),
            method::WORKSPACE_CREATE => {
                let p: rpc::CreateWorkspace = parse(params)?;
                let cwd = canonical_directory(&p.directory_path)?;
                let name = p.name.trim();
                if name.is_empty() || name.len() > 200 {
                    return Err(invalid("Workspace name must contain 1–200 bytes").into());
                }
                let id = axo_protocol::new_uuid_v4()?;
                axo_store::insert_workspace(&self.database.lock().unwrap(), &id, name, &cwd, None)?;
                let session = self.create_session(&id)?;
                Ok(
                    json!({"workspace":{"workspaceId":id,"name":name,"directoryPath":cwd},"session":session}),
                )
            }
            method::WORKSPACE_RENAME => {
                let p: rpc::RenameWorkspace = parse(params)?;
                if p.name.trim().is_empty() || p.name.len() > 200 {
                    return Err(invalid("Workspace name must contain 1–200 bytes").into());
                }
                axo_store::rename_open_workspace(
                    &self.database.lock().unwrap(),
                    &p.workspace_id,
                    p.name.trim(),
                )?;
                Ok(json!({"saved":true}))
            }
            method::WORKSPACE_SESSION_CREATE => {
                let p: rpc::WorkspaceRef = parse(params)?;
                Ok(self.create_session(&p.workspace_id)?)
            }
            method::SESSION_LIST => {
                let ids = axo_store::coding::list_sessions(&self.database.lock().unwrap(), false)?;
                Ok(
                    json!({"sessions":ids.into_iter().map(|id|self.record(id)).collect::<io::Result<Vec<_>>>()?,"resumeSessionId":null}),
                )
            }
            method::SESSION_RENAME => {
                let p: rpc::RenameSession = parse(params)?;
                if p.name.trim().is_empty() || p.name.len() > 200 {
                    return Err(invalid("Session name must contain 1–200 bytes").into());
                }
                let session = self.session(p.session_id)?;
                let _operation = session.operation.lock().unwrap();
                axo_store::set_manual_session_name(
                    &self.database.lock().unwrap(),
                    p.session_id,
                    p.name.trim(),
                )?;
                Ok(json!({"saved":true}))
            }
            "axo.session.open" => {
                let id = sid(params)?;
                let session = self.session(id)?;
                let _operation = session.operation.lock().unwrap();
                self.connect(id, &session)?;
                self.record(id).map_err(Into::into)
            }
            method::SESSION_PROMPT => {
                let p: rpc::PromptSession = parse(params)?;
                if p.text.trim().is_empty() || p.text.len() > 16000 {
                    return Err(invalid("Message must contain 1–16000 bytes").into());
                }
                if p.from_session_id.is_some() {
                    return Err(
                        invalid("Agent-to-agent prompting is not implemented on Windows").into(),
                    );
                }
                let session = self.session(p.session_id)?;
                let _operation = session.operation.lock().unwrap();
                let agent = self.connect(p.session_id, &session)?;
                let thread =
                    axo_store::coding::thread_id(&self.database.lock().unwrap(), p.session_id)?
                        .ok_or_else(|| io::Error::other("Codex thread missing"))?;
                {
                    let mut runtime = session.runtime.lock().unwrap();
                    if runtime.turn.is_some() || runtime.status == Some(SessionStatus::Working) {
                        return Err(
                            invalid("Codex is working; wait or stop the current turn").into()
                        );
                    }
                    runtime.status = Some(SessionStatus::Working);
                    runtime.error = None;
                    runtime.remote_command = None;
                    runtime.turn_entries.clear();
                }
                match agent.request(
                    "turn/start",
                    json!({"threadId":thread,"input":[{"type":"text","text":p.text}]}),
                ) {
                    Ok(result) => {
                        let mut runtime = session.runtime.lock().unwrap();
                        if runtime.status == Some(SessionStatus::Working) && runtime.turn.is_none()
                        {
                            runtime.turn = result["turn"]["id"].as_str().map(str::to_owned);
                        }
                        Ok(json!({"accepted":true,"turnId":result["turn"]["id"]}))
                    }
                    Err(error) => {
                        session.runtime.lock().unwrap().status = Some(SessionStatus::Ready);
                        Err(error.into())
                    }
                }
            }
            "axo.session.interrupt" => {
                let id = sid(params)?;
                let session = self.session(id)?;
                let _operation = session.operation.lock().unwrap();
                let (agent, turn) = {
                    let r = session.runtime.lock().unwrap();
                    (r.agent.clone(), r.turn.clone())
                };
                if let (Some(agent), Some(turn)) = (agent, turn) {
                    let thread = axo_store::coding::thread_id(&self.database.lock().unwrap(), id)?;
                    agent.request("turn/interrupt", json!({"threadId":thread,"turnId":turn}))?;
                }
                Ok(json!({"interrupted":true}))
            }
            "axo.session.messages" => {
                let p: Messages = parse(params)?;
                self.session(p.session_id)?;
                Ok(
                    json!({"messages":axo_store::coding::messages(&self.database.lock().unwrap(),p.session_id,p.after)?}),
                )
            }
            "axo.session.events.poll" => {
                let p: Poll = parse(params)?;
                let session = self.session(p.session_id)?;
                let runtime = session.runtime.lock().unwrap();
                let earliest = runtime
                    .events
                    .front()
                    .and_then(|e| e["sequence"].as_u64())
                    .unwrap_or(runtime.sequence + 1);
                let events: Vec<_> = runtime
                    .events
                    .iter()
                    .filter(|e| e["sequence"].as_u64().unwrap() > p.after)
                    .take(200)
                    .collect();
                Ok(
                    json!({"events":events,"sequence":runtime.sequence,"reset":p.after>runtime.sequence || p.after.saturating_add(1)<earliest,
                    "status":runtime.status.unwrap_or(SessionStatus::Ready),"error":runtime.error,"pendingRequests":runtime.pending.values().collect::<Vec<_>>()}),
                )
            }
            "axo.session.approval.respond" => {
                let p: Approval = parse(params)?;
                let session = self.session(p.session_id)?;
                let _operation = session.operation.lock().unwrap();
                let (request, agent) = {
                    let r = session.runtime.lock().unwrap();
                    (
                        r.pending
                            .get(&p.request_id)
                            .cloned()
                            .ok_or_else(|| invalid("Approval request has expired"))?,
                        r.agent
                            .clone()
                            .ok_or_else(|| io::Error::other("Codex is not running"))?,
                    )
                };
                let method = request["method"].as_str().unwrap_or_default();
                let result = match method {
                    "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
                        if !["accept", "decline", "cancel"].contains(&p.decision.as_str()) {
                            return Err(invalid("Invalid approval decision").into());
                        }
                        json!({"decision":p.decision})
                    }
                    "item/tool/requestUserInput" => {
                        json!({"answers":p.answers.unwrap_or_else(||json!({}))})
                    }
                    "mcpServer/elicitation/request" => {
                        json!({"action":if p.decision=="accept" {"accept"} else {"decline"},"content":null})
                    }
                    _ => {
                        agent.reject_request(
                            request["id"].clone(),
                            "This interaction is not supported by the Axo Windows preview",
                        )?;
                        let mut runtime = session.runtime.lock().unwrap();
                        runtime.pending.remove(&p.request_id);
                        return Ok(json!({"saved":true}));
                    }
                };
                agent.respond(request["id"].clone(), result)?;
                let mut runtime = session.runtime.lock().unwrap();
                runtime.pending.remove(&p.request_id);
                let resolved = runtime
                    .remote_questions
                    .iter()
                    .filter(|(_, (request, _))| request == &p.request_id)
                    .map(|(id, _)| id.clone())
                    .collect::<Vec<_>>();
                for question in resolved {
                    runtime.remote_questions.remove(&question);
                    self.publish(Event::ElicitationResolved {
                        id: question,
                        session_id: p.session_id,
                        action: if p.decision == "accept" {
                            axo_protocol::elicitation::ElicitationAction::Accept
                        } else {
                            axo_protocol::elicitation::ElicitationAction::Decline
                        },
                    });
                }
                if runtime.pending.is_empty() {
                    runtime.status = Some(if runtime.turn.is_some() {
                        SessionStatus::Working
                    } else {
                        SessionStatus::Ready
                    });
                }
                Ok(json!({"saved":true}))
            }
            "axo.terminal.open" => {
                let id = sid(params)?;
                let session = self.session(id)?;
                let _operation = session.operation.lock().unwrap();
                let cwd = axo_store::session_initial_pwd(&self.database.lock().unwrap(), id)?;
                use std::os::windows::process::CommandExt;
                let mut runtime = session.runtime.lock().unwrap();
                if let Some(child) = runtime.terminal.as_mut() {
                    if child.try_wait()?.is_none() {
                        return Ok(json!({"opened":true,"processId":child.id()}));
                    }
                }
                let executable = PathBuf::from(
                    std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()),
                )
                .join("System32/WindowsPowerShell/v1.0/powershell.exe");
                // A real interactive terminal, in the Session's workspace, tracked by axod.
                let child = Command::new(executable)
                    .args(["-NoLogo", "-NoProfile", "-NoExit"])
                    .env_remove("PSModulePath")
                    .current_dir(cwd)
                    .creation_flags(0x10)
                    .spawn()?;
                let pid = child.id();
                runtime.terminal = Some(child);
                Ok(json!({"opened":true,"processId":pid}))
            }
            method::SESSION_CLOSE => {
                let id = sid(params)?;
                let session = self.session(id)?;
                let _operation = session.operation.lock().unwrap();
                let (agent, terminal, pty) = {
                    let mut r = session.runtime.lock().unwrap();
                    r.generation += 1;
                    (r.agent.take(), r.terminal.take(), r.pseudoconsole.take())
                };
                if let Some(pty) = pty {
                    pty.stop();
                }
                if let Some(agent) = agent {
                    agent.stop();
                }
                if let Some(mut terminal) = terminal {
                    let _ = terminal.kill();
                    let _ = terminal.wait();
                }
                axo_store::archive_session(&mut self.database.lock().unwrap(), id, "user_closed")?;
                self.sessions.lock().unwrap().remove(&id);
                Ok(json!({"archivedSessionId":id,"replacement":null}))
            }
            method::SESSION_REOPEN => {
                let id = sid(params)?;
                axo_store::coding::reopen(&self.database.lock().unwrap(), id)?;
                self.record(id).map_err(Into::into)
            }
            "axo.daemon.stop" => Ok(json!({"stopping":true})),
            _ => Err(RpcError {
                code: -32601,
                message: format!("Method is not available on Windows: {name}"),
            }),
        }
    }

    /// Called with the Session operation lock, without the catalog or runtime lock.
    fn connect(
        self: &Arc<Self>,
        id: SessionId,
        session: &Arc<LiveSession>,
    ) -> io::Result<Arc<Codex>> {
        if let Some(agent) = session
            .runtime
            .lock()
            .unwrap()
            .agent
            .as_ref()
            .filter(|a| a.is_alive())
            .cloned()
        {
            return Ok(agent);
        }
        let (generation, old_agent) = {
            let mut runtime = session.runtime.lock().unwrap();
            runtime.generation += 1;
            runtime.status = Some(SessionStatus::Starting);
            runtime.turn = None;
            runtime.pending.clear();
            (runtime.generation, runtime.agent.take())
        };
        // Drop outside the runtime lock. The old reader may still report an exit; its
        // generation must not overwrite the new process's state or displayed conversation.
        drop(old_agent);
        let cwd = axo_store::session_initial_pwd(&self.database.lock().unwrap(), id)?;
        let weak = Arc::downgrade(self);
        let live = Arc::downgrade(session);
        let agent = Arc::new(
            Codex::spawn(&self.codex, &cwd, move |event| {
                if let (Some(backend), Some(session)) = (weak.upgrade(), live.upgrade()) {
                    backend.on_event(id, &session, generation, event);
                }
            })
            .map_err(|error| {
                let mut runtime = session.runtime.lock().unwrap();
                runtime.status = Some(SessionStatus::Unavailable);
                runtime.error = Some(error.to_string());
                error
            })?,
        );
        let thread = axo_store::coding::thread_id(&self.database.lock().unwrap(), id)?;
        let result=match thread {
            Some(thread)=>agent.request("thread/resume",json!({"threadId":thread,"cwd":cwd,"excludeTurns":true,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"})),
            None=>agent.request("thread/start",json!({"cwd":cwd,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write","serviceName":"axo"})),
        }?;
        let thread = result["thread"]["id"]
            .as_str()
            .ok_or_else(|| io::Error::other("Codex did not return a thread ID"))?;
        axo_store::coding::set_thread_id(&self.database.lock().unwrap(), id, thread)?;
        let mut runtime = session.runtime.lock().unwrap();
        runtime.agent = Some(agent.clone());
        runtime.status = Some(SessionStatus::Ready);
        runtime.error = None;
        Ok(agent)
    }

    fn on_event(&self, id: SessionId, session: &LiveSession, generation: u64, event: Value) {
        let mut runtime = session.runtime.lock().unwrap();
        if runtime.generation != generation {
            return;
        }
        let method = event["method"].as_str().unwrap_or_default();
        if method == "item/completed" {
            let item = &event["params"]["item"];
            if let (Some(item_id), Some((role, text))) = (item["id"].as_str(), message_text(item)) {
                if let Err(error) = axo_store::coding::save_message(
                    &self.database.lock().unwrap(),
                    id,
                    item_id,
                    role,
                    &text,
                ) {
                    log::error!("event=catalog.message_failed kind={:?}", error.kind());
                    runtime.error = Some("Could not save the conversation to the catalog".into());
                }
            }
        }
        match method {
            "turn/started" => {
                runtime.turn = event["params"]["turn"]["id"].as_str().map(str::to_owned);
                runtime.status = Some(SessionStatus::Working);
                runtime.turn_entries.clear();
                runtime.progress.clear();
            }
            "turn/completed" => {
                runtime.turn = None;
                runtime.pending.clear();
                runtime.status = Some(SessionStatus::Ready);
                runtime.remote_command = None;
                runtime.turn_entries.clear();
                runtime.progress.clear();
                if event["params"]["turn"]["status"] == "failed" {
                    runtime.error = Some(
                        event["params"]["turn"]["error"]["message"]
                            .as_str()
                            .unwrap_or("Codex turn failed")
                            .into(),
                    );
                }
            }
            "error" => {
                runtime.error = Some(
                    event["params"]["error"]["message"]
                        .as_str()
                        .unwrap_or("Codex error")
                        .into(),
                );
            }
            "axo/codex/exited" => {
                runtime.turn = None;
                runtime.pending.clear();
                runtime.status = Some(SessionStatus::Unavailable);
                runtime.error =
                    Some("Codex app-server exited. Open the session again to reconnect.".into());
            }
            "serverRequest/resolved" => {
                let key = event["params"]["requestId"].to_string();
                runtime.pending.remove(&key);
                if runtime.pending.is_empty() {
                    runtime.status = Some(if runtime.turn.is_some() {
                        SessionStatus::Working
                    } else {
                        SessionStatus::Ready
                    });
                }
            }
            _ => {}
        }
        if method == "item/completed" {
            if let Some(entry) = event["params"]["item"]["id"].as_str() {
                runtime.turn_entries.push(entry.to_owned());
            }
        }
        let progress = if method == "item/agentMessage/delta" {
            let item = event["params"]["itemId"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            let text = runtime.progress.entry(item).or_default();
            if text.len() < 128 * 1024 {
                text.push_str(event["params"]["delta"].as_str().unwrap_or_default());
            }
            Some(
                json!({"type":"message_update","message":{"role":"assistant","content":[{"type":"text","text":text}],"timestamp":axo_store::unix_timestamp()*1000}}),
            )
        } else {
            None
        };
        if event.get("id").is_some() {
            let key = event["id"].to_string();
            runtime.pending.insert(key.clone(), event.clone());
            runtime.status = Some(SessionStatus::NeedsAttention);
            if matches!(
                method,
                "item/commandExecution/requestApproval" | "item/fileChange/requestApproval"
            ) {
                let message = format!("Codex requests permission:\n{}", event["params"]);
                // A remote approval must contain the entire action being approved. Larger
                // requests stay on the PC, rather than authorizing an unseen truncation.
                if message.chars().count() <= axo_protocol::elicitation::MAX_MESSAGE_CHARS {
                    if let Ok(question) = axo_protocol::new_uuid_v4() {
                        let now = axo_store::unix_timestamp().max(0) as u64 * 1000;
                        let elicitation = axo_protocol::elicitation::Elicitation {
                            id: question.clone(),
                            session_id: id,
                            kind: axo_protocol::elicitation::ElicitationKind::Confirm,
                            asked_by: axo_protocol::elicitation::Asker::Agent,
                            message,
                            input: None,
                            created_at: now,
                            expires_at: now + axo_protocol::elicitation::TIMEOUT_MS,
                        };
                        runtime
                            .remote_questions
                            .insert(question, (key, elicitation.clone()));
                        self.publish(Event::ElicitationRequested { elicitation });
                    }
                }
            }
        }
        let expired = runtime
            .remote_questions
            .iter()
            .filter(|(_, (request, _))| !runtime.pending.contains_key(request))
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for question in expired {
            runtime.remote_questions.remove(&question);
            self.publish(Event::ElicitationResolved {
                id: question,
                session_id: id,
                action: axo_protocol::elicitation::ElicitationAction::Cancel,
            });
        }
        runtime.sequence += 1;
        let sequence = runtime.sequence;
        let raw_event = event.clone();
        let changed = matches!(
            method,
            "turn/started"
                | "turn/completed"
                | "axo/codex/exited"
                | "item/completed"
                | "serverRequest/resolved"
        ) || event.get("id").is_some();
        let settled = method == "turn/completed";
        let envelope = json!({"sequence":sequence,"event":event});
        runtime.event_bytes += envelope.to_string().len();
        runtime.events.push_back(envelope);
        while runtime.events.len() > MAX_EVENTS
            || (runtime.events.len() > 1 && runtime.event_bytes > MAX_EVENT_BYTES)
        {
            if let Some(old) = runtime.events.pop_front() {
                runtime.event_bytes = runtime.event_bytes.saturating_sub(old.to_string().len());
            }
        }
        drop(runtime);
        self.publish(Event::PiEvent {
            session_id: id,
            pi_session_id: id.to_string(),
            stream_id: generation.to_string(),
            sequence,
            name: "codex.event".into(),
            data: raw_event,
        });
        if let Some(data) = progress {
            self.publish(Event::PiEvent {
                session_id: id,
                pi_session_id: id.to_string(),
                stream_id: generation.to_string(),
                sequence,
                name: "message.update".into(),
                data,
            });
        }
        if settled {
            self.publish(Event::PiEvent {
                session_id: id,
                pi_session_id: id.to_string(),
                stream_id: generation.to_string(),
                sequence,
                name: "agent.settled".into(),
                data: Value::Null,
            });
        }
        if changed {
            self.publish_snapshot(id);
        }
    }
}

fn canonical_directory(path: &Path) -> io::Result<PathBuf> {
    if !path.is_absolute() || !path.is_dir() {
        return Err(invalid("Choose an existing absolute workspace directory"));
    }
    // Windows canonical paths may contain the extended-path prefix; strip it for CLI compatibility.
    let canonical = std::fs::canonicalize(path)?;
    let text = canonical.to_string_lossy();
    if let Some(unc) = text.strip_prefix(r"\\?\UNC\") {
        return Ok(PathBuf::from(format!(r"\\{unc}")));
    }
    Ok(text
        .strip_prefix(r"\\?\")
        .map(PathBuf::from)
        .unwrap_or(canonical))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn late_exit_from_old_process_cannot_disconnect_replacement() {
        let db = axo_store::Connection::open_in_memory().unwrap();
        let backend = Backend {
            database: Mutex::new(db),
            sessions: Mutex::new(HashMap::new()),
            codex: PathBuf::from("codex"),
            stop: tokio::sync::Notify::new(),
            directory: std::env::temp_dir(),
            relay: Mutex::new(None),
            subscriptions: Mutex::new(HashMap::new()),
            next_shell: std::sync::atomic::AtomicU32::new(1),
        };
        let session = LiveSession::default();
        {
            let mut r = session.runtime.lock().unwrap();
            r.generation = 2;
            r.status = Some(SessionStatus::Ready);
        }
        backend.on_event(
            SessionId::new_v4().unwrap(),
            &session,
            1,
            json!({"method":"axo/codex/exited","params":{}}),
        );
        let r = session.runtime.lock().unwrap();
        assert_eq!(r.status, Some(SessionStatus::Ready));
        assert_eq!(r.sequence, 0);
    }
    #[test]
    fn windows_negotiation_does_not_claim_apple_or_pi_features() {
        assert!(METHODS.contains(&method::SESSION_PROMPT));
        assert!(!METHODS.contains(&method::SESSION_PI_RESTART_FORCE));
        assert!(METHODS.contains(&method::RELAY_CONNECT));
    }
    #[test]
    fn unknown_or_misspelled_parameters_are_rejected() {
        assert!(serde_json::from_value::<Poll>(json!({"sessionId":"bad","after":0})).is_err());
        assert!(
            serde_json::from_value::<Messages>(
                json!({"sessionId":SessionId::new_v4().unwrap(),"aftr":1})
            )
            .is_err()
        );
    }
}
