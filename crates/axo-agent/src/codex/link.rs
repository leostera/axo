//! axod's link to one Codex app-server (RFD0072, Codex): a future that connects to its Unix
//! socket, speaks its JSON-RPC over WebSocket, starts or rejoins the Session's thread, reports
//! what happens in it as Axo events, and turns axod's commands into Codex requests.
//!
//! The TUI in the pane is another client of the same server; both see every notification of
//! the thread. The link owns the server process: dropping the link stops it, and the TUI exits
//! when its server goes.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use axo_protocol::asset::FetchedAttachment;
use axo_protocol::commands::{CommandId, StopTarget};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;

use crate::codex::rpc::{self, Incoming, RequestId};
use crate::codex::thread::{
    Emitted, Observed, SendPlan, StopPlan, Thread, TurnRequest, reasoning_effort,
};
use crate::runtime::{AgentEvent, CommandResult, QueuedDelivery, RejectReason};

/// How long the server gets to answer a request of the link's own (start, resume, list).
const SETUP_TIMEOUT: Duration = Duration::from_secs(30);
/// Waits between tries while the server is not listening yet, doubling up to the last.
const RETRY_FIRST: Duration = Duration::from_millis(50);
const RETRY_LAST: Duration = Duration::from_secs(1);
/// How long the link tries to reach a server that never listens.
const CONNECT_DEADLINE: Duration = Duration::from_secs(30);
const QUEUED_COMMANDS: usize = 32;

#[derive(Clone, Debug)]
pub struct LinkConfig {
    /// The app-server's socket.
    pub socket: PathBuf,
    /// The Session's thread, made by [`create_thread`] when the Session was new.
    pub thread_id: String,
    /// Axo's brief, as the thread's developer instructions.
    pub instructions: Option<String>,
    /// Prefix for log lines, e.g. `session_id=… shell_id=2`.
    pub log_context: String,
}

/// A command for the link, with where its answer goes.
#[derive(Debug)]
enum Action {
    Send {
        text: String,
        delivery: Option<QueuedDelivery>,
        command_id: Option<CommandId>,
        attachments: Vec<FetchedAttachment>,
    },
    Stop(StopTarget),
    ResumeTurn,
    Shutdown,
    SetModel {
        model: Option<String>,
        thinking_level: Option<String>,
    },
}

#[derive(Debug)]
struct Request {
    action: Action,
    reply: oneshot::Sender<io::Result<CommandResult>>,
}

/// Sends commands to the thread a link follows. Cheap to clone.
#[derive(Clone, Debug)]
pub struct LinkCommands(mpsc::Sender<Request>);

/// The link's end of [`LinkCommands`].
#[derive(Debug)]
pub struct LinkRequests(mpsc::Receiver<Request>);

pub fn command_channel() -> (LinkCommands, LinkRequests) {
    let (sender, receiver) = mpsc::channel(QUEUED_COMMANDS);
    (LinkCommands(sender), LinkRequests(receiver))
}

impl LinkCommands {
    pub async fn send_message(
        &self,
        text: &str,
        delivery: Option<QueuedDelivery>,
        command_id: Option<&CommandId>,
        attachments: &[FetchedAttachment],
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        self.command(
            Action::Send {
                text: text.to_owned(),
                delivery,
                command_id: command_id.cloned(),
                attachments: attachments.to_vec(),
            },
            timeout,
        )
        .await
    }

    pub async fn stop_turn(
        &self,
        stop: StopTarget,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        self.command(Action::Stop(stop), timeout).await
    }

    pub async fn resume_turn(&self, timeout: Duration) -> io::Result<CommandResult> {
        self.command(Action::ResumeTurn, timeout).await
    }

    pub async fn shutdown(&self, timeout: Duration) -> io::Result<CommandResult> {
        self.command(Action::Shutdown, timeout).await
    }

    /// Codex names models by id alone; the provider is ignored.
    pub async fn set_model(
        &self,
        model: Option<(&str, &str)>,
        thinking_level: Option<&str>,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        self.command(
            Action::SetModel {
                model: model.map(|(_, id)| id.to_owned()),
                thinking_level: thinking_level.map(str::to_owned),
            },
            timeout,
        )
        .await
    }

