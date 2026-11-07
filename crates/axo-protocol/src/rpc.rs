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
    pub const SESSION_CATALOG: &str = "axo.session.catalog";
    pub const SESSION_PROMPT: &str = "axo.session.prompt";
    pub const SESSION_CREATE: &str = "axo.session.create";
    pub const WORKSPACE_LIST: &str = "axo.workspace.list";
    pub const WORKSPACE_CREATE: &str = "axo.workspace.create";
    pub const WORKSPACE_RENAME: &str = "axo.workspace.rename";
    pub const WORKSPACE_ARCHIVE: &str = "axo.workspace.archive";
    pub const WORKSPACE_SESSION_CREATE: &str = "axo.workspace.session.create";
    pub const SESSION_CLOSE: &str = "axo.session.close";
    pub const SESSION_REOPEN: &str = "axo.session.reopen";
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
    pub const TERMINAL_WRITE: &str = "axo.terminal.write";
    pub const TERMINAL_SCREEN: &str = "axo.terminal.screen";
    pub const CLIENT_VIEWPORT_SET: &str = "axo.client.viewport.set";
    pub const RELAY_LINK: &str = "axo.relay.link";
    pub const RELAY_STATUS: &str = "axo.relay.status";
    pub const RELAY_CONNECT: &str = "axo.relay.connect";
    pub const SESSION_SHARE: &str = "axo.session.share";
    /// Apps (RFD0016): forwarded unchanged to the account over the relay, so their names
    /// and parameters are those of `apps.schema.json`.
    pub const APPS_LIST: &str = "axo.apps.list";
    pub const APPS_SEARCH: &str = "axo.apps.search";
    pub const APPS_RUN: &str = "axo.apps.run";
    pub const APPS_LOG: &str = "axo.apps.log";
    pub const APPS_ADD: &str = "axo.apps.add";
    pub const APPS_REMOVE: &str = "axo.apps.remove";
    /// Other Macs' Sessions, opened here in a pane (RFD0024).
    pub const PEER_SESSIONS_LIST: &str = "axo.peer.sessions.list";
    pub const PEER_SESSION_OPEN: &str = "axo.peer.session.open";
    pub const PEER_SESSION_CLOSE: &str = "axo.peer.session.close";
    pub const PEER_SESSION_WATCH: &str = "axo.peer.session.watch";
    pub const PEER_COMMAND: &str = "axo.peer.command";
    /// An agent or a tool asks its person and waits (RFD0029).
    pub const ELICITATION_REQUEST: &str = "axo.elicitation.request";
    /// The person answers, from Axo.app on this Mac (by code signature) or through the relay.
    pub const ELICITATION_RESOLVE: &str = "axo.elicitation.resolve";
    /// What waits for the person now, oldest first, for a client that just (re)subscribed.
    pub const ELICITATION_LIST: &str = "axo.elicitation.list";
    /// Fetches the account's assets into `~/.axo/assets`, for axod's own `axod mcp` (RFD0028).
    pub const ASSETS_FETCH: &str = "axo.assets.fetch";
    /// `request_input` from axod's own `axod mcp`: axod asks for the values and fills them in.
    pub const COMPUTER_INPUT: &str = "axo.computer.input";
    /// Salted hashes of values the person filled in, which `axod mcp` hides from its reads.
    pub const COMPUTER_REDACTIONS: &str = "axo.computer.redactions";

    /// Everything a version-1 client may call (negotiation itself excluded).
    pub const ADVERTISED: &[&str] = &[
        DAEMON_HEALTH,
        CONFIG_GET,
        CONFIG_SET,
        SESSION_LIST,
        SESSION_CATALOG,
        SESSION_CREATE,
        WORKSPACE_LIST,
        WORKSPACE_CREATE,
        WORKSPACE_RENAME,
        WORKSPACE_ARCHIVE,
        WORKSPACE_SESSION_CREATE,
        SESSION_CLOSE,
        SESSION_REOPEN,
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
        TERMINAL_WRITE,
        TERMINAL_SCREEN,
        SESSION_PROMPT,
        CLIENT_VIEWPORT_SET,
        RELAY_LINK,
        RELAY_STATUS,
        RELAY_CONNECT,
        SESSION_SHARE,
        APPS_LIST,
        APPS_SEARCH,
        APPS_RUN,
        APPS_LOG,
        APPS_ADD,
        APPS_REMOVE,
        PEER_SESSIONS_LIST,
        PEER_SESSION_OPEN,
        PEER_SESSION_CLOSE,
        PEER_SESSION_WATCH,
        PEER_COMMAND,
        ELICITATION_REQUEST,
        ELICITATION_RESOLVE,
        ELICITATION_LIST,
        ASSETS_FETCH,
        COMPUTER_INPUT,
        COMPUTER_REDACTIONS,
    ];
}

