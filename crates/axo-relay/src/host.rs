//! What the relay needs from the daemon that hosts it.

use std::io;
use std::time::Duration;

use axo_protocol::{Event, RelayStatus, SessionId};

use crate::sync::{StoredSyncState, SyncSession};

/// A client's id for one command (RFD0024): a hyphenated hexadecimal UUID, kept lowercase. The
/// Pi that owns the Session takes a prompt with a given id at most once.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(try_from = "String")]
pub struct CommandId(String);

impl CommandId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for CommandId {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if axo_protocol::is_uuid(&value) {
            Ok(Self(value.to_ascii_lowercase()))
        } else {
            Err("a commandId is a UUID")
        }
    }
}

/// The entry id of a user record in a Session's Pi log, naming the turn it belongs to: 1 to 128
/// letters, digits or `._:-`, as pi-axo checks it.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(try_from = "String")]
pub struct TurnId(String);

impl TurnId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for TurnId {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        let allowed = |byte: u8| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte);
        if (1..=128).contains(&value.len()) && value.bytes().all(allowed) {
            Ok(Self(value))
        } else {
            Err("a turnId is an entry id of the Session's log")
        }
    }
}

/// The most of a client's own prompts one stop names.
pub const MAX_STOP_COMMANDS: usize = 32;

/// What a client saw of the run it asks to stop (RFD0024, as amended): Pi stops its running run
/// only if one of these belongs to it, so a run the client never saw goes on. At least one is set.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StopTarget {
    /// A user record of the run.
    pub turn_id: Option<TurnId>,
    /// The newest entry the client held: of the run however long it is, once its records arrive.
    pub seen: Option<TurnId>,
    /// The client's own prompts, sent or queued: they name a run before any of its records arrive.
    pub command_ids: Vec<CommandId>,
}

impl StopTarget {
    pub fn new(
        turn_id: Option<TurnId>,
        seen: Option<TurnId>,
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
}

/// A key a remote person presses in a Session's Pi: what answering it on the Mac would take.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PiKey {
    /// Stops the reply in progress, or declines the question Pi is asking.
    Escape,
    /// Accepts the question Pi is asking.
    Enter,
}

/// When a remote person's prompt reaches a working Pi (RFD0033): once the turn ends, or within it.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ClientDelivery {
    #[default]
    FollowUp,
    Steer,
}

/// A model a remote person picks for a Session, as Pi's registry names it (RFD0033).
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelChoice {
    pub provider: ModelName,
    pub id: ModelName,
}

/// A provider or model id: 1 to 128 characters, no control characters.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(try_from = "String")]
pub struct ModelName(String);

impl ModelName {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for ModelName {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if (1..=128).contains(&value.chars().count()) && !value.chars().any(char::is_control) {
            Ok(Self(value))
        } else {
            Err("a model name has 1 to 128 characters")
        }
    }
}

/// The daemon's sessions, as seen by the cloud relay. Implemented by Axod's session manager.
///
/// Identifiers arrive already parsed (positive); implementations still check that they name
/// open sessions and panes, because remote callers are untrusted.
pub trait RelayHost: Send + Sync {
    /// Stable identity of this host.
    fn host_id(&self) -> &str;
    /// Changes every daemon start; lets the cloud discard stale state.
    fn host_generation(&self) -> &str;
    fn publish_relay_status(&self, status: &RelayStatus);

