//! Declarative CLI projections of supported local operations. Wire validation reuses RPC types;
//! this is not permission to call relay-only or signed-caller methods. The coverage test makes
//! every advertised method opt in here or carry an explicit exclusion.
use crate::rpc::{self, method};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ValueKind {
    Text,
    Session,
    Integer,
    Json,
    File,
    JsonFile,
}
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Parameter {
    pub flag: &'static str,
    pub wire: &'static str,
    pub kind: ValueKind,
    pub required: bool,
    pub positional: bool,
    pub help: &'static str,
}
const fn p(
    flag: &'static str,
    wire: &'static str,
    kind: ValueKind,
    required: bool,
    help: &'static str,
) -> Parameter {
    Parameter {
        flag,
        wire,
        kind,
        required,
        positional: false,
        help,
    }
}
const SID: Parameter = p(
    "sid",
    "sessionId",
    ValueKind::Session,
    true,
    "Session UUID, or self inside an Axo Session",
);
const SHELL: Parameter = p(
    "shell",
    "shellId",
    ValueKind::Integer,
    true,
    "Positive pane shell ID",
);
const HOST: Parameter = p(
    "host",
    "hostId",
    ValueKind::Text,
    true,
    "Remote host ID from peer list",
);
const NAME: Parameter = p("name", "name", ValueKind::Text, true, "Name");
const KEY: Parameter = Parameter {
    positional: true,
    ..p("key", "key", ValueKind::Text, true, "Daemon setting key")
};

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Effect {
    Read,
    Write,
    Disruptive,
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Projection {
    Identity,
    Sessions,
    Session,
    SelfSession,
    Shells,
    Layout,
    Hosts,
}
#[derive(Clone, Copy, Debug)]
pub enum Request {
    Empty,
    Create,
    Session,
    Shell,
    Rename,
    Prompt,
    Layout,
    Input,
    Resize,
    Write,
    Screen,
    ConfigGet,
    ConfigSet,
    Link,
    Share,
    Peer,
    WatchPeer,
    PeerCommand,
    Question,
    Apps,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Operation {
    pub path: &'static [&'static str],
    pub method: &'static str,
    pub about: &'static str,
    pub effect: Effect,
    pub parameters: &'static [Parameter],
    pub projection: Projection,
    #[serde(skip)]
    pub request: Request,
}
macro_rules! op {
    ($path:expr, $method:expr, $about:expr, $effect:ident, $request:ident, $projection:ident, [$($param:expr),* $(,)?]) => {
        Operation { path: $path, method: $method, about: $about, effect: Effect::$effect, request: Request::$request, projection: Projection::$projection, parameters: &[$($param),*] }
    };
}

pub static OPERATIONS: &[Operation] = &[
    op!(
        &["daemon", "status"],
        method::DAEMON_HEALTH,
        "Read the running daemon's version and readiness",
        Read,
        Empty,
        Identity,
        []
    ),
    op!(
        &["daemon", "permissions"],
        method::DAEMON_PERMISSIONS,
        "Inspect live permissions held by the running daemon; never prompts",
        Read,
        Empty,
        Identity,
        []
    ),
    op!(
        &["relay", "status"],
        method::RELAY_STATUS,
        "Read the saved account link and connection state",
        Read,
        Empty,
        Identity,
        []
    ),
    op!(
        &["relay", "link"],
        method::RELAY_LINK,
        "Link this computer to a local relay (development); link to your account from Axo, Settings, Remote Access",
        Write,
        Link,
        Identity,
        [Parameter {
            positional: true,
            ..p("code", "code", ValueKind::Text, true, "Pairing code")
        }]
    ),
    op!(
        &["relay", "unlink"],
        method::RELAY_UNLINK,
        "Forget the saved pairing and stop reconnecting",
        Disruptive,
        Empty,
        Identity,
        []
    ),
    op!(
        &["session", "list"],
        method::SESSION_CATALOG,
        "List open Sessions without consuming UI focus",
        Read,
        Empty,
        Sessions,
        []
    ),
    op!(
        &["session", "catalog"],
        method::SESSION_CATALOG,
        "List open and archived Sessions",
        Read,
        Empty,
        Identity,
        []
    ),
    op!(
        &["session", "show"],
        method::SESSION_CATALOG,
        "Read one open or archived Session",
        Read,
        Empty,
        Session,
        [SID]
    ),
    op!(
        &["session", "whoami"],
        method::SESSION_CATALOG,
        "Read this Session from AXO_SESSION_ID",
        Read,
        Empty,
        SelfSession,
        []
    ),
    op!(
        &["session", "create"],
        method::SESSION_CREATE,
        "Start Pi and a terminal at home, in a folder or beside a Session",
        Write,
        Create,
        Identity,
        [
            p(
                "folder",
                "folder",
                ValueKind::Text,
                false,
                "Existing folder; relative paths resolve here"
            ),
            p(
                "like",
                "like",
                ValueKind::Session,
                false,
                "Use another Session's folder"
            ),
            p(
                "name",
                "name",
                ValueKind::Text,
                false,
                "Explicit Session name, preserved over automatic titles"
            )
        ]
    ),
    op!(
        &["session", "close"],
        method::SESSION_CLOSE,
        "Close panes and archive a Session; preserve its transcript",
        Disruptive,
        Session,
        Identity,
        [SID]
    ),
    op!(
        &["session", "reopen"],
        method::SESSION_REOPEN,
        "Reopen the most recently closed Session",
        Write,
        Empty,
        Identity,
        []
    ),
    op!(
        &["session", "rename"],
        method::SESSION_RENAME,
        "Rename a Session",
        Write,
        Rename,
        Identity,
        [SID, NAME]
    ),
    op!(
        &["session", "prompt"],
        method::SESSION_PROMPT,
        "Send a prompt (receipt is not turn completion); use --message or --message-file",
        Write,
        Prompt,
        Identity,
        [
            SID,
            p(
                "message",
                "text",
                ValueKind::Text,
                false,
                "Prompt text, passed literally"
            ),
            p(
                "message-file",
                "text",
                ValueKind::File,
                false,
                "Read prompt text from a file, or - for stdin"
            ),
            p(
                "delivery",
                "delivery",
                ValueKind::Text,
                false,
                "followUp (default), steer, turn or interrupt"
            )
        ]
    ),
    op!(
        &["session", "recover"],
        method::SESSION_PI_RESTART_AUTO,
        "Recover an unavailable Pi pane on its existing conversation",
        Write,
        Shell,
        Identity,
        [SID, SHELL]
    ),
    op!(
        &["session", "brief"],
        method::SESSION_BRIEF,
        "Read the agent's reachable capabilities",
        Read,
        Session,
        Identity,
        [SID]
    ),
    op!(
        &["session", "share"],
        method::SESSION_SHARE,
        "Publish a supplied redacted snapshot, never raw history",
        Disruptive,
        Share,
        Identity,
        [p(
            "snapshot-file",
            "snapshot",
            ValueKind::JsonFile,
            true,
            "Redacted snapshot JSON file, or - for stdin"
        )]
    ),
    op!(
        &["shell", "list"],
        method::SESSION_CATALOG,
        "List one Session's panes",
        Read,
        Empty,
        Shells,
        [SID]
    ),
    op!(
        &["shell", "create"],
        method::SHELL_CREATE,
        "Create a terminal pane",
        Write,
        Session,
        Identity,
        [SID]
    ),
    op!(
        &["shell", "close"],
        method::SHELL_CLOSE,
        "Close a pane and its process",
        Disruptive,
        Shell,
        Identity,
        [SID, SHELL]
    ),
    op!(
        &["shell", "busy"],
        method::SHELL_BUSY,
        "Read a pane's command activity",
        Read,
        Shell,
        Identity,
        [SID, SHELL]
    ),
    op!(
        &["terminal", "write"],
        method::TERMINAL_WRITE,
        "Type literal text; CR submits and control characters act as keys",
        Write,
        Write,
        Identity,
        [
            SID,
            SHELL,
            p(
                "text",
                "text",
                ValueKind::Text,
                true,
                "Keyboard text; no newline is added"
            )
        ]
    ),
    op!(
        &["terminal", "input"],
        method::TERMINAL_INPUT,
        "Send sequenced base64 terminal bytes",
        Write,
        Input,
        Identity,
        [
            SID,
            SHELL,
            p(
                "sequence",
                "sequence",
                ValueKind::Integer,
                true,
                "Consecutive input sequence from zero"
            ),
            p(
                "data",
                "data",
                ValueKind::Text,
                true,
                "Base64 encoded bytes"
            )
        ]
    ),
    op!(
        &["terminal", "screen"],
        method::TERMINAL_SCREEN,
        "Read plain screen and scrollback text",
        Read,
        Screen,
        Identity,
        [
            SID,
            SHELL,
            p(
                "lines",
                "lines",
                ValueKind::Integer,
                false,
                "Lines: 1..10000, default 200"
            )
        ]
    ),
    op!(
        &["terminal", "resize"],
        method::TERMINAL_RESIZE,
        "Resize a pane",
        Write,
        Resize,
        Identity,
        [
            SID,
            SHELL,
            p("rows", "rows", ValueKind::Integer, true, "Rows"),
            p("columns", "columns", ValueKind::Integer, true, "Columns")
        ]
    ),
    op!(
        &["layout", "get"],
        method::SESSION_CATALOG,
        "Read a Session's pane layout",
        Read,
        Empty,
        Layout,
        [SID]
    ),
    op!(
        &["layout", "set"],
        method::SESSION_LAYOUT_SET,
        "Set a layout containing every open pane exactly once",
        Write,
        Layout,
        Identity,
        [
            SID,
            p(
                "layout-file",
                "layout",
                ValueKind::JsonFile,
                true,
                "Layout JSON file, or - for stdin"
            )
        ]
    ),
    op!(
        &["config", "get"],
        method::CONFIG_GET,
        "Read agent.command, shell.command, sessions.idleMinutes or sessions.idleLimit",
        Read,
        ConfigGet,
        Identity,
        [KEY]
    ),
    op!(
        &["config", "set"],
        method::CONFIG_SET,
        "Set a daemon setting using server-side validation",
        Write,
        ConfigSet,
        Identity,
        [
            KEY,
            Parameter {
                positional: true,
                ..p("value", "value", ValueKind::Text, true, "Setting value")
            }
        ]
    ),
    op!(
        &["peer", "list"],
        method::PEER_SESSIONS_LIST,
        "Read followed hosts and their Sessions (may be cached/offline)",
        Read,
        Empty,
        Identity,
        []
    ),
    op!(
        &["host", "list"],
        method::PEER_SESSIONS_LIST,
        "Read followed hosts and connection state",
        Read,
        Empty,
        Hosts,
        []
    ),
    op!(
        &["peer", "open"],
        method::PEER_SESSION_OPEN,
        "Open a local pane on a remote Session",
        Write,
        Peer,
        Identity,
        [HOST, SID]
    ),
    op!(
        &["peer", "close"],
        method::PEER_SESSION_CLOSE,
        "Close the local peer view, not the remote Session",
        Write,
        Peer,
        Identity,
        [HOST, SID]
    ),
    op!(
        &["peer", "watch"],
        method::PEER_SESSION_WATCH,
        "Read/wait for one peer update with cursor/reset semantics",
        Read,
        WatchPeer,
        Identity,
        [
            HOST,
            SID,
            p(
                "epoch",
                "epoch",
                ValueKind::Integer,
                false,
                "Previous epoch"
            ),
            p(
                "cursor",
                "cursor",
                ValueKind::Integer,
                false,
                "Previous cursor"
            ),
            p(
                "version",
                "version",
                ValueKind::Integer,
                false,
                "Previous live version"
            ),
            p(
                "wait-ms",
                "timeoutMs",
                ValueKind::Integer,
                false,
                "Wait up to 20000 ms"
            ),
            p(
                "window",
                "window",
                ValueKind::Integer,
                false,
                "Initial record count"
            )
        ]
    ),
    op!(
        &["peer", "call"],
        method::PEER_COMMAND,
        "Forward an explicit remote method without impersonating the relay",
        Write,
        PeerCommand,
        Identity,
        [
            HOST,
            p(
                "method",
                "method",
                ValueKind::Text,
                true,
                "Remote method name"
            ),
            p(
                "params",
                "params",
                ValueKind::Json,
                true,
                "Remote parameters JSON object"
            )
        ]
    ),
    op!(
        &["apps", "list"],
        method::APPS_LIST,
        "Discover the account's apps, hosts and connected accounts",
        Read,
        Apps,
        Identity,
        [SID]
    ),
    op!(
        &["apps", "search"],
        method::APPS_SEARCH,
        "Search the runtime tool catalog",
        Read,
        Apps,
        Identity,
        [
            SID,
            p("query", "query", ValueKind::Text, true, "Tool search query")
        ]
    ),
    op!(
        &["apps", "run"],
        method::APPS_RUN,
        "Run cloud codemode; dispatched actions may have run if interrupted",
        Write,
        Apps,
        Identity,
        [
            SID,
            p(
                "file",
                "code",
                ValueKind::File,
                true,
                "JavaScript async-function source file, or - for stdin"
            ),
            p(
                "limits",
                "limits",
                ValueKind::Json,
                false,
                "Optional smaller per-run limits as JSON"
            )
        ]
    ),
    op!(
        &["apps", "log"],
        method::APPS_LOG,
        "Read recent account tool calls",
        Read,
        Apps,
        Identity,
        [SID]
    ),
    op!(
        &["apps", "add"],
        method::APPS_ADD,
        "Add a remote MCP server; sign-in may still be required",
        Write,
        Apps,
        Identity,
        [
            SID,
            NAME,
            p("url", "url", ValueKind::Text, true, "MCP server URL")
        ]
    ),
    op!(
        &["apps", "remove"],
        method::APPS_REMOVE,
        "Remove an account MCP connection",
        Disruptive,
        Apps,
        Identity,
        [SID, NAME]
    ),
    op!(
        &["question", "list"],
        method::ELICITATION_LIST,
        "Read pending questions; this does not authorize answering them",
        Read,
        Empty,
        Identity,
        []
    ),
    op!(
        &["question", "ask"],
        method::ELICITATION_REQUEST,
        "Ask as an agent and wait for the person",
        Write,
        Question,
        Identity,
        [
            SID,
            p(
                "message",
                "message",
                ValueKind::Text,
                true,
                "Question for the person"
            )
        ]
    ),
];

/// Deliberate exclusions, not forgotten commands. Raw RPC still enforces the daemon's caller policy.
pub const EXCLUDED: &[(&str, &str)] = &[
    (
        method::SESSION_TIMER_CREATE,
        "Agent-owned runtime timer; use the Session MCP tools",
    ),
    (
        method::SESSION_TIMER_LIST,
        "Agent-owned runtime timer inventory; use the Session MCP tools",
    ),
    (
        method::SESSION_TIMER_CANCEL,
        "Agent-owned runtime timer cancellation; use the Session MCP tools",
    ),
    (
        method::DAEMON_PERMISSION_REQUEST,
        "Only signed Axo.app may request OS permission from an explicit setup action",
    ),
    (
        method::SESSION_LIST,
        "Consumes pending UI resume focus; CLI listings use session.catalog",
    ),
    (
        method::SESSION_PI_RESTART_FORCE,
        "Same unavailable-pane recovery backend; use session recover",
    ),
    (
        method::CLIENT_VIEWPORT_SET,
        "UI-owned viewport; not a CLI display",
    ),
    (
        method::CLIENT_VIEWPORT_SET_V2,
        "UI-owned native renderer metrics; not a CLI display",
    ),
    (
        method::RELAY_CONNECT,
        "App retry compatibility method; linked hosts automatically reconnect",
    ),
    (
        method::ELICITATION_RESOLVE,
        "Only the person, through signed Axo.app or a signed device, can answer",
    ),
    (method::ASSETS_FETCH, "Restricted to axod's own binary"),
    (method::COMPUTER_INPUT, "Restricted protected-input channel"),
    (
        method::DEVICE_LIST,
        "Axo.app's Settings › Devices; which devices answer is decided there",
    ),
    (
        method::DEVICE_DECIDE,
        "Only the person at the Mac, in signed Axo.app, allows a device",
    ),
    (
        method::DEVICE_REVOKE,
        "Only the person at the Mac, in signed Axo.app, removes a device",
    ),
];

fn typed<T: for<'de> Deserialize<'de> + Serialize>(
    value: Value,
) -> Result<Value, serde_json::Error> {
    serde_json::from_value::<T>(value).and_then(serde_json::to_value)
}
impl Request {
    pub fn parse(self, value: Value) -> Result<Value, serde_json::Error> {
        match self {
            Self::Empty => typed::<rpc::NoParams>(value),
            Self::Create => typed::<rpc::CreateSession>(value),
            Self::Session => typed::<rpc::SessionRef>(value),
            Self::Shell => typed::<rpc::ShellRef>(value),
            Self::Rename => typed::<rpc::RenameSession>(value),
            Self::Prompt => typed::<rpc::PromptSession>(value),
            Self::Layout => typed::<rpc::SetLayout>(value),
            Self::Input => typed::<rpc::TerminalInput>(value),
            Self::Resize => typed::<rpc::TerminalResize>(value),
            Self::Write => typed::<rpc::WriteTerminal>(value),
            Self::Screen => typed::<rpc::ReadTerminalScreen>(value),
            Self::ConfigGet => typed::<rpc::GetConfig>(value),
            Self::ConfigSet => typed::<rpc::SetConfig>(value),
            Self::Link => typed::<rpc::LinkHost>(value),
            Self::Share => typed::<rpc::ShareSession>(value),
            Self::Peer => typed::<rpc::PeerSessionRef>(value),
            Self::WatchPeer => typed::<rpc::WatchPeerSession>(value),
            Self::PeerCommand => typed::<rpc::PeerCommand>(value),
            Self::Question => typed::<crate::elicitation::RequestElicitation>(value),
            Self::Apps => {
                // The account's current schemas remain authoritative for dynamic app fields.
                typed::<rpc::SessionRef>(serde_json::json!({"sessionId":value["sessionId"]}))?;
                Ok(value)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    #[test]
    fn every_advertised_method_has_a_projection_or_an_explicit_exclusion() {
        let advertised: BTreeSet<_> = method::ADVERTISED.iter().copied().collect();
        let projected: BTreeSet<_> = OPERATIONS.iter().map(|op| op.method).collect();
        let excluded: BTreeSet<_> = EXCLUDED.iter().map(|(name, _)| *name).collect();
        assert!(projected.is_disjoint(&excluded));
        assert_eq!(advertised, projected.union(&excluded).copied().collect());
        let paths: BTreeSet<_> = OPERATIONS.iter().map(|op| op.path).collect();
        assert_eq!(paths.len(), OPERATIONS.len());
        assert!(
            OPERATIONS
                .iter()
                .all(|op| !op.method.starts_with("axo.remote."))
        );
    }
    #[test]
    fn wire_parsers_preserve_bounds_and_exclusive_create_options() {
        assert!(
            Request::Create
                .parse(serde_json::json!({"folder":"relative"}))
                .is_err()
        );
        assert!(
            Request::Session
                .parse(serde_json::json!({"sessionId":"bad"}))
                .is_err()
        );
        assert!(
            Request::Empty
                .parse(serde_json::json!({"surprise":true}))
                .is_err()
        );
    }
}
