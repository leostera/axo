//! Which coding agent a Session runs, and what each can do (RFD0072).
//!
//! A Session picks its kind when it is created and keeps it: a conversation belongs to the agent
//! that wrote it. Each kind declares its capabilities here, statically, so axod refuses what an
//! agent cannot do before reaching it and clients offer only what it can.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A coding agent Axo can run, named as ATXF's `source.agent` names it. Pi when unsaid: every
/// Session before RFD0072 runs Pi.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
pub enum AgentKind {
    #[default]
    Pi,
    Codex,
    OpenCode,
    ClaudeCode,
}

impl AgentKind {
    pub const ALL: [AgentKind; 4] = [
        AgentKind::Pi,
        AgentKind::Codex,
        AgentKind::OpenCode,
        AgentKind::ClaudeCode,
    ];

    /// For `skip_serializing_if`: Pi is what an unsaid agent means.
    pub fn is_pi(&self) -> bool {
        *self == AgentKind::Pi
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            AgentKind::Pi => "pi",
            AgentKind::Codex => "codex",
            AgentKind::OpenCode => "opencode",
            AgentKind::ClaudeCode => "claude-code",
        }
    }

    /// What this kind of agent can do, as its adapter drives it.
    pub const fn capabilities(self) -> Capabilities {
        match self {
            AgentKind::Pi => Capabilities {
                deliveries: Deliveries {
                    steer: true,
                    follow_up: true,
                    interrupt: true,
                },
                stop: true,
                // pi-axo refuses it on a Pi SDK without the operation (RFD0058).
                resume_turn: true,
                models: true,
                thinking_levels: true,
                images: true,
                slash_commands: true,
                streaming: true,
            },
            AgentKind::Codex => Capabilities {
                deliveries: Deliveries {
                    steer: true,
                    follow_up: true,
                    interrupt: true,
                },
                stop: true,
                resume_turn: false,
                models: true,
                thinking_levels: true,
                images: true,
                slash_commands: false,
                streaming: true,
            },
            AgentKind::OpenCode => Capabilities {
                deliveries: Deliveries {
                    steer: true,
                    follow_up: true,
                    interrupt: true,
                },
                stop: true,
                resume_turn: false,
                models: true,
                thinking_levels: false,
                images: true,
                slash_commands: false,
                streaming: true,
            },
            // Prompts are typed into its terminal: no steering, no model switch from a client.
            AgentKind::ClaudeCode => Capabilities {
                deliveries: Deliveries {
                    steer: false,
                    follow_up: true,
                    interrupt: false,
                },
                stop: true,
                resume_turn: false,
                models: false,
                thinking_levels: false,
                images: false,
                slash_commands: false,
                streaming: false,
            },
        }
    }
}

impl fmt::Display for AgentKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// A name that is not one of [`AgentKind::ALL`].
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnknownAgent(pub String);

impl fmt::Display for UnknownAgent {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "unknown agent {:?}: expected pi, codex, opencode or claude-code",
            self.0
        )
    }
}

impl std::error::Error for UnknownAgent {}

impl FromStr for AgentKind {
    type Err = UnknownAgent;

    fn from_str(name: &str) -> Result<Self, UnknownAgent> {
        AgentKind::ALL
            .into_iter()
            .find(|kind| kind.as_str() == name)
            .ok_or_else(|| UnknownAgent(name.to_owned()))
    }
}

impl Serialize for AgentKind {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for AgentKind {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let name = String::deserialize(deserializer)?;
        name.parse().map_err(serde::de::Error::custom)
    }
}

/// What an agent can do. Declared per kind; never discovered from a running agent.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    /// How a working agent can take a prompt. Every agent takes one when it is idle.
    pub deliveries: Deliveries,
    /// Stops the running turn.
    pub stop: bool,
    /// Continues interrupted work without a message (RFD0058).
    pub resume_turn: bool,
    /// Lists its models and switches between them.
    pub models: bool,
    /// Has thinking levels (reasoning effort) to choose from.
    pub thinking_levels: bool,
    /// Takes images as input, rather than paths to them.
    pub images: bool,
    /// Lists slash commands a client's prompt may run.
    pub slash_commands: bool,
    /// Reports replies and tool output as they are written.
    pub streaming: bool,
}

/// The deliveries a working agent takes, beside a new turn when it is idle.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Deliveries {
    /// Added to the running turn.
    pub steer: bool,
    /// Held until the running turn ends, then a turn of its own.
    pub follow_up: bool,
    /// Stops the running turn and starts one with it.
    pub interrupt: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_is_named_as_atxf_names_it_and_parses_back() {
        let names: Vec<_> = AgentKind::ALL.iter().map(|kind| kind.as_str()).collect();
        assert_eq!(names, ["pi", "codex", "opencode", "claude-code"]);
        for kind in AgentKind::ALL {
            assert_eq!(kind.as_str().parse::<AgentKind>(), Ok(kind));
            let json = serde_json::to_value(kind).unwrap();
            assert_eq!(serde_json::from_value::<AgentKind>(json).unwrap(), kind);
        }
        for name in ["", "Pi", "claude", "claude_code", "gemini"] {
            assert!(name.parse::<AgentKind>().is_err(), "{name}");
        }
        assert!(serde_json::from_value::<AgentKind>(serde_json::json!("nope")).is_err());
    }

    #[test]
    fn pi_keeps_every_capability_it_has_today() {
        let pi = AgentKind::Pi.capabilities();
        assert_eq!(
            pi.deliveries,
            Deliveries {
                steer: true,
                follow_up: true,
                interrupt: true
            }
        );
        assert!(pi.stop && pi.resume_turn && pi.models && pi.thinking_levels);
        assert!(pi.images && pi.slash_commands && pi.streaming);
    }

    #[test]
    fn only_pi_continues_without_a_message_and_every_agent_can_be_stopped() {
        for kind in AgentKind::ALL {
            let capabilities = kind.capabilities();
            assert_eq!(capabilities.resume_turn, kind == AgentKind::Pi, "{kind}");
            assert!(capabilities.stop, "{kind}");
            assert!(capabilities.deliveries.follow_up, "{kind}");
        }
    }
}
