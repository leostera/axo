//! One Codex thread as axod follows it: a state machine fed the app-server's notifications,
//! which says what each means in Axo's event vocabulary, and decides how each of axod's commands
//! becomes Codex requests (RFD0072, Codex).
//!
//! It does no I/O. The link feeds it what the server says and sends what it decides, so every
//! rule here is tested without a server.
//!
//! Invariants:
//! - A turn is active from the moment axod asks for one (or the server says one started) until
//!   the server says it completed. While one is active, a prompt never starts another.
//! - Follow-ups wait in order, and the first waiting one starts the next turn when the active one
//!   completes, however it completed. A stop does not drop them.
//! - A stop interrupts only the active turn, and only if the client saw it: one of its command
//!   ids started or joined that turn, or the entry it names is that turn or one of its items.

use std::collections::{HashSet, VecDeque};

use axo_protocol::asset::FetchedAttachment;
use axo_protocol::commands::{CommandId, StopTarget};
use serde_json::{Value, json};

use crate::runtime::{QueuedDelivery, RejectReason};

/// PNG, JPEG, GIF and WebP up to this size go to Codex as images (as pi-axo does for Pi).
const MAX_INLINE_IMAGE_BYTES: u64 = 5 * 1024 * 1024;
const MODEL_IMAGES: [&str; 4] = ["image/png", "image/jpeg", "image/gif", "image/webp"];

pub use crate::vocabulary::Emitted;
use crate::vocabulary::{emit, format_size};

/// A `turn/start` to send: the input, and the id of the client prompt that asked for it.
#[derive(Clone, Debug, PartialEq)]
pub struct TurnRequest {
    pub input: Vec<Value>,
    pub command_id: Option<CommandId>,
}

impl TurnRequest {
    pub fn new(
        text: &str,
        attachments: &[FetchedAttachment],
        command_id: Option<&CommandId>,
    ) -> Self {
        Self {
            input: user_input(text, attachments),
            command_id: command_id.cloned(),
        }
    }
}

/// What a prompt becomes.
#[derive(Clone, Debug, PartialEq)]
pub enum SendPlan {
    /// Send `turn/start` now.
    Start(TurnRequest),
    /// Send `turn/steer` into the active turn.
    Steer {
        turn_id: String,
        request: TurnRequest,
    },
    /// Held; starts a turn when the active one completes.
    Held,
    /// Send `turn/interrupt`; the prompt is held first in line.
    Interrupt { turn_id: String },
    Reject(RejectReason),
}

/// What a stop becomes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StopPlan {
    Interrupt { turn_id: String },
    /// Nothing the client saw is running.
    Idle,
}

/// The model and reasoning effort the next turn runs with.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ModelChoice {
    pub model: Option<String>,
    pub effort: Option<String>,
}

#[derive(Debug, Default)]
struct ActiveTurn {
    /// `None` between axod's `turn/start` and the server naming the turn.
    id: Option<String>,
    command_ids: Vec<CommandId>,
    item_ids: HashSet<String>,
}

#[derive(Debug, Default, Clone, Copy, Eq, PartialEq)]
struct Waiting {
    approval: bool,
    user_input: bool,
}

impl Waiting {
    fn any(self) -> bool {
        self.approval || self.user_input
    }
}

/// A thread, as far as axod needs to know it.
#[derive(Debug)]
pub struct Thread {
    id: String,
    active: Option<ActiveTurn>,
    waiting: Waiting,
    held: VecDeque<TurnRequest>,
    choice: ModelChoice,
    /// The model and provider Codex last said the thread runs, for `pi.state`.
    running_model: Option<(String, String)>,
    /// Each agent message being written, as written so far.
    replies: Vec<(String, String)>,
}

impl Thread {
    /// A thread just started or resumed; `working` is whether a turn is running in it now.
    pub fn new(id: String, running_turn: Option<String>) -> Self {
        Self {
            id,
            active: running_turn.map(|turn| ActiveTurn {
                id: Some(turn),
                ..ActiveTurn::default()
            }),
            waiting: Waiting::default(),
            held: VecDeque::new(),
            choice: ModelChoice::default(),
            running_model: None,
            replies: Vec::new(),
        }
    }

