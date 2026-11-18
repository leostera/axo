//! A Session's Pi: launching it, its link, what it reports, and its end (RFD0041).
//!
//! A launch runs on the blocking pool: it takes the transcript's writer lock and starts Pi on a
//! PTY with the lifeline, so Pi lives no longer than axod. If the lock is held by the Pi an
//! earlier axod started for this Session (the same pid, started at the same time, as stored),
//! that Pi is killed and the lock taken once it is gone: a Pi axod is not the parent of is never
//! left running. A holder axod does not know is never signalled; the pane is unavailable.
//!
//! Restarting a Pi asks it to exit on its bridge, kills it if it has not after a grace, and
//! starts a new one on the same transcript once it has exited. Putting an idle one to sleep
//! (RFD0045) is the same without the start: its pane is dormant once it has exited.

use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axo_agent::pi::link::{self, LinkConfig};
use axo_agent::pi::{BridgeSocketPath, PiLaunch, PiProcess, SocketCleanup};
use axo_agent::process::ProcessIdentity;
use axo_agent::discovery::{self, SearchPlaces};
use axo_agent::{
    Activity, AgentCommand, AgentCommands, AgentEvent, AgentKind, CommandResult,
    FORK_EXEC_WINDOW, RejectReason, WriterLock,
};
use axo_protocol::{Event, PaneRole, PiCommandInfo, PiModelInfo, SessionStatus, ThinkingLevel};
use axo_pty::WindowSize;
use serde_json::Value;
use tokio::sync::{oneshot, watch};

use super::controls::{PiCatalogEvent, PiControlEvent, PiControls};
use super::panes::{Running, RuntimeId, pi_environment};
use super::prompts::{MAX_QUEUED_PI_PROMPTS, Prompt, PromptError, QueuedPrompt, Receipt};
use super::{Message, Session};
use crate::catalog::PiPhase;
use crate::core::Core;

/// How long Pi gets to answer a command on its bridge.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a Pi asked to exit for a restart gets before it is killed.
const EXIT_GRACE: Duration = Duration::from_secs(10);
/// How long a Pi just killed gets to let go of its transcript.
const KILLED_RELEASE: Duration = Duration::from_secs(2);

/// What restoring does with a Session's Pi.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PiStart {
    Now,
    /// Restore work interrupted by a graceful daemon stop, without a synthetic prompt.
    Resume,
    /// Not until the Session is shown, prompted or typed into; unless an earlier axod's Pi still
    /// runs, which is replaced at once.
    Dormant,
}

/// Who waits for a launch to end; told its error as text.
pub(crate) type Waiter = oneshot::Sender<Result<(), String>>;

enum PiState {
    /// Not started: it starts when the Session is wanted.
    Dormant,
    /// Not running: it exited, or could not start.
    Unavailable,
    Launching {
        attempt: u64,
        waiters: Vec<Waiter>,
    },
    Running {
        runtime_id: RuntimeId,
        link: AgentCommands,
        link_task: tokio::task::AbortHandle,
    },
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum Recovery {
    #[default]
    None,
    Pending,
    /// Sent once to this runtime; retain recovery across shutdown until agent.start is seen.
    Claimed,
    /// Explicit stop intent wins, including when the eventual stop receipt is uncertain.
    Suppressed,
    /// The stopped run is observed idle. A subsequent start is new work, not a late old event.
    SettledAfterStop,
}

impl Recovery {
    fn claim(&mut self) -> bool {
        if *self != Self::Pending {
            return false;
        }
        *self = Self::Claimed;
        true
    }

    fn disarmed(self) -> bool {
        matches!(self, Self::Suppressed | Self::SettledAfterStop)
    }

    fn started(&mut self) -> bool {
        if *self == Self::Suppressed {
            return false;
        }
        std::mem::replace(self, Self::None) != Self::None
    }

    fn settled(&mut self) {
        if *self == Self::Suppressed {
            *self = Self::SettledAfterStop;
        }
    }
}

pub(crate) struct Pi {
    pub(crate) shell_id: ShellId,
    pub(crate) pane_id: String,
    state: PiState,
    /// What the running Pi is doing, from its bridge; `None` until its bridge first binds.
    activity: Option<Activity>,
    /// What it last said it runs; kept across Pis, the next one says its own.
    pub(crate) controls: PiControls,
    /// Prompts waiting for it to come up, oldest first.
    queued: Vec<QueuedPrompt>,
    /// The queue is being sent to the running Pi: new prompts queue behind it, so they reach Pi
    /// in the order they were taken.
    flushing: bool,
    /// Start again once the running one exits.
    restart: bool,
    /// Become dormant once the running one exits (RFD0045).
    sleep: bool,
    /// When anything last happened in the running Pi but its screen: it started, said
    /// something on its bridge, or was prompted.
    active_at: Instant,
    attempts: u64,
    recovery: Recovery,
    /// A normal Send must not abort a request or the work approved during this run.
    human_turn_protected: bool,
    /// Questions actually dispatched to this runtime, never a replacement Pi.
    ui_questions: std::collections::HashMap<String, RuntimeId>,
    /// Another agent's conversation, converted into the Session's transcript.
    mirror: Mirror,
}

/// The Session's transcript, kept from another agent's own file of the conversation (RFD0072,
/// Transcripts): converted again whenever the agent may have written to it, one conversion at a
/// time; a change during one runs another after it.
#[derive(Debug, Default)]
struct Mirror {
    conversation: Option<PathBuf>,
    running: bool,
    again: bool,
}

use axo_protocol::ShellId;

impl Pi {
    pub(crate) fn new(shell_id: ShellId, pane_id: String) -> Self {
        Self {
            shell_id,
            pane_id,
            state: PiState::Dormant,
            activity: None,
            controls: PiControls::default(),
            queued: Vec::new(),
            flushing: false,
            restart: false,
            sleep: false,
            active_at: Instant::now(),
            attempts: 0,
            recovery: Recovery::None,
            human_turn_protected: false,
            ui_questions: std::collections::HashMap::new(),
            mirror: Mirror::default(),
        }
    }

    pub(crate) fn recovering(&self) -> bool {
        matches!(self.recovery, Recovery::Pending | Recovery::Claimed)
    }

    fn resumable_work(&self) -> bool {
        self.working() && !self.recovery.disarmed()
    }

    pub(crate) fn recovery_candidate(&self) -> bool {
        self.recovering()
            || (self.phase() == PiPhase::Connected
                && self.queued.is_empty()
                && self.resumable_work())
    }

    pub(crate) fn is_dormant(&self) -> bool {
        matches!(self.state, PiState::Dormant)
    }

    fn connected(&self) -> bool {
        self.activity.is_some_and(|activity| activity.connected)
    }

    pub(crate) fn working(&self) -> bool {
        matches!(self.state, PiState::Running { .. })
            && self.activity.is_some_and(|activity| activity.working)
    }

    pub(crate) fn phase(&self) -> PiPhase {
        match self.state {
            PiState::Dormant | PiState::Unavailable => PiPhase::Absent,
            PiState::Launching { .. } => PiPhase::Launching,
            PiState::Running { .. } if self.connected() => PiPhase::Connected,
            PiState::Running { .. } => PiPhase::Running,
        }
    }

    /// The Session's status while this Pi runs; `None` when it doesn't.
    pub(crate) fn status(&self) -> Option<SessionStatus> {
        match self.state {
            PiState::Running { .. } => Some(
                self.activity
                    .map_or(SessionStatus::Starting, Activity::status),
            ),
            _ => None,
        }
    }