    async fn command(&self, action: Action, timeout: Duration) -> io::Result<CommandResult> {
        let (reply, answer) = oneshot::channel();
        let asked = async {
            self.0
                .send(Request { action, reply })
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::NotConnected, "Codex's link has ended"))?;
            answer.await.unwrap_or_else(|_| {
                Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "Codex's link closed before answering",
                ))
            })
        };
        tokio::time::timeout(timeout, asked)
            .await
            .unwrap_or_else(|_| {
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Codex did not answer the command in time",
                ))
            })
    }
}

type Socket = tokio_tungstenite::WebSocketStream<UnixStream>;

/// Why a connection ended.
enum Outcome {
    /// The socket closed; connect again and rejoin the thread.
    Closed,
    /// The Session let the link go, or asked it to shut the server down.
    Ended,
    /// The server could not start or rejoin the thread, or broke the protocol.
    Failed,
}

/// Follows the server until the Session lets the link go or the server fails it. `server` is
/// stopped when this returns, whatever the reason.
pub async fn run(
    config: LinkConfig,
    mut requests: LinkRequests,
    server: Option<ServerProcess>,
    mut report: impl FnMut(AgentEvent) -> bool + Send,
) {
    let _server = server;
    let context = config.log_context.clone();
    let mut stream_id_counter = 0_u64;
    loop {
        let Some(socket) = connect(&config.socket, &mut requests).await else {
            log::warn!("event=codex.unreachable {context}");
            return;
        };
        stream_id_counter += 1;
        let stream_id = axo_protocol::new_uuid_v4()
            .unwrap_or_else(|_| format!("00000000-0000-4000-8000-{stream_id_counter:012x}"));
        let mut connection = Connection::new(socket, stream_id, &context);
        let outcome = connection.follow(&config, &mut requests, &mut report).await;
        match outcome {
            Outcome::Closed => {
                if !report(AgentEvent::Disconnected) {
                    return;
                }
            }
            Outcome::Ended | Outcome::Failed => return,
        }
    }
}

/// Starts a thread for a new Session in `cwd` and names it, which writes it, so that the TUI
/// can resume it (a thread nobody has written cannot be resumed by another client). Returns
/// its id once the server has it.
pub async fn create_thread(
    socket: &Path,
    cwd: &Path,
    name: &str,
    instructions: Option<&str>,
    log_context: &str,
) -> io::Result<String> {
    let failed = |what: &str| io::Error::other(format!("Codex did not {what}"));
    let stream = connect_once(socket, CONNECT_DEADLINE)
        .await
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "Codex's app-server is not listening"))?;
    let mut connection = Connection::new(stream, String::new(), log_context);
    connection.initialize().await.map_err(|_| failed("initialize"))?;
    let mut params = json!({ "cwd": cwd });
    if let Some(instructions) = instructions {
        params["developerInstructions"] = json!(instructions);
    }
    let answer = connection
        .setup("thread/start", params)
        .await
        .map_err(|_| failed("start a thread"))?;
    let thread_id = thread_id_of(&answer).ok_or_else(|| failed("name its new thread"))?;
    connection
        .setup("thread/name/set", json!({ "threadId": thread_id, "name": name }))
        .await
        .map_err(|_| failed("write its new thread"))?;
    Ok(thread_id)
}

/// Connects and completes the WebSocket handshake, trying again while the server starts,
/// until `deadline` passes.
async fn connect_once(socket: &Path, deadline: Duration) -> Option<Socket> {
    let deadline = tokio::time::Instant::now() + deadline;
    let mut retry = RETRY_FIRST;
    loop {
        if let Ok(stream) = UnixStream::connect(socket).await
            && let Ok((socket, _)) = tokio_tungstenite::client_async("ws://localhost/", stream).await
        {
            return Some(socket);
        }
        if tokio::time::Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(retry).await;
        retry = (retry * 2).min(RETRY_LAST);
    }
}

/// Like [`connect_once`], refusing the commands that arrive meanwhile.
async fn connect(socket: &Path, requests: &mut LinkRequests) -> Option<Socket> {
    refuse_waiting(requests);
    let connecting = connect_once(socket, CONNECT_DEADLINE);
    tokio::pin!(connecting);
    loop {
        tokio::select! {
            socket = &mut connecting => return socket,
            request = requests.0.recv() => match request {
                Some(Request { reply, .. }) => { let _ = reply.send(Err(not_bound())); }
                None => return None,
            },
        }
    }
}

