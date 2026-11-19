//! Local JSON-RPC methods: names, parameters and results.
//!
//! Parameters reject unknown fields, so a misspelled field fails loudly instead of being ignored.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::{ConfigKey, LayoutNode, SessionId, SessionRecord, ShellId};

/// The error a method answers with: a JSON-RPC error code and what the caller is told. The
/// details of why stay on this Mac; the message is for the caller.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct MethodError {
    pub code: i64,
    pub message: String,
}

impl MethodError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// The parameters are not what the method takes.
    pub fn invalid_params(detail: impl std::fmt::Display) -> Self {
        Self::new(
            error_code::INVALID_PARAMS,
            format!("Invalid params: {detail}"),
        )
    }

    /// Nothing answers that method here.
    pub fn method_not_found() -> Self {
        Self::new(error_code::METHOD_NOT_FOUND, "Method not found")
    }
}

impl std::fmt::Display for MethodError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{} ({})", self.message, self.code)
    }
}

impl std::error::Error for MethodError {}

/// Error codes every method shares: JSON-RPC's own, and the ones the account and its Macs use
/// for each other (the API Worker's `host-do.ts` speaks the same).
pub mod error_code {
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INVALID_PARAMS: i64 = -32602;
    pub const INTERNAL_ERROR: i64 = -32603;
    /// Meant for another run of this Mac, or a lease that moved on.
    pub const STALE_HOST: i64 = -32002;
    /// Not allowed, or not done; the caller is told no more.
    pub const REFUSED: i64 = -32003;
    /// What it names is not here.
    pub const NOT_FOUND: i64 = -32004;
    /// Too much is running already; try again later.
    pub const BUSY: i64 = -32006;
    /// It did not finish in time.
    pub const TIMED_OUT: i64 = -32008;
    /// This Mac is not connected to its account, so what needs the account cannot be done.
    pub const NOT_CONNECTED: i64 = -32024;
    /// A caller named a Session it does not belong to: a Session acts only as itself (RFD0073).
    pub const NOT_THAT_SESSION: i64 = -32099;
}

/// Method names, in the order `axo.protocol.negotiate` advertises them.
pub mod method {
    pub const PROTOCOL_NEGOTIATE: &str = "axo.protocol.negotiate";
    pub const DAEMON_HEALTH: &str = "axo.daemon.health";
    pub const DAEMON_PERMISSIONS: &str = "axo.daemon.permissions";
    pub const DAEMON_PERMISSION_REQUEST: &str = "axo.daemon.permissions.request";
    pub const CONFIG_GET: &str = "axo.config.get";
    pub const CONFIG_SET: &str = "axo.config.set";
    pub const SESSION_LIST: &str = "axo.session.list";
    pub const SESSION_CATALOG: &str = "axo.session.catalog";
    pub const SESSION_PROMPT: &str = "axo.session.prompt";
    pub const SESSION_TIMER_CREATE: &str = "axo.session.timer.create";
    pub const SESSION_TIMER_LIST: &str = "axo.session.timer.list";
    pub const SESSION_TIMER_CANCEL: &str = "axo.session.timer.cancel";
    pub const SESSION_CREATE: &str = "axo.session.create";
    pub const SESSION_CLOSE: &str = "axo.session.close";
    pub const SESSION_REOPEN: &str = "axo.session.reopen";
    pub const SESSION_RENAME: &str = "axo.session.rename";
    pub const SESSION_PI_RESTART_FORCE: &str = "axo.session.pi.restart.force.v2";
    pub const SESSION_PI_RESTART_AUTO: &str = "axo.session.pi.restart.auto.v1";
    pub const SESSION_LAYOUT_SET: &str = "axo.session.layout.set";
    pub const SHELL_CREATE: &str = "axo.shell.create";
    pub const SHELL_CLOSE: &str = "axo.shell.close";
    pub const SHELL_BUSY: &str = "axo.shell.busy";
    pub const TERMINAL_INPUT: &str = "axo.terminal.input";
    pub const TERMINAL_RESIZE: &str = "axo.terminal.resize";
    pub const TERMINAL_WRITE: &str = "axo.terminal.write";
    pub const TERMINAL_SCREEN: &str = "axo.terminal.screen";
    pub const CLIENT_VIEWPORT_SET: &str = "axo.client.viewport.set";
    pub const CLIENT_VIEWPORT_SET_V2: &str = "axo.client.viewport.set.v2";
    pub const RELAY_LINK: &str = "axo.relay.link";
    pub const RELAY_STATUS: &str = "axo.relay.status";
    pub const RELAY_UNLINK: &str = "axo.relay.unlink";
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
    /// What a Session's agent can do through Axo, for pi-axo to put in its system prompt.
    pub const SESSION_BRIEF: &str = "axo.session.brief";
    /// The coding agents this Mac has, and what each can do (RFD0072).
    pub const AGENTS_LIST: &str = "axo.agents.list";

