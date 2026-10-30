//! Prompting a Session's Pi through its bridge, from a person away from the Mac or from another
//! Session's agent (RFD0015), and keeping agents that prompt agents from running away.
//!
//! Every prompt goes to Pi as the bridge's structured `send` command, written on the Pi's bridge
//! worker connection (Pi's bridge serves one Axod connection at a time), so it never mixes with
//! what someone is typing in the pane. A Pi still starting (its bridge not bound yet) cannot take
//! one: the prompt waits in `queued_pi_prompts` and is sent when the bridge binds.
//!
//! Provenance: each Session remembers the depth of the last prompt it was sent, the number of
//! agent prompts since a person last spoke to it. A prompt from Session S has depth
//! `depth(S) + 1`; a person's has depth 0, and a person typing into a Pi pane resets its depth.
//! Deeper than [`MAX_PROMPT_DEPTH`], or faster than the rate limits, is refused.

use std::collections::VecDeque;
use std::fmt;
use std::io;
use std::thread;
use std::time::{Duration, Instant};

use super::{SessionManager, SessionState};
use axo_pi::protocol::{CommandResult, QueuedDelivery, RejectReason};
use axo_pi::worker::CommandSender;
use axo_protocol::rpc::{PromptAccepted, PromptDelivery, PromptSession};
use axo_protocol::{PaneRole, SessionId, ShellId};

pub(super) const MAX_PI_PROMPT_BYTES: usize = 16_000;
/// A starting Pi holds at most this many prompts; more are refused until it is up.
pub(super) const MAX_QUEUED_PI_PROMPTS: usize = 8;
/// The longest chain of agents prompting agents (or themselves) since a person last spoke.
pub(super) const MAX_PROMPT_DEPTH: u32 = 8;
/// Prompts one Session's agent may send per [`RATE_WINDOW`], to anyone and to itself.
const MAX_AGENT_PROMPTS_PER_WINDOW: usize = 30;
const MAX_SELF_PROMPTS_PER_WINDOW: usize = 10;
const RATE_WINDOW: Duration = Duration::from_secs(60);

/// A prompt waiting for its Pi to finish starting.
pub(super) struct QueuedPrompt {
    text: String,
    delivery: PromptDelivery,
}

/// What each Session has sent and been sent, for loop limits.
#[derive(Default)]
pub(super) struct PromptProvenance {
    /// Depth of the last prompt each Session was sent; absent means 0.
    depth: std::collections::HashMap<SessionId, u32>,
    /// When each Session's agent sent prompts in the last window, and whether to itself.
    sent: std::collections::HashMap<SessionId, VecDeque<(Instant, bool)>>,
}

impl PromptProvenance {
    /// A person spoke to the Session's Pi directly.
    pub(super) fn reset(&mut self, session_id: SessionId) {
        self.depth.remove(&session_id);
    }

    pub(super) fn forget(&mut self, session_id: SessionId) {
        self.depth.remove(&session_id);
        self.sent.remove(&session_id);
    }

    fn depth_of(&self, session_id: SessionId) -> u32 {
        self.depth.get(&session_id).copied().unwrap_or(0)
    }

    /// Counts one prompt from `from` against its limits, or refuses it.
    fn admit(&mut self, from: SessionId, to_self: bool, now: Instant) -> Result<(), PromptError> {
        let sent = self.sent.entry(from).or_default();
        while sent
            .front()
            .is_some_and(|(at, _)| now.duration_since(*at) >= RATE_WINDOW)
        {
            sent.pop_front();
        }
        let to_self_count = sent.iter().filter(|(_, own)| *own).count();
        if sent.len() >= MAX_AGENT_PROMPTS_PER_WINDOW
            || (to_self && to_self_count >= MAX_SELF_PROMPTS_PER_WINDOW)
        {
            return Err(PromptError::RateLimited);
        }
        sent.push_back((now, to_self));
        Ok(())
    }
}

/// Why a prompt was not delivered.
#[derive(Debug)]
pub(super) enum PromptError {
    /// Empty, too long, or naming a Session that is not open.
    Invalid(&'static str),
    /// The Session has no running Pi.
    NoPi,
    /// The chain of agent prompts is deeper than [`MAX_PROMPT_DEPTH`].
    ChainTooDeep,
    RateLimited,
    /// `turn` delivery, and Pi is working.
    Busy,
    /// A starting Pi already holds [`MAX_QUEUED_PI_PROMPTS`].
    QueueFull,
    /// Pi refused or could not be reached.
    Unavailable(String),
}

impl fmt::Display for PromptError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(message) => formatter.write_str(message),
            Self::NoPi => formatter.write_str("Pi is not running in that Session"),
            Self::ChainTooDeep => write!(
                formatter,
                "chain too deep: more than {MAX_PROMPT_DEPTH} agent prompts since a person spoke"
            ),
            Self::RateLimited => write!(
                formatter,
                "rate limited: at most {MAX_AGENT_PROMPTS_PER_WINDOW} prompts a minute, \
                 {MAX_SELF_PROMPTS_PER_WINDOW} to the agent's own Session"
            ),
            Self::Busy => formatter.write_str("Pi is working; use steer or followUp delivery"),
            Self::QueueFull => {
                formatter.write_str("Pi is still starting and already has prompts waiting")
            }
            Self::Unavailable(reason) => write!(formatter, "Pi did not take the prompt: {reason}"),
        }
    }
}

