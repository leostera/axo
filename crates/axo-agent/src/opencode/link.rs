//! axod's link to one private OpenCode server (RFD0072, OpenCode): a future that follows the
//! server's event stream, reports what happens in the Session's OpenCode session as Axo
//! events, keeps the session's export for its transcript, and turns axod's commands into HTTP
//! requests. The TUI in the pane is another client of the same server.

use std::io;
use std::path::PathBuf;
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::Value;

use crate::channel::{Action, LinkRequests, Request, ServerProcess};
use crate::opencode::client::{Client, EventBytes, ServerAddress};
use crate::opencode::session::{SendPlan, Session, StopPlan, models_event};
use crate::opencode::sse::EventStream;
use crate::runtime::{AgentEvent, CommandResult, RejectReason};
use crate::vocabulary::{Emitted, text_with_attachments};

/// Waits between tries while the server is not listening yet, doubling up to the last.
const RETRY_FIRST: Duration = Duration::from_millis(50);
const RETRY_LAST: Duration = Duration::from_secs(1);
/// How long the link tries to reach a server that never listens.
const CONNECT_DEADLINE: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub struct LinkConfig {
    pub address: ServerAddress,
    /// The Session's OpenCode session, made by [`create_session`] when the Session was new.
    pub session_id: String,
    /// The Session's folder, where OpenCode lists models.
    pub directory: PathBuf,
    /// Where the link keeps the session's export: the conversation axod converts to the
    /// Session's transcript.
    pub conversation: PathBuf,
    /// Prefix for log lines, e.g. `session_id=… shell_id=2`.
    pub log_context: String,
}

enum Outcome {
    /// The event stream ended; connect again.
    Closed,
    /// The Session let the link go, or asked it to shut the server down.
    Ended,
    /// The server has no such session, or broke the protocol.
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
    let client = match Client::new(config.address.clone()) {
        Ok(client) => client,
        Err(error) => {
            log::warn!("event=opencode.client_failed {context} reason={error}");
            return;
        }
    };
    let mut streams = 0_u64;
    loop {
        let Some(events) = connect(&client, &mut requests).await else {
            log::warn!("event=opencode.unreachable {context}");
            return;
        };
        streams += 1;
        let stream_id = axo_protocol::new_uuid_v4()
            .unwrap_or_else(|_| format!("00000000-0000-4000-8000-{streams:012x}"));
        let mut link = Link {
            client: &client,
            config: &config,
            stream_id,
            sequence: 0,
            conversation_reported: false,
        };
        match link.follow(events, &mut requests, &mut report).await {
            Outcome::Closed => {
                if !report(AgentEvent::Disconnected) {
                    return;
                }
            }
            Outcome::Ended | Outcome::Failed => return,
        }
    }
}

/// Starts a session for a new Axo Session in `directory`, named `title`, once the server
/// listens; its id.
pub async fn create_session(
    address: &ServerAddress,
    directory: &std::path::Path,
    title: &str,
) -> io::Result<String> {
    let client = Client::new(address.clone())?;
    wait_for(&client).await?;
    client.create_session(directory, title).await
}

/// Returns once the server answers.
pub async fn wait_until_listening(address: &ServerAddress) -> io::Result<()> {
    wait_for(&Client::new(address.clone())?).await
}

async fn wait_for(client: &Client) -> io::Result<()> {
    let deadline = tokio::time::Instant::now() + CONNECT_DEADLINE;
    let mut retry = RETRY_FIRST;
    loop {
        match client.info().await {
            Ok(_) => return Ok(()),
            Err(error) if tokio::time::Instant::now() >= deadline => {
                return Err(io::Error::new(
                    io::ErrorKind::NotConnected,
                    format!("OpenCode's server is not listening: {error}"),
                ));
            }
            Err(_) => {}
        }
        tokio::time::sleep(retry).await;
        retry = (retry * 2).min(RETRY_LAST);
    }
}

