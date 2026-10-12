//! Typed originals, not a catch-all RPC body or a legacy receipt adapter.
use super::*;
use serde_json::Value;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    content = "accepted",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum Operation {
    CreateWorkspace(Accepted<WorkspaceGraph>),
    CreateSession(Accepted<SessionGraph>),
    CreateStandalone(Accepted<SessionGraph>),
    AddShell(Accepted<DesiredPane>),
    RemoveShell(Accepted<PaneId>),
    SetLifecycle(Accepted<LifecycleTarget>),
}
impl Operation {
    pub fn command_id(&self) -> CommandId {
        match self {
            Self::CreateWorkspace(value) => value.command_id,
            Self::CreateSession(value) | Self::CreateStandalone(value) => value.command_id,
            Self::AddShell(value) => value.command_id,
            Self::RemoveShell(value) => value.command_id,
            Self::SetLifecycle(value) => value.command_id,
        }
    }
}
impl Database {
    pub fn operation(&self, command: CommandId) -> Result<Option<Operation>, Error> {
        self.available()?;
        let row: Option<(String, Vec<u8>)> = self
            .connection
            .query_row(
                "SELECT kind,result FROM operations WHERE command_id=?1",
                [command.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((kind, bytes)) = row else {
            return Ok(None);
        };
        let accepted: Value = serde_json::from_slice(&bytes).map_err(|_| Error::Corrupt)?;
        let operation: Operation =
            serde_json::from_value(serde_json::json!({"kind":kind,"accepted":accepted}))
                .map_err(|_| Error::Corrupt)?;
        if operation.command_id() != command {
            return Err(Error::Corrupt);
        }
        Ok(Some(operation))
    }
}