impl From<PromptError> for io::Error {
    fn from(error: PromptError) -> Self {
        let kind = match error {
            PromptError::Invalid(_) => io::ErrorKind::InvalidInput,
            PromptError::NoPi => io::ErrorKind::NotFound,
            PromptError::ChainTooDeep | PromptError::RateLimited | PromptError::QueueFull => {
                io::ErrorKind::WouldBlock
            }
            PromptError::Busy => io::ErrorKind::ResourceBusy,
            PromptError::Unavailable(_) => io::ErrorKind::Other,
        };
        io::Error::new(kind, error.to_string())
    }
}

/// How long a prompt waits for Pi to answer on its bridge.
const PROMPT_ANSWER_TIMEOUT: Duration = Duration::from_secs(5);

/// A running Pi's bridge worker, reachable without holding the catalog lock.
struct PiBridge(CommandSender);

impl PiBridge {
    fn send(&self, text: &str, delivery: PromptDelivery) -> Result<(), PromptError> {
        let delivery_on_bridge = match delivery {
            PromptDelivery::Steer => Some(QueuedDelivery::Steer),
            PromptDelivery::FollowUp => Some(QueuedDelivery::FollowUp),
            PromptDelivery::Turn => None,
        };
        match self
            .0
            .send_message(text, delivery_on_bridge, PROMPT_ANSWER_TIMEOUT)
        {
            Ok(CommandResult::Accepted) => Ok(()),
            Ok(CommandResult::Rejected(RejectReason::Busy)) => Err(PromptError::Busy),
            Ok(CommandResult::Rejected(reason)) => Err(PromptError::Unavailable(
                format!("{reason:?}").to_lowercase(),
            )),
            Err(error) => Err(PromptError::Unavailable(error.to_string())),
        }
    }
}

fn pi_shell(state: &SessionState, session_id: SessionId) -> Option<ShellId> {
    state
        .panes
        .in_session(session_id)
        .find_map(|(id, pane)| match pane {
            axo_panes::Pane::Running(shell) if shell.role == PaneRole::Pi => Some(id),
            _ => None,
        })
}

fn pi_bridge(state: &SessionState, session_id: SessionId) -> io::Result<PiBridge> {
    let shell_id = pi_shell(state, session_id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Pi is not running"))?;
    state
        .panes
        .running(shell_id)
        .and_then(|running| running.pi_commands.clone())
        .map(PiBridge)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "Pi's bridge is not running"))
}

impl SessionManager {
    /// Sends `request.text` to the Session's Pi. Returns the prompt's depth, and whether it
    /// waits for Pi to finish starting.
    pub(super) fn prompt_session(
        &self,
        request: &PromptSession,
    ) -> Result<PromptAccepted, PromptError> {
        let PromptSession {
            session_id: target,
            ref text,
            delivery,
            from_session_id: from,
        } = *request;
        if text.trim().is_empty() || text.len() > MAX_PI_PROMPT_BYTES {
            return Err(PromptError::Invalid(
                "a prompt must contain 1 to 16000 bytes of text",
            ));
        }
        let (depth, bridge, text) = match self.admit_prompt(target, text, delivery, from) {
            Ok(Admitted::Queued { depth }) => {
                log_prompt(target, from, depth, delivery, "queued");
                return Ok(PromptAccepted {
                    accepted: true,
                    depth,
                    queued: true,
                });
            }
            Ok(Admitted::Send {
                depth,
                bridge,
                text,
            }) => (depth, bridge, text),
            Err(error) => {
                log_prompt(target, from, 0, delivery, refusal(&error));
                return Err(error);
            }
        };
        let sent = bridge.send(&text, delivery);
        log_prompt(
            target,
            from,
            depth,
            delivery,
            sent.as_ref().map_or_else(refusal, |()| "delivered"),
        );
        sent?;
        if let Ok(mut state) = self.lock_state() {
            state.prompt_provenance.depth.insert(target, depth);
        }
        Ok(PromptAccepted {
            accepted: true,
            depth,
            queued: false,
        })
    }

