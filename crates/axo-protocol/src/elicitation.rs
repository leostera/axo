//! Elicitations (RFD0029): an agent asks the person, and only the person answers.
//!
//! axod owns each one. `axod mcp` asks with `axo.elicitation.request` on `axod.sock` and waits;
//! the person's answer reaches axod through the relay, from a signed-in person's client, or from
//! Axo.app on this Mac, both as `axo.elicitation.resolve`. On `axod.sock` only Axo.app, by code
//! signature, answers one.

use serde::{Deserialize, Serialize};

use crate::SessionId;

/// The longest message an agent may ask, in characters.
pub const MAX_MESSAGE_CHARS: usize = 1_000;
/// Pending at once on this Mac; more are refused until one settles.
pub const MAX_PENDING: usize = 32;
/// How long one waits for an answer before it is cancelled, in milliseconds.
pub const TIMEOUT_MS: u64 = 5 * 60_000;

/// What the person is asked. Only yes-or-no exists yet.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ElicitationKind {
    Confirm,
}

/// Who asks. An agent's question is its own words; a tool's is the tool's reading of what it is
/// about to do, and only axod's own `axod mcp` (by code signature) may ask as one.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Asker {
    #[default]
    Agent,
    /// The computer-use gate, before an action it flagged or one the agent asked about.
    ComputerUse,
}

/// One question to the person, as every client shows it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Elicitation {
    /// A lowercase UUID.
    pub id: String,
    pub session_id: SessionId,
    pub kind: ElicitationKind,
    pub asked_by: Asker,
    /// The asker's words, shown as theirs.
    pub message: String,
    /// Unix milliseconds.
    pub created_at: u64,
    pub expires_at: u64,
}

/// How an elicitation ends: the person's answer, or `Cancel` when nobody answered in time or the
/// asker went away.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ElicitationAction {
    Accept,
    Decline,
    Cancel,
}

/// What a person may answer: `Cancel` is never theirs to send.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ElicitationAnswer {
    Accept,
    Decline,
}

impl From<ElicitationAnswer> for ElicitationAction {
    fn from(answer: ElicitationAnswer) -> Self {
        match answer {
            ElicitationAnswer::Accept => ElicitationAction::Accept,
            ElicitationAnswer::Decline => ElicitationAction::Decline,
        }
    }
}

/// `axo.elicitation.request`'s parameters, from `axod mcp`.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RequestElicitation {
    pub session_id: SessionId,
    pub message: String,
    #[serde(default)]
    pub asked_by: Asker,
}

/// `axo.elicitation.resolve`'s parameters on `axod.sock`, from Axo.app.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResolveElicitation {
    pub elicitation_id: String,
    pub action: ElicitationAnswer,
}

/// `axo.elicitation.list`'s result: what waits for the person, oldest first.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Pending {
    pub elicitations: Vec<Elicitation>,
}

/// `axo.elicitation.resolve`'s result.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Resolved {
    pub resolved: bool,
}

/// Shared with `@axo/protocol`'s `ELICITATION_ERRORS`.
pub const NOT_PENDING: i64 = -32011;
/// Only a person answers: on `axod.sock`, only Axo.app.
pub const NOT_A_PERSON: i64 = -32012;
/// Only axod's own tools ask as a tool.
pub const NOT_A_TOOL: i64 = -32013;

/// `axo.elicitation.request`'s result: how it ended.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ElicitationOutcome {
    pub id: String,
    pub action: ElicitationAction,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn elicitations_use_the_worker_s_field_names() {
        let elicitation = Elicitation {
            id: "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a".into(),
            session_id: SessionId::from_u128(1),
            kind: ElicitationKind::Confirm,
            asked_by: Asker::ComputerUse,
            message: "Delete the branch?".into(),
            created_at: 1,
            expires_at: 2,
        };
        assert_eq!(
            serde_json::to_value(&elicitation).unwrap(),
            json!({
                "id": "6c4e2f0a-1b2c-4d3e-8f9a-0b1c2d3e4f5a",
                "sessionId": "00000000-0000-0000-0000-000000000001",
                "kind": "confirm",
                "askedBy": "computerUse",
                "message": "Delete the branch?",
                "createdAt": 1,
                "expiresAt": 2,
            })
        );
        assert!(serde_json::from_value::<ElicitationAnswer>(json!("cancel")).is_err());
    }
}