    /// A thread rejoined after a reconnect: a running turn is known to run, but not by name
    /// until the server names the next one.
    pub fn resumed(id: String, working: bool) -> Self {
        let mut thread = Self::new(id, None);
        if working {
            thread.active = Some(ActiveTurn::default());
        }
        thread
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn working(&self) -> bool {
        self.active.is_some()
    }

    pub fn choice(&self) -> &ModelChoice {
        &self.choice
    }

    /// What the Session hears when axod binds: whether the thread is working, and what it runs.
    pub fn snapshot(&self) -> Vec<Emitted> {
        let mut events = vec![emit(
            "activity.snapshot",
            json!({ "working": self.working() }),
        )];
        events.extend(self.state_event());
        events
    }

    /// Records the model and provider the thread runs (from `thread/start` or `thread/resume`).
    pub fn set_running_model(&mut self, provider: &str, model: &str, effort: Option<&str>) {
        self.running_model = Some((provider.to_owned(), model.to_owned()));
        if self.choice.effort.is_none() {
            self.choice.effort = effort.map(str::to_owned);
        }
    }

    /// Chooses the model, the effort, or both, for the next turn. Announces the change.
    pub fn choose(&mut self, model: Option<&str>, effort: Option<&str>) -> Vec<Emitted> {
        if let Some(model) = model {
            self.choice.model = Some(model.to_owned());
            if let Some((provider, _)) = &self.running_model {
                self.running_model = Some((provider.clone(), model.to_owned()));
            }
        }
        if let Some(effort) = effort {
            self.choice.effort = Some(effort.to_owned());
        }
        self.state_event().into_iter().collect()
    }

    fn state_event(&self) -> Option<Emitted> {
        let (provider, model) = self.running_model.as_ref()?;
        Some(emit(
            "pi.state",
            json!({
                "model": { "provider": provider, "id": model, "name": model },
                "thinkingLevel": thinking_level(self.choice.effort.as_deref()),
            }),
        ))
    }

    /// Decides what a prompt becomes, and holds it if it waits.
    pub fn plan_send(&mut self, request: TurnRequest, delivery: Option<QueuedDelivery>) -> SendPlan {
        let Some(active) = &mut self.active else {
            self.active = Some(ActiveTurn {
                id: None,
                command_ids: request.command_id.iter().cloned().collect(),
                item_ids: HashSet::new(),
            });
            return SendPlan::Start(request);
        };
        match delivery {
            None => SendPlan::Reject(RejectReason::Busy),
            Some(QueuedDelivery::FollowUp) => {
                self.held.push_back(request);
                SendPlan::Held
            }
            // The turn is not named yet: there is nothing to steer into or interrupt.
            Some(QueuedDelivery::Steer | QueuedDelivery::Interrupt) if active.id.is_none() => {
                SendPlan::Reject(RejectReason::Busy)
            }
            Some(QueuedDelivery::Steer) => {
                let turn_id = active.id.clone().expect("checked above");
                active.command_ids.extend(request.command_id.iter().cloned());
                SendPlan::Steer { turn_id, request }
            }
            Some(QueuedDelivery::Interrupt) => {
                let turn_id = active.id.clone().expect("checked above");
                self.held.push_front(request);
                SendPlan::Interrupt { turn_id }
            }
        }
    }

    /// A `turn/start` axod sent failed: no turn is active after all, unless the server named one.
    pub fn start_failed(&mut self) {
        if self.active.as_ref().is_some_and(|active| active.id.is_none()) {
            self.active = None;
        }
    }

    /// The server answered axod's `turn/start` with the turn it started.
    pub fn started(&mut self, turn_id: &str) {
        if let Some(active) = &mut self.active
            && active.id.is_none()
        {
            active.id = Some(turn_id.to_owned());
        }
    }

    /// Whether a stop names the active turn, and so what it becomes.
    pub fn plan_stop(&self, stop: &StopTarget) -> StopPlan {
        let Some(active) = &self.active else {
            return StopPlan::Idle;
        };
        let Some(turn_id) = &active.id else {
            return StopPlan::Idle;
        };
        let by_command = stop
            .command_ids()
            .iter()
            .any(|command| active.command_ids.contains(command));
        let names_it = |entry: Option<&axo_protocol::commands::EntryId>| {
            entry.is_some_and(|entry| {
                entry.as_str() == turn_id || active.item_ids.contains(entry.as_str())
            })
        };
        if by_command || names_it(stop.turn_id()) || names_it(stop.seen()) {
            StopPlan::Interrupt {
                turn_id: turn_id.clone(),
            }
        } else {
            StopPlan::Idle
        }
    }

    /// Applies one notification. Returns what it means for the Session, and the turn to start
    /// next if it ended one and a prompt was waiting.
    pub fn observe(&mut self, method: &str, params: &Value) -> Observed {
        if params["threadId"].as_str().is_some_and(|thread| thread != self.id) {
            return Observed::default();
        }
        match method {
            "turn/started" => self.turn_started(params),
            "turn/completed" => self.turn_completed(),
            "thread/status/changed" => self.status_changed(&params["status"]),
            "item/started" => self.item_started(params),
            "item/completed" => self.item_completed(params),
            "item/agentMessage/delta" => self.reply_delta(params),
            "thread/name/updated" => match params["threadName"].as_str() {
                Some(name) => Observed::events(vec![emit("session.info", json!({ "name": name }))]),
                None => Observed::default(),
            },
            _ => Observed::default(),
        }
    }

    fn turn_started(&mut self, params: &Value) -> Observed {
        let turn_id = params["turn"]["id"].as_str().map(str::to_owned);
        match &mut self.active {
            Some(active) if active.id.is_none() || active.id == turn_id => {
                active.id = turn_id;
            }
            // A turn axod did not ask for: the person typed in the TUI.
            _ => {
                self.active = Some(ActiveTurn {
                    id: turn_id,
                    ..ActiveTurn::default()
                });
            }
        }
        Observed::events(vec![emit("agent.start", json!({}))])
    }

    fn turn_completed(&mut self) -> Observed {
        self.active = None;
        self.replies.clear();
        let mut events = self.set_waiting(Waiting::default());
        events.push(emit("agent.settled", json!({})));
        let next = self.held.pop_front();
        if let Some(request) = &next {
            self.active = Some(ActiveTurn {
                id: None,
                command_ids: request.command_id.iter().cloned().collect(),
                item_ids: HashSet::new(),
            });
        }
        Observed { events, next }
    }

    fn status_changed(&mut self, status: &Value) -> Observed {
        let waiting = match status["type"].as_str() {
            Some("active") => {
                let flags = status["activeFlags"].as_array();
                let has = |flag: &str| {
                    flags.is_some_and(|flags| flags.iter().any(|item| item.as_str() == Some(flag)))
                };
                Waiting {
                    approval: has("waitingOnApproval"),
                    user_input: has("waitingOnUserInput"),
                }
            }
            _ => Waiting::default(),
        };
        Observed::events(self.set_waiting(waiting))
    }

    /// `ui.prompt.start` when the thread starts waiting on the person, `ui.prompt.end` when it
    /// stops; one of each per wait, whatever it waits on.
    fn set_waiting(&mut self, waiting: Waiting) -> Vec<Emitted> {
        let was = std::mem::replace(&mut self.waiting, waiting);
        match (was.any(), waiting.any()) {
            (false, true) => vec![emit(
                "ui.prompt.start",
                json!({ "kind": if waiting.approval { "approval" } else { "input" } }),
            )],
            (true, false) => vec![emit(
                "ui.prompt.end",
                json!({ "kind": if was.approval { "approval" } else { "input" } }),
            )],
            _ => Vec::new(),
        }
    }

    fn note_item(&mut self, item: &Value) {
        if let (Some(active), Some(id)) = (&mut self.active, item["id"].as_str()) {
            active.item_ids.insert(id.to_owned());
        }
    }

    fn item_started(&mut self, params: &Value) -> Observed {
        let item = &params["item"];
        self.note_item(item);
        match item["type"].as_str() {
            Some("userMessage") => {
                if let (Some(active), Some(client)) = (&mut self.active, item["clientId"].as_str())
                    && let Ok(command) = CommandId::try_from(client.to_owned())
                    && !active.command_ids.contains(&command)
                {
                    active.command_ids.push(command);
                }
                Observed::events(vec![emit(
                    "message.start",
                    json!({ "type": "message_start", "message": user_message(item) }),
                )])
            }
            Some(kind) => match tool_start(kind, item) {
                Some(data) => Observed::events(vec![emit("tool.start", data)]),
                None => Observed::default(),
            },
            None => Observed::default(),
        }
    }

    fn item_completed(&mut self, params: &Value) -> Observed {
        let item = &params["item"];
        self.note_item(item);
        let message = match item["type"].as_str() {
            Some("userMessage") => user_message(item),
            Some("agentMessage") => {
                if let Some(id) = item["id"].as_str() {
                    self.replies.retain(|(reply, _)| reply != id);
                }
                assistant_message(item["text"].as_str().unwrap_or_default())
            }
            Some(kind) => {
                return match tool_end(kind, item) {
                    Some(data) => Observed::events(vec![emit("tool.end", data)]),
                    None => Observed::default(),
                };
            }
            None => return Observed::default(),
        };
        Observed::events(vec![emit(
            "message.end",
            json!({ "type": "message_end", "message": message }),
        )])
    }

    fn reply_delta(&mut self, params: &Value) -> Observed {
        let (Some(item), Some(delta)) = (params["itemId"].as_str(), params["delta"].as_str())
        else {
            return Observed::default();
        };
        let text = match self.replies.iter_mut().find(|(reply, _)| reply == item) {
            Some((_, text)) => {
                text.push_str(delta);
                text.clone()
            }
            None => {
                self.replies.push((item.to_owned(), delta.to_owned()));
                delta.to_owned()
            }
        };
        Observed::events(vec![emit(
            "message.update",
            json!({ "type": "message_update", "message": assistant_message(&text) }),
        )])
    }
}

/// What a notification meant.
#[derive(Debug, Default, PartialEq)]
pub struct Observed {
    pub events: Vec<Emitted>,
    /// A held prompt that now starts its turn.
    pub next: Option<TurnRequest>,
}

impl Observed {
    fn events(events: Vec<Emitted>) -> Self {
        Self { events, next: None }
    }
}

/// Axo's thinking level for a Codex reasoning effort.
fn thinking_level(effort: Option<&str>) -> &'static str {
    match effort {
        Some("minimal") => "minimal",
        Some("low") => "low",
        Some("medium") => "medium",
        Some("high") => "high",
        Some("xhigh") => "xhigh",
        _ => "off",
    }
}

