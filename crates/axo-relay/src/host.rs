//! What the relay needs from the daemon that hosts it.

use std::io;
use std::time::Duration;

use axo_protocol::{
    Event, LayoutNode, RelayStatus, RemoteSessionSnapshot, RemoteWorkspace, SessionId, ShellId,
};

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

/// A key a remote person presses in a Session's Pi: what answering it on the Mac would take.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PiKey {
    /// Stops the reply in progress, or declines the question Pi is asking.
    Escape,
    /// Accepts the question Pi is asking.
    Enter,
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
    fn next_remote_event(
        &self,
        subscription_id: &str,
        timeout: Duration,
    ) -> io::Result<Option<Event>>;
    fn unsubscribe_remote_events(&self, subscription_id: &str) -> io::Result<()>;

    /// What agents here are asking the person now (RFD0029), sent again on every connection.
    fn pending_elicitations(&self) -> Vec<axo_protocol::elicitation::Elicitation> {
        Vec::new()
    }
    /// A person's answer from the cloud; false when it no longer waits.
    fn resolve_elicitation(
        &self,
        _id: &str,
        _answer: axo_protocol::elicitation::ElicitationAnswer,
    ) -> bool {
        false
    }

    /// The Workspaces a Session can be created in.
    fn remote_workspaces(&self) -> io::Result<Vec<RemoteWorkspace>>;
    fn remote_create_session(&self, updated_at: &str) -> io::Result<RemoteSessionSnapshot>;
    fn remote_create_workspace_session(
        &self,
        workspace_id: &str,
        updated_at: &str,
    ) -> io::Result<RemoteSessionSnapshot>;
    /// Returns the replacement session, if closing the last one created it.
    fn remote_close_session(
        &self,
        session_id: SessionId,
        updated_at: &str,
    ) -> io::Result<Option<RemoteSessionSnapshot>>;
    /// Names the Session by hand (what `axo.session.rename` does locally).
    fn remote_rename_session(&self, session_id: SessionId, name: &str) -> io::Result<()>;
    fn remote_create_shell(&self, session_id: SessionId) -> io::Result<ShellId>;
    fn remote_close_shell(&self, session_id: SessionId, shell_id: ShellId) -> io::Result<()>;
    /// Fails with `InvalidInput` if the layout is malformed or does not match the open panes.
    fn remote_set_layout(&self, session_id: SessionId, layout: LayoutNode) -> io::Result<()>;
    fn remote_terminal_input(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        sequence: u64,
        data: &str,
    ) -> io::Result<()>;
    /// Sends `text` to the Session's Pi as a prompt, as if typed and submitted in its pane.
    /// Fails with `InvalidInput` for empty or oversized text, and `NotFound` if Pi is not running.
    /// With a `command_id`, the prompt is taken at most once and written after a receipt
    /// (RFD0024).
    /// `attachments` are already fetched and checked (RFD0030); with any, `text` may be empty.
    fn remote_prompt_pi(
        &self,
        session_id: SessionId,
        text: &str,
        command_id: Option<&CommandId>,
        attachments: &[axo_protocol::asset::FetchedAttachment],
    ) -> io::Result<()>;
    /// Stops the Session's running turn if it is the one `turn_id` names; says whether it did.
    /// Fails with `NotFound` if Pi is not running.
    fn remote_stop_pi_turn(&self, session_id: SessionId, turn_id: &TurnId) -> io::Result<bool>;
    /// Presses `key` in the Session's Pi pane. Fails with `NotFound` if Pi is not running.
    fn remote_press_pi_key(&self, session_id: SessionId, key: PiKey) -> io::Result<()>;
    fn remote_terminal_resize(
        &self,
        session_id: SessionId,
        shell_id: ShellId,
        rows: u32,
        columns: u32,
    ) -> io::Result<()>;
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
