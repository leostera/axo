//! axod's link to one Claude Code TUI (RFD0072, Claude Code): a future that receives its
//! hooks, reports them as Axo events, and types axod's prompts into its terminal as bracketed
//! pastes. Claude has no inbound channel, so everything axod asks is a keystroke.

use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axo_pty::output::TerminalOutput;

use crate::channel::{Action, LinkRequests, Request};
use crate::claude::ClaudeTrust;
use crate::claude::hooks::HookListener;
use crate::claude::session::{Observed, SendPlan, Session, StopPlan, asks_for_trust};
use crate::runtime::{AgentEvent, CommandResult, RejectReason};
use crate::vocabulary::{Emitted, text_with_attachments};

const WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// Between a paste and its Enter, so that the TUI has taken the paste as one.
const PASTE_SETTLE: Duration = Duration::from_millis(80);
const ESCAPE: &[u8] = b"\x1b";
/// After Escape, before typing anything else: a key that follows Escape at once reads as part
/// of one escape sequence, and Claude needs a moment to wind the turn down.
const ESCAPE_SETTLE: Duration = Duration::from_millis(300);
/// Claude Code exits on a second Ctrl-C.
const EXIT: &[u8] = b"\x03\x03";
/// How often an untrusted folder's question is looked at, until Claude trusts the folder.
const TRUST_POLL: Duration = Duration::from_millis(250);
/// The screen's height when looking for the question: no TUI shows it taller.
const TRUST_ROWS: usize = 60;

#[derive(Debug)]
pub struct LinkConfig {
    /// The conversation's id.
    pub conversation: String,
    /// The TUI's terminal, for typing into it: a copy of the PTY master.
    pub terminal: OwnedFd,
    /// Prefix for log lines, e.g. `session_id=… shell_id=2`.
    pub log_context: String,
    /// When Claude did not trust the folder as it started: where to see that it does.
    pub untrusted: Option<UntrustedFolder>,
}

/// How the link learns that the person trusted the folder: Claude's question is not on the
/// TUI's screen, and it was there before (the home's trust is not always recorded) or Claude's
/// record trusts the folder now. Never while the question shows: trusted elsewhere (another
/// Claude), this TUI still asks, and a prompt typed would answer "No, exit".
pub struct UntrustedFolder {
    pub trust: ClaudeTrust,
    pub screen: Arc<TerminalOutput>,
}

impl std::fmt::Debug for UntrustedFolder {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("UntrustedFolder").field("trust", &self.trust).finish_non_exhaustive()
    }
}

impl UntrustedFolder {
    /// Whether the folder is trusted now; `asked` remembers that the question was seen.
    fn trusted(&self, asked: &mut bool) -> bool {
        if asks_for_trust(&self.screen.screen_text(), TRUST_ROWS) {
            *asked = true;
            return false;
        }
        *asked || self.trust.trusted()
    }
}

/// Follows Claude until the Session lets the link go. The TUI's exit is noticed by the
/// Session as the pane's; the link only stops hearing hooks.
pub async fn run(
    config: LinkConfig,
    mut requests: LinkRequests,
    hooks: HookListener,
    mut report: impl FnMut(AgentEvent) -> bool + Send,
) {
    let context = config.log_context.clone();
    let mut hooks = match hooks.serve() {
        Ok(hooks) => hooks,
        Err(error) => {
            log::warn!("event=claude.hooks_failed {context} reason={error}");
            return;
        }
    };
    let mut link = Link {
        terminal: Arc::new(config.terminal),
        conversation: config.conversation,
        stream_id: axo_protocol::new_uuid_v4().unwrap_or_default(),
        sequence: 0,
        transcript: None,
        context,
    };
    let untrusted = config.untrusted;
    let mut asked = false;
    let mut trust_poll = tokio::time::interval(TRUST_POLL);
    let mut session = Session::new(link.conversation.clone(), untrusted.is_some());
    if !report(AgentEvent::Bound {
        agent_session_id: link.conversation.clone(),
    }) || !link.report_all(session.snapshot(), &mut report)
    {
        return;
    }
    loop {
        tokio::select! {
            hook = hooks.recv() => {
                let Some(hook) = hook else { return };
                let observed = session.observe(&hook);
                if !link.apply(observed, &mut session, &mut report).await {
                    return;
                }
            }
            _ = trust_poll.tick(), if session.untrusted() => {
                let Some(untrusted) = &untrusted else { continue };
                if !untrusted.trusted(&mut asked) {
                    continue;
                }
                log::info!("event=claude.folder_trusted {}", link.context);
                let observed = session.trusted();
                if !link.apply(observed, &mut session, &mut report).await {
                    return;
                }
            }
            request = requests.0.recv() => {
                let Some(Request { action, reply }) = request else { return };
                let (answer, observed, end) = link.command(action, &mut session).await;
                let _ = reply.send(answer);
                if end || !link.apply(observed, &mut session, &mut report).await {
                    return;
                }
            }
        }
    }
}

