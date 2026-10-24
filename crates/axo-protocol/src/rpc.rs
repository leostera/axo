//! Local JSON-RPC methods: names, parameters and results.
//!
//! Parameters reject unknown fields, so a misspelled field fails loudly instead of being ignored.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::{ConfigKey, Event, LayoutNode, SessionId, SessionRecord, ShellId, WorkspaceRecord};

/// Method names, in the order `axo.protocol.negotiate` advertises them.
pub mod method {
    pub const PROTOCOL_NEGOTIATE: &str = "axo.protocol.negotiate";
    pub const DAEMON_HEALTH: &str = "axo.daemon.health";
    pub const CONFIG_GET: &str = "axo.config.get";
    pub const CONFIG_SET: &str = "axo.config.set";
    pub const SESSION_LIST: &str = "axo.session.list";
    pub const SESSION_CREATE: &str = "axo.session.create";
    pub const WORKSPACE_LIST: &str = "axo.workspace.list";
    pub const WORKSPACE_CREATE: &str = "axo.workspace.create";
    pub const WORKSPACE_RENAME: &str = "axo.workspace.rename";
    pub const WORKSPACE_ARCHIVE: &str = "axo.workspace.archive";
    pub const WORKSPACE_SESSION_CREATE: &str = "axo.workspace.session.create";
    pub const SESSION_CLOSE: &str = "axo.session.close";
    pub const SESSION_RENAME: &str = "axo.session.rename";
    pub const SESSION_PI_RESTART_FORCE: &str = "axo.session.pi.restart.force.v2";
    pub const SESSION_PI_RESTART_AUTO: &str = "axo.session.pi.restart.auto.v1";
    pub const SESSION_LAYOUT_SET: &str = "axo.session.layout.set";
    pub const SESSION_SUBSCRIBE: &str = "axo.session.subscribe";
    pub const SESSION_EVENTS_NEXT: &str = "axo.session.events.next";
    pub const SESSION_UNSUBSCRIBE: &str = "axo.session.unsubscribe";
    pub const SHELL_CREATE: &str = "axo.shell.create";
    pub const SHELL_CLOSE: &str = "axo.shell.close";
    pub const SHELL_BUSY: &str = "axo.shell.busy";
    pub const TERMINAL_INPUT: &str = "axo.terminal.input";
    pub const TERMINAL_RESIZE: &str = "axo.terminal.resize";
    pub const RELAY_SETTINGS: &str = "axo.relay.settings";
    pub const RELAY_CONFIGURE: &str = "axo.relay.configure";
    pub const RELAY_LINK: &str = "axo.relay.link";
    pub const RELAY_DISABLE: &str = "axo.relay.disable";
    pub const RELAY_STATUS: &str = "axo.relay.status";
    pub const RELAY_CONNECT: &str = "axo.relay.connect";

    /// Everything a version-1 client may call (negotiation itself excluded).
    pub const ADVERTISED: &[&str] = &[
        DAEMON_HEALTH,
        CONFIG_GET,
        CONFIG_SET,
        SESSION_LIST,
        SESSION_CREATE,
        WORKSPACE_LIST,
        WORKSPACE_CREATE,
        WORKSPACE_RENAME,
        WORKSPACE_ARCHIVE,
        WORKSPACE_SESSION_CREATE,
        SESSION_CLOSE,
        SESSION_RENAME,
        SESSION_PI_RESTART_FORCE,
        SESSION_PI_RESTART_AUTO,
        SESSION_LAYOUT_SET,
        SESSION_SUBSCRIBE,
        SESSION_EVENTS_NEXT,
        SESSION_UNSUBSCRIBE,
        SHELL_CREATE,
        SHELL_CLOSE,
        SHELL_BUSY,
        TERMINAL_INPUT,
        TERMINAL_RESIZE,
        RELAY_SETTINGS,
        RELAY_CONFIGURE,
        RELAY_LINK,
        RELAY_DISABLE,
        RELAY_STATUS,
        RELAY_CONNECT,
    ];
}

/// The only protocol version.
pub const PROTOCOL_VERSION: u32 = 1;
/// Upper bound for `NextEvents::timeout_ms`.
pub const MAX_EVENTS_TIMEOUT_MS: u64 = 20_000;
/// Upper bound for `NextEvents::max_events`.
pub const MAX_EVENTS_PER_POLL: usize = 256;

// Parameters.