    /// Everything a version-1 client may call (negotiation itself excluded).
    pub const ADVERTISED: &[&str] = &[
        DAEMON_HEALTH,
        DAEMON_PERMISSIONS,
        DAEMON_PERMISSION_REQUEST,
        CONFIG_GET,
        CONFIG_SET,
        SESSION_LIST,
        SESSION_CATALOG,
        SESSION_CREATE,
        SESSION_CLOSE,
        SESSION_REOPEN,
        SESSION_RENAME,
        SESSION_PI_RESTART_FORCE,
        SESSION_PI_RESTART_AUTO,
        SESSION_LAYOUT_SET,
        SHELL_CREATE,
        SHELL_CLOSE,
        SHELL_BUSY,
        TERMINAL_INPUT,
        TERMINAL_RESIZE,
        TERMINAL_WRITE,
        TERMINAL_SCREEN,
        SESSION_PROMPT,
        SESSION_TIMER_CREATE,
        SESSION_TIMER_LIST,
        SESSION_TIMER_CANCEL,
        CLIENT_VIEWPORT_SET,
        CLIENT_VIEWPORT_SET_V2,
        RELAY_LINK,
        RELAY_STATUS,
        RELAY_UNLINK,
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
        SESSION_BRIEF,
        AGENTS_LIST,
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

/// Bytes of text in one prompt.
pub const MAX_PROMPT_BYTES: usize = 16_000;
/// Bytes typed into a pane in one request.
pub const MAX_TERMINAL_INPUT_BYTES: usize = 49_152;
/// Lines of screen and scrollback one read returns, by default and at most.
pub const DEFAULT_SCREEN_LINES: u32 = 200;
pub const MAX_SCREEN_LINES: u32 = 10_000;

/// A parameter outside what its method takes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidParam(pub &'static str);

impl std::fmt::Display for InvalidParam {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for InvalidParam {}

/// A prompt's words: at most [`MAX_PROMPT_BYTES`]. They may be blank on the wire: a prompt of
/// attachments alone needs none, and whoever takes the prompt decides whether it says anything.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct PromptText(String);

impl PromptText {
    pub fn parse(text: String) -> Result<Self, InvalidParam> {
        if text.len() > MAX_PROMPT_BYTES {
            return Err(InvalidParam("a prompt has at most 16000 bytes of text"));
        }
        Ok(Self(text))
    }

    /// Whether it says nothing but whitespace.
    pub fn is_blank(&self) -> bool {
        self.0.trim().is_empty()
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

impl TryFrom<String> for PromptText {
    type Error = InvalidParam;

    fn try_from(text: String) -> Result<Self, InvalidParam> {
        Self::parse(text)
    }
}

impl From<PromptText> for String {
    fn from(text: PromptText) -> String {
        text.0
    }
}

/// Text typed into a pane: 1 to [`MAX_TERMINAL_INPUT_BYTES`] bytes of UTF-8.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct TerminalText(String);

impl TerminalText {
    pub fn parse(text: String) -> Result<Self, InvalidParam> {
        if text.is_empty() || text.len() > MAX_TERMINAL_INPUT_BYTES {
            return Err(InvalidParam("terminal text has 1 to 49152 bytes"));
        }
        Ok(Self(text))
    }

    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }
}

impl TryFrom<String> for TerminalText {
    type Error = InvalidParam;

    fn try_from(text: String) -> Result<Self, InvalidParam> {
        Self::parse(text)
    }
}

impl From<TerminalText> for String {
    fn from(text: TerminalText) -> String {
        text.0
    }
}

/// Bytes typed into a pane, as base64 on the wire: 1 to [`MAX_TERMINAL_INPUT_BYTES`], in the
/// one canonical encoding (see [`crate::base64::decode`]).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalBytes(Vec<u8>);

impl TerminalBytes {
    /// The bound on the encoding, checked before decoding: exactly the bound on the bytes.
    const MAX_BASE64_BYTES: usize = MAX_TERMINAL_INPUT_BYTES / 3 * 4;

    pub fn from_base64(encoded: &str) -> Result<Self, InvalidParam> {
        if encoded.len() > Self::MAX_BASE64_BYTES {
            return Err(InvalidParam("terminal input has 1 to 49152 bytes"));
        }
        crate::base64::decode(encoded)
            .map(Self)
            .map_err(|_| InvalidParam("terminal input is padded, canonical base64"))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// Never: a parsed input has at least one byte.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl Serialize for TerminalBytes {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&crate::base64::encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for TerminalBytes {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let encoded = std::borrow::Cow::<str>::deserialize(deserializer)?;
        Self::from_base64(&encoded).map_err(serde::de::Error::custom)
    }
}

/// How many lines of screen and scrollback to read: 1 to [`MAX_SCREEN_LINES`].
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "u32", into = "u32")]
pub struct ScreenLines(u32);

impl ScreenLines {
    pub fn get(self) -> u32 {
        self.0
    }
}

impl Default for ScreenLines {
    fn default() -> Self {
        Self(DEFAULT_SCREEN_LINES)
    }
}

impl TryFrom<u32> for ScreenLines {
    type Error = InvalidParam;

    fn try_from(lines: u32) -> Result<Self, InvalidParam> {
        if !(1..=MAX_SCREEN_LINES).contains(&lines) {
            return Err(InvalidParam("lines must be 1 to 10000"));
        }
        Ok(Self(lines))
    }
}

impl From<ScreenLines> for u32 {
    fn from(lines: ScreenLines) -> u32 {
        lines.0
    }
}

/// The only protocol version.
pub const PROTOCOL_VERSION: u32 = 2;
/// Upper bound for a request that waits for something new (`WatchPeerSession::timeout_ms`).
pub const MAX_WAIT_MS: u64 = 20_000;
/// Most events in one `axo.session.events` notification.
pub const MAX_EVENTS_PER_BATCH: usize = 256;

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

/// An explicit Session name: 1–80 UTF-16 units, no controls or surrounding whitespace.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct SessionName(String);

impl SessionName {
    pub fn parse(name: String) -> Result<Self, InvalidParam> {
        if name.is_empty()
            || name.trim() != name
            || name.encode_utf16().count() > 80
            || name.chars().any(char::is_control)
        {
            return Err(InvalidParam(
                "Session name must be 1–80 UTF-16 units, without controls or surrounding whitespace",
            ));
        }
        Ok(Self(name))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for SessionName {
    type Error = InvalidParam;
    fn try_from(name: String) -> Result<Self, Self::Error> {
        Self::parse(name)
    }
}
impl From<SessionName> for String {
    fn from(name: SessionName) -> Self {
        name.0
    }
}

/// Where a Session starts; folder and like remain mutually exclusive.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub enum SessionLocation {
    #[default]
    AtHome,
    InFolder(PathBuf),
    Like(SessionId),
}

/// Optional explicit name is independent of the Session's location (RFD0038).
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "CreateSessionWire", into = "CreateSessionWire")]
pub struct CreateSession {
    pub location: SessionLocation,
    pub name: Option<SessionName>,
    /// The agent the Session runs, for good (RFD0072). Pi when unsaid.
    pub agent: crate::agent::AgentKind,
}

impl From<SessionLocation> for CreateSession {
    fn from(location: SessionLocation) -> Self {
        Self {
            location,
            name: None,
            agent: crate::agent::AgentKind::Pi,
        }
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateSessionWire {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    folder: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    like: Option<SessionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<SessionName>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agent: Option<crate::agent::AgentKind>,
}

impl TryFrom<CreateSessionWire> for CreateSession {
    type Error = InvalidParam;

    fn try_from(wire: CreateSessionWire) -> Result<Self, InvalidParam> {
        let location = match (wire.folder, wire.like) {
            (None, None) => SessionLocation::AtHome,
            (Some(folder), None) if folder.is_absolute() => SessionLocation::InFolder(folder),
            (Some(_), None) => {
                return Err(InvalidParam("a Session's folder must be an absolute path"));
            }
            (None, Some(like)) => SessionLocation::Like(like),
            (Some(_), Some(_)) => {
                return Err(InvalidParam(
                    "a new Session takes a folder or another Session's, not both",
                ));
            }
        };
        Ok(Self {
            location,
            name: wire.name,
            agent: wire.agent.unwrap_or_default(),
        })
    }
}

impl From<CreateSession> for CreateSessionWire {
    fn from(create: CreateSession) -> Self {
        let (folder, like) = match create.location {
            SessionLocation::AtHome => (None, None),
            SessionLocation::InFolder(folder) => (Some(folder), None),
            SessionLocation::Like(like) => (None, Some(like)),
        };
        Self {
            folder,
            like,
            name: create.name,
            // Pi is left unsaid, so a request reads as it did before other agents.
            agent: Some(create.agent).filter(|agent| *agent != crate::agent::AgentKind::Pi),
        }
    }
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
pub struct TerminalInput {
    pub session_id: SessionId,
    pub shell_id: ShellId,
    /// Per shell, from zero, consecutive; a repeated sequence is acknowledged and ignored.
    pub sequence: u64,
    pub data: TerminalBytes,
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
    pub text: TerminalText,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadTerminalScreen {
    pub session_id: SessionId,
    pub shell_id: ShellId,
    /// The last this many lines of screen and scrollback.
    #[serde(default)]
    pub lines: ScreenLines,
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
    /// Stops the running turn and starts the next one with it, ahead of anything waiting: what a
    /// person tapping Send means (RFD0033).
    Interrupt,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PromptSession {
    pub session_id: SessionId,
    pub text: PromptText,
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

/// `axo.agents.list`'s answer: every agent Axo can run, in [`AgentKind::ALL`]'s order.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentsList {
    pub agents: Vec<AgentAvailability>,
}

/// One agent on this Mac: found and runnable, or why not.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentAvailability {
    pub agent: crate::agent::AgentKind,
    pub installed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executable: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Why it cannot run: not installed, or a version the adapter does not support.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
    pub capabilities: crate::agent::Capabilities,
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

/// A live observation, not a cached authorization. Unknown is never permission to act.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionAccess {
    Granted,
    NotGranted,
    NotAsked,
    NotRunning,
    Unknown,
    Unsupported,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DaemonPermissions {
    pub process_id: u32,
    pub supported: bool,
    pub accessibility: PermissionAccess,
    pub input_control: PermissionAccess,
    pub screen_recording: PermissionAccess,
    pub developer_tools: PermissionAccess,
    pub full_disk_access: PermissionAccess,
    pub automation_finder: PermissionAccess,
    pub automation_system_events: PermissionAccess,
    pub locked: bool,
}
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AutomationPermissionTarget {
    Finder,
    SystemEvents,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RequestAutomationPermission {
    pub target: AutomationPermissionTarget,
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

/// `axo.session.brief`'s request: the Session whose agent it is for.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionBriefRequest {
    pub session_id: SessionId,
}

/// `axo.session.brief`'s answer: plain text, one line per thing the agent can use.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionBrief {
    pub brief: String,
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

/// Another Mac of the account, as this Mac follows it (RFD0024).
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerHost {
    pub host_id: String,
    pub label: String,
    pub online: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<PeerHostModel>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct PeerHostModel {
    pub identifier: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
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
    /// How long to wait for something new, at most `MAX_WAIT_MS`.
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

/// Every Session on this Mac: open ones as `axo.session.list` reports them, and archived ones.
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
    pub folder: PathBuf,
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
pub struct SessionClosed {
    pub archived_session_id: SessionId,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShellClosed {
    pub archived_shell_id: ShellId,
    /// Set when this was the session's last pane.
    pub archived_session_id: Option<SessionId>,
}

/// Durable pairing state and the current connection, without credential material.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayLinkStatus {
    #[serde(flatten)]
    pub connection: crate::RelayStatus,
    pub linked: bool,
    pub account_id: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostUnlinked {
    pub unlinked: bool,
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
    fn a_new_session_names_a_folder_another_session_or_neither() {
        let parse = |value| serde_json::from_value::<CreateSession>(value);
        assert_eq!(parse(json!({})).unwrap(), CreateSession::default());
        assert_eq!(
            parse(json!({ "folder": "/tmp" })).unwrap(),
            CreateSession::from(SessionLocation::InFolder("/tmp".into()))
        );
        assert_eq!(
            parse(json!({ "like": SID })).unwrap(),
            CreateSession::from(SessionLocation::Like(SID.parse().unwrap()))
        );
        let both = parse(json!({ "folder": "/tmp", "like": SID })).unwrap_err();
        assert!(both.to_string().contains("not both"), "{both}");
        let relative = parse(json!({ "folder": "tmp" })).unwrap_err();
        assert!(relative.to_string().contains("absolute"), "{relative}");
        for create in [
            CreateSession::default(),
            CreateSession::from(SessionLocation::InFolder("/tmp".into())),
            CreateSession::from(SessionLocation::Like(SID.parse().unwrap())),
        ] {
            let wire = serde_json::to_value(&create).unwrap();
            assert_eq!(parse(wire).unwrap(), create);
        }
    }

    #[test]
    fn creation_names_are_parsed_independently_of_location() {
        for location in [
            serde_json::json!({}),
            serde_json::json!({"folder":"/tmp"}),
            serde_json::json!({"like":SID}),
        ] {
            let mut wire = location;
            wire["name"] = serde_json::json!("Parser fixes");
            let parsed: CreateSession = serde_json::from_value(wire.clone()).unwrap();
            assert_eq!(parsed.name.as_ref().unwrap().as_str(), "Parser fixes");
            assert_eq!(serde_json::to_value(parsed).unwrap(), wire);
        }
        for name in [
            String::new(),
            " ".into(),
            " padded".into(),
            "padded ".into(),
            "a\nb".into(),
            "x".repeat(81),
            "🐈".repeat(41),
        ] {
            assert!(
                serde_json::from_value::<CreateSession>(serde_json::json!({"name":name})).is_err()
            );
        }
        assert!(SessionName::parse("🐈".repeat(40)).is_ok());
        assert!(serde_json::from_value::<CreateSession>(serde_json::json!({"name":7})).is_err());
        assert!(
            serde_json::from_value::<CreateSession>(
                serde_json::json!({"name":"ok","folder":"/tmp","like":SID})
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<CreateSession>(
                serde_json::json!({"name":"ok","unknown":true})
            )
            .is_err()
        );
    }

    #[test]
    fn bounded_texts_are_refused_outside_their_bounds_while_parsing() {
        assert!(PromptText::parse("x".repeat(MAX_PROMPT_BYTES)).is_ok());
        assert!(PromptText::parse("x".repeat(MAX_PROMPT_BYTES + 1)).is_err());
        assert!(PromptText::parse(" \n".into()).unwrap().is_blank());
        assert!(TerminalText::parse(String::new()).is_err());
        assert!(TerminalText::parse("x".repeat(MAX_TERMINAL_INPUT_BYTES)).is_ok());
        assert!(TerminalText::parse("x".repeat(MAX_TERMINAL_INPUT_BYTES + 1)).is_err());
        let most = crate::base64::encode(&vec![7; MAX_TERMINAL_INPUT_BYTES]);
        assert_eq!(
            TerminalBytes::from_base64(&most).unwrap().len(),
            MAX_TERMINAL_INPUT_BYTES
        );
        let over = crate::base64::encode(&vec![7; MAX_TERMINAL_INPUT_BYTES + 1]);
        assert!(TerminalBytes::from_base64(&over).is_err());
        assert!(TerminalBytes::from_base64("").is_err());
        let input: TerminalInput = serde_json::from_value(
            json!({ "sessionId": SID, "shellId": 2, "sequence": 0, "data": "aGk=" }),
        )
        .unwrap();
        assert_eq!(input.data.as_bytes(), b"hi");
        assert_eq!(serde_json::to_value(&input).unwrap()["data"], "aGk=");
        let screen = |value| serde_json::from_value::<ReadTerminalScreen>(value);
        assert_eq!(
            screen(json!({ "sessionId": SID, "shellId": 2 }))
                .unwrap()
                .lines
                .get(),
            DEFAULT_SCREEN_LINES
        );
        assert!(screen(json!({ "sessionId": SID, "shellId": 2, "lines": 0 })).is_err());
        assert!(screen(json!({ "sessionId": SID, "shellId": 2, "lines": 10_001 })).is_err());
    }

    #[test]
    fn subscriptions_include_terminal_output_unless_declined() {
        let subscribe: Subscribe = serde_json::from_value(json!({})).unwrap();
        assert!(subscribe.include_terminal_output && subscribe.session_id.is_none());
    }
}