/// The account's apps (RFD0016), which axod forwards unchanged over the relay, and how
/// long axod waits for each one's answer. A client must wait longer than that: see
/// [`forwarded::client_timeout`].
pub mod forwarded {
    use std::time::Duration;

    use super::method;

    /// A script may run for five minutes; its answer then has this long to arrive.
    const SCRIPT: Duration = Duration::from_secs(5 * 60 + 30);
    const QUICK: Duration = Duration::from_secs(30);

    /// Every forwarded method and how long axod waits for its answer.
    pub const METHODS: &[(&str, Duration)] = &[
        (method::APPS_LIST, QUICK),
        (method::APPS_SEARCH, SCRIPT),
        (method::APPS_RUN, SCRIPT),
        (method::APPS_LOG, QUICK),
        // Adding tries the server and may register a client with it.
        (method::APPS_ADD, Duration::from_secs(60)),
        (method::APPS_REMOVE, QUICK),
    ];

    /// How long a caller of `method` should wait for axod's answer, beyond axod's own wait;
    /// `None` for a method axod does not forward.
    pub fn client_timeout(method: &str) -> Option<Duration> {
        METHODS
            .iter()
            .find(|(name, _)| *name == method)
            .map(|(_, timeout)| *timeout + Duration::from_secs(5))
    }
}

/// The only protocol version.
pub const PROTOCOL_VERSION: u32 = 2;
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

