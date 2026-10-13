//! Vanilla Pi's canonical binding, owned control endpoint and writer lease.
//! No catalog, frontend-start RPC or JSON receipt store lives here.
mod canonical_file;
pub mod history;
pub mod persistence;
pub mod policy;
pub mod projection;
pub(crate) mod session_directory;
pub mod title;
use crate::{
    model::*,
    pi_control::{ChatId, Control},
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CanonicalReadError {
    Unavailable,
    Invalid,
    Changed,
    NotFound,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
    pub pane_id: PaneId,
    pub chat_id: ChatId,
    pub runtime: RuntimeRef,
    pub file: PathBuf,
    pub directory: PathBuf,
    pub start_command_id: CommandId,
}
pub(crate) struct Running {
    pub binding: Binding,
    pub control: Control,
    pub(crate) lease: persistence::WriterLease,
}
