//! Prompting a Session's Pi through its bridge, from a person away from the Mac or from another
//! Session's agent (RFD0015), and keeping agents that prompt agents from running away.
//!
//! Every prompt goes to Pi as the bridge's structured `send` command on the Pi's link, so it never
//! mixes with what someone is typing in the pane. A Pi still starting cannot take one: the prompt
//! waits in its Session's task and is sent when the bridge binds.

use std::collections::VecDeque;
use std::fmt;
use std::io;
use std::time::{Duration, Instant};

use axo_agent::pi::link::LinkCommands;
use axo_agent::pi::protocol::{CommandResult, QueuedDelivery, RejectReason};
use axo_protocol::SessionId;
use axo_protocol::asset::FetchedAttachment;
use axo_protocol::commands::{CommandId, StopTarget};
use axo_protocol::rpc::{PromptDelivery, PromptText};

/// A starting Pi holds at most this many prompts; more are refused until it is up.
pub(crate) const MAX_QUEUED_PI_PROMPTS: usize = 8;
/// Prompts one Session's agent may send per [`RATE_WINDOW`], to anyone and to itself.
const MAX_AGENT_PROMPTS_PER_WINDOW: usize = 30;
const MAX_SELF_PROMPTS_PER_WINDOW: usize = 10;
const RATE_WINDOW: Duration = Duration::from_secs(60);
/// How long a prompt waits for Pi to answer on its bridge.
pub(crate) const PROMPT_ANSWER_TIMEOUT: Duration = Duration::from_secs(5);

/// A prompt for Pi: what it says, how a working Pi takes it, and a client's command id.
#[derive(Clone, Debug)]
pub(crate) struct Prompt {
    pub(crate) text: String,
    pub(crate) delivery: PromptDelivery,
    pub(crate) command_id: Option<CommandId>,
    pub(crate) attachments: Vec<FetchedAttachment>,
}

/// What each Session's agent has sent, for rate limits.
#[derive(Default)]
pub(crate) struct PromptProvenance {
    /// When each Session's agent sent prompts in the last window, and whether to itself.
    sent: std::collections::HashMap<SessionId, VecDeque<(Instant, bool)>>,
}

impl PromptProvenance {
    pub(crate) fn forget(&mut self, session_id: SessionId) {
        self.sent.remove(&session_id);
    }

    /// Counts one prompt from `from` against its limits, or refuses it.
    pub(crate) fn admit(
        &mut self,
        from: SessionId,
        to_self: bool,
        now: Instant,
    ) -> Result<(), PromptError> {
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
pub(crate) enum PromptError {
    /// Empty, too long, or naming a Session that is not open.
    Invalid(&'static str),
    /// The Session has no running Pi.
    NoPi,
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
            PromptError::RateLimited | PromptError::QueueFull => io::ErrorKind::WouldBlock,
            PromptError::Busy => io::ErrorKind::ResourceBusy,
            PromptError::Unavailable(_) => io::ErrorKind::Other,
        };
        io::Error::new(kind, error.to_string())
    }
}

/// A prompt says something: words, or attachments alone (RFD0030). Its length is bounded by
/// [`PromptText`] where it was parsed.
pub(crate) fn check_prompt(
    text: &PromptText,
    attachments: &[FetchedAttachment],
) -> Result<(), PromptError> {
    if text.is_blank() && attachments.is_empty() {
        return Err(PromptError::Invalid("a prompt says something"));
    }
    Ok(())
}

pub(crate) fn still_starting() -> io::Error {
    io::Error::new(io::ErrorKind::TimedOut, "Pi is still starting")
}

/// Sends `prompt` on `link` and waits for Pi's answer. With a `command_id`, pi-axo takes the
/// prompt at most once, with a receipt (RFD0024).
pub(crate) async fn send(link: &LinkCommands, prompt: &Prompt) -> Result<(), PromptError> {
    let delivery = match prompt.delivery {
        PromptDelivery::Steer => Some(QueuedDelivery::Steer),
        PromptDelivery::FollowUp => Some(QueuedDelivery::FollowUp),
        PromptDelivery::Interrupt => Some(QueuedDelivery::Interrupt),
        PromptDelivery::Turn => None,
    };
    match link
        .send_message(
            &prompt.text,
            delivery,
            prompt.command_id.as_ref(),
            &prompt.attachments,
            PROMPT_ANSWER_TIMEOUT,
        )
        .await
    {
        Ok(CommandResult::Accepted) => Ok(()),
        Ok(CommandResult::Rejected(RejectReason::Busy)) => Err(PromptError::Busy),
        Ok(CommandResult::Rejected(reason)) => Err(PromptError::Unavailable(
            format!("{reason:?}").to_lowercase(),
        )),
        Err(error) => Err(PromptError::Unavailable(error.to_string())),
    }
}

/// Whether the run `stop` names was running and is stopping.
pub(crate) async fn stop(link: &LinkCommands, stop: &StopTarget) -> Result<bool, PromptError> {
    match link.stop_turn(stop.clone(), PROMPT_ANSWER_TIMEOUT).await {
        Ok(CommandResult::Accepted) => Ok(true),
        Ok(CommandResult::Rejected(RejectReason::Idle)) => Ok(false),
        Ok(CommandResult::Rejected(reason)) => Err(PromptError::Unavailable(
            format!("{reason:?}").to_lowercase(),
        )),
        Err(error) => Err(PromptError::Unavailable(error.to_string())),
    }
}

pub(crate) fn refusal(error: &PromptError) -> &'static str {
    match error {
        PromptError::Invalid(_) => "invalid",
        PromptError::NoPi => "no_pi",
        PromptError::RateLimited => "rate_limited",
        PromptError::Busy => "busy",
        PromptError::QueueFull => "queue_full",
        PromptError::Unavailable(_) => "unavailable",
    }
}

pub(crate) fn log_prompt(
    target: SessionId,
    from: Option<SessionId>,
    delivery: PromptDelivery,
    outcome: &str,
) {
    log::info!(
        "event=session.prompt target_session_id={} from_session_id={} delivery={delivery:?} outcome={outcome}",
        target,
        from.map_or_else(|| "person".to_owned(), |from| from.to_string()),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_agent_may_prompt_others_and_itself_within_its_limits() {
        let mut provenance = PromptProvenance::default();
        let (me, other) = (SessionId::from_u128(1), SessionId::from_u128(2));
        let now = Instant::now();
        for _ in 0..MAX_SELF_PROMPTS_PER_WINDOW {
            provenance.admit(me, true, now).unwrap();
        }
        assert!(matches!(
            provenance.admit(me, true, now),
            Err(PromptError::RateLimited)
        ));
        for _ in MAX_SELF_PROMPTS_PER_WINDOW..MAX_AGENT_PROMPTS_PER_WINDOW {
            provenance.admit(me, false, now).unwrap();
        }
        assert!(matches!(
            provenance.admit(me, false, now),
            Err(PromptError::RateLimited)
        ));
        provenance.admit(other, false, now).unwrap();
        provenance.admit(me, false, now + RATE_WINDOW).unwrap();
    }

    #[test]
    fn a_prompt_has_text_or_attachments() {
        let text = |text: &str| PromptText::parse(text.to_owned()).unwrap();
        assert!(check_prompt(&text("hello"), &[]).is_ok());
        assert!(check_prompt(&text(" \n"), &[]).is_err());
    }
}