/// Subscribes to the event stream, trying again while the server starts, refusing the
/// commands that arrive meanwhile.
async fn connect(client: &Client, requests: &mut LinkRequests) -> Option<EventBytes> {
    while let Ok(Request { reply, .. }) = requests.0.try_recv() {
        let _ = reply.send(Err(not_connected()));
    }
    let subscribing = async {
        let deadline = tokio::time::Instant::now() + CONNECT_DEADLINE;
        let mut retry = RETRY_FIRST;
        loop {
            if let Ok(events) = client.events().await {
                return Some(events);
            }
            if tokio::time::Instant::now() >= deadline {
                return None;
            }
            tokio::time::sleep(retry).await;
            retry = (retry * 2).min(RETRY_LAST);
        }
    };
    tokio::pin!(subscribing);
    loop {
        tokio::select! {
            events = &mut subscribing => return events,
            request = requests.0.recv() => match request {
                Some(Request { reply, .. }) => { let _ = reply.send(Err(not_connected())); }
                None => return None,
            },
        }
    }
}

fn not_connected() -> io::Error {
    io::Error::new(io::ErrorKind::NotConnected, "OpenCode is not connected")
}

struct Link<'a> {
    client: &'a Client,
    config: &'a LinkConfig,
    stream_id: String,
    sequence: u64,
    conversation_reported: bool,
}

