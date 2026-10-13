//! Read-only discovery of committed Pi bindings. No admission, file reads or
//! control dispatch. Missing admission is never permission to launch a writer.
#[cfg(test)]
mod tests;
use super::*;
use crate::{
    pi_control::{ChatId, ControlError, InteractionId, Question, State},
    pi_session::Binding,
};

const MAX_OBSERVATION_BYTES: usize = 48 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BindingTarget {
    machine_id: MachineId,
    host_generation: HostGeneration,
    store_generation: StoreGeneration,
    workspace_id: Option<WorkspaceId>,
    session_id: SessionId,
    pane_id: PaneId,
    runtime: RuntimeRef,
    chat_id: ChatId,
}
impl BindingTarget {
    fn new(scope: &SessionTarget, binding: &Binding) -> Self {
        Self {
            machine_id: scope.machine_id,
            host_generation: scope.host_generation,
            store_generation: scope.store_generation,
            workspace_id: scope.workspace_id,
            session_id: binding.session_id,
            pane_id: binding.pane_id,
            runtime: binding.runtime,
            chat_id: binding.chat_id,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveState {
    title: Option<String>,
    leaf_id: Option<String>,
    busy: bool,
    interaction_id: Option<InteractionId>,
    ui_waits: u16,
    question: Option<Question>,
    pending: bool,
    recovery: bool,
}
impl LiveState {
    fn parse(state: State, binding: &Binding) -> Result<Self, (i32, &'static str)> {
        if state.chat_id != binding.chat_id
            || state.file.as_ref() != Some(&binding.file)
            || state.cwd != binding.directory
        {
            return Err((-32002, "Stale central Pi binding"));
        }
        if state
            .leaf_id
            .as_ref()
            .is_some_and(|id| !bounded_text(id, 128))
            || state.question.as_ref().is_some_and(|question| {
                Some(question.interaction_id) != state.interaction_id
                    || state.ui_waits == 0
                    || !question_text(&question.title, 2000)
                    || question.options.len() < 2
                    || question.options.len() > 8
                    || question.options.iter().enumerate().any(|(index, option)| {
                        !question_text(&option.label, 500)
                            || question.options[..index]
                                .iter()
                                .any(|previous| previous.id == option.id)
                    })
            })
        {
            return Err((-32009, "Invalid central Pi observation"));
        }
        Ok(Self {
            title: state.title,
            leaf_id: state.leaf_id,
            busy: state.busy,
            interaction_id: state.interaction_id,
            ui_waits: state.ui_waits,
            question: state.question,
            pending: state.pending,
            recovery: state.recovery,
        })
    }
}
fn bounded_text(text: &str, bytes: usize) -> bool {
    !text.is_empty() && text.len() <= bytes && !text.chars().any(char::is_control)
}
fn question_text(text: &str, utf16: usize) -> bool {
    !text.is_empty() && text.encode_utf16().count() <= utf16 && !text.contains('\0')
}
#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum Observation {
    NotAdmitted,
    Live {
        target: BindingTarget,
        state: LiveState,
    },
    Stopped {
        target: BindingTarget,
    },
}
fn control_failure(error: ControlError) -> (i32, &'static str) {
    match error {
        ControlError::OutcomeUnknown => (-32009, "Central Pi observation gap"),
        ControlError::Stale => (-32002, "Stale central Pi binding"),
        _ => (-32009, "Central Pi observation unavailable"),
    }
}
fn capture(
    owner: &Controller,
    scope: &SessionTarget,
) -> Result<(u64, Observation), (i32, &'static str)> {
    // Keep the committed graph stable through cached control/native observation.
    // No disk history or IPC request occurs while holding this database guard.
    let database = owner.database.lock().unwrap();
    let revision = database.revision().map_err(failure)?;
    let Some(binding) = database.binding(scope.session_id).map_err(failure)? else {
        return Ok((revision, Observation::NotAdmitted));
    };
    if binding.workspace_id != scope.workspace_id
        || binding.session_id != scope.session_id
        || binding.runtime.target.session_id != binding.session_id
        || binding.runtime.target.pane_id != binding.pane_id
        || !database
            .panes(scope.session_id)
            .map_err(failure)?
            .iter()
            .any(|pane| {
                pane.pane_id == binding.pane_id && pane.present && pane.role == PaneRole::Pi
            })
    {
        return Err((-32002, "Stale central Pi binding"));
    }
    let attempt = database
        .attempt(binding.pane_id)
        .map_err(failure)?
        .ok_or((-32009, "Central Pi writer unproven"))?;
    if attempt.runtime != binding.runtime
        || attempt.command_id != binding.start_command_id
        || attempt.configuration.is_none()
    {
        return Err((-32009, "Central Pi writer unproven"));
    }
    let native = owner.runtime_owner();
    let target = BindingTarget::new(scope, &binding);
    if attempt.phase == AttemptPhase::CompletionProven && native.runtime_completed(binding.runtime)
    {
        return Ok((revision, Observation::Stopped { target }));
    }
    if attempt.phase != AttemptPhase::Admitted || !native.owns_running_runtime(binding.runtime) {
        return Err((-32009, "Central Pi writer unproven"));
    }
    let running = native
        .managed_live
        .lock()
        .unwrap()
        .get(&scope.session_id)
        .cloned()
        .ok_or((-32009, "Central Pi observation unavailable"))?;
    if running.binding != binding {
        return Err((-32002, "Stale central Pi binding"));
    }
    let observed = running.control.current().map_err(control_failure)?;
    if native.owned_running_pid(binding.runtime) != Some(observed.pid) {
        return Err((-32002, "Stale central Pi binding"));
    }
    let state = LiveState::parse(observed, &binding)?;
    // Cached status alone cannot keep a stopped or replaced writer live.
    if !native.owns_running_runtime(binding.runtime) {
        return Err((-32009, "Central Pi writer unproven"));
    }
    Ok((revision, Observation::Live { target, state }))
}
pub(super) fn observe(owner: &Controller, scope: SessionTarget) -> Outcome {
    let (revision, observation) = capture(owner, &scope)?;
    owner.ensure_owner().map_err(failure)?;
    if owner.revision().map_err(failure)? != revision {
        return Err((-32002, "Stale central observation"));
    }
    let body = json!({
        "hostGeneration": scope.host_generation,
        "storeGeneration": owner.generation().map_err(failure)?,
        "revision": revision,
        "value": observation,
    });
    if serde_json::to_vec(&body)
        .map_err(|_| (-32603, "Central encoding failed"))?
        .len()
        > MAX_OBSERVATION_BYTES
    {
        return Err((-32006, "Central Pi observation capacity"));
    }
    Ok(body)
}
