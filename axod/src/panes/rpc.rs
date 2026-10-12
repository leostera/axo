use super::{
    store::{self, Intent, Receipt, SessionTarget},
    view,
};
use crate::{
    model::*,
    rpc::{Outcome, validate_target},
    runtime::Manager,
    terminal::ErrorCode,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    path::Path,
    thread,
    time::{Duration, Instant},
};
#[derive(Deserialize)]
enum Method {
    #[serde(rename = "axo.session.pane.add")]
    AddPane,
    #[serde(rename = "axo.session.pane.remove")]
    RemovePane,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AddPaneRequest {
    target: SessionTarget,
    command_id: CommandId,
    #[serde(default)]
    profile_id: crate::user_shell::ShellSource,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RemovePaneRequest {
    target: SessionTarget,
    command_id: CommandId,
    pane_id: PaneId,
    #[serde(deserialize_with = "captured_runtime")]
    runtime: Option<RuntimeRef>,
}
fn captured_runtime<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<RuntimeRef>, D::Error> {
    Option::deserialize(d)
}
fn parse<T: serde::de::DeserializeOwned>(params: Option<Value>) -> Result<T, (i32, &'static str)> {
    serde_json::from_value(params.unwrap_or(Value::Null))
        .map_err(|_| (-32602, "Invalid pane params"))
}
pub(crate) fn dispatch(
    method: &str,
    params: Option<Value>,
    manager: &Manager,
    machine: MachineId,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Outcome {
    let method: Method = serde_json::from_value(Value::String(method.into()))
        .map_err(|_| (-32601, "Unsupported pane method"))?;
    let _operation = manager.pane_operation.lock().unwrap();
    match method {
        Method::AddPane => add(parse(params)?, manager, machine, profiles),
        Method::RemovePane => remove(parse(params)?, manager, machine),
    }
}
/// One serialized daemon transition. Missing attachment is never stop authority.
#[cfg(test)]
pub(crate) fn ensure_backing(
    manager: &Manager,
    machine: MachineId,
    session: &crate::work::SessionRecord,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Result<crate::session_lifecycle::Availability, (i32, &'static str)> {
    use crate::session_lifecycle::{Availability, command};
    use store::{Disposition, PaneState};
    let _operation = manager.pane_operation.lock().unwrap();
    let target = SessionTarget {
        machine_id: machine,
        host_generation: manager.generation,
        workspace_id: session.workspace_id,
        session_id: session.session_id,
    };
    destination(target, manager, machine)?;
    {
        let work = manager.work.lock().unwrap();
        if work.is_fenced() || work.session_deletion_pending(session.session_id) {
            return Ok(Availability::Blocked);
        }
    }
    let panes = {
        let store = manager.panes.lock().unwrap();
        if store.is_fenced() {
            return Ok(Availability::Blocked);
        }
        store.session_panes(session.session_id)
    };
    for pane in &panes {
        let runtime = pane
            .runtime
            .or_else(|| manager.pane_command_runtime(pane.add_command));
        if let Some(runtime) = runtime {
            if manager.owns_running_runtime(runtime) && pane.state != PaneState::Closing {
                if pane.state == PaneState::Adding {
                    // Reconcile the accepted original launch, never dispatch another.
                    manager
                        .panes
                        .lock()
                        .unwrap()
                        .finish_add(pane.add_command, Some(runtime), None)
                        .map_err(failure)?;
                }
                return Ok(Availability::Live);
            }
            if !manager.runtime_completed(runtime) {
                return Ok(Availability::Blocked);
            }
        }
        if pane.state == PaneState::Adding {
            return Ok(Availability::Blocked);
        }
    }
    // Retire only completion-proven backing. Independent extra panes remain
    // separate identities; automatic keep-alive guarantees at least one shell.
    let source = if let Some(pane) = panes.first() {
        let runtime = pane
            .runtime
            .or_else(|| manager.pane_command_runtime(pane.add_command));
        if let Some(original) = pane.remove_command {
            let receipt = manager
                .panes
                .lock()
                .unwrap()
                .receipt(original)
                .ok_or((-32008, "Original pane removal unavailable"))?;
            if receipt.disposition == Disposition::Prepared {
                let proof = runtime.and_then(|value| manager.completion_evidence(value));
                manager
                    .panes
                    .lock()
                    .unwrap()
                    .finish_remove(original, proof)
                    .map_err(failure)?;
            } else if receipt.disposition != Disposition::Removed {
                return Ok(Availability::Blocked);
            }
        } else {
            let command_id = command(
                "shell-retire",
                &(machine, session.session_id, pane.pane_id, runtime),
            )?;
            remove(
                RemovePaneRequest {
                    target,
                    command_id,
                    pane_id: pane.pane_id,
                    runtime,
                },
                manager,
                machine,
            )?;
        }
        pane.profile_id.clone()
    } else {
        crate::user_shell::ShellSource::UserLogin
    };
    let lineage = manager
        .panes
        .lock()
        .unwrap()
        .session_lineage(session.session_id);
    let command_id = command("shell-backing", &(machine, session.session_id, &lineage))?;
    add(
        AddPaneRequest {
            target,
            command_id,
            profile_id: source,
        },
        manager,
        machine,
        profiles,
    )?;
    let panes = manager
        .panes
        .lock()
        .unwrap()
        .session_panes(session.session_id);
    if panes.iter().any(|pane| {
        pane.runtime
            .is_some_and(|value| manager.owns_running_runtime(value))
    }) {
        Ok(Availability::Restored)
    } else {
        Ok(Availability::Waiting)
    }
}

fn destination(
    target: SessionTarget,
    manager: &Manager,
    machine: MachineId,
) -> Result<(), (i32, &'static str)> {
    validate_target(target.machine_id, target.host_generation, manager, machine)?;
    manager
        .work
        .lock()
        .unwrap()
        .session(target.workspace_id, target.session_id)
        .map(|_| ())
        .map_err(|_| (-32010, "Session not found"))
}
fn result(receipt: Receipt, manager: &Manager) -> Outcome {
    let pane = manager
        .panes
        .lock()
        .unwrap()
        .pane(receipt.pane_id)
        .ok_or((-32009, "Pane receipt binding unavailable"))?;
    Ok(json!({"hostGeneration":manager.generation,"receipt":receipt,"pane":view(pane, manager)}))
}
fn add(
    request: AddPaneRequest,
    manager: &Manager,
    machine: MachineId,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Outcome {
    destination(request.target, manager, machine)?;
    let intent = Intent::AddPane {
        target: request.target,
        profile_id: request.profile_id.clone(),
    };
    let original = manager
        .panes
        .lock()
        .unwrap()
        .reconcile(request.command_id, &intent)
        .map_err(failure)?;
    if let Some(receipt) = original {
        return result(receipt, manager);
    }
    let context = {
        let work = manager.work.lock().unwrap();
        let session = work
            .session(request.target.workspace_id, request.target.session_id)
            .map_err(|_| (-32010, "Session not found"))?;
        work.execution_context(
            request.target.workspace_id,
            request.target.session_id,
            session.pi_pane_id,
        )
        .map_err(|_| (-32003, "Pane directory unavailable"))?
    };
    let launch = pane_launch(&request.profile_id, &context, manager, profiles)?;
    let receipt = manager
        .prepare_pane(request.command_id, intent)
        .map_err(failure)?;
    let target = TerminalTarget {
        session_id: request.target.session_id,
        pane_id: receipt.pane_id,
    };
    let (runtime, rejection) =
        match manager.start_reserved_pane(request.command_id, target, &launch) {
            Ok(terminal) => (Some(terminal.runtime), None),
            Err(ErrorCode::StorageFailed | ErrorCode::RecoveryRequired) => {
                return Err((-32004, "Pane start outcome unknown; reconcile commandId"));
            }
            Err(reason) => (
                manager.pane_command_runtime(request.command_id),
                Some(reason),
            ),
        };
    let receipt = manager
        .panes
        .lock()
        .unwrap()
        .finish_add(request.command_id, runtime, rejection)
        .map_err(failure)?;
    result(receipt, manager)
}
fn pane_launch(
    source: &crate::user_shell::ShellSource,
    context: &crate::work::ExecutionContext,
    manager: &Manager,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Result<TerminalLaunch, (i32, &'static str)> {
    use crate::{user_shell::ShellSource, work::DirectoryApproval};
    match source {
        ShellSource::UserLogin => {
            // Local selections and captured HOME carry durable directory approval.
            // Configured workspace authority still requires its current approval.
            if let DirectoryApproval::Profile(id) = &context.approval {
                let approved = profiles
                    .get(id)
                    .ok_or((-32003, "Workspace profile not approved"))?;
                if Path::new(&approved.directory).canonicalize().ok().as_ref()
                    != Some(&context.directory)
                {
                    return Err((-32003, "Workspace profile directory mismatch"));
                }
            }
            manager
                .user_shell
                .as_ref()
                .and_then(|shell| shell.launch(&context.directory))
                .ok_or((-32003, "Captured user login shell unavailable"))
        }
        ShellSource::Approved(profile) => {
            let approved = profiles
                .get(profile.id())
                .ok_or((-32003, "Pane profile not approved"))?;
            if Path::new(&approved.directory).canonicalize().ok().as_ref()
                != Some(&context.directory)
            {
                return Err((-32003, "Pane profile directory mismatch"));
            }
            Ok(TerminalLaunch {
                directory: context
                    .directory
                    .to_str()
                    .ok_or((-32003, "Pane directory is not UTF-8"))?
                    .into(),
                argv: approved.argv.clone(),
            })
        }
    }
}

fn remove(request: RemovePaneRequest, manager: &Manager, machine: MachineId) -> Outcome {
    destination(request.target, manager, machine)?;
    let intent = Intent::RemovePane {
        target: request.target,
        pane_id: request.pane_id,
        runtime: request.runtime,
    };
    let original = manager
        .panes
        .lock()
        .unwrap()
        .reconcile(request.command_id, &intent)
        .map_err(failure)?;
    if let Some(receipt) = original {
        return result(receipt, manager);
    }
    if let Some(runtime) = request.runtime {
        if runtime.target.pane_id != request.pane_id
            || runtime.target.session_id != request.target.session_id
        {
            return Err((-32002, "Stale pane runtime"));
        }
        if runtime.host_generation != manager.generation && !manager.runtime_completed(runtime) {
            return Err((-32009, "Historical pane runtime is not proven stopped"));
        }
    }
    let receipt = manager
        .prepare_pane(request.command_id, intent)
        .map_err(failure)?;
    if let Some(runtime) = receipt.runtime {
        if !manager.runtime_completed(runtime) {
            match manager.stop(runtime) {
                Ok(()) | Err(ErrorCode::NotRunning) => (),
                Err(_) => {
                    return Err((
                        -32009,
                        "Pane removal requires recovery; reconcile commandId",
                    ));
                }
            }
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while !manager.runtime_completed(runtime) {
            if Instant::now() >= deadline {
                return Err((
                    -32004,
                    "Pane removal completion unknown; reconcile commandId",
                ));
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
    let completion = receipt
        .runtime
        .and_then(|runtime| manager.completion_evidence(runtime));
    let receipt = manager
        .panes
        .lock()
        .unwrap()
        .finish_remove(request.command_id, completion)
        .map_err(failure)?;
    result(receipt, manager)
}
fn failure(error: store::Error) -> (i32, &'static str) {
    match error {
        store::Error::Conflict => (-32007, "Pane command or lifecycle conflict"),
        store::Error::NotFound => (-32010, "Shell pane not found"),
        store::Error::Capacity => (-32006, "Pane capacity exhausted"),
        store::Error::Fenced => (-32008, "Storage fenced"),
        store::Error::Unknown => (
            -32004,
            "Pane persistence outcome unknown; reconcile commandId",
        ),
    }
}