/// Codex's reasoning effort for an Axo thinking level; `None` for one Codex has no name for.
pub fn reasoning_effort(thinking_level: &str) -> Option<&'static str> {
    match thinking_level {
        "off" => Some("none"),
        "minimal" => Some("minimal"),
        "low" => Some("low"),
        "medium" => Some("medium"),
        "high" => Some("high"),
        "xhigh" => Some("xhigh"),
        _ => None,
    }
}

/// A message in the shape Pi's bridge events carry, which every client reads.
fn assistant_message(text: &str) -> Value {
    json!({ "role": "assistant", "content": [{ "type": "text", "text": text }] })
}

fn user_message(item: &Value) -> Value {
    let text = item["content"]
        .as_array()
        .map(|inputs| {
            inputs
                .iter()
                .filter_map(|input| input["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default();
    json!({ "role": "user", "content": [{ "type": "text", "text": text }] })
}

fn tool_name(kind: &str, item: &Value) -> Option<String> {
    match kind {
        "commandExecution" => Some("bash".to_owned()),
        "fileChange" => Some("edit".to_owned()),
        "mcpToolCall" => Some(format!(
            "{}.{}",
            item["server"].as_str().unwrap_or("mcp"),
            item["tool"].as_str().unwrap_or("tool")
        )),
        "webSearch" => Some("web_search".to_owned()),
        _ => None,
    }
}

fn tool_arguments(kind: &str, item: &Value) -> Value {
    match kind {
        "commandExecution" => json!({ "command": item["command"] }),
        "fileChange" => json!({
            "paths": item["changes"].as_array().map(|changes| {
                changes.iter().map(|change| change["path"].clone()).collect::<Vec<_>>()
            })
        }),
        "mcpToolCall" => item["arguments"].clone(),
        _ => Value::Null,
    }
}

fn tool_start(kind: &str, item: &Value) -> Option<Value> {
    let name = tool_name(kind, item)?;
    Some(json!({
        "toolCallId": item["id"],
        "toolName": name,
        "args": tool_arguments(kind, item),
    }))
}

fn tool_end(kind: &str, item: &Value) -> Option<Value> {
    let name = tool_name(kind, item)?;
    let (output, failed) = match kind {
        "commandExecution" => (
            item["aggregatedOutput"].as_str().unwrap_or_default().to_owned(),
            item["exitCode"].as_i64().is_some_and(|code| code != 0),
        ),
        "mcpToolCall" => (
            item["result"].to_string(),
            !item["error"].is_null(),
        ),
        _ => (String::new(), item["status"].as_str() == Some("failed")),
    };
    Some(json!({
        "toolCallId": item["id"],
        "toolName": name,
        "result": { "content": [{ "type": "text", "text": output }] },
        "isError": failed,
    }))
}

/// A prompt as Codex takes it: the words, a line for each file naming where axod saved it, and
/// each image Codex can see, by its path.
fn user_input(text: &str, attachments: &[FetchedAttachment]) -> Vec<Value> {
    let mut lines = Vec::new();
    let mut images = Vec::new();
    for attachment in attachments {
        let path = attachment.path.to_string_lossy();
        let mime = attachment.mime_type.as_str();
        if MODEL_IMAGES.contains(&mime) && attachment.size <= MAX_INLINE_IMAGE_BYTES {
            lines.push(format!(
                "[Attached image: {} at {path} axo-asset:{}]",
                attachment.name.as_str(),
                attachment.asset
            ));
            images.push(json!({ "type": "localImage", "path": path }));
        } else {
            lines.push(format!(
                "[Attached file: {} ({mime}, {}) at {path} axo-asset:{}]",
                attachment.name.as_str(),
                format_size(attachment.size),
                attachment.asset
            ));
        }
    }
    let body = std::iter::once(text.to_owned())
        .chain(lines)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");
    let mut input = vec![json!({ "type": "text", "text": body, "text_elements": [] })];
    input.extend(images);
    input
}

/// A size as people read it, as pi-axo writes it.

#[cfg(test)]
#[path = "thread_tests.rs"]
mod tests;
