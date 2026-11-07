//! The relay's JSON-RPC messages: requests and responses, the host's registration and
//! capabilities, and the parameters of each `axo.remote.*` call.

use axo_protocol::{HostKind, LayoutNode, RemoteSessionSnapshot, SessionId, ShellId};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(super) const JSONRPC: &str = "2.0";

#[derive(Serialize)]
pub(super) struct OutgoingRequest<'a, P> {
    pub(super) jsonrpc: &'static str,
    pub(super) id: &'a str,
    pub(super) method: &'a str,
    pub(super) params: P,
}

/// A JSON-RPC request ID chosen by the relay.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(untagged)]
pub(super) enum RequestId {
    Number(i64),
    Text(String),
}

#[derive(Serialize)]
pub(super) struct OutgoingResult {
    pub(super) jsonrpc: &'static str,
    pub(super) id: RequestId,
    pub(super) result: RemoteResult,
}

#[derive(Serialize)]
pub(super) struct OutgoingError {
    pub(super) jsonrpc: &'static str,
    pub(super) id: RequestId,
    pub(super) error: ErrorBody,
}

#[derive(Serialize)]
pub(super) struct ErrorBody {
    pub(super) code: i64,
    pub(super) message: &'static str,
}

#[derive(Serialize)]
#[serde(untagged)]
pub(super) enum OutgoingResponse {
    Result(Box<OutgoingResult>),
    Error(OutgoingError),
}

/// One message from the relay: a request for this host, or a response to one of ours.
/// `params` stays raw until the method is known (each method has its own parameter type).
#[derive(Deserialize)]
pub(super) struct IncomingMessage {
    pub(super) id: Option<RequestId>,
    pub(super) method: Option<String>,
    #[serde(default)]
    pub(super) params: Value,
    pub(super) result: Option<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct NegotiateParams {
    pub(super) protocol_version: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct HostIdentity<'a> {
    pub(super) host_id: &'a str,
    pub(super) host_generation: &'a str,
}

#[derive(Serialize)]
pub(super) struct Capability {
    id: &'static str,
    version: u32,
}

pub(super) const HOST_CAPABILITIES: &[Capability] = &[
    Capability {
        id: "agent.pi",
        version: 1,
    },
    Capability {
        id: "terminal.pty",
        version: 1,
    },
    Capability {
        id: "workspace.filesystem",
        version: 1,
    },
];

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct HostRegistration<'a> {
    pub(super) protocol_version: u32,
    pub(super) host_id: &'a str,
    pub(super) host_generation: &'a str,
    pub(super) label: &'a str,
    pub(super) host_kind: HostKind,
    pub(super) capabilities: &'static [Capability],
    /// Sessions are synced with `axo.host.sync` after registering (RFD0018).
    pub(super) sessions: [(); 0],
}

/// Results of `axo.remote.*` calls.
#[derive(Serialize)]
#[serde(untagged, rename_all_fields = "camelCase")]
pub(super) enum RemoteResult {
    Session {
        session: RemoteSessionSnapshot,
    },
    SessionClosed {
        closed: bool,
        session_id: SessionId,
        replacement: Option<RemoteSessionSnapshot>,
    },
    ShellCreated {
        host_id: String,
        session_id: SessionId,
        shell_id: ShellId,
    },
    ShellClosed {
        closed: bool,
        host_id: String,
        session_id: SessionId,
        shell_id: ShellId,
    },
    Saved {
        saved: bool,
    },
    Workspaces {
        workspaces: Vec<axo_protocol::RemoteWorkspace>,
    },
    InputAccepted {
        accepted: bool,
        sequence: u64,
    },
    ResizeAccepted {
        accepted: bool,
        rows: u32,
        columns: u32,
    },
    PromptAccepted {
        accepted: bool,
    },
    KeyAccepted {
        accepted: bool,
    },
    /// Whether the turn the stop named was running, and is now stopping.
    Stopped {
        stopped: bool,
    },
    Commands {
        commands: Vec<axo_protocol::PiCommandInfo>,
    },
    Models {
        models: Vec<axo_protocol::PiModelInfo>,
    },
    Restarted {
        restarted: bool,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct KeyParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) key: crate::PiKey,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PromptParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) text: String,
    #[serde(default)]
    pub(super) command_id: Option<crate::CommandId>,
    #[serde(default)]
    pub(super) attachments: axo_protocol::asset::Attachments,
    /// When a working Pi takes it (RFD0033); a follow-up when absent.
    #[serde(default)]
    pub(super) delivery: crate::ClientDelivery,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ModelSetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    #[serde(default)]
    pub(super) model: Option<crate::ModelChoice>,
    #[serde(default)]
    pub(super) thinking_level: Option<axo_protocol::ThinkingLevel>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StopParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    #[serde(default)]
    pub(super) turn_id: Option<crate::TurnId>,
    #[serde(default)]
    pub(super) seen: Option<crate::TurnId>,
    #[serde(default)]
    pub(super) command_ids: Vec<crate::CommandId>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct HostRef {
    pub(super) host_id: String,
    pub(super) host_generation: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TargetParams {
    pub(super) target: HostRef,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct SessionTargetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RenameSessionParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) name: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct WorkspaceSessionTargetParams {
    pub(super) target: HostRef,
    pub(super) workspace_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ShellTargetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct LayoutSetParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) layout: LayoutNode,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TerminalInputParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
    pub(super) sequence: u64,
    pub(super) data: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct TerminalResizeParams {
    pub(super) target: HostRef,
    pub(super) session_id: SessionId,
    pub(super) shell_id: ShellId,
    pub(super) rows: u32,
    pub(super) columns: u32,
}
