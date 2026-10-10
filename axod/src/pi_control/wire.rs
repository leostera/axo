//! Closed owner/extension protocol. Pi documents are opaque, never routing envelopes.
use crate::model::{ChildPid, RuntimeRef};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::path::PathBuf;
macro_rules! uuid_id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(#[serde(deserialize_with = "crate::model::deserialize_uuid")] uuid::Uuid);
    };
}
uuid_id!(ChatId);
uuid_id!(InteractionId);
uuid_id!(RequestId);
impl RequestId {
    pub(super) fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Model {
    pub id: String,
    pub provider: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Tui,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct State {
    pub chat_id: ChatId,
    pub file: Option<PathBuf>,
    pub leaf_id: Option<String>,
    pub cwd: PathBuf,
    pub mode: Mode,
    #[serde(rename = "stdinTTY")]
    pub stdin_tty: bool,
    #[serde(rename = "stdoutTTY")]
    pub stdout_tty: bool,
    #[serde(rename = "stderrTTY")]
    pub stderr_tty: bool,
    pub rows: u16,
    pub columns: u16,
    pub pid: ChildPid,
    pub busy: bool,
    pub interaction_id: Option<InteractionId>,
    pub ui_waits: u16,
    pub tools: Vec<String>,
    pub pending: bool,
    pub recovery: bool,
    pub model: Option<Model>,
}
/// Exact Pi-owned document, including arbitrary public extension data. Interpretation
/// belongs to the canonical-history projection, not this transport router. RawValue
/// preserves JSON without using dynamic Value checks to identify protocol messages.
#[derive(Debug, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CanonicalDocument(Box<RawValue>);
impl CanonicalDocument {
    pub fn json(&self) -> &str {
        self.0.get()
    }
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct History {
    pub leaf_id: Option<String>,
    pub entries: Vec<CanonicalDocument>,
    pub branch: Vec<CanonicalDocument>,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum RemoteError {
    NotReady,
    NotInteractive,
    Rejected,
    Stale,
    Recovery,
    Invalid,
    Busy,
    StaleInteraction,
    Blocked,
    Unknown,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum Response {
    Snapshot(Box<State>),
    History(History),
    Dispatched,
    Rejected(RemoteError),
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Reply {
    pub id: Option<RequestId>,
    pub response: Response,
}
/// External tags are deliberate: every record has exactly one variant, and serde
/// deserializes opaque Pi documents directly rather than buffering an untagged union.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) enum Record {
    Ready(Box<State>),
    Status(Box<State>),
    Reply(Reply),
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Target {
    pub runtime: RuntimeRef,
    pub chat_id: ChatId,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct InteractionTarget {
    pub runtime: RuntimeRef,
    pub chat_id: ChatId,
    pub interaction_id: InteractionId,
}
#[derive(Serialize)]
#[serde(tag = "method", rename_all = "camelCase")]
pub(super) enum Request<'a> {
    Bind {
        id: RequestId,
        runtime: RuntimeRef,
    },
    Get {
        id: RequestId,
        target: Target,
    },
    History {
        id: RequestId,
        target: Target,
    },
    Send {
        id: RequestId,
        target: Target,
        text: &'a str,
    },
    Steer {
        id: RequestId,
        target: InteractionTarget,
        text: &'a str,
    },
    Cancel {
        id: RequestId,
        target: InteractionTarget,
    },
    Shutdown {
        id: RequestId,
        target: Target,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Expected {
    Snapshot,
    History,
    Dispatched,
}
impl Request<'_> {
    pub fn id(&self) -> RequestId {
        match self {
            Self::Bind { id, .. }
            | Self::Get { id, .. }
            | Self::History { id, .. }
            | Self::Send { id, .. }
            | Self::Steer { id, .. }
            | Self::Cancel { id, .. }
            | Self::Shutdown { id, .. } => *id,
        }
    }
    pub fn expected(&self) -> Expected {
        match self {
            Self::Bind { .. } | Self::Get { .. } => Expected::Snapshot,
            Self::History { .. } => Expected::History,
            _ => Expected::Dispatched,
        }
    }
}
impl Response {
    pub fn matches(&self, expected: Expected) -> bool {
        matches!(
            (self, expected),
            (Self::Snapshot(_), Expected::Snapshot)
                | (Self::History(_), Expected::History)
                | (Self::Dispatched, Expected::Dispatched)
                | (Self::Rejected(_), _)
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn closed_tags_and_payload_shapes_fail_during_deserialization() {
        for raw in [
            r#"{}"#,
            r#"{"invented":{}}"#,
            r#"{"ready":{},"status":{}}"#,
            r#"{"reply":{"id":null,"response":"invented"}}"#,
            r#"{"reply":{"id":null,"response":"dispatched","extra":true}}"#,
            r#"{"reply":{"id":null,"response":{"rejected":"payload-not-a-code"}}}"#,
            r#"{"reply":{"id":null,"response":{"history":{"leafId":null,"entries":[],"branch":[],"extra":true}}}}"#,
        ] {
            assert!(
                serde_json::from_str::<Record>(raw).is_err(),
                "Malformed control record admitted"
            );
        }
    }
    #[test]
    fn opaque_pi_documents_round_trip_without_becoming_protocol_discriminators() {
        let raw = r#"{"reply":{"id":null,"response":{"history":{"leafId":null,"entries":[{"type":"custom","data":{"arbitrary":[1,true,null]}}],"branch":[]}}}}"#;
        let Record::Reply(Reply {
            response: Response::History(history),
            ..
        }) = serde_json::from_str(raw).unwrap()
        else {
            panic!("Typed history variant missing");
        };
        assert!(
            history.entries[0].json() == r#"{"type":"custom","data":{"arbitrary":[1,true,null]}}"#
        );
    }
    #[test]
    fn well_formed_but_wrong_response_kind_is_not_an_acknowledgement() {
        assert!(!Response::Dispatched.matches(Expected::Snapshot));
        assert!(
            !Response::History(History {
                leaf_id: None,
                entries: vec![],
                branch: vec![]
            })
            .matches(Expected::Dispatched)
        );
        assert!(Response::Rejected(RemoteError::Busy).matches(Expected::Snapshot));
    }
}