    /// Every Session, open and archived, with its Pi transcript (RFD0018, Upload).
    fn sync_catalog(&self) -> io::Result<Vec<SyncSession>>;
    /// What `axo.db` keeps of each Session's upload.
    fn sync_states(&self) -> io::Result<Vec<StoredSyncState>>;
    /// The last position and chain the cloud acknowledged for a Session.
    fn store_sync_cursor(
        &self,
        session_id: SessionId,
        position: u64,
        chain: &str,
    ) -> io::Result<()>;
    /// The metadata last sent for a Session, and its version.
    fn store_sync_metadata(
        &self,
        session_id: SessionId,
        metadata_json: &str,
        version: u64,
    ) -> io::Result<()>;
    /// Deletes an archived Session's transcript, which the cloud acknowledged whole at
    /// `position` and `chain` while the file was `length` bytes (RFD0027). Records it in `axo.db`
    /// first; returns false, deleting nothing, if the Session no longer qualifies.
    fn evict_transcript(
        &self,
        session_id: SessionId,
        position: u64,
        chain: &str,
        length: u64,
    ) -> io::Result<bool>;
    /// Raises and returns the handshake round, which outlives sockets and restarts.
    fn next_sync_round(&self) -> io::Result<u64>;
    /// Subscribes to local events (including terminal output); returns the subscription ID.
    fn subscribe_remote_events(&self) -> io::Result<String>;
    /// The next local events, waiting up to `timeout` without holding a thread; none if it ran
    /// out. Dropping the wait loses nothing.
    fn next_remote_events<'a>(
        &'a self,
        subscription_id: &'a str,
        timeout: Duration,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Vec<Event>>> + Send + 'a>>;
    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()>;

    /// What agents here are asking the person now (RFD0029), sent again on every connection.
    fn pending_elicitations(&self) -> Vec<axo_protocol::elicitation::Elicitation> {
        Vec::new()
    }
    /// A person's answer from the cloud, with an input request's values sealed to this Mac.
    /// `Err((code, message))` when it no longer waits, or its values are no good.
    fn resolve_elicitation(
        &self,
        _id: &str,
        _answer: axo_protocol::elicitation::ElicitationAnswer,
        _sealed: Option<axo_protocol::elicitation::Sealed>,
        _device: Option<axo_protocol::elicitation::DeviceProof>,
    ) -> Result<(), (i64, String)> {
        Err((
            axo_protocol::elicitation::NOT_PENDING,
            "Already answered, or no longer asked".into(),
        ))
    }

    /// One computer-use tool from another Mac's script (RFD0028): the gate, the person's answer
    /// in the calling Session if it must ask, then the tool's MCP answer with its images inline.
    /// `Err` is a JSON-RPC error: refused, declined, or not answered.
    fn remote_computer(
        &self,
        _request: &crate::computer::ComputerParams,
    ) -> Result<serde_json::Value, (i64, String)> {
        Err((-32601, "Method not found".into()))
    }
    /// Whether this Mac can do computer use now: `{ available, accessibility, screenRecording, locked }`.
    fn computer_status(&self) -> serde_json::Value {
        serde_json::json!({ "available": false, "accessibility": false, "screenRecording": false })
    }
    /// Where the account's assets are reached from while the relay is connected, so local
    /// callers (`axod mcp`) can fetch them; `None` once it disconnects.
    fn set_asset_source(&self, _source: Option<crate::assets::AssetSource>) {}

    /// Answers one of the account's calls (`axo.remote.*`), a whole JSON-RPC request, as the
    /// account would be answered: the response to send back, or `None` for a notification.
    /// The relay only carries it; what the methods do is the host's.
    fn answer_remote(&self, request: serde_json::Value) -> Option<serde_json::Value>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_command_id_is_a_uuid_kept_lowercase() {
        let id: CommandId =
            serde_json::from_value(serde_json::json!("6F1D2C3B-4A5E-4F60-8A7B-9C0D1E2F3A4B"))
                .unwrap();
        assert_eq!(id.as_str(), "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b");
        for bad in ["", "not-a-uuid", "6f1d2c3b4a5e4f608a7b9c0d1e2f3a4b"] {
            assert!(serde_json::from_value::<CommandId>(serde_json::json!(bad)).is_err());
        }
    }

    #[test]
    fn a_turn_id_is_an_entry_id() {
        for good in ["a1b2c3d4", "turn-1", "x:y.z_w"] {
            let id: TurnId = serde_json::from_value(serde_json::json!(good)).unwrap();
            assert_eq!(id.as_str(), good);
        }
        let long = "a".repeat(129);
        for bad in ["", "two words", "slash/no", long.as_str()] {
            assert!(serde_json::from_value::<TurnId>(serde_json::json!(bad)).is_err());
        }
    }
}
