//! The command channel between axod and a link to an agent server it reaches with its own
//! client (Codex, OpenCode): axod's commands, each with where its answer goes, and the server
//! process the link owns.

use std::io;
use std::time::Duration;

use axo_protocol::asset::FetchedAttachment;
use axo_protocol::commands::{CommandId, StopTarget};
use tokio::sync::{mpsc, oneshot};

use crate::runtime::{CommandResult, QueuedDelivery};

const QUEUED_COMMANDS: usize = 32;

/// A command for the link, with where its answer goes.
#[derive(Debug)]
pub(crate) enum Action {
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
        /// `(provider, id)`.
        model: Option<(String, String)>,
        thinking_level: Option<String>,
    },
}

#[derive(Debug)]
pub(crate) struct Request {
    pub(crate) action: Action,
    pub(crate) reply: oneshot::Sender<io::Result<CommandResult>>,
}

/// Sends commands to the agent a link follows. Cheap to clone.
#[derive(Clone, Debug)]
pub struct LinkCommands(mpsc::Sender<Request>);

/// The link's end of [`LinkCommands`].
#[derive(Debug)]
pub struct LinkRequests(pub(crate) mpsc::Receiver<Request>);

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

    pub async fn set_model(
        &self,
        model: Option<(&str, &str)>,
        thinking_level: Option<&str>,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        self.command(
            Action::SetModel {
                model: model.map(|(provider, id)| (provider.to_owned(), id.to_owned())),
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
                .map_err(|_| io::Error::new(io::ErrorKind::NotConnected, "the agent's link has ended"))?;
            answer.await.unwrap_or_else(|_| {
                Err(io::Error::new(
                    io::ErrorKind::ConnectionAborted,
                    "the agent's link closed before answering",
                ))
            })
        };
        tokio::time::timeout(timeout, asked)
            .await
            .unwrap_or_else(|_| {
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "the agent did not answer the command in time",
                ))
            })
    }
}

/// The agent server a link owns: stopped when the link ends.
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

