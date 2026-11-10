//! What a Session's Pi runs, as a person away from the Mac sees and changes it (RFD0033), and
//! what a Pi event changes in its Session.
//!
//! pi-axo publishes `pi.state` (the model and thinking level), `pi.commands` (the slash commands
//! a client's prompt can run) and `pi.models` (the models it could switch to) on its bridge, on
//! start and whenever they change. The Session keeps the latest of each: the state goes into its
//! snapshot, and clients ask for the lists when they open the `/` menu or the model picker. A Pi
//! that exits leaves its last state in place; the next one publishes its own.

use axo_protocol::{PiCommandInfo, PiModelInfo, PiRuntime};
use serde_json::Value;

use crate::session::record::{valid_session_emoji, valid_session_title};

/// More than any Pi lists; pi-axo cuts its lists to these too.
const MAX_COMMANDS: usize = 500;
const MAX_MODELS: usize = 300;

/// What the Session's Pi last said it runs.
#[derive(Default)]
pub(crate) struct PiControls {
    pub(crate) runtime: Option<PiRuntime>,
    pub(crate) commands: Vec<PiCommandInfo>,
    pub(crate) models: Vec<PiModelInfo>,
}

/// One of pi-axo's announcements of what it runs.
pub(crate) enum PiControlEvent {
    State(PiRuntime),
    Commands(Vec<PiCommandInfo>),
    Models(Vec<PiModelInfo>),
}

impl PiControlEvent {
    /// `None` for any other event, or a payload that doesn't parse: it changes nothing.
    pub(crate) fn parse(name: &str, data: &Value) -> Option<Self> {
        match name {
            "pi.state" => serde_json::from_value(data.clone()).ok().map(Self::State),
            "pi.commands" => {
                let mut commands: Vec<PiCommandInfo> =
                    serde_json::from_value(data["commands"].clone()).ok()?;
                commands.truncate(MAX_COMMANDS);
                Some(Self::Commands(commands))
            }
            "pi.models" => {
                let mut models: Vec<PiModelInfo> =
                    serde_json::from_value(data["models"].clone()).ok()?;
                models.truncate(MAX_MODELS);
                Some(Self::Models(models))
            }
            _ => None,
        }
    }

    /// Keeps it; says whether the Session's snapshot changed.
    pub(crate) fn apply(self, controls: &mut PiControls) -> bool {
        match self {
            Self::State(runtime) => {
                let changed = controls.runtime.as_ref() != Some(&runtime);
                controls.runtime = Some(runtime);
                changed
            }
            Self::Commands(commands) => {
                controls.commands = commands;
                false
            }
            Self::Models(models) => {
                controls.models = models;
                false
            }
        }
    }
}

/// What a Pi event changes in its Session, parsed from its name and payload once. Invalid
/// titles and emoji are dropped here, so only valid ones are ever stored. Every Pi event is
/// still forwarded to clients as is; this is only the part axod acts on.
#[derive(Debug, Eq, PartialEq)]
pub(crate) enum PiCatalogEvent<'a> {
    AgentStarted,
    AgentSettled,
    PromptStarted,
    PromptEnded,
    /// A user message started, before Pi emits `agent.start` for its run.
    UserMessageStarted,
    /// A user or assistant message was completed.
    MessageEnded,
    /// Pi reported its current activity when the bridge connected or reconnected.
    ActivitySnapshot {
        working: bool,
    },
    /// Pi named its session (`session.info`).
    Named {
        title: &'a str,
    },
    /// The Axo extension described the session; at least one field is set.
    Described {
        title: Option<&'a str>,
        emoji: Option<&'a str>,
    },
    /// Not a catalog change, or a payload with nothing valid in it.
    Ignored,
}

impl<'a> PiCatalogEvent<'a> {
    pub(crate) fn parse(name: &str, data: &'a Value) -> Self {
        let field =
            |key: &str, valid: fn(&str) -> bool| data[key].as_str().filter(|value| valid(value));
        match name {
            "agent.start" => PiCatalogEvent::AgentStarted,
            "agent.settled" => PiCatalogEvent::AgentSettled,
            "ui.prompt.start" => PiCatalogEvent::PromptStarted,
            "ui.prompt.end" => PiCatalogEvent::PromptEnded,
            "message.start" if data["message"]["role"].as_str() == Some("user") => {
                PiCatalogEvent::UserMessageStarted
            }
            "message.end"
                if matches!(data["message"]["role"].as_str(), Some("user" | "assistant")) =>
            {
                PiCatalogEvent::MessageEnded
            }
            "activity.snapshot" => data["working"]
                .as_bool()
                .map(|working| PiCatalogEvent::ActivitySnapshot { working })
                .unwrap_or(PiCatalogEvent::Ignored),
            "session.info" => match field("name", valid_session_title) {
                Some(title) => PiCatalogEvent::Named { title },
                None => PiCatalogEvent::Ignored,
            },
            "axo.session.metadata" => {
                match (
                    field("title", valid_session_title),
                    field("emoji", valid_session_emoji),
                ) {
                    (None, None) => PiCatalogEvent::Ignored,
                    (title, emoji) => PiCatalogEvent::Described { title, emoji },
                }
            }
            _ => PiCatalogEvent::Ignored,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn pi_events_are_parsed_into_what_they_change() {
        assert_eq!(
            PiCatalogEvent::parse("agent.start", &json!({})),
            PiCatalogEvent::AgentStarted
        );
        assert_eq!(
            PiCatalogEvent::parse("message.start", &json!({ "message": { "role": "user" } })),
            PiCatalogEvent::UserMessageStarted
        );
        assert_eq!(
            PiCatalogEvent::parse(
                "message.start",
                &json!({ "message": { "role": "assistant" } })
            ),
            PiCatalogEvent::Ignored
        );
        assert_eq!(
            PiCatalogEvent::parse("activity.snapshot", &json!({ "working": true })),
            PiCatalogEvent::ActivitySnapshot { working: true }
        );
        assert_eq!(
            PiCatalogEvent::parse("session.info", &json!({ "name": " bad " })),
            PiCatalogEvent::Ignored
        );
        assert_eq!(
            PiCatalogEvent::parse(
                "axo.session.metadata",
                &json!({ "title": "Fix the relay", "emoji": "two words" })
            ),
            PiCatalogEvent::Described {
                title: Some("Fix the relay"),
                emoji: None
            }
        );
    }

    #[test]
    fn controls_keep_the_latest_and_only_the_state_changes_the_snapshot() {
        let mut controls = PiControls::default();
        let commands = PiControlEvent::parse(
            "pi.commands",
            &json!({ "commands": [{ "name": "compact", "description": "Compact", "source": "builtin" }] }),
        );
        if let Some(commands) = commands {
            assert!(!commands.apply(&mut controls));
        }
        assert!(PiControlEvent::parse("pi.models", &json!({ "models": "nope" })).is_none());
        assert!(PiControlEvent::parse("agent.start", &json!({})).is_none());
    }
}
