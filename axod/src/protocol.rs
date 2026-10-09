use crate::model::*;
use serde::{Deserialize, Serialize};

pub const VERSION: u16 = 1;
pub const FRAME_BYTES: u64 = 64 * 1024;
pub const OUTPUT_CHUNK: usize = 1024;
pub const BACKLOG_BYTES: usize = 8 * 1024;
pub const MAX_CLIENTS: usize = 16;
pub const MAX_TERMINALS: usize = 128;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u16,
    pub request_id: u64,
    pub host_generation: Option<HostGeneration>,
    pub command: Command,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Hello {},
    List {
        after: Option<PaneId>,
        #[serde(default = "page_limit")]
        limit: usize,
    },
    Start {
        command_id: CommandId,
        target: TerminalTarget,
        launch: TerminalLaunch,
    },
    Attach {
        runtime: RuntimeRef,
    },
    Input {
        attachment: AttachmentRef,
        data: Vec<u8>,
    },
    Resize {
        attachment: AttachmentRef,
        rows: u16,
        columns: u16,
    },
    Detach {
        attachment: AttachmentRef,
    },
    Stop {
        runtime: RuntimeRef,
    },
}
fn page_limit() -> usize {
    50
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Response {
    Hello {
        host_generation: HostGeneration,
        protocol_version: u16,
    },
    Terminals {
        terminals: Vec<TerminalSnapshot>,
        next: Option<PaneId>,
    },
    Started {
        terminal: TerminalSnapshot,
    },
    Attached {
        attachment: AttachmentRef,
        terminal: TerminalSnapshot,
        backlog: RawBacklog,
    },
    InputAccepted {
        bytes: usize,
    },
    Ok {},
    Error {
        code: ErrorCode,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidRequest,
    IncompatibleVersion,
    StaleHost,
    StaleRuntime,
    StaleAttachment,
    NotFound,
    Conflict,
    Capacity,
    AlreadyAttached,
    NotRunning,
    RecoveryRequired,
    LaunchFailed,
    StorageFailed,
    InputBlocked,
    InvalidSize,
    RequestOutOfOrder,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct RawBacklog {
    pub start_offset: u64,
    pub next_offset: u64,
    pub data: Vec<u8>,
    // This is not a VT snapshot. Truncation is disclosed rather than pretending complete state.
    pub truncated: bool,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "frame", rename_all = "snake_case")]
pub enum Frame {
    Response {
        request_id: u64,
        response: Response,
    },
    Output {
        attachment: AttachmentRef,
        offset: u64,
        data: Vec<u8>,
    },
    Exited {
        attachment: AttachmentRef,
        wait_status: i32,
    },
}
impl From<ErrorCode> for Response {
    fn from(code: ErrorCode) -> Self {
        Self::Error { code }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unknown_fields_and_ambient_selection_are_rejected() {
        assert!(serde_json::from_str::<Command>(r#"{"op":"list","selected":"other"}"#).is_err());
        assert!(serde_json::from_str::<Command>(r#"{"op":"broadcast_prompt"}"#).is_err());
    }
}
