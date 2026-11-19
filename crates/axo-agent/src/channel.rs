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

/// What a server's launcher keeps for as long as the server runs, such as its standing as its
/// Session's pane (RFD0073). Made from the server's pid the moment it is spawned: a server
/// starts its tools (`axod mcp`) before it is ready, and they act as the Session at once.
pub type WhileRunning = Box<dyn Send + Sync>;

/// The agent server a link owns: stopped when the link ends.
pub struct ServerProcess {
    child: std::process::Child,
    /// Let go before the server is reaped, so that its pid never vouches for a later process.
    while_running: Option<WhileRunning>,
}

impl ServerProcess {
    pub fn new(child: std::process::Child, while_running: impl FnOnce(u32) -> WhileRunning) -> Self {
        let while_running = Some(while_running(child.id()));
        Self { child, while_running }
    }

    pub fn id(&self) -> u32 {
        self.child.id()
    }
}

impl std::fmt::Debug for ServerProcess {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_tuple("ServerProcess").field(&self.child.id()).finish()
    }
}

impl Drop for ServerProcess {
    fn drop(&mut self) {
        drop(self.while_running.take());
        // The guard shell kills the server on SIGTERM; it leads its own process group.
        let pid = self.child.id() as libc::pid_t;
        // SAFETY: signals the guard this value spawned, and its group.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
            libc::kill(-pid, libc::SIGTERM);
        }
        let _ = self.child.wait();
    }
}


/// For tests whose server stands for no Session.
#[cfg(test)]
pub(crate) fn nothing_while_running(_pid: u32) -> WhileRunning {
    Box::new(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// Records, when let go, whether its server's pid still named the unreaped server.
    struct Standing {
        pid: u32,
        seen: Arc<Mutex<Option<bool>>>,
    }

    impl Drop for Standing {
        fn drop(&mut self) {
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            // SAFETY: waits without reaping (WNOWAIT) and without blocking, on our own child.
            let unreaped = unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.pid,
                    &mut info,
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            } == 0;
            *self.seen.lock().unwrap() = Some(unreaped);
        }
    }

    #[test]
    fn a_server_is_registered_from_its_spawn_and_let_go_before_it_is_reaped() {
        let seen = Arc::new(Mutex::new(None));
        let child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let spawned = child.id();
        let mut registered = None;
        let server = ServerProcess::new(child, |pid| {
            registered = Some(pid);
            Box::new(Standing {
                pid,
                seen: Arc::clone(&seen),
            })
        });
        assert_eq!(registered, Some(spawned));
        assert_eq!(*seen.lock().unwrap(), None, "held while the server runs");
        drop(server);
        assert_eq!(
            *seen.lock().unwrap(),
            Some(true),
            "let go while the pid still named the server"
        );
    }
}
