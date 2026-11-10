//! A Session's Pi: launching it, its link, what it reports, and its end (RFD0041).
//!
//! A launch runs on the blocking pool: it takes the transcript's writer lock and starts Pi on a
//! PTY with the lifeline, so Pi lives no longer than axod. If the lock is held by the Pi an
//! earlier axod started for this Session (the same pid, started at the same time, as stored),
//! that Pi is killed and the lock taken once it is gone: a Pi axod is not the parent of is never
//! left running. A holder axod does not know is never signalled; the pane is unavailable.
//!
//! Restarting a Pi asks it to exit on its bridge, kills it if it has not after a grace, and
//! starts a new one on the same transcript once it has exited.

use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axo_agent::pi::link::{self, LinkCommands, LinkConfig, LinkEvent};
use axo_agent::pi::protocol::{CommandResult, RejectReason};
use axo_agent::pi::{BridgeSocketPath, PiLaunch, PiProcess, SocketCleanup};
use axo_agent::process::ProcessIdentity;
use axo_agent::{Activity, AgentCommand, FORK_EXEC_WINDOW, WriterLock};
use axo_protocol::{Event, PaneRole, PiCommandInfo, PiModelInfo, SessionStatus, ThinkingLevel};
use axo_pty::WindowSize;
use serde_json::Value;
use tokio::sync::oneshot;

use super::controls::{PiCatalogEvent, PiControlEvent, PiControls};
use super::panes::{Running, RuntimeId, pi_environment};
use super::prompts::{self, MAX_QUEUED_PI_PROMPTS, Prompt, PromptError};
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
        link: LinkCommands,
        link_task: tokio::task::AbortHandle,
    },
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
    queued: Vec<Prompt>,
    /// Start again once the running one exits.
    restart: bool,
    attempts: u64,
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
            restart: false,
            attempts: 0,
        }
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
        self.queued.clear();
    }
}

/// A Pi a launch started.
pub(crate) struct Launched {
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

fn launch(core: &Core, request: LaunchRequest) -> io::Result<Launched> {
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
        process,
        bridge_token,
        session_file,
        bridge_socket,
    })
}

fn invalid_data(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_owned())
}

