//! Central addressed RPC. Store identity fences old caches/commands; local
//! directory authority never becomes remote argv or a legacy catalog fallback.
#[cfg(test)]
mod observation_tests;
mod pi_history;
mod pi_observation;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod transport_tests;
use super::{
    controller::{Availability, Controller},
    *,
};
use crate::{
    model::*,
    rpc::{Call, Destination, Outcome, error, validate_target},
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Target {
    machine_id: MachineId,
    host_generation: HostGeneration,
    store_generation: StoreGeneration,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    target: Target,
    revision: u64,
    domain: Domain,
    after: uuid::Uuid,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum Domain {
    Workspaces,
    Sessions {
        #[serde(deserialize_with = "nullable_workspace")]
        workspace_id: Option<WorkspaceId>,
    },
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Page {
    target: Target,
    #[serde(default, deserialize_with = "crate::rpc::non_null_option")]
    cursor: Option<Cursor>,
    #[serde(default = "limit")]
    limit: usize,
}
fn limit() -> usize {
    8
}
fn nullable_workspace<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<WorkspaceId>, D::Error> {
    Option::deserialize(d)
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionPage {
    target: Target,
    #[serde(deserialize_with = "nullable_workspace")]
    workspace_id: Option<WorkspaceId>,
    #[serde(default, deserialize_with = "crate::rpc::non_null_option")]
    cursor: Option<Cursor>,
    #[serde(default = "limit")]
    limit: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionTarget {
    machine_id: MachineId,
    host_generation: HostGeneration,
    store_generation: StoreGeneration,
    #[serde(deserialize_with = "nullable_workspace")]
    workspace_id: Option<WorkspaceId>,
    session_id: SessionId,
}
impl SessionTarget {
    fn source(&self) -> Target {
        Target {
            machine_id: self.machine_id,
            host_generation: self.host_generation,
            store_generation: self.store_generation,
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Get {
    target: SessionTarget,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceCreate {
    target: Target,
    command_id: CommandId,
    expected_revision: u64,
    name: String,
    directory_path: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionCreate {
    target: Target,
    command_id: CommandId,
    expected_revision: u64,
    #[serde(deserialize_with = "nullable_workspace")]
    workspace_id: Option<WorkspaceId>,
    name: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Lifecycle {
    target: Target,
    command_id: CommandId,
    expected_revision: u64,
    subject: LifecycleTarget,
    lifecycle: DesiredLifecycle,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Add {
    target: SessionTarget,
    command_id: CommandId,
    expected_revision: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Remove {
    target: SessionTarget,
    command_id: CommandId,
    expected_revision: u64,
    pane_id: PaneId,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OperationGet {
    target: Target,
    command_id: CommandId,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Completion {
    target: SessionTarget,
    runtimes: Vec<RuntimeRef>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PaneView {
    desired: DesiredPane,
    availability: Availability,
    last_runtime: Option<RuntimeRef>,
    terminal: Option<TerminalSnapshot>,
}
#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum Readiness {
    Ready,
    Materializing,
    Blocked,
    Stopped,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SessionView {
    session: DesiredSession,
    panes: Vec<PaneView>,
    readiness: Readiness,
}
fn parse<T: DeserializeOwned>(params: Option<Value>) -> Result<T, (i32, &'static str)> {
    serde_json::from_value(params.unwrap_or(Value::Null))
        .map_err(|_| (-32602, "Invalid central params"))
}
fn failure(error: Error) -> (i32, &'static str) {
    match error {
        Error::Invalid => (-32602, "Invalid central intent"),
        Error::NotFound => (-32010, "Central resource not found"),
        Error::Conflict => (-32007, "Central command or revision conflict"),
        Error::Capacity => (-32006, "Central capacity"),
        Error::Stopping => (-32010, "Daemon stopping"),
        _ => (-32008, "Central storage fenced"),
    }
}
fn target(
    target: Target,
    owner: &Controller,
    machine: MachineId,
) -> Result<(), (i32, &'static str)> {
    owner.ensure_owner().map_err(failure)?;
    validate_target(
        target.machine_id,
        target.host_generation,
        &owner.runtime_owner(),
        machine,
    )?;
    if target.store_generation != owner.generation().map_err(failure)? {
        return Err((-32002, "Stale central store"));
    }
    Ok(())
}
fn membership(
    target: &SessionTarget,
    owner: &Controller,
    machine: MachineId,
) -> Result<(), (i32, &'static str)> {
    self::target(target.source(), owner, machine)?;
    if !owner
        .database
        .lock()
        .unwrap()
        .sessions()
        .map_err(failure)?
        .iter()
        .any(|session| {
            session.session_id == target.session_id && session.workspace_id == target.workspace_id
        })
    {
        return Err((-32010, "Central session not found"));
    }
    Ok(())
}
fn session_view(owner: &Controller, session: DesiredSession) -> Result<SessionView, Error> {
    let desired = owner.database.lock().unwrap().panes(session.session_id)?;
    let observations = owner.observations()?;
    let native = owner.runtime_owner();
    let snapshots = native.list();
    let panes: Vec<_> = desired
        .into_iter()
        .filter(|pane| pane.present)
        .map(|desired| {
            let observed = observations
                .iter()
                .find(|observation| observation.pane_id == desired.pane_id);
            let availability = observed.map_or(Availability::Blocked, |observation| {
                observation.availability
            });
            let last_runtime = observed.and_then(|observation| observation.runtime);
            let terminal = if availability == Availability::Live {
                snapshots
                    .iter()
                    .find(|snapshot| {
                        Some(snapshot.runtime) == last_runtime
                            && native.owns_running_runtime(snapshot.runtime)
                    })
                    .cloned()
            } else {
                None
            };
            PaneView {
                desired,
                availability,
                last_runtime,
                terminal,
            }
        })
        .collect();
    let required: Vec<_> = panes.iter().filter(|pane| pane.desired.present).collect();
    let readiness = if session.lifecycle == DesiredLifecycle::Archived
        || required
            .iter()
            .all(|pane| pane.availability == Availability::Stopped)
    {
        Readiness::Stopped
    } else if !required.is_empty()
        && required
            .iter()
            .all(|pane| pane.availability == Availability::Live && pane.terminal.is_some())
    {
        Readiness::Ready
    } else if required
        .iter()
        .any(|pane| pane.availability == Availability::Blocked)
    {
        Readiness::Blocked
    } else {
        Readiness::Materializing
    };
    Ok(SessionView {
        session,
        panes,
        readiness,
    })
}
fn envelope(owner: &Controller, body: Value) -> Outcome {
    owner.ensure_owner().map_err(failure)?;
    Ok(
        json!({"hostGeneration":owner.runtime_owner().generation,"storeGeneration":owner.generation().map_err(failure)?,"revision":owner.revision().map_err(failure)?,"value":body}),
    )
}
fn operation_result(owner: &Controller, operation: Operation) -> Outcome {
    let session = match &operation {
        Operation::CreateWorkspace(value) => Some(value.graph.initial_session.session.session_id),
        Operation::CreateSession(value) | Operation::CreateStandalone(value) => {
            Some(value.graph.session.session_id)
        }
        Operation::AddShell(value) => Some(value.graph.session_id),
        _ => None,
    };
    let observation = match session {
        None => None,
        Some(id) => owner
            .database
            .lock()
            .unwrap()
            .sessions()
            .map_err(failure)?
            .into_iter()
            .find(|session| session.session_id == id),
    };
    let observation = observation
        .map(|session| session_view(owner, session))
        .transpose()
        .map_err(failure)?;
    envelope(owner, json!({"operation":operation,"session":observation}))
}
trait PageRecord {
    fn view(self, owner: &Controller) -> Result<Value, (i32, &'static str)>;
}
impl PageRecord for DesiredWorkspace {
    fn view(self, _: &Controller) -> Result<Value, (i32, &'static str)> {
        serde_json::to_value(self).map_err(|_| (-32603, "Central encoding failed"))
    }
}
impl PageRecord for DesiredSession {
    fn view(self, owner: &Controller) -> Result<Value, (i32, &'static str)> {
        serde_json::to_value(session_view(owner, self).map_err(failure)?)
            .map_err(|_| (-32603, "Central encoding failed"))
    }
}
fn page<T: PageRecord>(
    owner: &Controller,
    target: Target,
    revision: u64,
    domain: Domain,
    cursor: Option<Cursor>,
    limit: usize,
    records: Vec<(uuid::Uuid, T)>,
) -> Outcome {
    if !(1..=50).contains(&limit) {
        return Err((-32602, "Invalid central page limit"));
    }
    if let Some(cursor) = &cursor
        && (cursor.target != target
            || cursor.revision != revision
            || cursor.domain != domain
            || !records.iter().any(|(id, _)| *id == cursor.after))
    {
        return Err((-32002, "Stale central cursor"));
    }
    let mut values = Vec::<Value>::new();
    let mut after = None;
    let mut next = false;
    let mut bytes = 0;
    for (id, record) in records
        .into_iter()
        .filter(|(id, _)| cursor.as_ref().is_none_or(|cursor| *id > cursor.after))
    {
        if values.len() == limit {
            next = true;
            break;
        }
        let value = record.view(owner)?;
        let size = serde_json::to_vec(&value)
            .map_err(|_| (-32603, "Central encoding failed"))?
            .len();
        if bytes + size > 48 * 1024 {
            if values.is_empty() {
                return Err((-32006, "Central page capacity"));
            }
            next = true;
            break;
        }
        bytes += size;
        values.push(value);
        after = Some(id);
    }
    let cursor = if next {
        after.map(|after| Cursor {
            target,
            revision,
            domain,
            after,
        })
    } else {
        None
    };
    // Re-reading revision after collecting views catches concurrent catalog
    // mutation; availability itself remains a bounded last-known observation.
    if owner.revision().map_err(failure)? != revision {
        return Err((-32002, "Stale central observation"));
    }
    envelope(owner, json!({"records":values,"cursor":cursor}))
}
pub(crate) fn dispatch(
    call: Call,
    owner: &Controller,
    machine: MachineId,
    local: bool,
) -> Option<Value> {
    let id = call.id?; // Never mutate from notifications, including null params.
    let mutation = matches!(
        call.method.as_str(),
        "axo.state.workspace.create"
            | "axo.state.session.create"
            | "axo.state.lifecycle.set"
            | "axo.state.pane.add"
            | "axo.state.pane.remove"
    );
    let _gate = mutation.then(|| owner.admission.lock().unwrap());
    let result = route(&call.method, call.params, owner, machine, local);
    Some(match result {
        Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
        Err((code, message)) => error(id, code, message),
    })
}
fn route(
    method: &str,
    params: Option<Value>,
    owner: &Controller,
    machine: MachineId,
    local: bool,
) -> Outcome {
    match method {
        "axo.state.get" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Request {
                target: Destination,
            }
            let request: Request = parse(params)?;
            owner.ensure_owner().map_err(failure)?;
            validate_target(
                request.target.machine_id,
                request.target.host_generation,
                &owner.runtime_owner(),
                machine,
            )?;
            envelope(
                owner,
                json!({"backendCompleteCreation":true,"schemaVersion":SCHEMA_VERSION}),
            )
        }
        "axo.state.workspace.list" => {
            let request: Page = parse(params)?;
            target(request.target, owner, machine)?;
            let (revision, records) = {
                let database = owner.database.lock().unwrap();
                (
                    database.revision().map_err(failure)?,
                    database.workspaces().map_err(failure)?,
                )
            };
            let records = records
                .into_iter()
                .map(|workspace| {
                    (
                        uuid::Uuid::parse_str(&workspace.workspace_id.to_string())
                            .expect("Typed UUID"),
                        workspace,
                    )
                })
                .collect();
            page(
                owner,
                request.target,
                revision,
                Domain::Workspaces,
                request.cursor,
                request.limit,
                records,
            )
        }
        "axo.state.session.list" => {
            let request: SessionPage = parse(params)?;
            target(request.target, owner, machine)?;
            let (revision, sessions) = {
                let database = owner.database.lock().unwrap();
                (
                    database.revision().map_err(failure)?,
                    database.sessions().map_err(failure)?,
                )
            };
            let records = sessions
                .into_iter()
                .filter(|session| session.workspace_id == request.workspace_id)
                .map(|session| {
                    let id =
                        uuid::Uuid::parse_str(&session.session_id.to_string()).expect("Typed UUID");
                    (id, session)
                })
                .collect();
            page(
                owner,
                request.target,
                revision,
                Domain::Sessions {
                    workspace_id: request.workspace_id,
                },
                request.cursor,
                request.limit,
                records,
            )
        }
        "axo.state.chat.history" => {
            let request: pi_history::Input = parse(params)?;
            pi_history::read(owner, machine, request)
        }
        "axo.state.chat.get" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Request {
                target: pi_observation::BindingTarget,
            }
            let request: Request = parse(params)?;
            membership(&request.target.scope(), owner, machine)?;
            pi_observation::get(owner, request.target)
        }
        "axo.state.chat.observe" => {
            let request: Get = parse(params)?;
            membership(&request.target, owner, machine)?;
            pi_observation::observe(owner, request.target)
        }
        "axo.state.session.get" => {
            let request: Get = parse(params)?;
            membership(&request.target, owner, machine)?;
            let session = owner
                .database
                .lock()
                .unwrap()
                .sessions()
                .map_err(failure)?
                .into_iter()
                .find(|session| session.session_id == request.target.session_id)
                .ok_or_else(|| failure(Error::NotFound))?;
            envelope(
                owner,
                serde_json::to_value(session_view(owner, session).map_err(failure)?)
                    .map_err(|_| (-32603, "Central encoding failed"))?,
            )
        }
        "axo.state.workspace.create" if local => {
            let request: WorkspaceCreate = parse(params)?;
            target(request.target, owner, machine)?;
            let directory = ApprovedDirectory::local_selection(Path::new(&request.directory_path))
                .map_err(failure)?;
            let accepted = owner
                .create_workspace(
                    request.command_id,
                    request.expected_revision,
                    &request.name,
                    &directory,
                )
                .map_err(failure)?;
            operation_result(owner, Operation::CreateWorkspace(accepted))
        }
        "axo.state.session.create" => {
            let request: SessionCreate = parse(params)?;
            target(request.target, owner, machine)?;
            let operation = if let Some(workspace) = request.workspace_id {
                Operation::CreateSession(
                    owner
                        .create_session(
                            request.command_id,
                            request.expected_revision,
                            workspace,
                            &request.name,
                        )
                        .map_err(failure)?,
                )
            } else {
                let home = ApprovedHome::capture().map_err(failure)?;
                Operation::CreateStandalone(
                    owner
                        .create_standalone(
                            request.command_id,
                            request.expected_revision,
                            &request.name,
                            &home,
                        )
                        .map_err(failure)?,
                )
            };
            operation_result(owner, operation)
        }
        "axo.state.lifecycle.set" if local => {
            let request: Lifecycle = parse(params)?;
            target(request.target, owner, machine)?;
            operation_result(
                owner,
                Operation::SetLifecycle(
                    owner
                        .set_lifecycle(
                            request.command_id,
                            request.expected_revision,
                            request.subject,
                            request.lifecycle,
                        )
                        .map_err(failure)?,
                ),
            )
        }
        "axo.state.pane.add" if local => {
            let request: Add = parse(params)?;
            membership(&request.target, owner, machine)?;
            operation_result(
                owner,
                Operation::AddShell(
                    owner
                        .add_shell(
                            request.command_id,
                            request.expected_revision,
                            request.target.session_id,
                        )
                        .map_err(failure)?,
                ),
            )
        }
        "axo.state.pane.remove" if local => {
            let request: Remove = parse(params)?;
            membership(&request.target, owner, machine)?;
            operation_result(
                owner,
                Operation::RemoveShell(
                    owner
                        .remove_shell(
                            request.command_id,
                            request.expected_revision,
                            request.target.session_id,
                            request.pane_id,
                        )
                        .map_err(failure)?,
                ),
            )
        }
        "axo.state.operation.get" => {
            let request: OperationGet = parse(params)?;
            target(request.target, owner, machine)?;
            let operation = owner
                .database
                .lock()
                .unwrap()
                .operation(request.command_id)
                .map_err(failure)?;
            match operation {
                Some(operation) => operation_result(owner, operation),
                None => envelope(owner, json!({"operation":null,"session":null})),
            }
        }
        "axo.state.session.completion" if local => {
            let request: Completion = parse(params)?;
            membership(&request.target, owner, machine)?;
            if request.runtimes.is_empty()
                || request.runtimes.len() > 32
                || request.runtimes.iter().enumerate().any(|(index, runtime)| {
                    runtime.target.session_id != request.target.session_id
                        || request.runtimes[..index].contains(runtime)
                })
            {
                return Err((-32602, "Invalid completion scope"));
            }
            let native = owner.runtime_owner();
            let completed: Vec<_> = request
                .runtimes
                .into_iter()
                .filter(|runtime| native.runtime_completed(*runtime))
                .collect();
            envelope(owner, json!({"completed":completed}))
        }
        // Native attachment remains on its exact-runtime transport. Only host
        // observation is reused here; old metadata/start/chat writers are absent.
        "axo.host.get" if local => crate::host::get(params, &owner.runtime_owner(), machine),
        _ => Err((-32601, "Method not found")),
    }
}
