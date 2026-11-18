//! A running agent as its Session sees it, whatever the agent (RFD0072): the commands it takes
//! ([`AgentCommands`]), its answers ([`CommandResult`]) and what it reports ([`AgentEvent`]).
//!
//! Each kind has its own link to its agent; this is the one shape they all present. Event names
//! are the vocabulary pi-axo defined for its bridge (`agent.start`, `agent.settled`,
//! `message.end`, `pi.state`, …); every adapter speaks it, so nothing above knows which agent
//! runs.

use std::fmt;
use std::io;
use std::time::Duration;

use axo_protocol::asset::FetchedAttachment;
use axo_protocol::commands::{CommandId, StopTarget};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::AgentKind;
use crate::codex;
use crate::pi::link::LinkCommands;

/// How a working agent takes a message: `steer` into the running turn, `followUp` once it ends,
/// `interrupt` at once, stopping it.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum QueuedDelivery {
    Steer,
    FollowUp,
    Interrupt,
}

/// An agent's answer to a command.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(try_from = "CommandResultWire")]
pub enum CommandResult {
    Accepted,
    Rejected(RejectReason),
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum RejectReason {
    Invalid,
    Busy,
    Idle,
    Stale,
    Unavailable,
}

/// `{accepted: true}` or `{accepted: false, reason}`.
#[derive(Deserialize)]
struct CommandResultWire {
    accepted: bool,
    reason: Option<RejectReason>,
}

impl TryFrom<CommandResultWire> for CommandResult {
    type Error = &'static str;

    fn try_from(wire: CommandResultWire) -> Result<Self, Self::Error> {
        match (wire.accepted, wire.reason) {
            (true, None) => Ok(CommandResult::Accepted),
            (false, Some(reason)) => Ok(CommandResult::Rejected(reason)),
            _ => Err("a command result has a reason exactly when it was rejected"),
        }
    }
}

impl fmt::Display for RejectReason {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            RejectReason::Invalid => "invalid",
            RejectReason::Busy => "busy",
            RejectReason::Idle => "idle",
            RejectReason::Stale => "stale",
            RejectReason::Unavailable => "unavailable",
        })
    }
}

/// What a link tells its Session, in the order it happens.
#[derive(Debug, PartialEq)]
pub enum AgentEvent {
    /// The link proved it reaches the agent the Session launched; `agent_session_id` is the
    /// agent's own name for the conversation (Pi's session id, a Codex thread id).
    Bound { agent_session_id: String },
    /// A bound connection ended; the link tries again.
    Disconnected,
    /// Pi's `/resume` picked a saved Session (`None` when the request was malformed).
    ResumeRequested { target_session_file: Option<String> },
    /// One event, in stream order, named in Axo's agent vocabulary.
    Event {
        agent_session_id: String,
        stream_id: String,
        sequence: u64,
        name: String,
        data: Value,
    },
}

/// Commands for the agent a link follows. Cheap to clone; every clone reaches the same agent.
#[derive(Clone, Debug)]
pub enum AgentCommands {
    Pi(LinkCommands),
    Codex(codex::LinkCommands),
}

impl AgentCommands {
    pub fn kind(&self) -> AgentKind {
        match self {
            AgentCommands::Pi(_) => AgentKind::Pi,
            AgentCommands::Codex(_) => AgentKind::Codex,
        }
    }

    /// Submits `text` as a user message and waits for the agent's answer, for at most
    /// `timeout`. Without a delivery a working agent answers `busy`.
    pub async fn send_message(
        &self,
        text: &str,
        delivery: Option<QueuedDelivery>,
        command_id: Option<&CommandId>,
        attachments: &[FetchedAttachment],
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        match self {
            AgentCommands::Pi(link) => {
                link.send_message(text, delivery, command_id, attachments, timeout)
                    .await
            }
            AgentCommands::Codex(link) => {
                link.send_message(text, delivery, command_id, attachments, timeout)
                    .await
            }
        }
    }

    /// Stops the running turn if anything in `stop` belongs to it; otherwise answers `idle`.
    pub async fn stop_turn(
        &self,
        stop: StopTarget,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        match self {
            AgentCommands::Pi(link) => link.stop_turn(stop, timeout).await,
            AgentCommands::Codex(link) => link.stop_turn(stop, timeout).await,
        }
    }

    /// Continues interrupted work without a message (RFD0058). A lost receipt is not retried.
    pub async fn resume_turn(&self, timeout: Duration) -> io::Result<CommandResult> {
        match self {
            AgentCommands::Pi(link) => link.resume_turn(timeout).await,
            AgentCommands::Codex(link) => link.resume_turn(timeout).await,
        }
    }

    /// Asks the agent to exit now, stopping any turn in progress.
    pub async fn shutdown(&self, timeout: Duration) -> io::Result<CommandResult> {
        match self {
            AgentCommands::Pi(link) => link.shutdown(timeout).await,
            AgentCommands::Codex(link) => link.shutdown(timeout).await,
        }
    }

    /// Switches the model (`provider`, `id`), the thinking level, or both.
    pub async fn set_model(
        &self,
        model: Option<(&str, &str)>,
        thinking_level: Option<&str>,
        timeout: Duration,
    ) -> io::Result<CommandResult> {
        match self {
            AgentCommands::Pi(link) => link.set_model(model, thinking_level, timeout).await,
            AgentCommands::Codex(link) => link.set_model(model, thinking_level, timeout).await,
        }
    }

    /// Shows an agent's question to the person in the agent's own UI. Only Pi can; the others
    /// answer `Unsupported`, and the question is still asked on the person's devices.
    pub async fn show_elicitation(
        &self,
        id: &str,
        title: &str,
        message: &str,
        expires_at: u64,
    ) -> io::Result<CommandResult> {
        match self {
            AgentCommands::Pi(link) => link.show_elicitation(id, title, message, expires_at).await,
            _ => Err(no_elicitations(self.kind())),
        }
    }

    /// Takes down a question `show_elicitation` showed.
    pub async fn dismiss_elicitation(&self, id: &str) -> io::Result<CommandResult> {
        match self {
            AgentCommands::Pi(link) => link.dismiss_elicitation(id).await,
            _ => Err(no_elicitations(self.kind())),
        }
    }
}

fn no_elicitations(kind: AgentKind) -> io::Error {
    io::Error::new(
        io::ErrorKind::Unsupported,
        format!("{kind} cannot show Axo's questions in its own UI"),
    )
}