    /// Lets go of the running Pi's link; it is gone or going.
    pub(crate) fn let_go(&mut self) {
        if let PiState::Running { link_task, .. } = &self.state {
            link_task.abort();
        }
        if let PiState::Launching { waiters, .. } = &mut self.state {
            for waiter in waiters.drain(..) {
                let _ = waiter.send(Err("the Session closed".to_owned()));
            }
        }
        self.state = PiState::Unavailable;
        self.activity = None;
        // Each dropped prompt tells whoever waits for it (`QueuedPrompt`'s `Drop`).
        self.queued.clear();
        self.flushing = false;
    }
}

/// Pi launches not yet settled: each ends installed in its Session or stopped. Stopping axod
/// waits for them, so no Pi it launched outlives it holding its transcript's writer lock, which
/// the next axod could neither take nor, knowing no such Pi, free.
pub(crate) struct PiLaunches(Arc<watch::Sender<usize>>);

impl Default for PiLaunches {
    fn default() -> Self {
        Self(Arc::new(watch::channel(0).0))
    }
}

impl PiLaunches {
    fn begin(&self) -> LaunchInFlight {
        self.0.send_modify(|count| *count += 1);
        LaunchInFlight(Arc::clone(&self.0))
    }

    /// Waits until every launch has settled.
    pub(crate) async fn settled(&self) {
        let _ = self.0.subscribe().wait_for(|count| *count == 0).await;
    }
}

/// One launch until its Pi is installed or stopped (or it failed).
pub(crate) struct LaunchInFlight(Arc<watch::Sender<usize>>);

impl Drop for LaunchInFlight {
    fn drop(&mut self) {
        self.0.send_modify(|count| *count -= 1);
    }
}

/// An agent a launch started.
pub(crate) struct Launched {
    /// Dropped once this agent is installed or stopped.
    in_flight: LaunchInFlight,
    agent: LaunchedAgent,
}

pub(crate) enum LaunchedAgent {
    Pi(LaunchedPi),
    /// Codex's server, its TUI and their thread (RFD0072).
    Codex(axo_agent::codex::CodexProcess),
    /// OpenCode's server, its TUI and their session (RFD0072).
    OpenCode(axo_agent::opencode::OpenCodeProcess),
    /// Claude Code's TUI and the hooks it posts (RFD0072).
    ClaudeCode(axo_agent::claude::ClaudeProcess),
}

pub(crate) struct LaunchedPi {
    process: PiProcess,
    bridge_token: String,
    session_file: PathBuf,
    bridge_socket: BridgeSocketPath,
}

/// What a launch needs, owned so it can run on the blocking pool.
struct LaunchRequest {
    agent_command: AgentCommand,
    folder: PathBuf,
    session_file: PathBuf,
    bridge_socket: BridgeSocketPath,
    session_uuid: String,
    pane_id: String,
    size: WindowSize,
    has_messages: bool,
    /// The Pi an earlier axod started, if it said.
    previous: Option<ProcessIdentity>,
}

fn launch(core: &Core, request: LaunchRequest, in_flight: LaunchInFlight) -> io::Result<Launched> {
    let LaunchRequest {
        agent_command,
        folder,
        session_file,
        bridge_socket,
        session_uuid,
        pane_id,
        size,
        has_messages,
        previous,
    } = request;
    axo_agent::recoverable_history(
        &session_file,
        core.pi_directories.home_of(&session_file),
        has_messages,
    )?;
    let lock = match WriterLock::acquire_within(&session_file, FORK_EXEC_WINDOW) {
        Ok(lock) => lock,
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
            let Some(previous) = previous.filter(|previous| previous.is_running()) else {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "another process holds this Pi's transcript",
                ));
            };
            log::warn!(
                "event=pi.previous_killed session_id={session_uuid} pid={}",
                previous.pid
            );
            previous.kill();
            WriterLock::acquire_within(&session_file, KILLED_RELEASE)?
        }
        Err(error) => return Err(error),
    };
    let bridge_token = axo_protocol::new_uuid_v4()?;
    let home = crate::current_user_home_directory()?;
    let environment = pi_environment(&core.agent_socket);
    let process = axo_agent::pi::spawn(
        &PiLaunch {
            agent_command: &agent_command,
            initial_pwd: &folder,
            session_file: &session_file,
            bridge_socket: &bridge_socket,
            session_uuid: &session_uuid,
            pane_id: &pane_id,
            home: &home,
            environment: &environment,
            lifeline: &core.lifeline,
        },
        lock,
        &bridge_token,
        size,
    )?;
    Ok(Launched {
        in_flight,
        agent: LaunchedAgent::Pi(LaunchedPi {
        process,
        bridge_token,
        session_file,
        bridge_socket,
    }),
    })
}

/// Launches a Session's Codex: finds `codex`, starts its server on the blocking pool, then
/// starts or confirms the thread and the TUI.
async fn launch_codex(
    core: Arc<Core>,
    request: ServedRequest,
    in_flight: LaunchInFlight,
) -> io::Result<Launched> {
    let places = SearchPlaces::from_environment(AgentKind::Codex, &request.home);
    let installed = discovery::discover(AgentKind::Codex, &places, discovery::VERSION_TIMEOUT).await?;
    let launch = axo_agent::codex::CodexLaunch {
        executable: installed.executable,
        paths: axo_agent::codex::CodexPaths::new(&core.pi_directories.bridges, &request.session_uuid)?,
        initial_pwd: request.folder,
        session_uuid: request.session_uuid,
        pane_id: request.pane_id,
        environment: pi_environment(&core.agent_socket),
        home: request.home,
        thread_id: request.conversation,
        thread_name: request.name,
        instructions: Some(agent_brief()),
        mcp: Some(request.mcp),
        previous: request.previous,
        size: request.size,
    };
    let (lock, server) = {
        let (core, launch) = (Arc::clone(&core), launch.clone());
        tokio::task::spawn_blocking(move || axo_agent::codex::start_server(&launch, &core.lifeline))
            .await
            .map_err(io::Error::other)??
    };
    axo_agent::codex::attach(launch, lock, server)
        .await
        .map(|process| Launched {
            in_flight,
            agent: LaunchedAgent::Codex(process),
        })
}

/// Launches a Session's OpenCode: finds `opencode`, starts its server on the blocking pool,
/// then creates or confirms the session and starts the TUI.
async fn launch_opencode(
    core: Arc<Core>,
    request: ServedRequest,
    in_flight: LaunchInFlight,
) -> io::Result<Launched> {
    let places = SearchPlaces::from_environment(AgentKind::OpenCode, &request.home);
    let installed =
        discovery::discover(AgentKind::OpenCode, &places, discovery::VERSION_TIMEOUT).await?;
    let launch = axo_agent::opencode::OpenCodeLaunch {
        executable: installed.executable,
        paths: axo_agent::opencode::OpenCodePaths::new(
            &core.pi_directories.bridges,
            &request.session_uuid,
        ),
        initial_pwd: request.folder,
        session_uuid: request.session_uuid,
        pane_id: request.pane_id,
        environment: pi_environment(&core.agent_socket),
        home: request.home,
        session_id: request.conversation,
        session_name: request.name,
        mcp: Some(request.mcp),
        previous: request.previous,
        size: request.size,
    };
    let (lock, server, address) = {
        let (core, launch) = (Arc::clone(&core), launch.clone());
        tokio::task::spawn_blocking(move || {
            axo_agent::opencode::start_server(&launch, &core.lifeline)
        })
        .await
        .map_err(io::Error::other)??
    };
    axo_agent::opencode::attach(launch, lock, server, address)
        .await
        .map(|process| Launched {
            in_flight,
            agent: LaunchedAgent::OpenCode(process),
        })
}

