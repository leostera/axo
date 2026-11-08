//! Local Windows vertical slice of axod. Shares Axo IDs, workspaces and SQLite sessions,
//! with a Codex app-server agent and a per-user named-pipe transport. Apple-only extensions
//! are deliberately absent from negotiation. No listener is exposed to the network.
mod security;

use axo_agent::codex::{Codex, message_text};
use axo_protocol::rpc::{self, method};
use axo_protocol::{SessionId, SessionStatus};
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
}

pub fn serve(directory: Option<PathBuf>, pipe: Option<String>, codex: PathBuf) -> io::Result<()> {
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
        });
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
        for session in backend.sessions.lock().unwrap().values() {
            let mut runtime = session.runtime.lock().unwrap();
            if let Some(agent) = runtime.agent.take() {
                agent.stop();
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
                match tokio::task::spawn_blocking(move || {
                    state.dispatch(&request.method, request.params)
                })
                .await
                {
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
        Ok(
            json!({"id":id,"agent":"codex","name":row.manual_name.clone().unwrap_or(row.name),
            "manualName":row.manual_name,"emoji":row.emoji,"piSessionFile":null,"piSessionId":null,"shells":[],"layout":null,
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
        let name = format!("Codex {}", axo_store::next_session_ordinal(&db, workspace)?);
        axo_store::coding::insert_session(&mut db, id, workspace, &cwd, &name)?;
        drop(db);
        self.record(id)
    }

    fn dispatch(self: &Arc<Self>, name: &str, params: Value) -> Result<Value, RpcError> {
        match name {
            method::PROTOCOL_NEGOTIATE => {
                let p: rpc::NegotiateProtocol = parse(params)?;
                if p.protocol_version != 1 {
                    return Err(invalid("Only protocol version 1 is supported").into());
                }
                Ok(
                    json!({"protocolVersion":1,"methods":METHODS,"platform":"windows","agent":"codex"}),
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
                    .args(["-NoLogo", "-NoExit"])
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
                let (agent, terminal) = {
                    let mut r = session.runtime.lock().unwrap();
                    r.generation += 1;
                    (r.agent.take(), r.terminal.take())
                };
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
            }
            "turn/completed" => {
                runtime.turn = None;
                runtime.pending.clear();
                runtime.status = Some(SessionStatus::Ready);
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
        if event.get("id").is_some() {
            let key = event["id"].to_string();
            runtime.pending.insert(key, event.clone());
            runtime.status = Some(SessionStatus::NeedsAttention);
        }
        runtime.sequence += 1;
        let sequence = runtime.sequence;
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
        assert!(!METHODS.contains(&method::RELAY_CONNECT));
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
