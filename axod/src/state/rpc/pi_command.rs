//! Exact originals and one fresh effect; no offline queue, replay or retarget.
use super::pi_observation::{BindingTarget, SnapshotCapture, capture_action};
use super::*;
use crate::{
    pi_control::{Action, ControlError, InteractionId, OptionId, QuestionId},
    state::submitted::{
        PiCapture, PiCaptureInput, PiDisposition, PiOriginal, PiPermit, PiPreparation, PiRejection,
        PiTerminal,
    },
};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Input {
    target: BindingTarget,
    command_id: CommandId,
    expected_revision: u64,
    action: Action,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Lookup {
    target: Target,
    capture: Input,
}
#[derive(Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum ActionView {
    Send,
    Steer {
        interaction_id: InteractionId,
    },
    Cancel {
        interaction_id: InteractionId,
    },
    Answer {
        interaction_id: InteractionId,
        question_id: QuestionId,
        option_id: OptionId,
    },
}
impl From<&Action> for ActionView {
    fn from(action: &Action) -> Self {
        match action {
            Action::Send { .. } => Self::Send,
            Action::Steer { interaction_id, .. } => Self::Steer {
                interaction_id: *interaction_id,
            },
            Action::Cancel { interaction_id } => Self::Cancel {
                interaction_id: *interaction_id,
            },
            Action::Answer {
                interaction_id,
                question_id,
                option_id,
            } => Self::Answer {
                interaction_id: *interaction_id,
                question_id: *question_id,
                option_id: *option_id,
            },
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OriginalView<'a> {
    command_id: CommandId,
    target: BindingTarget,
    expected_revision: u64,
    accepted_revision: u64,
    configuration: &'a Configuration,
    action: ActionView,
    disposition: &'a PiDisposition,
}
fn view(original: &PiOriginal) -> OriginalView<'_> {
    let input = original.capture.input();
    OriginalView {
        command_id: input.command_id,
        target: BindingTarget::captured(&original.capture),
        expected_revision: input.expected_revision,
        accepted_revision: original.accepted_revision,
        configuration: &input.configuration,
        action: (&input.action).into(),
        disposition: &original.disposition,
    }
}
fn publish(owner: &Controller, original: Option<&PiOriginal>) -> Outcome {
    let body = serde_json::to_value(original.map(view))
        .map_err(|_| (-32603, "Central encoding failed"))?;
    let result = envelope(owner, body)?;
    if serde_json::to_vec(&result)
        .map_err(|_| (-32603, "Central encoding failed"))?
        .len()
        > 48 * 1024
    {
        return Err((-32006, "Central Pi command capacity"));
    }
    Ok(result)
}
pub(super) fn lookup(owner: &Controller, machine: MachineId, request: Lookup) -> Outcome {
    target(request.target, owner, machine)?;
    let scope = request.capture.target.scope();
    if scope.machine_id != machine
        || scope.store_generation != request.target.store_generation
        || request.capture.expected_revision > MAX_REVISION
        || request.capture.target.runtime().host_generation != scope.host_generation
    {
        return Err((-32602, "Invalid central Pi lookup capture"));
    }
    let original = owner
        .database
        .lock()
        .unwrap()
        .pi_original(request.capture.command_id)
        .map_err(failure)?;
    if original
        .as_ref()
        .is_some_and(|original| !matches(original, &request.capture))
    {
        return Err((-32007, "Central Pi command conflict"));
    }
    publish(owner, original.as_ref())
}
fn matches(original: &PiOriginal, request: &Input) -> bool {
    let input = original.capture.input();
    BindingTarget::captured(&original.capture) == request.target
        && input.expected_revision == request.expected_revision
        && input.action == request.action
}
/// Owns the only fresh storage permit and exact current Arc. Broad locks are
/// released before IPC; withdrawal can cause uncertainty, never retargeting.
struct Dispatch {
    permit: PiPermit,
    source: SnapshotCapture,
    target: BindingTarget,
}
enum Preparation {
    New(Box<Dispatch>),
    Original(Box<PiOriginal>),
}
fn prepare(
    owner: &Controller,
    machine: MachineId,
    request: Input,
) -> Result<Preparation, (i32, &'static str)> {
    if request.expected_revision > MAX_REVISION
        || request.target.runtime().host_generation != request.target.scope().host_generation
    {
        return Err((-32602, "Invalid central Pi command"));
    }
    let _gate = owner.admission.lock().unwrap();
    target(request.target.scope().source(), owner, machine)?;
    // Existing captures reconcile independently of current admission, desired
    // state or channel health. Exact bytes/target must match, not just command ID.
    if let Some(original) = owner
        .database
        .lock()
        .unwrap()
        .pi_original(request.command_id)
        .map_err(failure)?
    {
        if !matches(&original, &request) {
            return Err((-32007, "Central Pi command conflict"));
        }
        return Ok(Preparation::Original(Box::new(original)));
    }
    membership(&request.target.scope(), owner, machine)?;
    let source = capture_action(owner, &request.target)?;
    if source.revision() != request.expected_revision {
        return Err((-32007, "Central Pi command revision conflict"));
    }
    let scope = request.target.scope();
    let capture = PiCapture::parse(PiCaptureInput {
        command_id: request.command_id,
        machine_id: scope.machine_id,
        host_generation: scope.host_generation,
        store_generation: scope.store_generation,
        expected_revision: request.expected_revision,
        binding: source.running().binding.clone(),
        configuration: source.configuration().clone(),
        action: request.action,
    })
    .map_err(failure)?;
    match owner
        .database
        .lock()
        .unwrap()
        .prepare_pi(capture)
        .map_err(failure)?
    {
        PiPreparation::New(permit) => Ok(Preparation::New(Box::new(Dispatch {
            permit,
            source,
            target: request.target,
        }))),
        PiPreparation::Original(original) => Ok(Preparation::Original(Box::new(original))),
    }
}
fn rejection(error: ControlError) -> PiTerminal {
    match error {
        ControlError::OutcomeUnknown => PiTerminal::OutcomeUnknown,
        ControlError::NotReady => PiTerminal::Rejected(PiRejection::NotReady),
        ControlError::Capacity => PiTerminal::Rejected(PiRejection::Capacity),
        ControlError::Stale => PiTerminal::Rejected(PiRejection::Stale),
        ControlError::Busy => PiTerminal::Rejected(PiRejection::Busy),
        ControlError::Blocked => PiTerminal::Rejected(PiRejection::Blocked),
        ControlError::Invalid => PiTerminal::Rejected(PiRejection::Invalid),
        ControlError::RecoveryRequired => PiTerminal::Rejected(PiRejection::RecoveryRequired),
    }
}
fn execute(owner: &Controller, dispatch: Dispatch) -> Result<PiOriginal, (i32, &'static str)> {
    let preflight = {
        let _gate = owner.admission.lock().unwrap();
        dispatch.source.check_action(owner, &dispatch.target)
    };
    let outcome = if preflight.is_err() {
        // No request bytes written by this operation. Retain the original even
        // when availability/configuration changed after durable preparation.
        PiTerminal::Rejected(PiRejection::SourceChanged)
    } else {
        let input = dispatch.permit.original().capture.input();
        // No database, admission or native-map mutex spans bounded IPC. The Arc
        // retains the exact original control/lease and cannot select a successor.
        match dispatch
            .source
            .running()
            .control
            .execute(input.command_id, &input.action)
        {
            Ok(proof) => PiTerminal::Dispatched(proof),
            Err(error) => rejection(error),
        }
    };
    // Captured acknowledgement remains about the original source, not current
    // readiness. Freeze may forbid replying but does not rewrite known evidence.
    owner
        .record_pi_result(dispatch.permit, outcome)
        .map_err(failure)
}
pub(super) fn submit(owner: &Controller, machine: MachineId, request: Input) -> Outcome {
    let original = match prepare(owner, machine, request)? {
        Preparation::Original(original) => *original,
        Preparation::New(dispatch) => execute(owner, *dispatch)?,
    };
    publish(owner, Some(&original))
}
#[cfg(test)]
mod tests;
