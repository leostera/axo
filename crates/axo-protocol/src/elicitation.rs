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

/// What the person is asked: yes or no, or values for a form's fields.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ElicitationKind {
    Confirm,
    /// Values the agent must not see (RFD0029, the side channel for input): a client seals them
    /// to this Mac's input key, and axod fills them into the window itself.
    Input,
}

/// The most fields one input request asks for.
pub const MAX_INPUT_FIELDS: usize = 8;
/// The longest value the person may enter in one field, in characters.
pub const MAX_INPUT_CHARS: usize = 1_000;

/// What a field is for: the person's form gives it the matching autofill hint and entry.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InputFieldKind {
    Username,
    Email,
    Password,
    /// A one-time code.
    Code,
    Text,
}

/// One field the person fills, as axod read it in the window.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InputField {
    /// `f0`, `f1`, …: the key of its value in the sealed answer.
    pub id: String,
    pub label: String,
    pub kind: InputFieldKind,
}

/// Where an input request's values go, all of it axod's own reading of the window, never the
/// agent's words.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InputRequest {
    pub app: String,
    pub window: String,
    /// The page's origin, from the browser's web area; absent outside a browser.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    pub fields: Vec<InputField>,
    /// The button pressed after filling, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub submit: Option<String>,
    /// This Mac's input key: base64 of an uncompressed P-256 point. Clients pin it per Mac and
    /// seal the values to it.
    pub key: String,
}

/// Values sealed to a Mac's input key (HPKE base mode; see `axo-seal`), as base64. The plaintext
/// is `{ "values": { "<field id>": "<value>" } }`, bound to `requestId\norigin`.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Sealed {
    pub enc: String,
    pub ciphertext: String,
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
    /// For `Input`: the fields, where they go, and the key to seal them to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<InputRequest>,
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

impl ElicitationAnswer {
    /// Its wire name, which a device signs (`axo_seal::answer_message`).
    pub fn as_str(self) -> &'static str {
        match self {
            ElicitationAnswer::Accept => "accept",
            ElicitationAnswer::Decline => "decline",
        }
    }
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
    /// An input request's values by field id. Axo.app sends them in the clear on this socket,
    /// which only it may answer on; remote clients seal them instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<std::collections::BTreeMap<String, String>>,
}

/// What a phone or a browser sends with every answer: its key, its name, and its signature over
/// that answer alone (`axo_seal::answer_message`).
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceProof {
    /// Base64 of an uncompressed P-256 point.
    pub key: String,
    pub name: String,
    /// Base64 of the raw 64-byte r‖s ECDSA signature over SHA-256.
    pub signature: String,
}

/// What comes with a person's answer to an input request.
#[derive(Debug, Default)]
pub enum Reply {
    /// A confirm's answer, or a Decline.
    #[default]
    Bare,
    /// From the phone or the web, through the relay.
    Sealed(Sealed),
    /// From Axo.app on this Mac.
    Values(std::collections::BTreeMap<String, String>),
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
/// An input answer that is missing, did not open, or does not fit its fields: the request still
/// waits for a good one.
pub const BAD_INPUT: i64 = -32014;
/// An answer without its device's signature over it: the request still waits.
pub const BAD_SIGNATURE: i64 = -32015;

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
            input: None,
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
        for answer in [ElicitationAnswer::Accept, ElicitationAnswer::Decline] {
            assert_eq!(serde_json::to_value(answer).unwrap(), answer.as_str());
        }
    }
}