/// Launches a Session's Claude Code: finds `claude`, then starts its TUI on the blocking pool.
async fn launch_claude(
    core: Arc<Core>,
    request: ServedRequest,
    in_flight: LaunchInFlight,
) -> io::Result<Launched> {
    let places = SearchPlaces::from_environment(AgentKind::ClaudeCode, &request.home);
    let installed =
        discovery::discover(AgentKind::ClaudeCode, &places, discovery::VERSION_TIMEOUT).await?;
    let launch = axo_agent::claude::ClaudeLaunch {
        executable: installed.executable,
        paths: axo_agent::claude::ClaudePaths::new(
            &core.pi_directories.bridges,
            &request.session_uuid,
        ),
        initial_pwd: request.folder,
        // The conversation is named by axod: the Session's own id, until one is bound.
        conversation: request
            .conversation
            .unwrap_or_else(|| request.session_uuid.clone()),
        session_uuid: request.session_uuid,
        pane_id: request.pane_id,
        environment: pi_environment(&core.agent_socket),
        config_dir: axo_agent::claude::config_directory(&request.home),
        home: request.home,
        brief: Some(agent_brief()),
        mcp: Some(request.mcp),
        previous: request.previous,
        size: request.size,
    };
    tokio::task::spawn_blocking(move || axo_agent::claude::launch(&launch))
        .await
        .map_err(io::Error::other)?
        .map(|process| Launched {
            in_flight,
            agent: LaunchedAgent::ClaudeCode(process),
        })
}

/// A launched agent's pane process, with the link that follows it.
struct Followed {
    running: Running,
    /// Who the agent's process is (Pi, or Codex's server), for a later axod to kill should it
    /// outlive this one.
    identity: Option<ProcessIdentity>,
    link: AgentCommands,
    link_task: tokio::task::AbortHandle,
    /// The conversation an agent other than Pi named at launch.
    thread_id: Option<String>,
}

/// What the launch of an agent axod runs as a server of its own (Codex, OpenCode) needs, owned.
struct ServedRequest {
    folder: PathBuf,
    home: PathBuf,
    session_uuid: String,
    pane_id: String,
    size: WindowSize,
    /// The Session's conversation in the agent (Codex's thread, OpenCode's session), once it
    /// has one.
    conversation: Option<String>,
    /// The new conversation's name.
    name: String,
    mcp: axo_agent::axo_mcp::AxoMcp,
    /// The server an earlier axod started, if it said.
    previous: Option<ProcessIdentity>,
}

/// Axo's brief for an agent that is not Pi, given once at launch. pi-axo asks for it again
/// after every turn to keep the account's apps current; an agent configured at launch cannot,
/// so its brief names the account without listing it and the agent asks (`apps_list`).
fn agent_brief() -> String {
    axo_mcp::brief::brief(&axo_mcp::brief::Reach {
        calls: axo_mcp::brief::ToolCalls::Direct,
        computer: axo_computer::AVAILABLE,
        account: axo_mcp::brief::Account::Unreachable,
    })
}

/// Axo's MCP server for the Session's agent, as pi-axo registers it for Pi.
fn axo_mcp_server(core: &Core, session_id: axo_protocol::SessionId) -> io::Result<axo_agent::axo_mcp::AxoMcp> {
    Ok(axo_agent::axo_mcp::AxoMcp {
        axod: std::env::current_exe()?,
        socket: core.agent_socket.clone(),
        session_id: session_id.to_string(),
    })
}

fn invalid_data(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_owned())
}

/// What a prompt for the Session's Pi does now.
pub(crate) enum Admission {
    /// It waits for Pi to come up.
    Queued {
        delivery: axo_protocol::rpc::PromptDelivery,
        /// What became of it, once Pi took it or stopped first.
        receipt: Receipt,
    },
    /// Send it on this link.
    Send {
        link: AgentCommands,
        delivery: axo_protocol::rpc::PromptDelivery,
    },
}

impl Session {
    /// Starts the Pi as restoring says: a dormant one stays dormant unless an earlier axod's Pi
    /// still runs for it.
    pub(super) async fn start_pi_as(&mut self, start: PiStart, waiter: Option<Waiter>) {
        if self.pi.is_none() {
            self.quiet = false;
            self.publish();
            if let Some(waiter) = waiter {
                let _ = waiter.send(Err("the Session has no Pi pane".to_owned()));
            }
            return;
        }
        let start = match start {
            PiStart::Now => true,
            PiStart::Resume => {
                self.pi.as_mut().expect("Pi checked above").recovery = Recovery::Pending;
                true
            }
            PiStart::Dormant => {
                let id = self.id;
                let previous = self
                    .core
                    .store
                    .call(move |database| axo_store::load_pi_process(database, id))
                    .await
                    .ok()
                    .flatten()
                    .and_then(|stored| ProcessIdentity::parse(&stored).ok());
                previous.is_some_and(ProcessIdentity::is_running)
            }
        };
        if start {
            self.start_pi(waiter).await;
        } else {
            self.quiet = false;
            self.publish();
        }
    }

    /// Starts the Pi if it is not running or starting; `waiter`, if any, hears when it is up.
    pub(crate) async fn start_pi(&mut self, waiter: Option<Waiter>) {
        let core = Arc::clone(&self.core);
        let Some(pi) = &mut self.pi else {
            if let Some(waiter) = waiter {
                let _ = waiter.send(Err("the Session has no Pi pane".to_owned()));
            }
            return;
        };
        match &mut pi.state {
            PiState::Running { .. } => {
                if let Some(waiter) = waiter {
                    let _ = waiter.send(Ok(()));
                }
                return;
            }
            PiState::Launching { waiters, .. } => {
                waiters.extend(waiter);
                return;
            }
            PiState::Dormant | PiState::Unavailable => {}
        }
        if core.is_stopping() {
            if let Some(waiter) = waiter {
                let _ = waiter.send(Err("Axod is shutting down".to_owned()));
            }
            return;
        }
        if pi.recovering() {
            pi.recovery = Recovery::Pending;
        }
        pi.attempts += 1;
        let attempt = pi.attempts;
        pi.state = PiState::Launching {
            attempt,
            waiters: waiter.into_iter().collect(),
        };
        let pane_id = pi.pane_id.clone();
        let shell_id = pi.shell_id;
        log::info!(
            "event=session.pi_starting session_id={} shell_id={}",
            self.id,
            shell_id.get()
        );
        self.publish();
        let agent = self.row.agent;
        if matches!(
            agent,
            AgentKind::Codex | AgentKind::OpenCode | AgentKind::ClaudeCode
        ) {
            let id = self.id;
            let previous = core
                .store
                .call(move |database| axo_store::load_pi_process(database, id))
                .await
                .ok()
                .flatten()
                .and_then(|stored| ProcessIdentity::parse(&stored).ok());
            let request = crate::current_user_home_directory().and_then(|home| {
                Ok(ServedRequest {
                    folder: self.row.folder.clone(),
                    home,
                    session_uuid: self.id.to_string(),
                    pane_id,
                    size: self.pane_size(shell_id),
                    conversation: self.row.agent_conversation.clone(),
                    name: self.row.manual_name.clone().unwrap_or_else(|| self.row.name.clone()),
                    mcp: axo_mcp_server(&core, self.id)?,
                    previous,
                })
            });
            let request = match request {
                Ok(request) => request,
                Err(error) => {
                    self.launched(attempt, Err(error)).await;
                    return;
                }
            };
            let mailbox = self.mailbox();
            let in_flight = core.pi_launches.begin();
            tokio::spawn(async move {
                let result = match agent {
                    AgentKind::OpenCode => launch_opencode(core, request, in_flight).await,
                    AgentKind::ClaudeCode => launch_claude(core, request, in_flight).await,
                    _ => launch_codex(core, request, in_flight).await,
                };
                match mailbox.upgrade() {
                    Some(mailbox) => {
                        if let Err(unsent) = mailbox.send(Message::Launched { attempt, result }) {
                            stop_unwanted(unsent.0);
                        }
                    }
                    None => stop_unwanted(Message::Launched { attempt, result }),
                }
            });
            return;
        }
        let id = self.id;
        let stored = core
            .store
            .call(move |database| {
                Ok((
                    axo_store::open_pi_session(database, id)?,
                    axo_store::load_pi_process(database, id)?,
                ))
            })
            .await;
        let request = stored.and_then(|(stored, previous)| {
            let session_file = stored
                .session_file
                .ok_or_else(|| invalid_data("Pi Session is missing its persisted history path"))?;
            let bridge_socket =
                BridgeSocketPath::parse(PathBuf::from(stored.bridge_socket_path.ok_or_else(
                    || invalid_data("Pi Session is missing its persisted bridge socket path"),
                )?))?;
            Ok(LaunchRequest {
                agent_command: core.settings().agent_command,
                folder: self.row.folder.clone(),
                session_file,
                bridge_socket,
                session_uuid: id.to_string(),
                pane_id,
                size: self.pane_size(shell_id),
                has_messages: stored.has_messages,
                previous: previous.and_then(|stored| ProcessIdentity::parse(&stored).ok()),
            })
        });
        let request = match request {
            Ok(request) => request,
            Err(error) => {
                self.launched(attempt, Err(error)).await;
                return;
            }
        };
        let mailbox = self.mailbox();
        let in_flight = core.pi_launches.begin();
        tokio::task::spawn_blocking(move || {
            let result = launch(&core, request, in_flight);
            match mailbox.upgrade() {
                Some(mailbox) => {
                    if let Err(unsent) = mailbox.send(Message::Launched { attempt, result }) {
                        stop_unwanted(unsent.0);
                    }
                }
                None => stop_unwanted(Message::Launched { attempt, result }),
            }
        });
    }

