//! Addressed work-record RPCs. Cursors fence source, revision, domain and filter.
use crate::{
    model::*,
    rpc::{Destination, Outcome, validate_target},
    runtime::Manager,
    work::*,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum Scope {
    Workspaces,
    #[serde(rename_all = "camelCase")]
    Sessions {
        workspace_id: Option<WorkspaceId>,
    },
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    target: Destination,
    revision: u64,
    scope: Scope,
    #[serde(deserialize_with = "crate::model::deserialize_uuid")]
    after: uuid::Uuid,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceDirectories {
    target: Destination,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspacePage {
    target: Destination,
    #[serde(default, deserialize_with = "workspace_cursor")]
    cursor: Option<Cursor>,
    #[serde(default = "page_limit", deserialize_with = "bounded_page_limit")]
    limit: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionPage {
    target: Destination,
    #[serde(default, deserialize_with = "crate::rpc::non_null_option")]
    workspace_id: Option<WorkspaceId>,
    #[serde(default, deserialize_with = "session_cursor")]
    cursor: Option<Cursor>,
    #[serde(default = "page_limit", deserialize_with = "bounded_page_limit")]
    limit: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkspaceTarget {
    machine_id: MachineId,
    host_generation: HostGeneration,
    workspace_id: WorkspaceId,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionTarget {
    machine_id: MachineId,
    host_generation: HostGeneration,
    workspace_id: WorkspaceId,
    session_id: SessionId,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateWorkspace {
    target: Destination,
    command_id: CommandId,
    expected_revision: u64,
    directory_id: String,
    name: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateLocalWorkspace {
    target: Destination,
    command_id: CommandId,
    expected_revision: u64,
    directory_path: String,
    name: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RenameWorkspace {
    target: WorkspaceTarget,
    command_id: CommandId,
    expected_revision: u64,
    name: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CreateSession {
    target: WorkspaceTarget,
    command_id: CommandId,
    expected_revision: u64,
    name: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RenameSession {
    target: SessionTarget,
    command_id: CommandId,
    expected_revision: u64,
    name: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GetSession {
    target: SessionTarget,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GetCommand {
    target: Destination,
    command_id: CommandId,
}
fn page_limit() -> usize {
    50
}
fn bounded_page_limit<'de, D: serde::Deserializer<'de>>(d: D) -> Result<usize, D::Error> {
    let limit = usize::deserialize(d)?;
    if !(1..=50).contains(&limit) {
        return Err(serde::de::Error::custom("Invalid page limit"));
    }
    Ok(limit)
}
fn workspace_cursor<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Cursor>, D::Error> {
    let cursor = Cursor::deserialize(d)?;
    if cursor.scope != Scope::Workspaces || cursor.revision > MAX_REVISION {
        return Err(serde::de::Error::custom("Invalid workspace cursor"));
    }
    Ok(Some(cursor))
}
fn session_cursor<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Cursor>, D::Error> {
    let cursor = Cursor::deserialize(d)?;
    if !matches!(cursor.scope, Scope::Sessions { .. }) || cursor.revision > MAX_REVISION {
        return Err(serde::de::Error::custom("Invalid session cursor"));
    }
    Ok(Some(cursor))
}
fn parse<T: DeserializeOwned>(params: Option<Value>) -> Result<T, (i32, &'static str)> {
    serde_json::from_value(params.unwrap_or(Value::Null)).map_err(|_| (-32602, "Invalid params"))
}
fn failure(error: WorkError) -> (i32, &'static str) {
    match error {
        WorkError::Invalid => (-32602, "Invalid work intent"),
        WorkError::NotFound => (-32010, "Work record not found"),
        WorkError::Conflict => (-32007, "Command or revision conflict"),
        WorkError::Capacity => (-32006, "Work-record capacity"),
        WorkError::Rejected => (-32010, "Daemon stopping"),
        WorkError::StorageFailed => (-32008, "Work-record storage fenced"),
        WorkError::OutcomeUnknown => (-32004, "Outcome unknown; reconcile commandId"),
    }
}
pub(crate) fn dispatch(
    method: &str,
    params: Option<Value>,
    manager: &Manager,
    machine: MachineId,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Outcome {
    match method {
        "axo.workspace.directories" => workspace_directories(params, manager, machine, profiles),
        "axo.workspace.list" => workspace_page(params, manager, machine),
        "axo.session.list" => session_page(params, manager, machine),
        "axo.session.get" => session_get(params, manager, machine),
        "axo.command.get" => command_get(params, manager, machine),
        "axo.workspace.create"
        | "axo.workspace.createLocal"
        | "axo.workspace.rename"
        | "axo.session.create"
        | "axo.session.rename" => mutate(method, params, manager, machine, profiles),
        _ => Err((-32601, "Method not found")),
    }
}
fn workspace_directories(
    params: Option<Value>,
    manager: &Manager,
    machine: MachineId,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Outcome {
    let request: WorkspaceDirectories = parse(params)?;
    validate_target(
        request.target.machine_id,
        request.target.host_generation,
        manager,
        machine,
    )?;
    let directories = profiles
        .keys()
        .map(|directory_id| json!({"directoryId": directory_id, "name": directory_id}))
        .collect::<Vec<_>>();
    Ok(json!({"hostGeneration": manager.generation, "directories": directories}))
}

struct Page<T> {
    records: Vec<T>,
    next: Option<Cursor>,
}
fn page<T>(
    records: Vec<(uuid::Uuid, T)>,
    cursor: Option<Cursor>,
    target: Destination,
    revision: u64,
    scope: Scope,
    limit: usize,
) -> Result<Page<T>, (i32, &'static str)> {
    if limit == 0 || limit > 50 {
        return Err((-32602, "Invalid page limit"));
    }
    if cursor.as_ref().is_some_and(|c| c.revision > MAX_REVISION) {
        return Err((-32602, "Invalid cursor revision"));
    }
    if let Some(cursor) = &cursor
        && (cursor.target != target
            || cursor.revision != revision
            || cursor.scope != scope
            || !records.iter().any(|(id, _)| *id == cursor.after))
    {
        return Err((-32002, "Stale observation cursor"));
    }
    let mut remaining = records
        .into_iter()
        .filter(|(id, _)| cursor.as_ref().is_none_or(|c| *id > c.after));
    let selected: Vec<_> = remaining.by_ref().take(limit).collect();
    let next = remaining.next().and_then(|_| {
        selected.last().map(|(after, _)| Cursor {
            target,
            revision,
            scope,
            after: *after,
        })
    });
    Ok(Page {
        records: selected.into_iter().map(|(_, record)| record).collect(),
        next,
    })
}
fn workspace_page(params: Option<Value>, manager: &Manager, machine: MachineId) -> Outcome {
    let params: WorkspacePage = parse(params)?;
    validate_target(
        params.target.machine_id,
        params.target.host_generation,
        manager,
        machine,
    )?;
    let store = manager.work.lock().unwrap();
    let revision = store.revision();
    let records = store
        .workspaces()
        .into_iter()
        .map(|w| (w.workspace_id.as_uuid(), w))
        .collect();
    let page = page(
        records,
        params.cursor,
        params.target,
        revision,
        Scope::Workspaces,
        params.limit,
    )?;
    Ok(
        json!({"hostGeneration":manager.generation,"revision":revision,"workspaces":page.records,"next":page.next}),
    )
}
fn session_page(params: Option<Value>, manager: &Manager, machine: MachineId) -> Outcome {
    let params: SessionPage = parse(params)?;
    validate_target(
        params.target.machine_id,
        params.target.host_generation,
        manager,
        machine,
    )?;
    let (revision, records) = {
        let store = manager.work.lock().unwrap();
        (
            store.revision(),
            store.sessions(params.workspace_id).map_err(failure)?,
        )
    };
    let records = records
        .into_iter()
        .map(|s| (s.session_id.as_uuid(), s))
        .collect();
    let page = page(
        records,
        params.cursor,
        params.target,
        revision,
        Scope::Sessions {
            workspace_id: params.workspace_id,
        },
        params.limit,
    )?;
    let runtimes = manager.list();
    let mut sessions = Vec::new();
    let mut bytes = 0;
    let mut last = None;
    let mut next = page.next;
    for session in page.records {
        let id = session.session_id.as_uuid();
        let view = session_view(session, &runtimes, manager);
        let size = serde_json::to_vec(&view)
            .map_err(|_| (-32006, "Session projection unavailable"))?
            .len();
        if bytes + size > 48 * 1024 {
            let after = last.ok_or((-32006, "Session projection capacity"))?;
            next = Some(Cursor {
                target: params.target,
                revision,
                scope: Scope::Sessions {
                    workspace_id: params.workspace_id,
                },
                after,
            });
            break;
        }
        bytes += size;
        last = Some(id);
        sessions.push(view);
    }
    Ok(
        json!({"hostGeneration":manager.generation,"revision":revision,"sessions":sessions,"next":next}),
    )
}
fn session_get(params: Option<Value>, manager: &Manager, machine: MachineId) -> Outcome {
    let params: GetSession = parse(params)?;
    validate_target(
        params.target.machine_id,
        params.target.host_generation,
        manager,
        machine,
    )?;
    let (revision, session) = {
        let store = manager.work.lock().unwrap();
        (
            store.revision(),
            store
                .session(params.target.workspace_id, params.target.session_id)
                .map_err(failure)?,
        )
    };
    Ok(
        json!({"hostGeneration":manager.generation,"revision":revision,"session":session_view(session, &manager.list(), manager)}),
    )
}
fn session_view(session: SessionRecord, runtimes: &[TerminalSnapshot], manager: &Manager) -> Value {
    let runtime = runtimes.iter().find(|r| {
        r.runtime.target.session_id == session.session_id
            && r.runtime.target.pane_id == session.pi_pane_id
    });
    let binding = manager.managed.lock().unwrap().binding(session.session_id);
    let admission = binding
        .as_ref()
        .map_or(crate::managed::Admission::NotAdmitted, |binding| {
            crate::managed::admission(manager, session.session_id, Some(binding.runtime))
        });
    let chat_id = binding.map(|binding| binding.chat_id);
    json!({"sessionId":session.session_id,"workspaceId":session.workspace_id,"name":session.name,"nameSource":"manual","pi":{"paneId":session.pi_pane_id,"chatId":chat_id,"admission":admission},"runtime":runtime,"shellPanes":crate::panes::session_views(session.session_id, manager)})
}
fn command_get(params: Option<Value>, manager: &Manager, machine: MachineId) -> Outcome {
    let params: GetCommand = parse(params)?;
    validate_target(
        params.target.machine_id,
        params.target.host_generation,
        manager,
        machine,
    )?;
    Ok(
        json!({"hostGeneration":manager.generation,"receipt":manager.command_receipt(params.command_id)}),
    )
}
struct WorkCommand {
    target: Destination,
    command: CommandId,
    intent: WorkIntent,
}
fn work_command(method: &str, params: Option<Value>) -> Result<WorkCommand, (i32, &'static str)> {
    Ok(match method {
        "axo.workspace.create" => {
            let p: CreateWorkspace = parse(params)?;
            WorkCommand {
                target: p.target,
                command: p.command_id,
                intent: WorkIntent::CreateWorkspace {
                    directory_id: p.directory_id,
                    name: p.name,
                    expected_revision: p.expected_revision,
                },
            }
        }
        "axo.workspace.createLocal" => {
            let p: CreateLocalWorkspace = parse(params)?;
            WorkCommand {
                target: p.target,
                command: p.command_id,
                intent: WorkIntent::CreateLocalWorkspace {
                    directory: LocalDirectoryPath::parse(p.directory_path).map_err(failure)?,
                    name: p.name,
                    expected_revision: p.expected_revision,
                },
            }
        }
        "axo.workspace.rename" => {
            let p: RenameWorkspace = parse(params)?;
            WorkCommand {
                target: Destination {
                    machine_id: p.target.machine_id,
                    host_generation: p.target.host_generation,
                },
                command: p.command_id,
                intent: WorkIntent::RenameWorkspace {
                    workspace_id: p.target.workspace_id,
                    name: p.name,
                    expected_revision: p.expected_revision,
                },
            }
        }
        "axo.session.create" => {
            let p: CreateSession = parse(params)?;
            WorkCommand {
                target: Destination {
                    machine_id: p.target.machine_id,
                    host_generation: p.target.host_generation,
                },
                command: p.command_id,
                intent: WorkIntent::CreateSession {
                    workspace_id: p.target.workspace_id,
                    name: p.name,
                    expected_revision: p.expected_revision,
                },
            }
        }
        "axo.session.rename" => {
            let p: RenameSession = parse(params)?;
            WorkCommand {
                target: Destination {
                    machine_id: p.target.machine_id,
                    host_generation: p.target.host_generation,
                },
                command: p.command_id,
                intent: WorkIntent::RenameSession {
                    workspace_id: p.target.workspace_id,
                    session_id: p.target.session_id,
                    name: p.name,
                    expected_revision: p.expected_revision,
                },
            }
        }
        _ => return Err((-32601, "Method not found")),
    })
}
fn mutate(
    method: &str,
    params: Option<Value>,
    manager: &Manager,
    machine: MachineId,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Outcome {
    let request = work_command(method, params)?;
    validate_target(
        request.target.machine_id,
        request.target.host_generation,
        manager,
        machine,
    )?;
    let committed = manager
        .mutate_work(request.command, request.intent, profiles)
        .map_err(failure)?;
    Ok(match committed.record {
        WorkRecord::Workspace(workspace) => {
            json!({"hostGeneration":manager.generation,"revision":committed.revision,"workspace":workspace})
        }
        WorkRecord::Session(session) => {
            json!({"hostGeneration":manager.generation,"revision":committed.revision,"session":session_view(session, &manager.list(), manager)})
        }
    })
}
