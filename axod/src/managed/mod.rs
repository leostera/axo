//! Managed ambient Pi authority; work records and canonical Pi files keep distinct owners.
mod history;
mod persistence;
pub(crate) mod policy;
mod projection;
mod rpc;
pub(crate) mod store;
#[cfg(test)]
mod tests;
pub(crate) mod title;
use crate::{model::*, pi_control::Control, runtime::Manager};
use persistence::WriterLease;
use serde::Serialize;
use std::sync::Arc;
use store::*;
pub(crate) struct Running {
    pub binding: Binding,
    pub control: Control,
    _lease: WriterLease,
    viewing: std::sync::Mutex<std::collections::BTreeMap<uuid::Uuid, std::time::Instant>>,
}
pub(crate) enum Reservation {
    Existing(Box<Receipt>),
    New,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Admission {
    NotAdmitted,
    Ready,
    Stopped,
    Failed,
    RecoveryRequired,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StartResult {
    host_generation: HostGeneration,
    receipt: ReceiptView,
    chat: Option<ChatTarget>,
    admission: Admission,
}
pub(crate) use rpc::dispatch;
fn start(
    manager: &Manager,
    machine: MachineId,
    command: CommandId,
    target: SessionTarget,
    persistence: Persistence,
) -> crate::rpc::Outcome {
    let _starting = manager.managed_start.lock().unwrap();
    discard_completed_controls(manager);
    let context = manager
        .work
        .lock()
        .unwrap()
        .execution_context(target.workspace_id, target.session_id, target.pane_id)
        .map_err(|_| (-32010, "Work destination not found"))?;
    let approval = context.approval;
    let directory = context.directory;
    let intent = Intent::Start {
        target,
        persistence: persistence.clone(),
    };
    let fingerprint = Store::fingerprint(&intent, &()).map_err(failure)?;
    let existing = manager
        .managed
        .lock()
        .unwrap()
        .reconcile(command, &intent, &fingerprint)
        .map_err(failure)?;
    if let Some(receipt) = existing {
        return start_result(manager, machine, receipt);
    }
    let policy = manager
        .managed_policy
        .lock()
        .unwrap()
        .clone()
        .ok_or((-32003, "Managed Pi policy unavailable"))?;
    let profile = policy
        .profile(&approval, &directory)
        .map_err(|_| (-32003, "Managed directory policy unavailable"))?;
    let previous = manager.managed.lock().unwrap().binding(target.session_id);
    let mut lease = None;
    let resume = match (&persistence, previous.as_ref()) {
        (Persistence::Fresh, None) => None,
        (
            Persistence::Resume {
                chat_id,
                previous_runtime,
            },
            Some(binding),
        ) if binding.chat_id == *chat_id && binding.runtime == *previous_runtime => {
            if !manager.runtime_completed(binding.runtime) {
                return Err((-32009, "Previous writer is not proven stopped"));
            }
            manager
                .managed_live
                .lock()
                .unwrap()
                .remove(&target.session_id);
            persistence::validate_resume(binding, &directory, &profile.session_directory)
                .map_err(|_| (-32010, "Exact resume binding rejected"))?;
            lease = Some(
                WriterLease::acquire(&binding.file)
                    .map_err(|_| (-32007, "Persistence writer conflict"))?,
            );
            Some(binding.file.clone())
        }
        _ => return Err((-32007, "Persistence intent conflict")),
    };
    let approved = policy
        .launch(&profile, &directory, resume.as_deref())
        .map_err(|_| (-32003, "Ambient Pi dependency or policy unavailable"))?;
    let launch = approved.terminal;
    let sessions = approved.sessions;
    crate::pty::validate_launch(&launch.directory, &launch.argv)
        .map_err(|_| (-32003, "Invalid managed launch policy"))?;
    // The work identities are revalidated after dependency probing, before durable reservation.
    manager
        .work
        .lock()
        .unwrap()
        .execution_context(target.workspace_id, target.session_id, target.pane_id)
        .map_err(|_| (-32002, "Work destination changed"))?;
    match manager
        .prepare_managed(command, intent, fingerprint)
        .map_err(failure)?
    {
        Reservation::Existing(receipt) => return start_result(manager, machine, *receipt),
        Reservation::New => (),
    }
    let native = TerminalTarget {
        session_id: target.session_id,
        pane_id: target.pane_id,
    };
    let (terminal, socket) = manager
        .start_reserved_pi(command, native, &launch)
        .map_err(|error| {
            eprintln!("Managed Pi native admission: {error:?}");
            (-32004, "Start outcome unknown; reconcile commandId")
        })?;
    let ProcessState::Running { pid } = terminal.process else {
        return Err((-32004, "Start outcome unknown; reconcile commandId"));
    };
    let control =
        Control::admit(terminal.runtime, pid, &directory, &sessions, socket).map_err(|error| {
            eprintln!("Managed Pi public capability admission: {error:?}");
            (-32004, "Admission outcome unknown; reconcile commandId")
        })?;
    let state = control
        .current()
        .map_err(|_| (-32004, "Admission outcome unknown; reconcile commandId"))?;
    let file = state
        .file
        .ok_or((-32004, "Canonical binding unavailable"))?;
    if let Some(previous) = &previous
        && (state.chat_id != previous.chat_id || file != previous.file)
    {
        return Err((-32004, "Exact resume admission mismatch"));
    }
    let lease = match lease {
        Some(lease) => lease,
        None => {
            WriterLease::acquire(&file).map_err(|_| (-32004, "Writer admission outcome unknown"))?
        }
    };
    let binding = Binding {
        workspace_id: target.workspace_id,
        session_id: target.session_id,
        pane_id: target.pane_id,
        chat_id: state.chat_id,
        runtime: terminal.runtime,
        file,
        directory,
        start_command_id: command,
    };
    let running = Arc::new(Running {
        binding: binding.clone(),
        control,
        _lease: lease,
        viewing: std::sync::Mutex::new(std::collections::BTreeMap::new()),
    });
    // Retain accepted ownership even if the admission commit has an uncertain outcome.
    manager
        .managed_live
        .lock()
        .unwrap()
        .insert(target.session_id, running);
    let receipt = manager
        .managed
        .lock()
        .unwrap()
        .admit(binding)
        .map_err(failure)?;
    start_result(manager, machine, receipt)
}
fn discard_completed_controls(manager: &Manager) {
    // Never drop a live/uncertain execution endpoint merely because a client or storage failed.
    // Completed native ownership has already proved reap + EOF + original group absence.
    let completed = manager
        .list()
        .into_iter()
        .filter(|terminal| manager.runtime_completed(terminal.runtime))
        .map(|terminal| terminal.runtime)
        .collect::<Vec<_>>();
    manager
        .managed_live
        .lock()
        .unwrap()
        .retain(|_, running| !completed.contains(&running.binding.runtime));
}
fn start_result(manager: &Manager, machine: MachineId, receipt: Receipt) -> crate::rpc::Outcome {
    let Intent::Start { target, .. } = receipt.intent else {
        return Err((-32007, "Command domain conflict"));
    };
    let runtime = receipt
        .runtime
        .or_else(|| match manager.command_receipt(receipt.command_id) {
            Some(crate::work::CommandReceipt::Pi { receipt }) => receipt.runtime,
            _ => None,
        });
    let binding = manager.managed.lock().unwrap().binding(target.session_id);
    let chat = binding.map(|mut binding| {
        if let Some(runtime) = runtime {
            binding.runtime = runtime;
        }
        binding.target(machine, manager.generation)
    });
    let admission = admission(manager, target.session_id, runtime);
    serde_json::to_value(StartResult {
        host_generation: manager.generation,
        receipt: receipt.view(),
        chat,
        admission,
    })
    .map_err(|_| (-32004, "Result unavailable; reconcile commandId"))
}
pub(crate) fn admission(
    manager: &Manager,
    session: SessionId,
    runtime: Option<RuntimeRef>,
) -> Admission {
    let process = runtime.and_then(|runtime| {
        manager
            .list()
            .into_iter()
            .find(|terminal| terminal.runtime == runtime)
            .map(|terminal| terminal.process)
    });
    if matches!(process, Some(ProcessState::Running { .. }))
        && let Some(running) = manager.managed_live.lock().unwrap().get(&session).cloned()
        && Some(running.binding.runtime) == runtime
        && !manager.managed.lock().unwrap().is_fenced()
        && running.control.current().is_ok_and(|state| !state.recovery)
    {
        return Admission::Ready;
    }
    let Some(runtime) = runtime else {
        return Admission::NotAdmitted;
    };
    match process {
        Some(ProcessState::Exited { .. }) if manager.runtime_completed(runtime) => {
            Admission::Stopped
        }
        Some(ProcessState::Failed { .. }) if manager.runtime_completed(runtime) => {
            Admission::Failed
        }
        _ => Admission::RecoveryRequired,
    }
}
fn failure(error: Error) -> (i32, &'static str) {
    match error {
        Error::Conflict => (-32007, "Command or binding conflict"),
        Error::Capacity => (-32006, "Managed capacity"),
        Error::StorageFenced => (-32008, "Managed storage fenced"),
        Error::OutcomeUnknown => (-32004, "Outcome unknown; reconcile commandId"),
        Error::Invalid => (-32602, "Invalid managed intent"),
    }
}