    /// A launch ended: its Pi enters the Session, unless the Session moved on meanwhile.
    pub(super) async fn launched(&mut self, attempt: u64, result: io::Result<Launched>) {
        let current = self.pi.as_ref().is_some_and(|pi| {
            matches!(pi.state, PiState::Launching { attempt: current, .. } if current == attempt)
        });
        if !current || self.ended {
            stop_unwanted(Message::Launched { attempt, result });
            return;
        }
        self.quiet = false;
        let Some(pi) = &mut self.pi else { return };
        let PiState::Launching { waiters, .. } =
            std::mem::replace(&mut pi.state, PiState::Unavailable)
        else {
            return;
        };
        let (shell_id, pane_id) = (pi.shell_id, pi.pane_id.clone());
        let started = result.and_then(|launched| self.follow(launched, shell_id, pane_id));
        let Followed {
            running,
            identity,
            link,
            link_task,
            thread_id,
        } = match started {
            Ok(started) => started,
            Err(error) => {
                log::warn!(
                    "event=session.pi_start_failed session_id={} shell_id={} error_kind={:?} reason={error}",
                    self.id,
                    shell_id.get(),
                    error.kind()
                );
                if let Some(pi) = &mut self.pi {
                    pi.queued.clear();
                    pi.restart = false;
                }
                for waiter in waiters {
                    let _ = waiter.send(Err(error.to_string()));
                }
                self.publish();
                return;
            }
        };
        let runtime_id = running.runtime_id;
        let process_id = running.child.id();
        if let Some(thread_id) = thread_id {
            let id = self.id;
            self.row.agent_conversation = Some(thread_id.clone());
            if let Err(error) = self
                .write(move |database| axo_store::bind_agent_conversation(database, id, &thread_id))
                .await
            {
                log::warn!("event=session.agent_bind_failed session_id={id} reason={error}");
            }
        }
        self.install(shell_id, running);
        if let Some(pi) = &mut self.pi {
            pi.state = PiState::Running {
                runtime_id,
                link,
                link_task,
            };
            pi.activity = None;
            pi.active_at = Instant::now();
        }
        log::info!(
            "event=session.pi_started session_id={} shell_id={} pid={process_id}",
            self.id,
            shell_id.get()
        );
        let id = self.id;
        let stored = identity.map(ProcessIdentity::to_stored);
        if let Err(error) = self
            .core
            .store
            .call(move |database| axo_store::store_pi_process(database, id, stored.as_deref()))
            .await
        {
            log::warn!("event=session.pi_process_unsaved session_id={id} reason={error}");
        }
        self.publish();
        for waiter in waiters {
            let _ = waiter.send(Ok(()));
        }
    }

    /// The pane process and the link of a launched agent, the link already following it; and
    /// the thread it runs, for an agent that names its conversation at launch.
    fn follow(
        &self,
        launched: Launched,
        shell_id: ShellId,
        pane_id: String,
    ) -> io::Result<Followed> {
        let log_context = format!("session_id={} shell_id={}", self.id, shell_id.get());
        // Counted until it is installed, as this returns.
        let Launched {
            in_flight: _in_flight,
            agent,
        } = launched;
        match agent {
            LaunchedAgent::Pi(launched) => {
                log_socket_cleanup(self.id, launched.process.socket_cleanup);
                let identity = launched.process.identity;
                let running = Running::new(
                    PaneRole::Pi,
                    Some(pane_id.clone()),
                    self.row.folder.clone(),
                    launched.process.pty,
                    Some(launched.process.writer_lock),
                )?;
                let runtime_id = running.runtime_id;
                let (link, requests) = link::command_channel();
                let config = LinkConfig {
                    session_uuid: self.id.to_string(),
                    pane_id,
                    initial_pwd: self.row.folder.clone(),
                    session_file: launched.session_file,
                    bridge_socket: launched.bridge_socket,
                    bridge_token: launched.bridge_token,
                    process_id: running.child.id(),
                    log_context,
                };
                let mailbox = self.mailbox();
                let link_task = tokio::spawn(link::run(
                    config,
                    requests,
                    Arc::clone(&self.core.bridges_changed),
                    move |event| {
                        mailbox.upgrade().is_some_and(|mailbox| {
                            mailbox.send(Message::Link { runtime_id, event }).is_ok()
                        })
                    },
                ))
                .abort_handle();
                Ok(Followed {
                    running,
                    identity,
                    link: AgentCommands::Pi(link),
                    link_task,
                    thread_id: None,
                })
            }
            LaunchedAgent::Codex(launched) => {
                let axo_agent::codex::CodexProcess {
                    pty,
                    writer_lock,
                    server,
                    identity,
                    thread_id,
                } = launched;
                let socket = axo_agent::codex::CodexPaths::new(
                    &self.core.pi_directories.bridges,
                    &self.id.to_string(),
                )?;
                let running = Running::new(
                    PaneRole::Pi,
                    Some(pane_id),
                    self.row.folder.clone(),
                    pty,
                    Some(writer_lock),
                )?;
                let runtime_id = running.runtime_id;
                let (link, requests) = axo_agent::codex::command_channel();
                let config = axo_agent::codex::LinkConfig {
                    socket: socket.socket().to_owned(),
                    thread_id: thread_id.clone(),
                    instructions: Some(agent_brief()),
                    log_context,
                };
                let mailbox = self.mailbox();
                // The link owns the server: it stops when the link is let go.
                let link_task = tokio::spawn(axo_agent::codex::run(
                    config,
                    requests,
                    Some(server),
                    move |event| {
                        mailbox.upgrade().is_some_and(|mailbox| {
                            mailbox.send(Message::Link { runtime_id, event }).is_ok()
                        })
                    },
                ))
                .abort_handle();
                Ok(Followed {
                    running,
                    identity,
                    link: AgentCommands::Codex(link),
                    link_task,
                    thread_id: Some(thread_id),
                })
            }
            LaunchedAgent::OpenCode(launched) => {
                let axo_agent::opencode::OpenCodeProcess {
                    pty,
                    writer_lock,
                    server,
                    identity,
                    address,
                    session_id,
                } = launched;
                let paths = axo_agent::opencode::OpenCodePaths::new(
                    &self.core.pi_directories.bridges,
                    &self.id.to_string(),
                );
                let running = Running::new(
                    PaneRole::Pi,
                    Some(pane_id),
                    self.row.folder.clone(),
                    pty,
                    Some(writer_lock),
                )?;
                let runtime_id = running.runtime_id;
                let (link, requests) = axo_agent::opencode::command_channel();
                let config = axo_agent::opencode::LinkConfig {
                    address,
                    session_id: session_id.clone(),
                    directory: self.row.folder.clone(),
                    conversation: paths.conversation().to_owned(),
                    log_context,
                };
                let mailbox = self.mailbox();
                // The link owns the server: it stops when the link is let go.
                let link_task = tokio::spawn(axo_agent::opencode::run(
                    config,
                    requests,
                    Some(server),
                    move |event| {
                        mailbox.upgrade().is_some_and(|mailbox| {
                            mailbox.send(Message::Link { runtime_id, event }).is_ok()
                        })
                    },
                ))
                .abort_handle();
                Ok(Followed {
                    running,
                    identity,
                    link: AgentCommands::OpenCode(link),
                    link_task,
                    thread_id: Some(session_id),
                })
            }
            LaunchedAgent::ClaudeCode(launched) => {
                let axo_agent::claude::ClaudeProcess {
                    pty,
                    writer_lock,
                    hooks,
                    identity,
                    conversation,
                } = launched;
                let terminal = pty.master.try_clone()?;
                let running = Running::new(
                    PaneRole::Pi,
                    Some(pane_id),
                    self.row.folder.clone(),
                    pty,
                    Some(writer_lock),
                )?;
                let runtime_id = running.runtime_id;
                let (link, requests) = axo_agent::claude::command_channel();
                let config = axo_agent::claude::LinkConfig {
                    conversation: conversation.clone(),
                    terminal,
                    log_context,
                };
                let mailbox = self.mailbox();
                let link_task = tokio::spawn(axo_agent::claude::run(
                    config,
                    requests,
                    hooks,
                    move |event| {
                        mailbox.upgrade().is_some_and(|mailbox| {
                            mailbox.send(Message::Link { runtime_id, event }).is_ok()
                        })
                    },
                ))
                .abort_handle();
                Ok(Followed {
                    running,
                    identity,
                    link: AgentCommands::ClaudeCode(link),
                    link_task,
                    thread_id: Some(conversation),
                })
            }
        }
    }

