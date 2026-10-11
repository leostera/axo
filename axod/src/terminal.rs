//! Internal terminal domain events, not a public RPC or legacy transport envelope.
use crate::model::*;
use serde::{Deserialize, Serialize};
pub const OUTPUT_CHUNK: usize = 1024;
pub const BACKLOG_BYTES: usize = 8 * 1024;
pub const MAX_TERMINALS: usize = 128;
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidRequest,
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
    InvalidTransition,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawBacklog {
    pub start_offset: u64,
    pub next_offset: u64,
    pub data: Vec<u8>,
    // Raw bytes are not a VT screen snapshot; incomplete backlog is disclosed.
    pub truncated: bool,
}
#[derive(Clone)]
pub enum Frame {
    Attached {
        attachment: AttachmentRef,
        terminal: TerminalSnapshot,
        backlog: RawBacklog,
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