    /// Checks a prompt against its target and limits under the lock, and either queues it or
    /// returns what is needed to send it after the lock is released.
    fn admit_prompt(
        &self,
        target: SessionId,
        text: &str,
        delivery: PromptDelivery,
        from: Option<SessionId>,
    ) -> Result<Admitted, PromptError> {
        let mut state = self
            .lock_state()
            .map_err(|error| PromptError::Unavailable(error.to_string()))?;
        if let Some(from) = from
            && !state.panes.session_ids().contains(&from)
        {
            return Err(PromptError::Invalid("the sending Session is not open"));
        }
        pi_shell(&state, target).ok_or(PromptError::NoPi)?;
        // The receiving agent, and whoever reads its transcript, sees who sent the prompt.
        let text = match from {
            Some(from) => {
                let sender = axo_store::open_session_row(&state.database, from)
                    .map(|row| row.manual_name.unwrap_or(row.name))
                    .unwrap_or_default();
                format!("[From Axo Session {} {sender:?}]\n\n{text}", from)
            }
            None => text.to_owned(),
        };
        let depth = from.map_or(0, |from| state.prompt_provenance.depth_of(from) + 1);
        if depth > MAX_PROMPT_DEPTH {
            return Err(PromptError::ChainTooDeep);
        }
        if let Some(from) = from {
            state
                .prompt_provenance
                .admit(from, from == target, Instant::now())?;
        }
        let ready = state
            .pi_activity
            .get(&target)
            .is_some_and(|activity| activity.connected);
        if !ready {
            let queue = state.queued_pi_prompts.entry(target).or_default();
            if queue.len() >= MAX_QUEUED_PI_PROMPTS {
                return Err(PromptError::QueueFull);
            }
            queue.push(QueuedPrompt { text, delivery });
            state.prompt_provenance.depth.insert(target, depth);
            return Ok(Admitted::Queued { depth });
        }
        let bridge = pi_bridge(&state, target)
            .map_err(|error| PromptError::Unavailable(error.to_string()))?;
        Ok(Admitted::Send {
            depth,
            bridge,
            text,
        })
    }

    /// A person away from the Mac prompts the Session's Pi. Arriving while Pi works, it steers,
    /// as Enter in Pi's editor would.
    pub(super) fn prompt_pi(&self, session_id: SessionId, text: &str) -> io::Result<()> {
        self.prompt_session(&PromptSession {
            session_id,
            text: text.to_owned(),
            delivery: PromptDelivery::Steer,
            from_session_id: None,
        })
        .map(drop)
        .map_err(io::Error::from)
    }

    /// Sends the prompts that waited for the Session's Pi to finish starting, oldest first, on a
    /// thread of their own: the bridge round trips must not hold up the caller.
    pub(super) fn flush_queued_pi_prompts(&self, session_id: SessionId) -> io::Result<()> {
        let (queue, bridge) = {
            let mut state = self.lock_state()?;
            let Some(queue) = state.queued_pi_prompts.remove(&session_id) else {
                return Ok(());
            };
            (queue, pi_bridge(&state, session_id)?)
        };
        log::info!(
            "event=session.pi_prompts_flushed session_id={} count={}",
            session_id,
            queue.len()
        );
        thread::Builder::new()
            .name(format!("axo-pi-prompts-{}", session_id))
            .spawn(move || {
                for prompt in queue {
                    if let Err(error) = bridge.send(&prompt.text, prompt.delivery) {
                        log::warn!(
                            "event=session.pi_prompt_lost session_id={} reason={}",
                            session_id,
                            refusal(&error)
                        );
                    }
                }
            })?;
        Ok(())
    }
}

enum Admitted {
    Queued {
        depth: u32,
    },
    Send {
        depth: u32,
        bridge: PiBridge,
        /// What Pi is sent: the prompt, with its sender when an agent sent it.
        text: String,
    },
}

fn refusal(error: &PromptError) -> &'static str {
    match error {
        PromptError::Invalid(_) => "invalid",
        PromptError::NoPi => "no_pi",
        PromptError::ChainTooDeep => "chain_too_deep",
        PromptError::RateLimited => "rate_limited",
        PromptError::Busy => "busy",
        PromptError::QueueFull => "queue_full",
        PromptError::Unavailable(_) => "unavailable",
    }
}

fn log_prompt(
    target: SessionId,
    from: Option<SessionId>,
    depth: u32,
    delivery: PromptDelivery,
    outcome: &str,
) {
    log::info!(
        "event=session.prompt target_session_id={} from_session_id={} depth={depth} delivery={delivery:?} outcome={outcome}",
        target,
        from.map_or_else(|| "person".to_owned(), |from| from.to_string()),
    );
}