    /// The running Pi exited: it is unavailable, dormant if it was put to sleep, or starts again
    /// if a restart asked for it, taking the prompts that waited for it.
    pub(super) async fn pi_exited(&mut self) {
        let Some(pi) = &mut self.pi else { return };
        let restart = std::mem::take(&mut pi.restart);
        let sleep = std::mem::take(&mut pi.sleep);
        let queued = std::mem::take(&mut pi.queued);
        if pi.resumable_work() && !sleep && queued.is_empty() {
            pi.recovery = Recovery::Pending;
        }
        pi.let_go();
        if restart {
            pi.queued = queued;
        } else if sleep {
            pi.state = PiState::Dormant;
            log::info!("event=session.pi_slept session_id={}", self.id);
        }
        let id = self.id;
        if let Err(error) = self
            .core
            .store
            .call(move |database| axo_store::store_pi_process(database, id, None))
            .await
        {
            log::warn!("event=session.pi_process_unsaved session_id={id} reason={error}");
        }
        self.publish();
        if restart {
            self.start_pi(None).await;
        }
    }

    pub(super) fn kill_pi(&mut self, runtime_id: RuntimeId) {
        let Some(pi) = &self.pi else { return };
        let PiState::Running {
            runtime_id: current,
            ..
        } = pi.state
        else {
            return;
        };
        if current != runtime_id {
            return;
        }
        if let Some(running) = self.panes.get(&pi.shell_id) {
            log::warn!(
                "event=session.pi_restart_kill session_id={} pid={}",
                self.id,
                running.child.id()
            );
            axo_pty::process::signal(&running.child, libc::SIGKILL);
        }
    }

    /// Starts a dormant Pi, for anyone who wants the Session: a prompt, a client showing it,
    /// typing into it. `only` limits it to that pane. Whether it was dormant.
    pub(crate) async fn wake(&mut self, only: Option<ShellId>) -> bool {
        let dormant = self
            .pi
            .as_ref()
            .is_some_and(|pi| pi.is_dormant() && only.is_none_or(|only| only == pi.shell_id));
        if dormant {
            log::info!("event=session.pi_woken session_id={}", self.id);
            self.start_pi(None).await;
        }
        dormant
    }