fn not_bound() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "Codex is not connected")
}

fn refuse_waiting(requests: &mut LinkRequests) {
    while let Ok(Request { reply, .. }) = requests.0.try_recv() {
        let _ = reply.send(Err(not_bound()));
    }
}

/// What an answer from the server is for.
enum Pending {
    /// A request of the link's own, awaited inline during setup.
    Setup(oneshot::Sender<Result<Value, rpc::RpcError>>),
    /// `turn/start` for a client's prompt, answered when the server answers.
    StartTurn(Option<oneshot::Sender<io::Result<CommandResult>>>),
    Steer(oneshot::Sender<io::Result<CommandResult>>),
    Interrupt(Option<oneshot::Sender<io::Result<CommandResult>>>),
    Models,
}

struct Connection<'a> {
    socket: Socket,
    next_id: i64,
    pending: HashMap<i64, Pending>,
    stream_id: String,
    sequence: u64,
    context: &'a str,
}

impl<'a> Connection<'a> {
    fn new(socket: Socket, stream_id: String, context: &'a str) -> Self {
        Self {
            socket,
            next_id: 1,
            pending: HashMap::new(),
            stream_id,
            sequence: 0,
            context,
        }
    }

    async fn follow(
        &mut self,
        config: &LinkConfig,
        requests: &mut LinkRequests,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> Outcome {
        let mut thread = match self.rejoin(config).await {
            Ok(thread) => thread,
            Err(outcome) => return outcome,
        };
        let thread_id = thread.id().to_owned();
        log::info!("event=codex.thread_bound {} thread_id={thread_id}", self.context);
        if !report(AgentEvent::Bound {
            agent_session_id: thread_id.clone(),
        }) {
            return Outcome::Ended;
        }
        let snapshot = thread.snapshot();
        if !self.report_all(&thread_id, snapshot, report) {
            return Outcome::Ended;
        }
        if self.send_request("model/list", json!({}), Pending::Models).await.is_err() {
            return Outcome::Closed;
        }
        loop {
            tokio::select! {
                frame = self.socket.next() => {
                    let text = match frame {
                        Some(Ok(Message::Text(text))) => text,
                        Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => continue,
                        Some(Ok(Message::Binary(_))) => {
                            log::warn!("event=codex.protocol_rejected {} reason=binary_frame", self.context);
                            return Outcome::Failed;
                        }
                        Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return Outcome::Closed,
                    };
                    match rpc::parse(&text) {
                        Ok(incoming) => {
                            if let Some(outcome) = self.receive(incoming, &mut thread, report).await {
                                return outcome;
                            }
                        }
                        Err(error) => {
                            log::warn!("event=codex.protocol_rejected {} reason={error:?}", self.context);
                            return Outcome::Failed;
                        }
                    }
                }
                request = requests.0.recv() => {
                    let Some(Request { action, reply }) = request else { return Outcome::Ended };
                    if let Some(outcome) = self.command(action, reply, &mut thread, report).await {
                        return outcome;
                    }
                }
            }
        }
    }

    async fn initialize(&mut self) -> Result<(), Outcome> {
        self.setup(
            "initialize",
            json!({
                "clientInfo": { "name": "axod", "version": env!("CARGO_PKG_VERSION") },
                "capabilities": { "experimentalApi": false, "requestAttestation": false },
            }),
        )
        .await?;
        self.write(rpc::notification("initialized"))
            .await
            .map_err(|_| Outcome::Closed)
    }

    /// Joins the Session's thread: the server loads it, or adds axod to the running one.
    async fn rejoin(&mut self, config: &LinkConfig) -> Result<Thread, Outcome> {
        self.initialize().await?;
        let mut params = json!({ "threadId": config.thread_id, "excludeTurns": true });
        if let Some(instructions) = &config.instructions {
            params["developerInstructions"] = json!(instructions);
        }
        let answer = self.setup("thread/resume", params).await?;
        if thread_id_of(&answer).as_deref() != Some(config.thread_id.as_str()) {
            log::warn!("event=codex.binding_rejected {} reason=thread_mismatch", self.context);
            return Err(Outcome::Failed);
        }
        let mut thread = Thread::resumed(config.thread_id.clone(), working_of(&answer));
        if let (Some(provider), Some(model)) =
            (answer["modelProvider"].as_str(), answer["model"].as_str())
        {
            thread.set_running_model(provider, model, answer["reasoningEffort"].as_str());
        }
        Ok(thread)
    }

    /// Sends one of the link's own requests and waits for its answer, following nothing else
    /// meanwhile (nothing else is subscribed yet).
    async fn setup(&mut self, method: &str, params: Value) -> Result<Value, Outcome> {
        let (reply, answer) = oneshot::channel();
        let id = self
            .send_request(method, params, Pending::Setup(reply))
            .await
            .map_err(|_| Outcome::Closed)?;
        let waited = tokio::time::timeout(SETUP_TIMEOUT, async {
            let mut answer = answer;
            loop {
                tokio::select! {
                    answered = &mut answer => return answered.ok(),
                    frame = self.socket.next() => match frame {
                        Some(Ok(Message::Text(text))) => {
                            if let Ok(Incoming::Response { id, result }) = rpc::parse(&text) {
                                self.answer(&id, Ok(result));
                            } else if let Ok(Incoming::Failure { id, error }) = rpc::parse(&text) {
                                self.answer(&id, Err(error));
                            }
                        }
                        Some(Ok(_)) => {}
                        _ => return None,
                    },
                }
            }
        })
        .await;
        match waited {
            Ok(Some(Ok(result))) => Ok(result),
            Ok(Some(Err(error))) => {
                log::warn!(
                    "event=codex.setup_failed {} method={method} code={} reason={}",
                    self.context,
                    error.code,
                    error.message
                );
                Err(Outcome::Failed)
            }
            Ok(None) => Err(Outcome::Closed),
            Err(_) => {
                self.pending.remove(&id);
                log::warn!("event=codex.setup_timed_out {} method={method}", self.context);
                Err(Outcome::Failed)
            }
        }
    }

    /// Settles a setup request's answer; other answers are ignored during setup.
    fn answer(&mut self, id: &RequestId, result: Result<Value, rpc::RpcError>) {
        let RequestId::Number(number) = id else { return };
        if let Some(Pending::Setup(reply)) = self.pending.remove(number) {
            let _ = reply.send(result);
        }
    }

    async fn write(&mut self, frame: String) -> io::Result<()> {
        self.socket
            .send(Message::Text(frame.into()))
            .await
            .map_err(io::Error::other)
    }

    async fn send_request(&mut self, method: &str, params: Value, pending: Pending) -> io::Result<i64> {
        let id = self.next_id;
        self.next_id += 1;
        self.pending.insert(id, pending);
        if let Err(error) = self.write(rpc::request(id, method, params)).await {
            self.pending.remove(&id);
            return Err(error);
        }
        Ok(id)
    }

    fn report_all(
        &mut self,
        thread_id: &str,
        events: Vec<Emitted>,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> bool {
        events.into_iter().all(|event| {
            self.sequence += 1;
            report(AgentEvent::Event {
                agent_session_id: thread_id.to_owned(),
                stream_id: self.stream_id.clone(),
                sequence: self.sequence,
                name: event.name.to_owned(),
                data: event.data,
            })
        })
    }

    /// Applies one frame from the server; `Some` when the connection must end.
    async fn receive(
        &mut self,
        incoming: Incoming,
        thread: &mut Thread,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> Option<Outcome> {
        let thread_id = thread.id().to_owned();
        match incoming {
            Incoming::Notification { method, params } => {
                let Observed { events, next } = thread.observe(&method, &params);
                if !self.report_all(&thread_id, events, report) {
                    return Some(Outcome::Ended);
                }
                if let Some(request) = next
                    && self.start_turn(request, None, thread).await.is_err()
                {
                    return Some(Outcome::Closed);
                }
                None
            }
            // Approvals and questions are the person's, in the TUI.
            Incoming::Request { .. } => None,
            Incoming::Response { id, result } => {
                self.settle(&id, Ok(result), thread, report);
                None
            }
            Incoming::Failure { id, error } => {
                self.settle(&id, Err(error), thread, report);
                None
            }
        }
    }

    fn settle(
        &mut self,
        id: &RequestId,
        result: Result<Value, rpc::RpcError>,
        thread: &mut Thread,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) {
        let RequestId::Number(number) = id else { return };
        let Some(pending) = self.pending.remove(number) else { return };
        let accepted = || Ok(CommandResult::Accepted);
        match (pending, result) {
            (Pending::Setup(reply), result) => {
                let _ = reply.send(result);
            }
            (Pending::StartTurn(reply), Ok(answer)) => {
                if let Some(turn) = answer["turn"]["id"].as_str() {
                    thread.started(turn);
                }
                reply.map(|reply| reply.send(accepted()));
            }
            (Pending::StartTurn(reply), Err(error)) => {
                thread.start_failed();
                log::warn!("event=codex.turn_refused {} reason={}", self.context, error.message);
                reply.map(|reply| reply.send(Ok(CommandResult::Rejected(RejectReason::Unavailable))));
            }
            (Pending::Steer(reply), Ok(_)) => {
                let _ = reply.send(accepted());
            }
            // The turn it named is no longer the active one.
            (Pending::Steer(reply), Err(_)) => {
                let _ = reply.send(Ok(CommandResult::Rejected(RejectReason::Stale)));
            }
            (Pending::Interrupt(reply), result) => {
                let answer = match result {
                    Ok(_) => CommandResult::Accepted,
                    Err(_) => CommandResult::Rejected(RejectReason::Idle),
                };
                reply.map(|reply| reply.send(Ok(answer)));
            }
            (Pending::Models, Ok(answer)) => {
                let models = models_event(&answer);
                let thread_id = thread.id().to_owned();
                self.report_all(&thread_id, vec![models], report);
            }
            (Pending::Models, Err(_)) => {}
        }
    }

    async fn start_turn(
        &mut self,
        request: TurnRequest,
        reply: Option<oneshot::Sender<io::Result<CommandResult>>>,
        thread: &Thread,
    ) -> io::Result<()> {
        let mut params = json!({ "threadId": thread.id(), "input": request.input });
        if let Some(command) = &request.command_id {
            params["clientUserMessageId"] = json!(command.as_str());
        }
        let choice = thread.choice();
        if let Some(model) = &choice.model {
            params["model"] = json!(model);
        }
        if let Some(effort) = &choice.effort {
            params["effort"] = json!(effort);
        }
        self.send_request("turn/start", params, Pending::StartTurn(reply))
            .await
            .map(|_| ())
    }

    /// Carries out one command; `Some` when the connection must end.
    async fn command(
        &mut self,
        action: Action,
        reply: oneshot::Sender<io::Result<CommandResult>>,
        thread: &mut Thread,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> Option<Outcome> {
        let written = match action {
            Action::Send {
                text,
                delivery,
                command_id,
                attachments,
            } => {
                let request = TurnRequest::new(&text, &attachments, command_id.as_ref());
                match thread.plan_send(request, delivery) {
                    SendPlan::Start(request) => self.start_turn(request, Some(reply), thread).await,
                    SendPlan::Steer { turn_id, request } => {
                        let mut params = json!({
                            "threadId": thread.id(),
                            "expectedTurnId": turn_id,
                            "input": request.input,
                        });
                        if let Some(command) = &request.command_id {
                            params["clientUserMessageId"] = json!(command.as_str());
                        }
                        self.send_request("turn/steer", params, Pending::Steer(reply)).await.map(|_| ())
                    }
                    SendPlan::Held => {
                        let _ = reply.send(Ok(CommandResult::Accepted));
                        Ok(())
                    }
                    SendPlan::Interrupt { turn_id } => self.interrupt(thread, &turn_id, Some(reply)).await,
                    SendPlan::Reject(reason) => {
                        let _ = reply.send(Ok(CommandResult::Rejected(reason)));
                        Ok(())
                    }
                }
            }
            Action::Stop(stop) => match thread.plan_stop(&stop) {
                StopPlan::Interrupt { turn_id } => self.interrupt(thread, &turn_id, Some(reply)).await,
                StopPlan::Idle => {
                    let _ = reply.send(Ok(CommandResult::Rejected(RejectReason::Idle)));
                    Ok(())
                }
            },
            // Codex has no message-free continuation (RFD0058 asks for an explicit refusal).
            Action::ResumeTurn => {
                let _ = reply.send(Ok(CommandResult::Rejected(RejectReason::Unavailable)));
                Ok(())
            }
            Action::Shutdown => {
                let _ = reply.send(Ok(CommandResult::Accepted));
                return Some(Outcome::Ended);
            }
            Action::SetModel {
                model,
                thinking_level,
            } => {
                let effort = match thinking_level.as_deref().map(reasoning_effort) {
                    Some(None) => {
                        let _ = reply.send(Ok(CommandResult::Rejected(RejectReason::Invalid)));
                        return None;
                    }
                    Some(Some(effort)) => Some(effort),
                    None => None,
                };
                let events = thread.choose(model.as_deref(), effort);
                let _ = reply.send(Ok(CommandResult::Accepted));
                let thread_id = thread.id().to_owned();
                if !self.report_all(&thread_id, events, report) {
                    return Some(Outcome::Ended);
                }
                Ok(())
            }
        };
        written.is_err().then_some(Outcome::Closed)
    }

    async fn interrupt(
        &mut self,
        thread: &Thread,
        turn_id: &str,
        reply: Option<oneshot::Sender<io::Result<CommandResult>>>,
    ) -> io::Result<()> {
        self.send_request(
            "turn/interrupt",
            json!({ "threadId": thread.id(), "turnId": turn_id }),
            Pending::Interrupt(reply),
        )
        .await
        .map(|_| ())
    }
}

fn thread_id_of(answer: &Value) -> Option<String> {
    answer["thread"]["id"]
        .as_str()
        .filter(|id| !id.is_empty() && id.len() <= 128)
        .map(str::to_owned)
}

/// Whether a resumed thread is running a turn now.
fn working_of(answer: &Value) -> bool {
    answer["thread"]["status"]["type"].as_str() == Some("active")
}

/// `model/list`'s answer as `pi.models`: each visible model, with the thinking levels of its
/// reasoning efforts.
fn models_event(answer: &Value) -> Emitted {
    let models: Vec<Value> = answer["data"]
        .as_array()
        .map(|models| {
            models
                .iter()
                .filter(|model| model["hidden"] != true)
                .filter_map(|model| {
                    let id = model["id"].as_str()?;
                    let name = model["displayName"].as_str().unwrap_or(id);
                    let mut levels: Vec<&str> = model["supportedReasoningEfforts"]
                        .as_array()
                        .map(|efforts| {
                            efforts
                                .iter()
                                .filter_map(|effort| effort["reasoningEffort"].as_str())
                                .filter_map(thinking_level_of)
                                .collect()
                        })
                        .unwrap_or_default();
                    if levels.is_empty() {
                        levels.push("off");
                    }
                    Some(json!({ "provider": "codex", "id": id, "name": name, "thinkingLevels": levels }))
                })
                .take(300)
                .collect()
        })
        .unwrap_or_default();
    Emitted {
        name: "pi.models",
        data: json!({ "models": models }),
    }
}

fn thinking_level_of(effort: &str) -> Option<&'static str> {
    match effort {
        "none" => Some("off"),
        "minimal" => Some("minimal"),
        "low" => Some("low"),
        "medium" => Some("medium"),
        "high" => Some("high"),
        "xhigh" => Some("xhigh"),
        _ => None,
    }
}

/// The app-server process the link owns: stopped when the link ends.
pub struct ServerProcess(std::process::Child);

impl ServerProcess {
    pub fn new(child: std::process::Child) -> Self {
        Self(child)
    }

    pub fn id(&self) -> u32 {
        self.0.id()
    }
}

impl std::fmt::Debug for ServerProcess {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_tuple("ServerProcess").field(&self.0.id()).finish()
    }
}

impl Drop for ServerProcess {
    fn drop(&mut self) {
        // The guard shell kills the server on SIGTERM; it leads its own process group.
        let pid = self.0.id() as libc::pid_t;
        // SAFETY: signals the guard this value spawned, and its group.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
            libc::kill(-pid, libc::SIGTERM);
        }
        let _ = self.0.wait();
    }
}

#[cfg(test)]
#[path = "link_tests.rs"]
mod tests;
