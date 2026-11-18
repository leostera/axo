//! One OpenCode session as axod follows it (RFD0072, OpenCode): pure state, fed OpenCode's
//! events (`GET /api/event`, `packages/schema/src/session-event.ts` at v2.0.20) and axod's
//! commands, answering what to report and what to ask the server.
//!
//! OpenCode runs a session's work as executions (`session.execution.started` …
//! `succeeded | failed | interrupted`), takes prompts while one runs with `delivery: steer |
//! queue`, and stops one with `interrupt`. Approvals (`permission.asked`) and questions
//! (`form.created`) are the person's, in the TUI; axod only reports that the person is asked.

use std::collections::{HashMap, HashSet};

use axo_protocol::commands::{CommandId, StopTarget};
use serde_json::{Value, json};

use crate::runtime::{QueuedDelivery, RejectReason};
use crate::vocabulary::{
    Emitted, activity, emit, message_end, message_update, pi_state, prompt_end, prompt_start,
    tool_end, tool_start, user_message, whole_message,
};

/// What a prompt becomes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SendPlan {
    /// `POST …/prompt` with this delivery (none starts an execution of an idle session).
    Prompt { delivery: Option<&'static str> },
    /// `POST …/interrupt`, then the prompt.
    InterruptThenPrompt,
    Reject(RejectReason),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StopPlan {
    Interrupt,
    Idle,
}

#[derive(Debug)]
pub struct Session {
    id: String,
    working: bool,
    /// Executions started so far; prompts remember the one they were sent in.
    execution: u64,
    /// Each client prompt and the execution it went to (the next, when queued while idle).
    prompts: HashMap<CommandId, u64>,
    /// What the person is being asked in the TUI, by request id: approvals and questions.
    approvals: HashSet<String>,
    questions: HashSet<String>,
    /// Assistant text being streamed, by message and part.
    texts: HashMap<(String, u64), String>,
    /// Tool names, by call id.
    tools: HashMap<String, String>,
    model: Option<(String, String)>,
}

impl Session {
    pub fn new(id: String, working: bool) -> Self {
        Self {
            id,
            working,
            execution: u64::from(working),
            prompts: HashMap::new(),
            approvals: HashSet::new(),
            questions: HashSet::new(),
            texts: HashMap::new(),
            tools: HashMap::new(),
            model: None,
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn working(&self) -> bool {
        self.working
    }

    pub fn set_model(&mut self, provider: &str, model: &str) {
        self.model = Some((provider.to_owned(), model.to_owned()));
    }

    /// What a client joining now is told.
    pub fn snapshot(&self) -> Vec<Emitted> {
        let mut events = vec![activity(self.working)];
        events.extend(self.state());
        events
    }

    fn state(&self) -> Option<Emitted> {
        let (provider, model) = self.model.as_ref()?;
        Some(pi_state(provider, model, "off"))
    }

    pub fn plan_send(
        &mut self,
        delivery: Option<QueuedDelivery>,
        command_id: Option<&CommandId>,
    ) -> SendPlan {
        let plan = match (self.working, delivery) {
            (false, _) => SendPlan::Prompt { delivery: None },
            (true, None) => return SendPlan::Reject(RejectReason::Busy),
            (true, Some(QueuedDelivery::Steer)) => SendPlan::Prompt {
                delivery: Some("steer"),
            },
            (true, Some(QueuedDelivery::FollowUp)) => SendPlan::Prompt {
                delivery: Some("queue"),
            },
            (true, Some(QueuedDelivery::Interrupt)) => SendPlan::InterruptThenPrompt,
        };
        if let Some(command_id) = command_id {
            // Steered into the running execution; anything else starts or waits for the next.
            let execution = match plan {
                SendPlan::Prompt {
                    delivery: Some("steer"),
                } => self.execution,
                _ => self.execution + 1,
            };
            self.prompts.insert(command_id.clone(), execution);
        }
        plan
    }

    /// A stop ends the running execution only when it names a prompt that went to it, or names
    /// none of axod's (a turn the person started in the TUI); a stop for a prompt whose
    /// execution ended is refused, so it cannot stop newer work.
    pub fn plan_stop(&self, stop: &StopTarget) -> StopPlan {
        if !self.working {
            return StopPlan::Idle;
        }
        let named: Vec<u64> = stop
            .command_ids()
            .iter()
            .filter_map(|command| self.prompts.get(command).copied())
            .collect();
        if named.is_empty() || named.iter().any(|execution| *execution >= self.execution) {
            StopPlan::Interrupt
        } else {
            StopPlan::Idle
        }
    }

    /// What one of OpenCode's events means for Axo; nothing for another session's.
    pub fn observe(&mut self, event: &Value) -> Vec<Emitted> {
        let data = &event["data"];
        let ours = |field: &Value| field.as_str() == Some(self.id.as_str());
        let kind = event["type"].as_str().unwrap_or_default();
        let belongs = match kind {
            "form.created" => ours(&data["form"]["sessionID"]),
            _ => ours(&data["sessionID"]),
        };
        if !belongs {
            return Vec::new();
        }
        match kind {
            "session.execution.started" => {
                self.working = true;
                self.execution += 1;
                vec![emit("agent.start", json!({}))]
            }
            "session.execution.succeeded" | "session.execution.failed" | "session.execution.interrupted" => {
                self.working = false;
                self.texts.clear();
                let mut events = self.end_waits();
                events.push(emit("agent.settled", json!({})));
                events
            }
            "session.inbox.enqueued" if data["item"]["type"] == "user" => {
                let text = data["item"]["payload"]["text"].as_str().unwrap_or_default();
                whole_message(user_message(text)).into()
            }
            "session.text.started" => {
                self.texts.insert(text_key(data), String::new());
                vec![emit(
                    "message.start",
                    json!({ "type": "message_start", "message": crate::vocabulary::assistant_message("") }),
                )]
            }
            "session.text.delta" => {
                let text = self.texts.entry(text_key(data)).or_default();
                text.push_str(data["delta"].as_str().unwrap_or_default());
                vec![message_update(text)]
            }
            "session.text.ended" => {
                self.texts.remove(&text_key(data));
                vec![message_end(data["text"].as_str().unwrap_or_default())]
            }
            "session.tool.input.started" => {
                if let (Some(id), Some(name)) = (data["id"].as_str(), data["name"].as_str()) {
                    self.tools.insert(id.to_owned(), name.to_owned());
                }
                Vec::new()
            }
            "session.tool.called" => {
                let id = data["id"].as_str().unwrap_or_default();
                let name = self.tools.get(id).cloned().unwrap_or_else(|| "tool".to_owned());
                vec![tool_start(id, &name, data["input"].clone())]
            }
            "session.tool.success" | "session.tool.failed" => {
                let id = data["id"].as_str().unwrap_or_default();
                let name = self.tools.remove(id).unwrap_or_else(|| "tool".to_owned());
                let failed = kind == "session.tool.failed";
                let mut output = content_text(&data["content"]);
                if failed && output.is_empty() {
                    output = data["error"]["message"].as_str().unwrap_or_default().to_owned();
                }
                vec![tool_end(id, &name, &output, failed)]
            }
            "permission.asked" => Self::wait(&mut self.approvals, data["id"].as_str(), "approval", true),
            "permission.replied" => {
                Self::wait(&mut self.approvals, data["requestID"].as_str(), "approval", false)
            }
            "form.created" => Self::wait(&mut self.questions, data["form"]["id"].as_str(), "question", true),
            "form.replied" | "form.cancelled" => {
                Self::wait(&mut self.questions, data["id"].as_str(), "question", false)
            }
            "session.renamed" => match data["title"].as_str() {
                Some(title) => vec![emit("session.info", json!({ "name": title }))],
                None => Vec::new(),
            },
            "session.model.selected" => {
                match (data["model"]["providerID"].as_str(), data["model"]["id"].as_str()) {
                    (Some(provider), Some(model)) => {
                        self.set_model(provider, model);
                        self.state().into_iter().collect()
                    }
                    _ => Vec::new(),
                }
            }
            _ => Vec::new(),
        }
    }

    /// One prompt start when the first request of a kind is asked, one end when the last is
    /// answered.
    fn wait(
        waiting: &mut HashSet<String>,
        id: Option<&str>,
        kind: &'static str,
        asked: bool,
    ) -> Vec<Emitted> {
        let Some(id) = id else { return Vec::new() };
        if asked {
            let first = waiting.is_empty();
            if waiting.insert(id.to_owned()) && first {
                return vec![prompt_start(kind)];
            }
        } else if waiting.remove(id) && waiting.is_empty() {
            return vec![prompt_end(kind)];
        }
        Vec::new()
    }

    /// An execution that ended ends what it asked the person.
    fn end_waits(&mut self) -> Vec<Emitted> {
        let mut events = Vec::new();
        if !std::mem::take(&mut self.approvals).is_empty() {
            events.push(prompt_end("approval"));
        }
        if !std::mem::take(&mut self.questions).is_empty() {
            events.push(prompt_end("question"));
        }
        events
    }
}

fn text_key(data: &Value) -> (String, u64) {
    (
        data["assistantMessageID"].as_str().unwrap_or_default().to_owned(),
        data["ordinal"].as_u64().unwrap_or_default(),
    )
}

fn content_text(content: &Value) -> String {
    content
        .as_array()
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// `GET /api/model`'s answer as `pi.models`.
pub fn models_event(answer: &Value) -> Emitted {
    let models: Vec<Value> = answer["data"]
        .as_array()
        .map(|models| {
            models
                .iter()
                .filter_map(|model| {
                    let provider = model["providerID"].as_str()?;
                    let id = model["id"].as_str().or(model["modelID"].as_str())?;
                    let name = model["name"].as_str().unwrap_or(id);
                    Some(json!({ "provider": provider, "id": id, "name": name, "thinkingLevels": ["off"] }))
                })
                .take(300)
                .collect()
        })
        .unwrap_or_default();
    emit("pi.models", json!({ "models": models }))
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