    /// Starts the Pi of `shell_id`, which must not be running; `waiter` hears when it is up.
    pub(crate) async fn restart_unavailable(
        &mut self,
        shell_id: ShellId,
        waiter: Waiter,
    ) -> io::Result<()> {
        let unavailable = self.pi.as_ref().is_some_and(|pi| {
            pi.shell_id == shell_id && !matches!(pi.state, PiState::Running { .. })
        });
        if !unavailable {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "the requested Pi pane is not unavailable",
            ));
        }
        self.start_pi(Some(waiter)).await;
        Ok(())
    }

    /// Restarts the Pi for a person away from the Mac, whether it runs, is stuck, or has exited:
    /// a running one is asked to exit (stopping any turn), killed if it doesn't, and started
    /// again on its conversation once it has gone.
    pub(crate) async fn restart_for_client(&mut self) -> io::Result<()> {
        if self.core.is_stopping() {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "Axod is shutting down",
            ));
        }
        let interrupted = self.pi.as_ref().is_some_and(Pi::resumable_work);
        let Some(pi) = &mut self.pi else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "the Session has no Pi pane",
            ));
        };
        if interrupted {
            pi.recovery = Recovery::Pending;
        }
        log::info!(
            "event=session.pi_restart_requested session_id={} running={}",
            self.id,
            matches!(pi.state, PiState::Running { .. })
        );
        match &pi.state {
            PiState::Running {
                runtime_id, link, ..
            } => {
                // Already exiting to sleep: it starts again instead.
                let exiting = std::mem::take(&mut pi.sleep);
                pi.restart = true;
                if !exiting {
                    let (runtime_id, link) = (*runtime_id, link.clone());
                    self.ask_pi_to_exit(runtime_id, link);
                }
            }
            PiState::Launching { .. } => {}
            PiState::Dormant | PiState::Unavailable => self.start_pi(None).await,
        }
        self.publish();
        Ok(())
    }

    /// Asks the running Pi to exit (stopping any turn), and kills it if it has not after a grace.
    fn ask_pi_to_exit(&self, runtime_id: RuntimeId, link: AgentCommands) {
        let mailbox = self.mailbox();
        tokio::spawn(async move {
            // Its answer doesn't matter.
            let _ = link.shutdown(ANSWER_TIMEOUT).await;
            tokio::time::sleep(EXIT_GRACE).await;
            if let Some(mailbox) = mailbox.upgrade() {
                let _ = mailbox.send(Message::KillPi { runtime_id });
            }
        });
    }

    /// How long the Pi has been idle (RFD0045): running and connected, not working or asking the
    /// person anything, with nothing waiting for it and not on its way out, for this long since
    /// anything happened in it or on its screen. `None` when it is not idle.
    pub(crate) fn pi_idle(&self) -> Option<Duration> {
        let pi = self.pi.as_ref()?;
        let PiState::Running { .. } = pi.state else {
            return None;
        };
        let activity = pi.activity?;
        let busy = !activity.connected
            || activity.working
            || activity.ui_waits > 0
            || !pi.queued.is_empty()
            || pi.flushing
            || pi.restart
            || pi.sleep;
        if busy {
            return None;
        }
        let shown = self
            .panes
            .get(&pi.shell_id)
            .map(|running| running.output.last_output_at());
        let last = shown.map_or(pi.active_at, |shown| shown.max(pi.active_at));
        Some(last.elapsed())
    }

    /// Puts the Pi to sleep if it is still idle: it is asked to exit, and its pane is dormant
    /// once it has. Whether it was idle.
    pub(crate) fn sleep_pi(&mut self) -> bool {
        if self.pi_idle().is_none() {
            return false;
        }
        let Some(pi) = &mut self.pi else { return false };
        let PiState::Running {
            runtime_id, link, ..
        } = &pi.state
        else {
            return false;
        };
        let (runtime_id, link) = (*runtime_id, link.clone());
        pi.sleep = true;
        log::info!("event=session.pi_sleeping session_id={}", self.id);
        self.ask_pi_to_exit(runtime_id, link);
        true
    }

    /// Whether `runtime_id` is the Pi running now.
    pub(crate) fn pi_is_current(&self, runtime_id: RuntimeId) -> bool {
        self.pi.as_ref().is_some_and(|pi| {
            matches!(pi.state, PiState::Running { runtime_id: current, .. } if current == runtime_id)
        })
    }

    /// Takes a prompt for the Pi: sent now on its link if it is up, or queued while it starts.
    /// A dormant Pi starts for it.
    pub(crate) async fn admit_prompt(
        &mut self,
        mut prompt: Prompt,
    ) -> Result<Admission, PromptError> {
        self.wake(None).await;
        let asking = self
            .core
            .questions
            .pending()
            .iter()
            .any(|question| question.session_id == self.id);
        let Some(pi) = &mut self.pi else {
            return Err(PromptError::NoPi);
        };
        pi.active_at = Instant::now();
        if (pi.human_turn_protected || asking)
            && prompt.delivery == axo_protocol::rpc::PromptDelivery::Interrupt
        {
            prompt.delivery = axo_protocol::rpc::PromptDelivery::FollowUp;
        }
        // A Pi on its way to sleep starts again for it; the prompt waits for the next one.
        if std::mem::take(&mut pi.sleep) {
            pi.restart = true;
        }
        let taking = pi.connected() && !pi.restart && !pi.flushing;
        let admitted = match &pi.state {
            PiState::Running { link, .. } if taking => {
                pi.recovery = Recovery::None;
                Ok(Admission::Send {
                    link: link.clone(),
                    delivery: prompt.delivery,
                })
            }
            PiState::Running { .. } | PiState::Launching { .. } => {
                if pi.queued.len() >= MAX_QUEUED_PI_PROMPTS {
                    return Err(PromptError::QueueFull);
                }
                let delivery = prompt.delivery;
                let (queued, receipt) = QueuedPrompt::new(prompt, self.id);
                pi.queued.push(queued);
                pi.recovery = Recovery::None;
                Ok(Admission::Queued { delivery, receipt })
            }
            PiState::Dormant | PiState::Unavailable => Err(PromptError::NoPi),
        };
        // Shutdown reads the catalog: publish supersession before admission returns.
        if admitted.is_ok() {
            self.publish();
        }
        admitted
    }

    fn release_human_turn_if_settled(&mut self) {
        if !self
            .core
            .questions
            .pending()
            .iter()
            .any(|question| question.session_id == self.id)
            && let Some(pi) = &mut self.pi
        {
            pi.human_turn_protected = false;
        }
    }

    pub(crate) fn protect_human_turn(&mut self) {
        if let Some(pi) = &mut self.pi {
            pi.human_turn_protected = true;
        }
    }

    /// Disarm automatic recovery before admitting explicit stop I/O. A lost receipt must not
    /// turn a person's stop into fresh work after a restart. New real prompts re-arm normally.
    pub(crate) fn pi_stop_link(&mut self) -> io::Result<AgentCommands> {
        let link = self.pi_link()?;
        if let Some(pi) = &mut self.pi {
            pi.recovery = Recovery::Suppressed;
            // Stop bypasses prompt admission. An unconfirmed/stale Stop is not proof that
            // the protected run ended; its settlement event releases the Send fence.
        }
        self.publish();
        Ok(link)
    }

    /// The running Pi's link: `NotFound` when no Pi runs.
    pub(crate) fn pi_link(&self) -> io::Result<AgentCommands> {
        match self.pi.as_ref().map(|pi| &pi.state) {
            Some(PiState::Running { link, .. }) => Ok(link.clone()),
            _ => Err(io::Error::new(io::ErrorKind::NotFound, "Pi is not running")),
        }
    }

    pub(crate) fn show_pi_agent_question(
        &mut self,
        question: axo_protocol::elicitation::Elicitation,
    ) {
        use axo_protocol::elicitation::{Asker, ElicitationKind};
        if question.session_id != self.id
            || question.asked_by != Asker::Agent
            || question.kind != ElicitationKind::Confirm
            || question.input.is_some()
        {
            return;
        }
        let Some(pi) = &mut self.pi else { return };
        let PiState::Running {
            runtime_id, link, ..
        } = &pi.state
        else {
            return;
        };
        pi.ui_questions.insert(question.id.clone(), *runtime_id);
        let link = link.clone();
        tokio::spawn(async move {
            let _ = link
                .show_elicitation(
                    &question.id,
                    question.title.as_deref().unwrap_or("Agent asks"),
                    &question.message,
                    question.expires_at,
                )
                .await;
        });
    }

    pub(crate) fn dismiss_pi_agent_question(&mut self, id: &str) {
        let Some(pi) = &mut self.pi else { return };
        let Some(owner) = pi.ui_questions.remove(id) else {
            return;
        };
        let PiState::Running {
            runtime_id, link, ..
        } = &pi.state
        else {
            return;
        };
        if owner != *runtime_id {
            return;
        }
        let link = link.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            let _ = link.dismiss_elicitation(&id).await;
        });
    }

    /// The input of the running Pi's pane.
    pub(crate) fn pi_input(&self) -> io::Result<Arc<crate::terminal_input::TerminalInput>> {
        let not_running = || io::Error::new(io::ErrorKind::NotFound, "Pi is not running");
        let pi = self.pi.as_ref().ok_or_else(not_running)?;
        self.input(pi.shell_id).map_err(|_| not_running())
    }

    pub(crate) fn pi_commands(&self) -> Vec<PiCommandInfo> {
        self.pi
            .as_ref()
            .map_or_else(Vec::new, |pi| pi.controls.commands.clone())
    }

    pub(crate) fn pi_models(&self) -> Vec<PiModelInfo> {
        self.pi
            .as_ref()
            .map_or_else(Vec::new, |pi| pi.controls.models.clone())
    }

    pub(super) async fn link_event(&mut self, runtime_id: RuntimeId, event: AgentEvent) {
        if !self.pi_is_current(runtime_id) {
            return;
        }
        if let Some(pi) = &mut self.pi {
            pi.active_at = Instant::now();
        }
        match event {
            AgentEvent::Bound { agent_session_id } => self.bound(agent_session_id).await,
            AgentEvent::Conversation { file } => {
                if let Some(pi) = &mut self.pi {
                    pi.mirror.conversation = Some(file);
                }
                self.mirror_transcript();
            }
            AgentEvent::Disconnected => {
                if let Some(pi) = &mut self.pi
                    && let Some(activity) = &mut pi.activity
                {
                    activity.connected = false;
                }
                self.publish();
            }
            AgentEvent::ResumeRequested {
                target_session_file,
            } => {
                let Some(target) = target_session_file else {
                    log::warn!(
                        "event=session.pi_resume_rejected session_id={} reason=invalid_request",
                        self.id
                    );
                    return;
                };
                let core = Arc::clone(&self.core);
                let id = self.id;
                tokio::spawn(async move {
                    if let Err(error) = crate::sessions::resume(core, id, runtime_id, target).await
                    {
                        log::warn!(
                            "event=session.pi_resume_rejected session_id={id} error_kind={:?} reason={error}",
                            error.kind()
                        );
                    }
                });
            }
            AgentEvent::Event {
                agent_session_id: pi_session_id,
                stream_id,
                sequence,
                name,
                data,
            } => {
                if matches!(name.as_str(), "message.end" | "tool.end" | "agent.settled") {
                    self.mirror_transcript();
                }
                self.pi_event(runtime_id, &name, &data).await;
                if name == "session.import.requested" || name == "elicitation.answer" {
                    return;
                }
                self.core.events.publish(Event::PiEvent {
                    session_id: self.id,
                    pi_session_id,
                    stream_id,
                    sequence,
                    name,
                    data,
                });
            }
        }
    }

    async fn bound(&mut self, pi_session_id: String) {
        let id = self.id;
        // Another agent's conversation was bound when it launched.
        if self.row.agent == AgentKind::Pi
            && let Err(error) = self
                .write(move |database| axo_store::bind_pi_session_id(database, id, &pi_session_id))
                .await
        {
            log::warn!("event=session.pi_bind_failed session_id={id} reason={error}");
        }
        let Some(pi) = &mut self.pi else { return };
        pi.activity.get_or_insert_default().connected = true;
        // Never deliver replacement-runtime work back to the old Pi while it exits. A flush
        // still running takes what queued behind it when it ends.
        if pi.restart || pi.flushing || self.core.is_stopping() {
            return;
        }
        let queued = std::mem::take(&mut pi.queued);
        let resume = queued.is_empty() && pi.recovery.claim();
        if !queued.is_empty() {
            pi.recovery = Recovery::None;
        }
        let link = match &pi.state {
            PiState::Running { link, .. } => link.clone(),
            _ => return,
        };
        self.publish();
        if resume {
            let resume_link = link.clone();
            tokio::spawn(async move {
                // A lost receipt is uncertain: don't recreate intent on reconnect or retry it.
                match resume_link.resume_turn(ANSWER_TIMEOUT).await {
                    Ok(result) => log::info!(
                        "event=session.pi_resume_turn session_id={id} outcome={result:?}"
                    ),
                    Err(error) => log::warn!(
                        "event=session.pi_resume_turn_uncertain session_id={id} kind={:?}",
                        error.kind()
                    ),
                }
            });
        }
        if queued.is_empty() {
            return;
        }
        // Pi has finished starting: it takes what was sent to it meanwhile, oldest first.
        if let Some(runtime_id) = self.running_runtime() {
            self.flush(runtime_id, link, queued);
        }
    }

    fn running_runtime(&self) -> Option<RuntimeId> {
        match self.pi.as_ref().map(|pi| &pi.state) {
            Some(PiState::Running { runtime_id, .. }) => Some(*runtime_id),
            _ => None,
        }
    }

    /// Sends `queued` to the running Pi in order, then takes whatever queued behind it meanwhile.
    fn flush(&mut self, runtime_id: RuntimeId, link: AgentCommands, queued: Vec<QueuedPrompt>) {
        let Some(pi) = &mut self.pi else { return };
        pi.flushing = true;
        log::info!(
            "event=session.pi_prompts_flushed session_id={} count={}",
            self.id,
            queued.len()
        );
        let mailbox = self.mailbox();
        tokio::spawn(async move {
            for prompt in queued {
                prompt.deliver(&link).await;
            }
            if let Some(mailbox) = mailbox.upgrade() {
                let _ = mailbox.send(Message::Job(Box::new(move |session| {
                    session.flushed(runtime_id, link);
                    Box::pin(async {})
                })));
            }
        });
    }

    /// A flush ended: what queued behind it goes next, unless that Pi is going.
    fn flushed(&mut self, runtime_id: RuntimeId, link: AgentCommands) {
        if !self.pi_is_current(runtime_id) {
            return;
        }
        let stopping = self.core.is_stopping();
        let Some(pi) = &mut self.pi else { return };
        pi.flushing = false;
        if pi.queued.is_empty() || pi.restart || stopping {
            return;
        }
        let queued = std::mem::take(&mut pi.queued);
        self.flush(runtime_id, link, queued);
    }

    async fn pi_event(&mut self, runtime_id: RuntimeId, name: &str, data: &Value) {
        if name == "elicitation.answer" {
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Reply {
                id: String,
                action: axo_protocol::elicitation::ElicitationAction,
            }
            let Ok(reply) = serde_json::from_value::<Reply>(data.clone()) else {
                return;
            };
            if !self
                .pi
                .as_ref()
                .is_some_and(|pi| pi.ui_questions.get(&reply.id) == Some(&runtime_id))
            {
                return;
            }
            let _ = self.core.questions.resolve_pi_agent_question(
                self.core.as_ref(),
                self.id,
                &reply.id,
                reply.action,
            );
            return;
        }
        if name == "session.import.requested" {
            let Some(source) = data["sourcePath"]
                .as_str()
                .filter(|path| !path.is_empty() && path.len() <= 4096 && !path.contains('\0'))
                .map(str::to_owned)
            else {
                log::warn!(
                    "event=session.pi_import_rejected session_id={} reason=invalid_path",
                    self.id
                );
                return;
            };
            let core = Arc::clone(&self.core);
            let id = self.id;
            let folder = self.folder();
            tokio::spawn(async move {
                if let Err(error) =
                    crate::sessions::import(core, id, runtime_id, folder, source).await
                {
                    log::warn!(
                        "event=session.pi_import_rejected session_id={id} error_kind={:?}",
                        error.kind()
                    );
                }
            });
            return;
        }
        // What Pi runs (RFD0033): kept for clients; only its model and level are in the snapshot.
        if let Some(control) = PiControlEvent::parse(name, data) {
            let changed = self
                .pi
                .as_mut()
                .is_some_and(|pi| control.apply(&mut pi.controls));
            if changed {
                self.publish();
            }
            return;
        }
        let id = self.id;
        let changed = match PiCatalogEvent::parse(name, data) {
            PiCatalogEvent::AgentStarted | PiCatalogEvent::UserMessageStarted => {
                let recovered = self.pi.as_mut().is_some_and(|pi| {
                    if pi.restart {
                        return false;
                    }
                    pi.recovery.started()
                });
                self.update_activity(|activity| !std::mem::replace(&mut activity.working, true))
                    || recovered
            }
            PiCatalogEvent::AgentSettled => {
                self.release_human_turn_if_settled();
                if let Some(pi) = &mut self.pi {
                    pi.recovery.settled();
                }
                // The agent may have changed the repository: read it again.
                self.core.workspace_states.refresh(id, self.folder());
                self.update_activity(|activity| std::mem::replace(&mut activity.working, false))
            }
            PiCatalogEvent::PromptStarted => self.update_activity(|activity| {
                let previous = activity.ui_waits;
                activity.ui_waits = previous.saturating_add(1);
                activity.ui_waits != previous
            }),
            PiCatalogEvent::PromptEnded => self.update_activity(|activity| {
                let previous = activity.ui_waits;
                activity.ui_waits = previous.saturating_sub(1);
                activity.ui_waits != previous
            }),
            PiCatalogEvent::ActivitySnapshot { working } => {
                if !working {
                    self.release_human_turn_if_settled();
                }
                if let Some(pi) = &mut self.pi {
                    if working && pi.recovery == Recovery::SettledAfterStop {
                        pi.recovery.started();
                    } else if !working {
                        pi.recovery.settled();
                    }
                }
                self.update_activity(|activity| {
                    std::mem::replace(&mut activity.working, working) != working
                })
            }
            PiCatalogEvent::MessageEnded => self
                .write(move |database| {
                    axo_store::record_session_message(database, id, axo_store::unix_timestamp())
                })
                .await
                .unwrap_or(false),
            PiCatalogEvent::Named { title } => {
                let title = title.to_owned();
                self.write(move |database| {
                    axo_store::describe_session(database, id, Some(&title), None)
                })
                .await
                .unwrap_or(false)
            }
            PiCatalogEvent::Described { title, emoji } => {
                let (title, emoji) = (title.map(str::to_owned), emoji.map(str::to_owned));
                self.write(move |database| {
                    axo_store::describe_session(database, id, title.as_deref(), emoji.as_deref())
                })
                .await
                .unwrap_or(false)
            }
            PiCatalogEvent::Ignored => false,
        };
        if changed {
            self.publish();
        }
    }

    /// Converts the agent's conversation into the Session's transcript, on the blocking pool,
    /// unless a conversion runs already (then once more after it). Pi writes its own.
    fn mirror_transcript(&mut self) {
        if self.row.agent == AgentKind::Pi {
            return;
        }
        let Some(transcript) = self.row.pi_session_file.clone() else {
            return;
        };
        let Some(pi) = &mut self.pi else { return };
        let Some(native) = pi.mirror.conversation.clone() else {
            return;
        };
        if pi.mirror.running {
            pi.mirror.again = true;
            return;
        }
        pi.mirror.running = true;
        let header = axo_agent::transcript::PiHeader {
            session_id: self.id.to_string(),
            timestamp: axo_agent::transcript::rfc3339_utc(self.row.created_at),
            cwd: self.row.folder.to_string_lossy().into_owned(),
        };
        let (kind, id, mailbox) = (self.row.agent, self.id, self.mailbox());
        tokio::spawn(async move {
            let converted = tokio::task::spawn_blocking(move || {
                let native = std::fs::read_to_string(&native)?;
                let lines = axo_agent::transcript::pi_lines(kind, &native, &header)?;
                axo_agent::transcript::write_if_changed(&transcript, &lines)
            })
            .await
            .map_err(io::Error::other)
            .and_then(|converted| converted);
            match converted {
                Ok(true) => log::debug!("event=session.transcript_converted session_id={id}"),
                Ok(false) => {}
                Err(error) => log::warn!(
                    "event=session.transcript_unconverted session_id={id} error_kind={:?} reason={error}",
                    error.kind()
                ),
            }
            if let Some(mailbox) = mailbox.upgrade() {
                let _ = mailbox.send(Message::Job(Box::new(|session: &mut Session| {
                    Box::pin(async move { session.mirrored() })
                })));
            }
        });
    }

    fn mirrored(&mut self) {
        let Some(pi) = &mut self.pi else { return };
        pi.mirror.running = false;
        if std::mem::take(&mut pi.mirror.again) {
            self.mirror_transcript();
        }
    }

    fn update_activity(&mut self, change: impl FnOnce(&mut Activity) -> bool) -> bool {
        self.pi
            .as_mut()
            .is_some_and(|pi| change(pi.activity.get_or_insert_default()))
    }
}

