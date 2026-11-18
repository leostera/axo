//! One Claude Code conversation as axod follows it (RFD0072, Claude Code): pure state, fed
//! the JSON of Claude Code's HTTP hooks and axod's commands, answering what to report and
//! what to type into the TUI.
//!
//! Claude Code reports outward only, through hooks; prompts go in as keystrokes. So a prompt
//! is typed only while Claude is idle, a follow-up waits for `Stop`, steering and interrupting
//! are refused, and a stop is Escape. Claude runs no `Stop` hook for a turn the person
//! interrupts, so axod settles the turn itself when it sends Escape, and on `idle_prompt`.

use std::collections::VecDeque;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::runtime::{QueuedDelivery, RejectReason};
use crate::vocabulary::{
    Emitted, activity, assistant_message, emit, pi_state, prompt_end, prompt_start, tool_end,
    tool_start, user_message, whole_message,
};

/// The most follow-ups held while Claude works.
pub const MAX_HELD: usize = 16;

/// What a prompt becomes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SendPlan {
    /// Type it now.
    Type(String),
    /// Held until the turn ends.
    Held,
    Reject(RejectReason),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StopPlan {
    /// Press Escape; the turn is over.
    Escape,
    Idle,
}

/// What a hook meant.
#[derive(Debug, Default, PartialEq)]
pub struct Observed {
    pub events: Vec<Emitted>,
    /// The conversation's transcript, when a hook named it.
    pub transcript: Option<PathBuf>,
    /// A held prompt to type now.
    pub next: Option<String>,
}

#[derive(Debug)]
pub struct Session {
    id: String,
    working: bool,
    held: VecDeque<String>,
    approval: bool,
    question: bool,
}

impl Session {
    pub fn new(id: String) -> Self {
        Self {
            id,
            working: false,
            held: VecDeque::new(),
            approval: false,
            question: false,
        }
    }

    pub fn working(&self) -> bool {
        self.working
    }

    pub fn snapshot(&self) -> Vec<Emitted> {
        vec![activity(self.working)]
    }

    pub fn plan_send(&mut self, text: String, delivery: Option<QueuedDelivery>) -> SendPlan {
        if !self.working {
            // Typed now; the hook that follows says the turn started.
            self.working = true;
            return SendPlan::Type(text);
        }
        match delivery {
            None => SendPlan::Reject(RejectReason::Busy),
            Some(QueuedDelivery::FollowUp) if self.held.len() < MAX_HELD => {
                self.held.push_back(text);
                SendPlan::Held
            }
            Some(QueuedDelivery::FollowUp) => SendPlan::Reject(RejectReason::Busy),
            // Its terminal takes no input mid-turn that axod can name (Capabilities).
            Some(QueuedDelivery::Steer | QueuedDelivery::Interrupt) => {
                SendPlan::Reject(RejectReason::Unavailable)
            }
        }
    }

    /// A stop is Escape while Claude works. Claude runs no hook for it, so the turn settles
    /// here; follow-ups held for it are kept (agent extension §3.1) and the next is typed.
    pub fn plan_stop(&mut self) -> (StopPlan, Observed) {
        if !self.working {
            return (StopPlan::Idle, Observed::default());
        }
        (StopPlan::Escape, self.settle(None))
    }

    /// The prompt typed for a send failed to reach the terminal.
    pub fn type_failed(&mut self) {
        self.working = false;
    }

    fn settle(&mut self, last_message: Option<&str>) -> Observed {
        let mut events = Vec::new();
        if let Some(text) = last_message.filter(|text| !text.is_empty()) {
            events.extend(whole_message(assistant_message(text)));
        }
        events.extend(self.end_waits());
        let was_working = std::mem::take(&mut self.working);
        if was_working {
            events.push(emit("agent.settled", json!({})));
        }
        let next = self.held.pop_front();
        if next.is_some() {
            self.working = true;
        }
        Observed {
            events,
            transcript: None,
            next,
        }
    }

