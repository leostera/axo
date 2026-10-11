use super::*;
use crate::work::{SessionDeletionIntent, SessionDeletionReceipt, WorkError};
use std::time::Instant;

impl Manager {
    /// Called under the shared admission lock. Reconciliation can finish the
    /// original tombstone from completion proofs; it never reissues stop effects.
    pub(super) fn settle_session_deletion(
        &self,
        command: CommandId,
    ) -> Option<SessionDeletionReceipt> {
        let receipt = self.work.lock().unwrap().deletion_receipt(command)?;
        if receipt.revision.is_some() {
            return Some(receipt);
        }
        let completed: Option<Vec<_>> = receipt
            .runtimes
            .iter()
            .map(|runtime| self.completion_evidence(*runtime))
            .collect();
        if let Some(completed) = completed {
            let settled = self
                .work
                .lock()
                .unwrap()
                .finish_session_deletion(command, &completed)
                .unwrap_or(receipt);
            if settled.revision.is_some() {
                self.managed_live
                    .lock()
                    .unwrap()
                    .retain(|session, running| {
                        !settled
                            .intent
                            .sessions
                            .iter()
                            .any(|address| address.session_id == *session)
                            || !settled.runtimes.contains(&running.binding.runtime)
                    });
            }
            return Some(settled);
        }
        Some(receipt)
    }
    pub(crate) fn delete_sessions(
        &self,
        command: CommandId,
        intent: SessionDeletionIntent,
    ) -> Result<SessionDeletionReceipt, WorkError> {
        // Same lock order as upgrades. Wait for in-flight Pi/shell admissions;
        // the durable reservation then fences this exact session set from starts.
        let _starting = self.managed_start.lock().unwrap();
        let _panes = self.pane_operation.lock().unwrap();
        let receipt = {
            let _admission = self.admission.lock().unwrap();
            let original = self.work.lock().unwrap().deletion_receipt(command);
            if let Some(original) = original {
                if original.intent != intent {
                    return Err(WorkError::Conflict);
                }
                return Ok(self.settle_session_deletion(command).unwrap_or(original));
            }
            if !intent.valid() {
                return Err(WorkError::Invalid);
            }
            if self.stopping.load(Ordering::SeqCst) {
                return Err(WorkError::Rejected);
            }
            let journal = self.journal.lock().unwrap();
            let managed = self.managed.lock().unwrap();
            let panes = self.panes.lock().unwrap();
            let work = self.work.lock().unwrap();
            if journal.is_fenced() || managed.is_fenced() || panes.is_fenced() || work.is_fenced() {
                return Err(WorkError::StorageFailed);
            }
            if journal.contains_command(command)
                || managed.contains_command(command)
                || panes.contains_command(command)
            {
                return Err(WorkError::Conflict);
            }
            let selected = |session| intent.sessions.iter().any(|s| s.session_id == session);
            // A prepared start lacking durable disposition may have crossed fork.
            // Confirmation is not permission to adopt/signal uncertain processes.
            if managed.commands().filter_map(|id| managed.receipt(id)).any(|receipt|
                matches!(receipt.intent, crate::managed::store::Intent::Start { target, .. } if selected(target.session_id))
                && matches!(receipt.disposition, crate::managed::store::Disposition::Prepared))
                || panes.commands().filter_map(|id| panes.receipt(id)).any(|receipt|
                    matches!(receipt.intent, crate::panes::store::Intent::AddPane { target, .. } if selected(target.session_id))
                    && matches!(receipt.disposition, crate::panes::store::Disposition::Prepared)) {
                return Err(WorkError::Rejected);
            }
            let runtimes: Vec<_> = journal
                .snapshots()
                .into_iter()
                .filter(|snapshot| selected(snapshot.runtime.target.session_id))
                .map(|s| s.runtime)
                .collect();
            drop(journal);
            drop(managed);
            drop(panes);
            drop(work);
            // Proof preflight must precede the durable intent and every signal.
            for runtime in &runtimes {
                if runtime.host_generation != self.generation && !self.runtime_completed(*runtime) {
                    return Err(WorkError::Rejected);
                }
            }
            self.work
                .lock()
                .unwrap()
                .prepare_session_deletion(command, intent, runtimes)?
        };
        for runtime in &receipt.runtimes {
            if !self.runtime_completed(*runtime) {
                match self.stop(*runtime) {
                    Ok(()) | Err(ErrorCode::NotRunning) => (),
                    Err(_) => return Err(WorkError::OutcomeUnknown),
                }
            }
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let _admission = self.admission.lock().unwrap();
            let current = self
                .settle_session_deletion(command)
                .ok_or(WorkError::OutcomeUnknown)?;
            if current.revision.is_some() {
                return Ok(current);
            }
            if Instant::now() >= deadline {
                return Ok(current);
            }
            drop(_admission);
            thread::sleep(Duration::from_millis(20));
        }
    }
}