/// A Pi started for a Session that no longer wants it is stopped.
pub(super) fn stop_unwanted(message: Message) {
    let Message::Launched {
        result: Ok(launched),
        ..
    } = message
    else {
        return;
    };
    let Launched { in_flight, agent } = launched;
    let grace = axo_agent::pi::STOP_GRACE;
    match agent {
        LaunchedAgent::Pi(launched) => {
            let mut process = launched.process;
            tokio::spawn(async move {
                axo_pty::process::stop_async(&mut process.pty.child, grace).await;
                drop(process);
                drop(in_flight);
            });
        }
        // Dropping the server stops it; the TUI is stopped like a Pi.
        LaunchedAgent::Codex(mut process) => {
            tokio::spawn(async move {
                axo_pty::process::stop_async(&mut process.pty.child, grace).await;
                drop(process);
                drop(in_flight);
            });
        }
        LaunchedAgent::OpenCode(mut process) => {
            tokio::spawn(async move {
                axo_pty::process::stop_async(&mut process.pty.child, grace).await;
                drop(process);
                drop(in_flight);
            });
        }
        LaunchedAgent::ClaudeCode(mut process) => {
            tokio::spawn(async move {
                axo_pty::process::stop_async(&mut process.pty.child, grace).await;
                drop(process);
                drop(in_flight);
            });
        }
    }
}

