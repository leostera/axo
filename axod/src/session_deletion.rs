use crate::{
    model::*,
    rpc::{Outcome, validate_target},
    runtime::Manager,
    work::{DeletionTarget, SessionAddress, SessionDeletionIntent, WorkError},
};
use serde::Deserialize;
use serde_json::{Value, json};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DeleteRequest {
    command_id: CommandId,
    target: DeletionTarget,
    sessions: Vec<SessionAddress>,
    expected_revision: u64,
}
pub(crate) fn delete(params: Option<Value>, manager: &Manager, machine: MachineId) -> Outcome {
    let request: DeleteRequest = serde_json::from_value(params.unwrap_or(Value::Null))
        .map_err(|_| (-32602, "Invalid session deletion params"))?;
    validate_target(
        request.target.machine_id,
        request.target.host_generation,
        manager,
        machine,
    )?;
    let intent = SessionDeletionIntent {
        target: request.target,
        sessions: request.sessions,
        expected_revision: request.expected_revision,
    };
    let receipt = manager
        .delete_sessions(request.command_id, intent)
        .map_err(|error| match error {
            WorkError::Invalid => (-32602, "Invalid session deletion"),
            WorkError::NotFound => (-32010, "Session not found"),
            WorkError::Conflict => (-32007, "Session deletion revision or command conflict"),
            WorkError::Capacity => (-32006, "Session deletion capacity exhausted"),
            WorkError::Rejected => (-32009, "Session deletion requires durable runtime recovery"),
            WorkError::StorageFailed => (-32008, "Storage fenced"),
            WorkError::OutcomeUnknown => (
                -32004,
                "Session deletion outcome unknown; reconcile commandId",
            ),
        })?;
    Ok(json!({"hostGeneration": manager.generation, "receipt": receipt}))
}