/// For methods without parameters.
#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NoParams {}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NegotiateProtocol {
    pub protocol_version: u32,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionRef {
    pub session_id: SessionId,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ShellRef {
    pub session_id: SessionId,
    pub shell_id: ShellId,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SetLayout {
    pub session_id: SessionId,
    /// Validated by the handler, which reports structural problems with their own message.
    pub layout: LayoutNode,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RenameSession {
    pub session_id: SessionId,
    pub name: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceRef {
    pub workspace_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RenameWorkspace {
    pub workspace_id: String,
    pub name: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CreateWorkspace {
    pub name: String,
    pub directory_path: PathBuf,
    /// A security-scoped bookmark granting access to `directory_path`, base64.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory_bookmark: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GetConfig {
    pub key: ConfigKey,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SetConfig {
    pub key: ConfigKey,
    pub value: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Subscribe {
    /// Only this session's events; all sessions when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<SessionId>,
    /// Catalog clients pass `false`; terminal bytes would otherwise dominate their queue.
    #[serde(default = "default_true")]
    pub include_terminal_output: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NextEvents {
    pub subscription_id: String,
    /// `1..=MAX_EVENTS_TIMEOUT_MS`.
    pub timeout_ms: u64,
    /// `1..=MAX_EVENTS_PER_POLL`. When absent the result carries at most one `event`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_events: Option<usize>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Unsubscribe {
    pub subscription_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TerminalInput {
    pub session_id: SessionId,
    pub shell_id: ShellId,
    /// Per shell, from zero, consecutive; a repeated sequence is acknowledged and ignored.
    pub sequence: u64,
    /// Base64, 1 to 49,152 bytes decoded.
    pub data: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TerminalResize {
    pub session_id: SessionId,
    pub shell_id: ShellId,
    pub rows: u32,
    pub columns: u32,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LinkHost {
    pub code: String,
}

// Results.

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProtocolNegotiated {
    pub protocol_version: u32,
    pub methods: Vec<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DaemonStatus {
    Running,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DaemonHealth {
    pub version: String,
    pub build_number: u64,
    pub status: DaemonStatus,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionList {
    pub sessions: Vec<SessionRecord>,
    /// Set once after Pi's `/resume` switched sessions; clients select it.
    pub resume_session_id: Option<SessionId>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigValue {
    pub key: ConfigKey,
    pub value: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    pub saved: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Subscribed {
    pub subscription_id: String,
}

/// `axo.session.events.next`: one optional event for legacy pollers, or a batch when the caller
/// passed `maxEvents`. Both are empty when the wait timed out.
///
/// Generic so a server can serialize shared (`Arc`) events without copying them.
#[derive(Debug, Deserialize, Serialize)]
#[serde(untagged)]
pub enum EventsNext<E = Event> {
    Batch { events: Vec<E> },
    Single { event: Option<E> },
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Unsubscribed {
    pub unsubscribed: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InputAccepted {
    pub accepted: bool,
    pub sequence: u64,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResizeAccepted {
    pub accepted: bool,
    pub rows: u32,
    pub columns: u32,
}

/// Whether closing a shell would interrupt work: a foreground job other than the shell itself
/// (terminal panes) or a Pi turn in progress (Pi panes).
#[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellBusy {
    pub busy: bool,
    /// Name of the foreground process when it is not the shell; informational only.
    pub foreground_process: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceList {
    pub workspaces: Vec<WorkspaceRecord>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceCreated {
    pub workspace: WorkspaceRecord,
    pub session: SessionRecord,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceArchived {
    pub archived_workspace_id: String,
    pub archived_session_ids: Vec<SessionId>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionClosed {
    pub archived_session_id: SessionId,
    /// Closing the last session creates a fresh one.
    pub replacement: Option<SessionRecord>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellClosed {
    pub archived_shell_id: ShellId,
    /// Set when this was the session's last pane.
    pub archived_session_id: Option<SessionId>,
    pub replacement: Option<SessionRecord>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayDisabled {
    pub disabled: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostLinked {
    pub linked: bool,
    pub host_label: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectRequested {
    pub requested: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parameters_reject_unknown_fields_and_invalid_ids() {
        assert!(
            serde_json::from_value::<ShellRef>(json!({ "sessionId": 1, "shellId": 2 })).is_ok()
        );
        assert!(
            serde_json::from_value::<ShellRef>(json!({ "sessionId": 1, "shellId": 2, "x": 1 }))
                .is_err()
        );
        assert!(
            serde_json::from_value::<ShellRef>(json!({ "sessionId": 0, "shellId": 2 })).is_err()
        );
        assert!(serde_json::from_value::<NoParams>(json!({})).is_ok());
    }

    #[test]
    fn subscriptions_include_terminal_output_unless_declined() {
        let subscribe: Subscribe = serde_json::from_value(json!({})).unwrap();
        assert!(subscribe.include_terminal_output && subscribe.session_id.is_none());
    }

    #[test]
    fn event_polls_answer_in_the_shape_the_caller_asked_for() {
        let single = serde_json::to_value(EventsNext::<Event>::Single { event: None }).unwrap();
        assert_eq!(single, json!({ "event": null }));
        let batch = serde_json::to_value(EventsNext::Batch {
            events: vec![Event::SubscriptionLagged],
        })
        .unwrap();
        assert_eq!(
            batch,
            json!({ "events": [{ "type": "subscription.lagged" }] })
        );
    }
}