struct Link {
    terminal: Arc<OwnedFd>,
    conversation: String,
    stream_id: String,
    sequence: u64,
    /// The transcript last reported.
    transcript: Option<PathBuf>,
    context: String,
}

impl Link {
    fn report_all(
        &mut self,
        events: Vec<Emitted>,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> bool {
        events.into_iter().all(|event| {
            self.sequence += 1;
            report(AgentEvent::Event {
                agent_session_id: self.conversation.clone(),
                stream_id: self.stream_id.clone(),
                sequence: self.sequence,
                name: event.name.to_owned(),
                data: event.data,
            })
        })
    }

    /// Reports what a hook or a command meant, and types the prompt it lets go.
    async fn apply(
        &mut self,
        observed: Observed,
        session: &mut Session,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> bool {
        let Observed {
            events,
            transcript,
            next,
        } = observed;
        if let Some(file) = transcript
            && self.transcript.as_ref() != Some(&file)
        {
            self.transcript = Some(file.clone());
            if !report(AgentEvent::Conversation { file }) {
                return false;
            }
        }
        if !self.report_all(events, report) {
            return false;
        }
        if let Some(text) = next
            && let Err(error) = self.type_prompt(&text).await
        {
            log::warn!("event=claude.prompt_unsent {} reason={error}", self.context);
            session.type_failed();
        }
        true
    }

    /// Carries out one command: its answer, what it meant, and whether the link ends.
    async fn command(
        &mut self,
        action: Action,
        session: &mut Session,
    ) -> (io::Result<CommandResult>, Observed, bool) {
        let rejected = |reason| (Ok(CommandResult::Rejected(reason)), Observed::default(), false);
        match action {
            Action::Send {
                text,
                delivery,
                attachments,
                ..
            } => match session.plan_send(text_with_attachments(&text, &attachments), delivery) {
                SendPlan::Type(text) => match self.type_prompt(&text).await {
                    Ok(()) => (Ok(CommandResult::Accepted), Observed::default(), false),
                    Err(error) => {
                        session.type_failed();
                        (Err(error), Observed::default(), false)
                    }
                },
                SendPlan::Held => (Ok(CommandResult::Accepted), Observed::default(), false),
                SendPlan::Reject(reason) => rejected(reason),
            },
            Action::Stop(_) => match session.plan_stop() {
                (StopPlan::Escape, observed) => match self.write(ESCAPE.to_vec()).await {
                    Ok(()) => {
                        if observed.next.is_some() {
                            tokio::time::sleep(ESCAPE_SETTLE).await;
                        }
                        (Ok(CommandResult::Accepted), observed, false)
                    }
                    Err(error) => (Err(error), observed, false),
                },
                (StopPlan::Idle, _) => rejected(RejectReason::Idle),
            },
            Action::ResumeTurn | Action::SetModel { .. } => rejected(RejectReason::Unavailable),
            Action::Shutdown => {
                let written = self.write(EXIT.to_vec()).await;
                (written.map(|()| CommandResult::Accepted), Observed::default(), true)
            }
        }
    }

    /// Types `text` as one bracketed paste, then Enter.
    async fn type_prompt(&self, text: &str) -> io::Result<()> {
        self.write(paste(text)).await?;
        tokio::time::sleep(PASTE_SETTLE).await;
        self.write(b"\r".to_vec()).await
    }

    async fn write(&self, bytes: Vec<u8>) -> io::Result<()> {
        let terminal = Arc::clone(&self.terminal);
        tokio::task::spawn_blocking(move || {
            axo_pty::process::write_all(terminal.as_raw_fd(), &bytes, WRITE_TIMEOUT)
        })
        .await
        .map_err(io::Error::other)?
    }
}

/// `text` as a bracketed paste. Control characters other than newline and tab are dropped,
/// so that nothing in the text can end the paste early or reach the TUI as a key.
pub fn paste(text: &str) -> Vec<u8> {
    let clean: String = text
        .chars()
        .filter(|character| !character.is_control() || matches!(character, '\n' | '\t'))
        .collect();
    let mut bytes = b"\x1b[200~".to_vec();
    bytes.extend_from_slice(clean.as_bytes());
    bytes.extend_from_slice(b"\x1b[201~");
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_paste_carries_the_text_and_nothing_that_could_end_it() {
        assert_eq!(paste("hi\nthere"), b"\x1b[200~hi\nthere\x1b[201~");
        let sneaky = paste("a\x1b[201~\rrm -rf /\x03");
        assert_eq!(sneaky, b"\x1b[200~a[201~rm -rf /\x1b[201~");
        let mut seed = 0x2545_f491_4f6c_dd1d_u64;
        for _ in 0..2_000 {
            let text: String = (0..(seed % 40))
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    char::from_u32((seed % 0x250) as u32).unwrap_or('x')
                })
                .collect();
            let bytes = paste(&text);
            let inner = &bytes[6..bytes.len() - 6];
            assert!(!inner.contains(&0x1b), "{text:?}");
            assert!(!inner.contains(&b'\r'), "{text:?}");
        }
    }
}