    fn end_waits(&mut self) -> Vec<Emitted> {
        let mut events = Vec::new();
        if std::mem::take(&mut self.approval) {
            events.push(prompt_end("approval"));
        }
        if std::mem::take(&mut self.question) {
            events.push(prompt_end("question"));
        }
        events
    }

    /// What one hook's JSON means; nothing for another conversation's or a subagent's.
    pub fn observe(&mut self, hook: &Value) -> Observed {
        if hook["session_id"].as_str() != Some(self.id.as_str()) || hook.get("agent_id").is_some() {
            return Observed::default();
        }
        let transcript = hook["transcript_path"]
            .as_str()
            .map(PathBuf::from)
            .filter(|path| path.is_absolute());
        let mut observed = match hook["hook_event_name"].as_str().unwrap_or_default() {
            "SessionStart" => {
                let mut events = Vec::new();
                if let Some(model) = hook["model"].as_str() {
                    events.push(pi_state("anthropic", model, "off"));
                }
                if let Some(title) = hook["session_title"].as_str() {
                    events.push(emit("session.info", json!({ "name": title })));
                }
                Observed::events(events)
            }
            "UserPromptSubmit" => {
                let mut events = self.end_waits();
                events.push(emit("agent.start", json!({})));
                self.working = true;
                let text = hook["prompt"].as_str().unwrap_or_default();
                events.extend(whole_message(user_message(text)));
                Observed::events(events)
            }
            "PreToolUse" => Observed::events(vec![tool_start(
                hook["tool_use_id"].as_str().unwrap_or_default(),
                hook["tool_name"].as_str().unwrap_or("tool"),
                hook["tool_input"].clone(),
            )]),
            "PostToolUse" | "PostToolUseFailure" => {
                let failed = hook["hook_event_name"] == "PostToolUseFailure";
                let output = if failed {
                    hook["error"].as_str().unwrap_or_default().to_owned()
                } else {
                    tool_output(&hook["tool_response"])
                };
                let mut events = self.end_waits();
                events.push(tool_end(
                    hook["tool_use_id"].as_str().unwrap_or_default(),
                    hook["tool_name"].as_str().unwrap_or("tool"),
                    &output,
                    failed,
                ));
                Observed::events(events)
            }
            "PermissionRequest" => self.wait_approval(true),
            "PermissionDenied" => self.wait_approval(false),
            "Notification" => match hook["notification_type"].as_str() {
                Some("elicitation_dialog" | "elicitation_url_dialog") if !self.question => {
                    self.question = true;
                    Observed::events(vec![prompt_start("question")])
                }
                Some("elicitation_complete" | "elicitation_response") if self.question => {
                    self.question = false;
                    Observed::events(vec![prompt_end("question")])
                }
                // Claude finished a while ago: whatever axod missed, it is idle.
                Some("idle_prompt") => self.settle(None),
                _ => Observed::default(),
            },
            "Stop" | "StopFailure" => self.settle(hook["last_assistant_message"].as_str()),
            "PostModelSwitch" => match hook["to_model"].as_str() {
                Some(model) => Observed::events(vec![pi_state("anthropic", model, "off")]),
                None => Observed::default(),
            },
            _ => Observed::default(),
        };
        observed.transcript = transcript;
        observed
    }

    fn wait_approval(&mut self, asked: bool) -> Observed {
        if asked == self.approval {
            return Observed::default();
        }
        self.approval = asked;
        Observed::events(vec![if asked {
            prompt_start("approval")
        } else {
            prompt_end("approval")
        }])
    }
}

impl Observed {
    fn events(events: Vec<Emitted>) -> Self {
        Self {
            events,
            ..Self::default()
        }
    }
}

/// A tool's response as text: a string as is, `{content: [...]}` blocks' text, or the JSON.
fn tool_output(response: &Value) -> String {
    match response {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        _ => {
            let blocks = response["content"].as_array().map(|blocks| {
                blocks
                    .iter()
                    .filter_map(|block| block["text"].as_str())
                    .collect::<Vec<_>>()
                    .join("\n")
            });
            match blocks {
                Some(text) if !text.is_empty() => text,
                _ => response.to_string(),
            }
        }
    }
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
