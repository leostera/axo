//! The bridge protocol between Axod and the pi-axo extension (`packages/pi-axo/src/protocol.ts`).
//!
//! Newline-delimited JSON over the Pi's Unix socket. Axod connects, authenticates with the
//! Session's bridge token, and Pi answers with its identity, then streams events and answers
//! commands.

use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

/// The only protocol version either side speaks.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProtocolVersion;

impl ProtocolVersion {
    const NUMBER: u32 = 1;
}

impl Serialize for ProtocolVersion {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u32(Self::NUMBER)
    }
}

impl<'de> Deserialize<'de> for ProtocolVersion {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        match u32::deserialize(deserializer)? {
            Self::NUMBER => Ok(ProtocolVersion),
            other => Err(serde::de::Error::custom(format_args!(
                "unsupported Pi bridge protocol version {other}"
            ))),
        }
    }
}

/// Records Axod sends.
#[derive(Debug, Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Outgoing<'a> {
    Authenticate {
        protocol_version: ProtocolVersion,
        token: &'a str,
    },
    Command {
        request_id: &'a str,
        axo_session_id: &'a str,
        action: Action<'a>,
    },
}

/// What a command asks Pi to do.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Action<'a> {
    /// Exit now, aborting any turn in progress.
    Shutdown,
    /// Exit only if no turn is in progress; otherwise answer `busy`.
    ShutdownIfIdle,
    /// Submit `text` as a user message. An idle Pi starts a turn with it; a working Pi queues
    /// it as `delivery` says, or answers `busy` when there is none.
    Send {
        text: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        delivery: Option<QueuedDelivery>,
    },
}

/// How a working Pi takes a message: `steer` after the current tool calls, `followUp` once the
/// turn ends.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum QueuedDelivery {
    Steer,
    FollowUp,
}

/// Records Pi sends.
#[derive(Debug, Deserialize, PartialEq)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Record {
    Authenticated {
        protocol_version: ProtocolVersion,
    },
    Hello {
        protocol_version: ProtocolVersion,
        identity: Identity,
    },
    Event {
        stream_id: String,
        sequence: u64,
        name: String,
        /// Pi's own payload, forwarded unchanged.
        #[serde(default)]
        data: Value,
    },
    CommandResult {
        request_id: String,
        result: CommandResult,
    },
    ProtocolError {
        message: String,
    },
}

/// Who a Pi says it is; Axod checks every field against the pane it launched.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub axo_session_id: String,
    pub axo_pane_id: String,
    pub pi_session_id: String,
    pub session_file: Option<PathBuf>,
    pub cwd: PathBuf,
    pub process_id: u64,
}

/// Pi's answer to a command.
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

/// Parses one record (without its newline).
pub fn parse_record(line: &[u8]) -> serde_json::Result<Record> {
    serde_json::from_slice(line)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn outgoing_records_match_the_extension() {
        assert_eq!(
            serde_json::to_value(Outgoing::Authenticate {
                protocol_version: ProtocolVersion,
                token: "token"
            })
            .unwrap(),
            json!({ "type": "authenticate", "protocolVersion": 1, "token": "token" })
        );
        assert_eq!(
            serde_json::to_value(Outgoing::Command {
                request_id: "takeover-1",
                axo_session_id: "session",
                action: Action::ShutdownIfIdle,
            })
            .unwrap(),
            json!({
                "type": "command",
                "requestId": "takeover-1",
                "axoSessionId": "session",
                "action": { "kind": "shutdownIfIdle" }
            })
        );
        assert_eq!(
            serde_json::to_value(Action::Shutdown).unwrap(),
            json!({ "kind": "shutdown" })
        );
        assert_eq!(
            serde_json::to_value(Action::Send {
                text: "hi",
                delivery: Some(QueuedDelivery::FollowUp)
            })
            .unwrap(),
            json!({ "kind": "send", "text": "hi", "delivery": "followUp" })
        );
        assert_eq!(
            serde_json::to_value(Action::Send {
                text: "hi",
                delivery: None
            })
            .unwrap(),
            json!({ "kind": "send", "text": "hi" })
        );
    }

    #[test]
    fn records_from_the_extension_parse() {
        let parse = |value: Value| parse_record(value.to_string().as_bytes());
        assert_eq!(
            parse(json!({ "type": "authenticated", "protocolVersion": 1 })).unwrap(),
            Record::Authenticated {
                protocol_version: ProtocolVersion
            }
        );
        let hello = parse(json!({
            "type": "hello",
            "protocolVersion": 1,
            "identity": {
                "axoSessionId": "s", "axoPaneId": "p", "piSessionId": "pi",
                "sessionFile": null, "cwd": "/work", "processId": 42
            }
        }))
        .unwrap();
        let Record::Hello { identity, .. } = hello else {
            panic!("expected hello");
        };
        assert_eq!(identity.session_file, None);
        assert_eq!(identity.process_id, 42);

        assert_eq!(
            parse(
                json!({ "type": "event", "streamId": "x", "sequence": 3, "name": "agent.start" })
            )
            .unwrap(),
            Record::Event {
                stream_id: "x".to_owned(),
                sequence: 3,
                name: "agent.start".to_owned(),
                data: Value::Null
            }
        );
        assert_eq!(
            parse(json!({ "type": "commandResult", "requestId": "r", "result": { "accepted": false, "reason": "busy" } }))
                .unwrap(),
            Record::CommandResult {
                request_id: "r".to_owned(),
                result: CommandResult::Rejected(RejectReason::Busy)
            }
        );
    }

    #[test]
    fn malformed_records_are_rejected() {
        for value in [
            json!({ "type": "authenticated", "protocolVersion": 2 }),
            json!({ "type": "event", "streamId": "x", "sequence": -1, "name": "n" }),
            json!({ "type": "commandResult", "requestId": "r", "result": { "accepted": true, "reason": "busy" } }),
            json!({ "type": "commandResult", "requestId": "r", "result": { "accepted": false } }),
            json!({ "type": "unknown" }),
            json!([]),
        ] {
            assert!(
                parse_record(value.to_string().as_bytes()).is_err(),
                "{value}"
            );
        }
    }
}