impl Link<'_> {
    async fn follow(
        &mut self,
        mut events: EventBytes,
        requests: &mut LinkRequests,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> Outcome {
        let context = &self.config.log_context;
        let id = self.config.session_id.as_str();
        // Read after subscribing, so that nothing in between is missed.
        let info = match self.client.session(id).await {
            Ok(info) if info["id"] == id => info,
            Ok(_) => {
                log::warn!("event=opencode.binding_rejected {context} reason=session_mismatch");
                return Outcome::Failed;
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                log::warn!("event=opencode.binding_rejected {context} reason=no_such_session");
                return Outcome::Failed;
            }
            Err(error) => {
                log::warn!("event=opencode.binding_failed {context} reason={error}");
                return Outcome::Closed;
            }
        };
        let working = self.client.is_active(id).await.unwrap_or(false);
        let mut session = Session::new(id.to_owned(), working);
        if let (Some(provider), Some(model)) =
            (info["model"]["providerID"].as_str(), info["model"]["id"].as_str())
        {
            session.set_model(provider, model);
        }
        log::info!("event=opencode.session_bound {context} opencode_session={id}");
        if !report(AgentEvent::Bound {
            agent_session_id: id.to_owned(),
        }) {
            return Outcome::Ended;
        }
        if !self.export(report).await || !self.report_all(session.snapshot(), report) {
            return Outcome::Ended;
        }
        if let Ok(models) = self.client.models(&self.config.directory).await
            && !self.report_all(vec![models_event(&models)], report)
        {
            return Outcome::Ended;
        }
        let mut parser = EventStream::default();
        loop {
            tokio::select! {
                chunk = events.next() => {
                    let Some(Ok(bytes)) = chunk else { return Outcome::Closed };
                    for event in parser.push(&bytes) {
                        let emitted = session.observe(&event);
                        // The transcript is current before clients hear the work settled.
                        if emitted.iter().any(|event| event.name == "agent.settled") && !self.export(report).await {
                            return Outcome::Ended;
                        }
                        if !self.report_all(emitted, report) {
                            return Outcome::Ended;
                        }
                    }
                }
                request = requests.0.recv() => {
                    let Some(Request { action, reply }) = request else { return Outcome::Ended };
                    if let Some(outcome) = self.command(action, reply, &mut session).await {
                        return outcome;
                    }
                }
            }
        }
    }

    fn report_all(
        &mut self,
        events: Vec<Emitted>,
        report: &mut (impl FnMut(AgentEvent) -> bool + Send),
    ) -> bool {
        events.into_iter().all(|event| {
            self.sequence += 1;
            report(AgentEvent::Event {
                agent_session_id: self.config.session_id.clone(),
                stream_id: self.stream_id.clone(),
                sequence: self.sequence,
                name: event.name.to_owned(),
                data: event.data,
            })
        })
    }

    /// Saves the session's export where the conversation is kept, and says where the first
    /// time. A failed export is logged and skipped: the transcript catches up at the next.
    async fn export(&mut self, report: &mut (impl FnMut(AgentEvent) -> bool + Send)) -> bool {
        let context = &self.config.log_context;
        let saved = match self.client.export(&self.config.session_id).await {
            Ok(Value::Null) => return true,
            Ok(export) => save(&self.config.conversation, &export).await,
            Err(error) => Err(error),
        };
        match saved {
            Ok(()) if !self.conversation_reported => {
                self.conversation_reported = true;
                report(AgentEvent::Conversation {
                    file: self.config.conversation.clone(),
                })
            }
            Ok(()) => true,
            Err(error) => {
                log::warn!("event=opencode.export_failed {context} reason={error}");
                true
            }
        }
    }

    /// Carries out one command; `Some` when the connection must end.
    async fn command(
        &mut self,
        action: Action,
        reply: tokio::sync::oneshot::Sender<io::Result<CommandResult>>,
        session: &mut Session,
    ) -> Option<Outcome> {
        let id = self.config.session_id.as_str();
        let answer = match action {
            Action::Send {
                text,
                delivery,
                command_id,
                attachments,
            } => {
                let text = text_with_attachments(&text, &attachments);
                match session.plan_send(delivery, command_id.as_ref()) {
                    SendPlan::Prompt { delivery } => self.prompt(&text, delivery).await,
                    SendPlan::InterruptThenPrompt => match self.client.interrupt(id).await {
                        Ok(_) => self.prompt(&text, Some("queue")).await,
                        Err(error) => Err(error),
                    },
                    SendPlan::Reject(reason) => Ok(CommandResult::Rejected(reason)),
                }
            }
            Action::Stop(stop) => match session.plan_stop(&stop) {
                StopPlan::Interrupt => self.client.interrupt(id).await.map(|interrupted| {
                    if interrupted {
                        CommandResult::Accepted
                    } else {
                        CommandResult::Rejected(RejectReason::Idle)
                    }
                }),
                StopPlan::Idle => Ok(CommandResult::Rejected(RejectReason::Idle)),
            },
            // OpenCode has no message-free continuation axod can name (RFD0058 asks for an
            // explicit refusal).
            Action::ResumeTurn => Ok(CommandResult::Rejected(RejectReason::Unavailable)),
            Action::Shutdown => {
                let _ = reply.send(Ok(CommandResult::Accepted));
                return Some(Outcome::Ended);
            }
            Action::SetModel {
                model,
                thinking_level,
            } => {
                // OpenCode picks reasoning by model variant; Axo offers only "off".
                if thinking_level.as_deref().is_some_and(|level| level != "off") {
                    Ok(CommandResult::Rejected(RejectReason::Invalid))
                } else if let Some((provider, model)) = model {
                    match self.client.select_model(id, &provider, &model).await {
                        Ok(()) => Ok(CommandResult::Accepted),
                        Err(error) => {
                            log::warn!(
                                "event=opencode.model_refused {} reason={error}",
                                self.config.log_context
                            );
                            Ok(CommandResult::Rejected(RejectReason::Invalid))
                        }
                    }
                } else {
                    Ok(CommandResult::Accepted)
                }
            }
        };
        let _ = reply.send(answer);
        None
    }

    async fn prompt(&self, text: &str, delivery: Option<&str>) -> io::Result<CommandResult> {
        match self.client.prompt(&self.config.session_id, text, delivery).await {
            Ok(_) => Ok(CommandResult::Accepted),
            Err(error) => {
                log::warn!(
                    "event=opencode.prompt_refused {} reason={error}",
                    self.config.log_context
                );
                Ok(CommandResult::Rejected(RejectReason::Unavailable))
            }
        }
    }
}

/// Writes `export` to `file` through a temporary file and a rename, only when it changed.
async fn save(file: &std::path::Path, export: &Value) -> io::Result<()> {
    let text = serde_json::to_string(export).map_err(io::Error::other)?;
    let file = file.to_owned();
    tokio::task::spawn_blocking(move || crate::transcript::write_if_changed(&file, &text).map(drop))
        .await
        .map_err(io::Error::other)?
}

#[cfg(test)]
#[path = "link_tests.rs"]
mod tests;
