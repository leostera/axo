//! Addressed public Pi methods. Generic JSON-RPC params become closed native request types.
use super::{
    projection::{self, Projection},
    *,
};
use crate::{
    pi_control::{ControlError, InteractionId},
    rpc::{Outcome, validate_target},
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::sync::Arc;
#[derive(Clone, Eq, PartialEq, Serialize)]
struct EntryId(String);
#[derive(Clone, Eq, PartialEq, Serialize)]
struct ToolCallId(String);
fn recorded_id<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<String, D::Error> {
    let value = String::deserialize(deserializer)?;
    if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
        return Err(serde::de::Error::custom("Invalid recorded identity"));
    }
    Ok(value)
}
impl<'de> Deserialize<'de> for EntryId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        recorded_id(deserializer).map(Self)
    }
}
impl<'de> Deserialize<'de> for ToolCallId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        recorded_id(deserializer).map(Self)
    }
}
#[derive(Deserialize)]
enum Method {
    #[serde(rename = "axo.session.start")]
    StartSession,
    #[serde(rename = "axo.chat.get")]
    GetChat,
    #[serde(rename = "axo.chat.history")]
    GetChatHistory,
    #[serde(rename = "axo.chat.getToolOutput")]
    GetToolOutput,
    #[serde(rename = "axo.chat.sendMessage")]
    SendMessage,
    #[serde(rename = "axo.chat.sendSteeringMessage")]
    SendSteeringMessage,
    #[serde(rename = "axo.chat.cancelTurn")]
    CancelTurn,
    #[serde(rename = "axo.chat.answerQuestion")]
    AnswerQuestion,
    #[serde(rename = "axo.chat.setViewing")]
    SetViewing,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartSessionRequest {
    command_id: CommandId,
    target: SessionTarget,
    persistence: Persistence,
}
#[derive(Clone, Copy, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ReadMode {
    #[default]
    Live,
    Stopped,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GetChatRequest {
    target: ChatTarget,
    #[serde(default)]
    read_mode: ReadMode,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GetChatHistoryRequest {
    target: ChatTarget,
    #[serde(default)]
    read_mode: ReadMode,
    #[serde(default = "limit")]
    limit: usize,
    #[serde(default, deserialize_with = "crate::rpc::non_null_option")]
    cursor: Option<HistoryCursor>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HistoryCursor {
    target: ChatTarget,
    read_mode: ReadMode,
    leaf_id: Option<EntryId>,
    after: EntryId,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryResult {
    host_generation: HostGeneration,
    read_mode: ReadMode,
    target: ChatTarget,
    leaf_id: Option<String>,
    entries: Vec<Projection>,
    next: Option<HistoryCursor>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SendMessageRequest {
    target: ChatTarget,
    command_id: CommandId,
    text: MessageText,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SendSteeringMessageRequest {
    target: ChatTarget,
    command_id: CommandId,
    interaction_id: InteractionId,
    text: MessageText,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CancelTurnRequest {
    target: ChatTarget,
    command_id: CommandId,
    interaction_id: InteractionId,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AnswerQuestionRequest {
    target: ChatTarget,
    command_id: CommandId,
    interaction_id: InteractionId,
    question_id: crate::pi_control::QuestionId,
    option_id: crate::pi_control::OptionId,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SetViewingRequest {
    target: ChatTarget,
    command_id: CommandId,
    lease_id: uuid::Uuid,
    viewing: bool,
    ttl_seconds: u16,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GetToolOutputRequest {
    target: ChatTarget,
    #[serde(default)]
    read_mode: ReadMode,
    entry_id: EntryId,
    tool_call_id: ToolCallId,
    offset: usize,
    #[serde(default = "tool_limit")]
    limit: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolResult {
    host_generation: HostGeneration,
    read_mode: ReadMode,
    target: ChatTarget,
    entry_id: EntryId,
    tool_call_id: ToolCallId,
    offset: usize,
    text: String,
    next_offset: Option<usize>,
    total_bytes: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    host_generation: HostGeneration,
    read_mode: ReadMode,
    target: ChatTarget,
    admission: Admission,
    busy: bool,
    interaction_id: Option<InteractionId>,
    ui_waits: u16,
    question: Option<crate::pi_control::Question>,
    recovery: bool,
    leaf_id: Option<String>,
    recent_entries: Vec<Projection>,
    viewing_count: usize,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MutationResult {
    host_generation: HostGeneration,
    receipt: ReceiptView,
}
#[derive(Serialize)]
struct MessageText(String);
impl<'de> Deserialize<'de> for MessageText {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        if text.trim().is_empty() || text.trim_start().starts_with('/') || text.len() > 48 * 1024 {
            return Err(serde::de::Error::custom("Invalid message text"));
        }
        Ok(Self(text))
    }
}
fn limit() -> usize {
    50
}
fn tool_limit() -> usize {
    8192
}
fn parse<T: DeserializeOwned>(params: Option<Value>) -> Result<T, (i32, &'static str)> {
    serde_json::from_value(params.unwrap_or(Value::Null)).map_err(|_| (-32602, "Invalid params"))
}
fn encode<T: Serialize>(result: T) -> Outcome {
    serde_json::to_value(result).map_err(|_| (-32004, "Result unavailable; reconcile commandId"))
}
pub(crate) fn dispatch(
    method: &str,
    params: Option<Value>,
    manager: &Manager,
    machine: MachineId,
) -> Outcome {
    let method = Method::deserialize(
        serde::de::value::StrDeserializer::<serde::de::value::Error>::new(method),
    )
    .map_err(|_| (-32601, "Method not found"))?;
    match method {
        Method::StartSession => {
            let request: StartSessionRequest = parse(params)?;
            validate_target(
                request.target.machine_id,
                request.target.host_generation,
                manager,
                machine,
            )?;
            start(
                manager,
                machine,
                request.command_id,
                request.target,
                request.persistence,
            )
        }
        Method::GetChat => get(parse(params)?, manager, machine),
        Method::GetChatHistory => history(parse(params)?, manager, machine),
        Method::GetToolOutput => tool_output(parse(params)?, manager, machine),
        Method::SendMessage => {
            let request: SendMessageRequest = parse(params)?;
            mutate(
                manager,
                machine,
                request.target,
                request.command_id,
                Operation::SendMessage,
                &request.text,
                |running| running.control.send(&request.text.0),
            )
        }
        Method::SendSteeringMessage => {
            let request: SendSteeringMessageRequest = parse(params)?;
            mutate(
                manager,
                machine,
                request.target,
                request.command_id,
                Operation::SendSteeringMessage,
                &(request.interaction_id, &request.text),
                |running| {
                    running
                        .control
                        .steer(request.interaction_id, &request.text.0)
                },
            )
        }
        Method::CancelTurn => {
            let request: CancelTurnRequest = parse(params)?;
            mutate(
                manager,
                machine,
                request.target,
                request.command_id,
                Operation::CancelTurn,
                &request.interaction_id,
                |running| running.control.cancel(request.interaction_id),
            )
        }
        Method::AnswerQuestion => {
            let request: AnswerQuestionRequest = parse(params)?;
            mutate(
                manager,
                machine,
                request.target,
                request.command_id,
                Operation::AnswerQuestion,
                &(
                    request.interaction_id,
                    request.question_id,
                    request.option_id,
                ),
                |running| {
                    running.control.answer(
                        request.interaction_id,
                        request.question_id,
                        request.option_id,
                    )
                },
            )
        }
        Method::SetViewing => {
            let request: SetViewingRequest = parse(params)?;
            if request.lease_id.is_nil()
                || request.lease_id.is_max()
                || !(1..=120).contains(&request.ttl_seconds)
            {
                return Err((-32602, "Invalid viewing lease"));
            }
            mutate(
                manager,
                machine,
                request.target,
                request.command_id,
                Operation::SetViewing,
                &(request.lease_id, request.viewing, request.ttl_seconds),
                |running| {
                    let now = std::time::Instant::now();
                    let mut leases = running.viewing.lock().unwrap();
                    leases.retain(|_, deadline| *deadline > now);
                    if request.viewing {
                        if !leases.contains_key(&request.lease_id) && leases.len() >= 16 {
                            return Err(ControlError::Capacity);
                        }
                        leases.insert(
                            request.lease_id,
                            now + std::time::Duration::from_secs(u64::from(request.ttl_seconds)),
                        );
                    } else {
                        leases.remove(&request.lease_id);
                    }
                    Ok(crate::pi_control::Dispatched)
                },
            )
        }
    }
}
fn live(
    manager: &Manager,
    machine: MachineId,
    target: ChatTarget,
) -> Result<Arc<Running>, (i32, &'static str)> {
    validate_target(target.machine_id, target.host_generation, manager, machine)?;
    manager
        .work
        .lock()
        .unwrap()
        .execution_context(target.workspace_id, target.session_id, target.pane_id)
        .map_err(|_| (-32010, "Work destination not found"))?;
    let running = manager
        .managed_live
        .lock()
        .unwrap()
        .get(&target.session_id)
        .cloned()
        .ok_or((-32009, "Chat runtime not admitted; reads cannot start it"))?;
    if running.binding.runtime != target.runtime()
        || running.binding.chat_id != target.chat_id
        || running.binding.workspace_id != target.workspace_id
        || running.binding.pane_id != target.pane_id
    {
        return Err((-32002, "Stale chat destination"));
    }
    Ok(running)
}
fn canonical(
    manager: &Manager,
    machine: MachineId,
    target: ChatTarget,
    mode: ReadMode,
) -> Result<crate::pi_control::History, (i32, &'static str)> {
    if mode == ReadMode::Live {
        return live(manager, machine, target)?
            .control
            .history()
            .map_err(control_failure);
    }
    let _starting = manager.managed_start.lock().unwrap();
    validate_target(target.machine_id, target.host_generation, manager, machine)?;
    manager
        .work
        .lock()
        .unwrap()
        .execution_context(target.workspace_id, target.session_id, target.pane_id)
        .map_err(|_| (-32010, "Work destination not found"))?;
    let binding = manager
        .managed
        .lock()
        .unwrap()
        .binding(target.session_id)
        .ok_or((-32010, "Canonical binding not found"))?;
    if binding.target(machine, manager.generation) != target {
        return Err((-32002, "Stale stopped canonical destination"));
    }
    if !manager.runtime_completed(target.runtime()) {
        return Err((-32009, "Writer is not proven stopped"));
    }
    super::history::stopped(&binding).map_err(|_| (-32009, "Stopped canonical source unavailable"))
}
fn get(request: GetChatRequest, manager: &Manager, machine: MachineId) -> Outcome {
    if request.read_mode == ReadMode::Stopped {
        let history = canonical(manager, machine, request.target, request.read_mode)?;
        let recent_entries = projection::recent(&history)
            .map_err(|_| (-32009, "Canonical projection unavailable"))?;
        return encode(Snapshot {
            host_generation: manager.generation,
            read_mode: request.read_mode,
            target: request.target,
            admission: admission(
                manager,
                request.target.session_id,
                Some(request.target.runtime()),
            ),
            busy: false,
            interaction_id: None,
            ui_waits: 0,
            question: None,
            recovery: false,
            leaf_id: history.leaf_id,
            recent_entries,
            viewing_count: 0,
        });
    }
    let running = live(manager, machine, request.target)?;
    let state = running.control.get().map_err(control_failure)?;
    let history = running.control.history().map_err(control_failure)?;
    let recent_entries =
        projection::recent(&history).map_err(|_| (-32009, "Canonical projection unavailable"))?;
    encode(Snapshot {
        host_generation: manager.generation,
        read_mode: request.read_mode,
        target: request.target,
        admission: admission(
            manager,
            request.target.session_id,
            Some(request.target.runtime()),
        ),
        busy: state.busy,
        interaction_id: state.interaction_id,
        ui_waits: state.ui_waits,
        question: state.question,
        recovery: state.recovery,
        leaf_id: history.leaf_id,
        recent_entries,
        viewing_count: {
            let mut leases = running.viewing.lock().unwrap();
            leases.retain(|_, deadline| *deadline > std::time::Instant::now());
            leases.len()
        },
    })
}
fn history(request: GetChatHistoryRequest, manager: &Manager, machine: MachineId) -> Outcome {
    if !(1..=50).contains(&request.limit) {
        return Err((-32602, "Invalid history limit"));
    }
    let history = canonical(manager, machine, request.target, request.read_mode)?;
    if let Some(cursor) = &request.cursor
        && (cursor.target != request.target
            || cursor.read_mode != request.read_mode
            || cursor.leaf_id.as_ref().map(|id| &id.0) != history.leaf_id.as_ref())
    {
        return Err((-32002, "Stale canonical branch cursor"));
    }
    let mut offset = 0;
    if let Some(cursor) = &request.cursor {
        offset = history
            .branch
            .iter()
            .position(|entry| {
                projection::project(entry).is_ok_and(|entry| entry.entry_id == cursor.after.0)
            })
            .ok_or((-32002, "Unknown branch anchor"))?
            + 1;
    }
    let mut entries = Vec::new();
    let mut bytes = 0;
    for document in history.branch.iter().skip(offset).take(request.limit) {
        let entry = projection::project(document)
            .map_err(|_| (-32009, "Canonical projection unavailable"))?;
        let size = serde_json::to_vec(&entry)
            .map_err(|_| (-32009, "Canonical projection unavailable"))?
            .len();
        if bytes + size > 48 * 1024 {
            break;
        }
        bytes += size;
        entries.push(entry);
    }
    let more = offset + entries.len() < history.branch.len();
    let next = if more {
        entries.last().map(|entry| HistoryCursor {
            target: request.target,
            read_mode: request.read_mode,
            leaf_id: history.leaf_id.clone().map(EntryId),
            after: EntryId(entry.entry_id.clone()),
        })
    } else {
        None
    };
    if more && entries.is_empty() {
        return Err((-32006, "Canonical entry metadata capacity"));
    }
    encode(HistoryResult {
        host_generation: manager.generation,
        read_mode: request.read_mode,
        target: request.target,
        leaf_id: history.leaf_id,
        entries,
        next,
    })
}
fn tool_output(request: GetToolOutputRequest, manager: &Manager, machine: MachineId) -> Outcome {
    if !(1..=8192).contains(&request.limit) || request.offset > 9_007_199_254_740_991 {
        return Err((-32602, "Invalid tool detail bounds"));
    }
    let history = canonical(manager, machine, request.target, request.read_mode)?;
    let text = projection::tool_text(&history, &request.entry_id.0, &request.tool_call_id.0)
        .map_err(|_| (-32010, "Recorded tool output not found"))?;
    if request.offset > text.len() || !text.is_char_boundary(request.offset) {
        return Err((-32602, "Invalid UTF-8 tool offset"));
    }
    let (part, _) = projection::clip(&text[request.offset..], request.limit);
    if part.is_empty() && request.offset < text.len() {
        return Err((-32602, "Limit cannot hold a UTF-8 scalar"));
    }
    let next_offset =
        (request.offset + part.len() < text.len()).then_some(request.offset + part.len());
    encode(ToolResult {
        host_generation: manager.generation,
        read_mode: request.read_mode,
        target: request.target,
        entry_id: request.entry_id,
        tool_call_id: request.tool_call_id,
        offset: request.offset,
        text: part.to_owned(),
        next_offset,
        total_bytes: text.len(),
    })
}
fn mutate<T: Serialize>(
    manager: &Manager,
    machine: MachineId,
    target: ChatTarget,
    command: CommandId,
    operation: Operation,
    preparation: &T,
    dispatch: impl FnOnce(&Running) -> Result<crate::pi_control::Dispatched, ControlError>,
) -> Outcome {
    validate_target(target.machine_id, target.host_generation, manager, machine)?;
    let intent = Intent::Chat { target, operation };
    let fingerprint = Store::fingerprint(&intent, preparation).map_err(failure)?;
    let existing = manager
        .managed
        .lock()
        .unwrap()
        .reconcile(command, &intent, &fingerprint)
        .map_err(failure)?;
    if let Some(receipt) = existing {
        return encode(MutationResult {
            host_generation: manager.generation,
            receipt: receipt.view(),
        });
    }
    let running = live(manager, machine, target)?;
    match manager
        .prepare_managed(command, intent, fingerprint)
        .map_err(failure)?
    {
        Reservation::Existing(receipt) => {
            return encode(MutationResult {
                host_generation: manager.generation,
                receipt: receipt.view(),
            });
        }
        Reservation::New => (),
    }
    let disposition = match dispatch(&running) {
        Ok(_) => Disposition::Dispatched,
        Err(
            error @ (ControlError::Busy
            | ControlError::Blocked
            | ControlError::Invalid
            | ControlError::Stale
            | ControlError::Capacity
            | ControlError::NotReady
            | ControlError::RecoveryRequired),
        ) => Disposition::Rejected {
            code: control_failure(error).0,
        },
        Err(_) => return Err((-32004, "Dispatch outcome unknown; reconcile commandId")),
    };
    let receipt = manager
        .managed
        .lock()
        .unwrap()
        .finish(command, disposition, Some(target.runtime()))
        .map_err(failure)?;
    encode(MutationResult {
        host_generation: manager.generation,
        receipt: receipt.view(),
    })
}
fn control_failure(error: ControlError) -> (i32, &'static str) {
    match error {
        ControlError::Busy | ControlError::Blocked => (-32010, "Pi delivery state blocks intent"),
        ControlError::Invalid => (-32602, "Invalid Pi intent"),
        ControlError::Stale => (-32002, "Stale Pi interaction or binding"),
        ControlError::Capacity => (-32006, "Pi control capacity"),
        ControlError::NotReady => (-32003, "Pi not admitted for delivery"),
        ControlError::RecoveryRequired => (-32009, "Pi requires reconciliation"),
        ControlError::OutcomeUnknown => (
            -32004,
            "Pi observation or dispatch uncertain; reconcile commandId",
        ),
    }
}