/// What a prompt for the Session's Pi does now.
pub(crate) enum Admission {
    /// It waits for Pi to come up.
    Queued,
    /// Send it on this link.
    Send(LinkCommands),
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
        tokio::task::spawn_blocking(move || {
            let result = launch(&core, request);
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
        let started = result.and_then(|launched| {
            log_socket_cleanup(self.id, launched.process.socket_cleanup);
            let identity = launched.process.identity;
            let running = Running::new(
                PaneRole::Pi,
                Some(pane_id.clone()),
                self.row.folder.clone(),
                launched.process.pty,
                Some(launched.process.writer_lock),
            )?;
            Ok((
                running,
                identity,
                launched.bridge_token,
                launched.session_file,
                launched.bridge_socket,
            ))
        });
        let (running, identity, token, session_file, bridge_socket) = match started {
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
        let (link, requests) = link::command_channel();
        let config = LinkConfig {
            session_uuid: self.id.to_string(),
            pane_id,
            initial_pwd: self.row.folder.clone(),
            session_file,
            bridge_socket,
            bridge_token: token,
            process_id,
            log_context: format!("session_id={} shell_id={}", self.id, shell_id.get()),
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
        self.install(shell_id, running);
        if let Some(pi) = &mut self.pi {
            pi.state = PiState::Running {
                runtime_id,
                link,
                link_task,
            };
            pi.activity = None;
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

    /// The running Pi exited: it is unavailable, or starts again if a restart asked for it.
    pub(super) async fn pi_exited(&mut self) {
        let Some(pi) = &mut self.pi else { return };
        let restart = std::mem::take(&mut pi.restart);
        pi.let_go();
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
        let Some(pi) = &mut self.pi else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "the Session has no Pi pane",
            ));
        };
        log::info!(
            "event=session.pi_restart_requested session_id={} running={}",
            self.id,
            matches!(pi.state, PiState::Running { .. })
        );
        match &pi.state {
            PiState::Running {
                runtime_id, link, ..
            } => {
                pi.restart = true;
                let (runtime_id, link) = (*runtime_id, link.clone());
                let mailbox = self.mailbox();
                tokio::spawn(async move {
                    // Pi stops its turn and exits; its answer doesn't matter.
                    let _ = link.shutdown(ANSWER_TIMEOUT).await;
                    tokio::time::sleep(EXIT_GRACE).await;
                    if let Some(mailbox) = mailbox.upgrade() {
                        let _ = mailbox.send(Message::KillPi { runtime_id });
                    }
                });
            }
            PiState::Launching { .. } => {}
            PiState::Dormant | PiState::Unavailable => self.start_pi(None).await,
        }
        Ok(())
    }

    /// Whether `runtime_id` is the Pi running now.
    pub(crate) fn pi_is_current(&self, runtime_id: RuntimeId) -> bool {
        self.pi.as_ref().is_some_and(|pi| {
            matches!(pi.state, PiState::Running { runtime_id: current, .. } if current == runtime_id)
        })
    }

    /// Takes a prompt for the Pi: sent now on its link if it is up, or queued while it starts.
    /// A dormant Pi starts for it.
    pub(crate) async fn admit_prompt(&mut self, prompt: Prompt) -> Result<Admission, PromptError> {
        self.wake(None).await;
        let Some(pi) = &mut self.pi else {
            return Err(PromptError::NoPi);
        };
        let connected = pi.connected();
        match &pi.state {
            PiState::Running { link, .. } if connected => Ok(Admission::Send(link.clone())),
            PiState::Running { .. } | PiState::Launching { .. } => {
                if pi.queued.len() >= MAX_QUEUED_PI_PROMPTS {
                    return Err(PromptError::QueueFull);
                }
                pi.queued.push(prompt);
                Ok(Admission::Queued)
            }
            PiState::Dormant | PiState::Unavailable => Err(PromptError::NoPi),
        }
    }

    /// The running Pi's link: `NotFound` when no Pi runs.
    pub(crate) fn pi_link(&self) -> io::Result<LinkCommands> {
        match self.pi.as_ref().map(|pi| &pi.state) {
            Some(PiState::Running { link, .. }) => Ok(link.clone()),
            _ => Err(io::Error::new(io::ErrorKind::NotFound, "Pi is not running")),
        }
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

    pub(super) async fn link_event(&mut self, runtime_id: RuntimeId, event: LinkEvent) {
        if !self.pi_is_current(runtime_id) {
            return;
        }
        match event {
            LinkEvent::Bound { pi_session_id } => self.bound(pi_session_id).await,
            LinkEvent::Disconnected => {
                if let Some(pi) = &mut self.pi
                    && let Some(activity) = &mut pi.activity
                {
                    activity.connected = false;
                }
                self.publish();
            }
            LinkEvent::ResumeRequested {
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
            LinkEvent::Event {
                pi_session_id,
                stream_id,
                sequence,
                name,
                data,
            } => {
                self.pi_event(runtime_id, &name, &data).await;
                if name == "session.import.requested" {
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
        if let Err(error) = self
            .write(move |database| axo_store::bind_pi_session_id(database, id, &pi_session_id))
            .await
        {
            log::warn!("event=session.pi_bind_failed session_id={id} reason={error}");
        }
        let Some(pi) = &mut self.pi else { return };
        pi.activity.get_or_insert_default().connected = true;
        let queued = std::mem::take(&mut pi.queued);
        let link = match &pi.state {
            PiState::Running { link, .. } => link.clone(),
            _ => return,
        };
        self.publish();
        if queued.is_empty() {
            return;
        }
        log::info!(
            "event=session.pi_prompts_flushed session_id={id} count={}",
            queued.len()
        );
        // Pi has finished starting: it takes what was sent to it meanwhile, oldest first.
        tokio::spawn(async move {
            for prompt in queued {
                if let Err(error) = prompts::send(&link, &prompt).await {
                    log::warn!(
                        "event=session.pi_prompt_lost session_id={id} reason={}",
                        prompts::refusal(&error)
                    );
                }
            }
        });
    }

    async fn pi_event(&mut self, runtime_id: RuntimeId, name: &str, data: &Value) {
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
                self.update_activity(|activity| !std::mem::replace(&mut activity.working, true))
            }
            PiCatalogEvent::AgentSettled => {
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
            PiCatalogEvent::ActivitySnapshot { working } => self.update_activity(|activity| {
                std::mem::replace(&mut activity.working, working) != working
            }),
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

    fn update_activity(&mut self, change: impl FnOnce(&mut Activity) -> bool) -> bool {
        self.pi
            .as_mut()
            .is_some_and(|pi| change(pi.activity.get_or_insert_default()))
    }
}

/// A Pi started for a Session that no longer wants it is stopped.
fn stop_unwanted(message: Message) {
    if let Message::Launched {
        result: Ok(launched),
        ..
    } = message
    {
        let mut process = launched.process;
        let grace = axo_agent::pi::STOP_GRACE;
        tokio::spawn(async move {
            axo_pty::process::stop_async(&mut process.pty.child, grace).await;
            drop(process);
        });
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
    link: &LinkCommands,
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
