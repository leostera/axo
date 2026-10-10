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
    profile_id: String,
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
    if !crate::work::valid_directory_id(&request.profile_id) {
        return Err((-32602, "Invalid approved pane profile"));
    }
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
    let launch = profiles
        .get(&request.profile_id)
        .ok_or((-32003, "Pane profile not approved"))?;
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
    if Path::new(&launch.directory).canonicalize().ok().as_ref() != Some(&context.directory) {
        return Err((-32003, "Pane profile directory mismatch"));
    }
    let launch = TerminalLaunch {
        directory: context
            .directory
            .to_str()
            .ok_or((-32003, "Pane directory is not UTF-8"))?
            .into(),
        argv: launch.argv.clone(),
    };
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