/// Text typed into a pane as if from a keyboard, outside the pane's input sequence: control
/// characters act as keys (`\r` submits, `\u0003` interrupts).
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WriteTerminal {
    pub session_id: SessionId,
    pub shell_id: ShellId,
    /// 1 to 49,152 bytes of UTF-8.
    pub text: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadTerminalScreen {
    pub session_id: SessionId,
    pub shell_id: ShellId,
    /// The last this many lines of screen and scrollback; 1 to 10,000, default 200.
    #[serde(default)]
    pub lines: Option<u32>,
}

/// How a Session's Pi takes a prompt that arrives while it is working. An idle Pi starts a
/// turn with it whatever the delivery.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PromptDelivery {
    /// After its current tool calls, before its next model call.
    Steer,
    /// Once its current turn ends.
    #[default]
    FollowUp,
    /// Only if idle; refused while working.
    Turn,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PromptSession {
    pub session_id: SessionId,
    /// 1 to 16,000 bytes.
    pub text: String,
    #[serde(default)]
    pub delivery: PromptDelivery,
    /// The Session whose agent sends this; absent when a person does.
    #[serde(default)]
    pub from_session_id: Option<SessionId>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LinkHost {
    pub code: String,
}

/// Publishes a redacted conversation through this Mac's Axo account (`/axo-share`).
///
/// `snapshot` is passed through untouched: the cloud validates it (the `@axo/protocol` shared
/// snapshot schema), stores it and picks its ID. Axod only adds which host is publishing.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ShareSession {
    pub snapshot: serde_json::Value,
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
    /// Whether Axod has finished starting (see `Event::DaemonReady`). An Axod that predates it
    /// says nothing, and was ready whenever it answered.
    #[serde(default = "answered_means_ready")]
    pub ready: bool,
    /// Whether macOS lets axod run as a developer tool, so the programs Sessions run skip the
    /// scan before their first run; absent where macOS cannot say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub developer_tools: Option<PermissionState>,
}

fn answered_means_ready() -> bool {
    true
}

/// How a process stands with one of macOS's privacy permissions.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionState {
    Granted,
    Denied,
    NotAsked,
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

/// Every Session on this Mac: open ones as `axo.session.list` reports them, and archived ones.
/// Another Mac of the account, as this Mac follows it (RFD0024).
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerHost {
    pub host_id: String,
    pub label: String,
    pub online: bool,
}

/// Another Mac's Session: its record as a local one would be, with the Mac it runs on. Its
/// shells are this Mac's remote pane on it, if one is open; `piSessionFile` is this Mac's copy.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerSession {
    pub host_id: String,
    #[serde(flatten)]
    pub session: SessionRecord,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerSessionList {
    /// Whether this Mac follows the account now; the list is the last one it had otherwise.
    pub connected: bool,
    pub hosts: Vec<PeerHost>,
    pub sessions: Vec<PeerSession>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PeerSessionRef {
    pub host_id: String,
    pub session_id: SessionId,
}

/// What a remote pane has drawn: the copy's epoch and cursor, and the live state's version.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WatchPeerSession {
    pub host_id: String,
    pub session_id: SessionId,
    #[serde(default)]
    pub epoch: Option<u64>,
    #[serde(default)]
    pub cursor: u64,
    /// The `version` of the last answer; 0 the first time, which answers at once.
    #[serde(default)]
    pub version: u64,
    /// How long to wait for something new, at most `MAX_EVENTS_TIMEOUT_MS`.
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    /// How many records to read when starting over, newest last.
    #[serde(default)]
    pub window: Option<usize>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerRecord {
    pub cursor: u64,
    pub line: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerProgress {
    pub slot: String,
    pub snapshot: serde_json::Value,
}

/// A remote pane's next view of the copy. With `reset`, it drops what it drew and draws
/// `records` afresh (a cut, another epoch, or its first look); otherwise `records` follow its
/// cursor. `more` asks it to call again at once.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerSessionView {
    pub version: u64,
    pub epoch: Option<u64>,
    pub cursor: u64,
    pub reset: bool,
    pub records: Vec<PeerRecord>,
    pub more: bool,
    pub progress: Vec<PeerProgress>,
    pub status: Option<crate::SessionStatus>,
    pub host_label: String,
    pub host_online: bool,
    /// Whether this Mac follows the account now.
    pub connected: bool,
}

/// A command for another Mac's Session, sent as a client would (`axo.remote.*`).
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PeerCommand {
    pub host_id: String,
    pub method: String,
    pub params: serde_json::Map<String, serde_json::Value>,
}

/// Unlike `axo.session.list`, this has no side effects.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCatalog {
    pub sessions: Vec<SessionRecord>,
    pub archived: Vec<ArchivedSessionRecord>,
}

/// An archived Session: no panes, but its conversation is still on disk.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArchivedSessionRecord {
    pub id: SessionId,
    pub name: String,
    pub emoji: Option<String>,
    pub workspace_id: Option<String>,
    pub workspace_name: Option<String>,
    pub initial_pwd: PathBuf,
    /// Pi's JSONL transcript; it may not exist if Pi never wrote to it.
    pub pi_session_file: Option<PathBuf>,
    pub last_message_at: Option<i64>,
    pub archived_at: Option<i64>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptAccepted {
    pub accepted: bool,
    /// True when Pi is still starting and the prompt waits for it.
    pub queued: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteAccepted {
    pub accepted: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalScreen {
    pub text: String,
    /// Whether earlier lines were left out.
    pub truncated: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InputAccepted {
    pub accepted: bool,
    pub sequence: u64,
}

/// `axo.client.viewport.set` took effect; its parameters are a [`crate::Viewport`].
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewportAccepted {
    pub accepted: bool,
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
pub struct SessionShared {
    pub share_id: String,
    pub url: String,
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

    const SID: &str = "2f5c3a1e-8d4b-4c6a-9e1f-0b7d3c2a5e41";

    #[test]
    fn parameters_reject_unknown_fields_and_invalid_ids() {
        assert!(
            serde_json::from_value::<ShellRef>(json!({ "sessionId": SID, "shellId": 2 })).is_ok()
        );
        assert!(
            serde_json::from_value::<ShellRef>(json!({ "sessionId": SID, "shellId": 2, "x": 1 }))
                .is_err()
        );
        assert!(
            serde_json::from_value::<ShellRef>(json!({ "sessionId": 1, "shellId": 2 })).is_err()
        );
        assert!(
            serde_json::from_value::<ShellRef>(
                json!({ "sessionId": SID.to_uppercase(), "shellId": 2 })
            )
            .is_err()
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