pub(crate) fn log_socket_cleanup(session_id: axo_protocol::SessionId, cleanup: SocketCleanup) {
    match cleanup {
        SocketCleanup::Removed => {
            log::info!("event=pi.bridge_socket_removed session_id={session_id} reason=abandoned")
        }
        SocketCleanup::NotASocket => {
            log::warn!("event=pi.bridge_socket_blocked session_id={session_id} reason=not_a_socket")
        }
        SocketCleanup::Absent | SocketCleanup::InUse => {}
    }
}

/// Switches the model, the thinking level, or both, on `link`. Pi announces the result itself,
/// in `pi.state`, which reaches clients in the snapshot.
pub(crate) async fn set_model(
    link: &AgentCommands,
    model: Option<(&str, &str)>,
    thinking_level: Option<ThinkingLevel>,
) -> io::Result<()> {
    let answer = link
        .set_model(
            model,
            thinking_level.map(ThinkingLevel::as_str),
            ANSWER_TIMEOUT,
        )
        .await?;
    match answer {
        CommandResult::Accepted => Ok(()),
        CommandResult::Rejected(RejectReason::Invalid) => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Pi has no such model",
        )),
        CommandResult::Rejected(RejectReason::Unavailable) => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Pi is not signed in to that model's provider",
        )),
        CommandResult::Rejected(reason) => Err(io::Error::other(format!(
            "Pi did not switch the model: {reason}"
        ))),
    }
}

#[cfg(test)]
mod recovery_tests {
    use super::Recovery;

    #[test]
    fn reconnects_cannot_reclaim_a_runtime_resume() {
        let mut recovery = Recovery::Pending;
        assert!(recovery.claim());
        assert!(!recovery.claim());
        assert!(recovery.started());
        assert_eq!(recovery, Recovery::None);
        assert!(!recovery.claim());
    }

    #[test]
    fn late_start_events_cannot_resurrect_a_stop_before_settlement() {
        let mut recovery = Recovery::Suppressed;
        for _ in 0..2 {
            assert!(!recovery.started());
        }
        assert!(recovery.disarmed());
        recovery.settled();
        assert_eq!(recovery, Recovery::SettledAfterStop);
        assert!(recovery.disarmed());
        assert!(recovery.started());
        assert_eq!(recovery, Recovery::None);
        assert!(!recovery.disarmed());
    }

    #[test]
    fn an_old_runtime_settling_does_not_erase_captured_recovery() {
        for mut recovery in [Recovery::Pending, Recovery::Claimed] {
            let captured = recovery;
            recovery.settled();
            assert_eq!(recovery, captured);
        }
    }
}

#[cfg(test)]
#[path = "human_turn_tests.rs"]
mod human_turn_tests;
