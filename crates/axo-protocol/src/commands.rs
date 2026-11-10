//! A client's commands to a Session's Pi (RFD0024): the ids that name its own prompts and the
//! entries of the Session's log, and what a stop names.

use serde::{Deserialize, Serialize};

/// A client's id for one command: a hyphenated hexadecimal UUID, kept lowercase. The Pi that
/// owns the Session takes a prompt with a given id at most once.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct CommandId(String);

impl CommandId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for CommandId {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if crate::is_uuid(&value) {
            Ok(Self(value.to_ascii_lowercase()))
        } else {
            Err("a commandId is a UUID")
        }
    }
}

impl From<CommandId> for String {
    fn from(id: CommandId) -> Self {
        id.0
    }
}

/// The id of an entry in a Session's Pi log: 1 to 128 letters, digits or `._:-`, as pi-axo
/// checks it.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct EntryId(String);

impl EntryId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for EntryId {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        let allowed = |byte: u8| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte);
        if (1..=128).contains(&value.len()) && value.bytes().all(allowed) {
            Ok(Self(value))
        } else {
            Err("an entry id is 1 to 128 letters, digits or ._:-")
        }
    }
}

impl From<EntryId> for String {
    fn from(id: EntryId) -> Self {
        id.0
    }
}

/// The most of a client's own prompts one stop names.
pub const MAX_STOP_COMMANDS: usize = 32;

/// What a client saw of the run it asks to stop (RFD0024, as amended): Pi stops its running run
/// only if one of these belongs to it, so a run the client never saw goes on. It names at least
/// one, and at most [`MAX_STOP_COMMANDS`] prompts; only [`StopTarget::new`] makes one.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StopTarget {
    /// A user record of the run.
    #[serde(skip_serializing_if = "Option::is_none")]
    turn_id: Option<EntryId>,
    /// The newest entry the client held: of the run however long it is, once its records arrive.
    #[serde(skip_serializing_if = "Option::is_none")]
    seen: Option<EntryId>,
    /// The client's own prompts, sent or queued: they name a run before any of its records arrive.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    command_ids: Vec<CommandId>,
}

impl StopTarget {
    pub fn new(
        turn_id: Option<EntryId>,
        seen: Option<EntryId>,
        command_ids: Vec<CommandId>,
    ) -> Result<Self, &'static str> {
        if turn_id.is_none() && seen.is_none() && command_ids.is_empty() {
            return Err("a stop names a turnId, the entry seen, or commandIds");
        }
        if command_ids.len() > MAX_STOP_COMMANDS {
            return Err("a stop names at most 32 commandIds");
        }
        Ok(Self {
            turn_id,
            seen,
            command_ids,
        })
    }

    pub fn turn_id(&self) -> Option<&EntryId> {
        self.turn_id.as_ref()
    }

    pub fn seen(&self) -> Option<&EntryId> {
        self.seen.as_ref()
    }

    pub fn command_ids(&self) -> &[CommandId] {
        &self.command_ids
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const COMMAND: &str = "6F1D2C3B-4A5E-4F60-8A7B-9C0D1E2F3A4B";

    #[test]
    fn a_command_id_is_a_uuid_kept_lowercase() {
        let id: CommandId = serde_json::from_value(json!(COMMAND)).unwrap();
        assert_eq!(id.as_str(), COMMAND.to_ascii_lowercase());
        assert_eq!(
            serde_json::to_value(&id).unwrap(),
            COMMAND.to_ascii_lowercase()
        );
        for refused in ["", "prompt-1", "6f1d2c3b4a5e4f608a7b9c0d1e2f3a4b"] {
            assert!(serde_json::from_value::<CommandId>(json!(refused)).is_err());
        }
    }

    #[test]
    fn an_entry_id_is_short_and_plain() {
        assert!(EntryId::try_from("a1b2:c3.d-4_".to_owned()).is_ok());
        for refused in [String::new(), "a b".into(), "x".repeat(129), "e/1".into()] {
            assert!(EntryId::try_from(refused).is_err());
        }
    }

    #[test]
    fn a_stop_names_something_and_not_too_much() {
        let command = || CommandId::try_from(COMMAND.to_owned()).unwrap();
        assert!(StopTarget::new(None, None, Vec::new()).is_err());
        assert!(StopTarget::new(None, None, vec![command(); MAX_STOP_COMMANDS + 1]).is_err());
        let seen = EntryId::try_from("e9".to_owned()).unwrap();
        let stop = StopTarget::new(None, Some(seen), vec![command()]).unwrap();
        assert_eq!(
            serde_json::to_value(&stop).unwrap(),
            json!({ "seen": "e9", "commandIds": [COMMAND.to_ascii_lowercase()] })
        );
    }
}
