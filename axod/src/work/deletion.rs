//! Durable batch deletion: retain records/history, tombstone catalogs only after exact completion.
use super::*;
use crate::runtime::RuntimeCompletion;
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionAddress {
    #[serde(deserialize_with = "nullable_workspace")]
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeletionTarget {
    pub machine_id: MachineId,
    pub host_generation: HostGeneration,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionDeletionIntent {
    pub target: DeletionTarget,
    pub sessions: Vec<SessionAddress>,
    pub expected_revision: u64,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionDeletionReceipt {
    pub command_id: CommandId,
    pub intent: SessionDeletionIntent,
    pub runtimes: Vec<RuntimeRef>,
    /// Null is durable prepared/unknown, never permission to repeat stop effects.
    #[serde(deserialize_with = "nullable_revision")]
    pub revision: Option<u64>,
}
fn nullable_workspace<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<WorkspaceId>, D::Error> {
    Option::deserialize(d)
}
fn nullable_revision<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
    Option::deserialize(d)
}
impl SessionDeletionIntent {
    pub(crate) fn valid(&self) -> bool {
        !self.sessions.is_empty()
            && self.sessions.len() <= 32
            && self.expected_revision < MAX_REVISION
            && self
                .sessions
                .iter()
                .map(|s| s.session_id)
                .collect::<BTreeSet<_>>()
                .len()
                == self.sessions.len()
    }
}
impl WorkStore {
    pub(crate) fn validate_deletion_runtimes(&self, snapshots: &[TerminalSnapshot]) -> bool {
        self.saved.deletions.values().all(|receipt| {
            let selected = |session| {
                receipt
                    .intent
                    .sessions
                    .iter()
                    .any(|address| address.session_id == session)
            };
            receipt.runtimes.iter().all(|runtime| {
                snapshots.iter().any(|snapshot| {
                    snapshot.runtime == *runtime
                        && (receipt.revision.is_none()
                            || matches!(
                                snapshot.process,
                                ProcessState::Exited { .. } | ProcessState::Failed { .. }
                            ))
                })
            }) && snapshots
                .iter()
                .filter(|snapshot| selected(snapshot.runtime.target.session_id))
                .all(|snapshot| receipt.runtimes.contains(&snapshot.runtime))
        })
    }

    pub(crate) fn deletion_receipt(&self, command: CommandId) -> Option<SessionDeletionReceipt> {
        self.saved.deletions.get(&command).cloned()
    }
    pub(crate) fn deletion_reserves_pane(&self, pane: PaneId) -> bool {
        self.saved.deletions.values().any(|receipt| {
            receipt
                .runtimes
                .iter()
                .any(|runtime| runtime.target.pane_id == pane)
        })
    }
    pub(crate) fn session_deleted(&self, session: SessionId) -> bool {
        self.saved.deletions.values().any(|r| {
            r.revision.is_some() && r.intent.sessions.iter().any(|s| s.session_id == session)
        })
    }
    pub(crate) fn session_deletion_pending(&self, session: SessionId) -> bool {
        self.saved.deletions.values().any(|r| {
            r.revision.is_none() && r.intent.sessions.iter().any(|s| s.session_id == session)
        })
    }
    pub(crate) fn prepare_session_deletion(
        &mut self,
        command: CommandId,
        intent: SessionDeletionIntent,
        runtimes: Vec<RuntimeRef>,
    ) -> Result<SessionDeletionReceipt, WorkError> {
        if self.poisoned {
            return Err(WorkError::StorageFailed);
        }
        if !intent.valid() {
            return Err(WorkError::Invalid);
        }
        if let Some(receipt) = self.saved.deletions.get(&command) {
            return if receipt.intent == intent {
                Ok(receipt.clone())
            } else {
                Err(WorkError::Conflict)
            };
        }
        if self.contains_command(command)
            || self.saved.deletions.values().any(|r| r.revision.is_none())
            || intent.expected_revision != self.saved.revision
        {
            return Err(WorkError::Conflict);
        }
        for session in &intent.sessions {
            self.session(session.workspace_id, session.session_id)?;
        }
        if self.saved.receipts.len() + self.saved.deletions.len() >= MAX_RECEIPTS
            || runtimes.len() > 256
        {
            return Err(WorkError::Capacity);
        }
        let receipt = SessionDeletionReceipt {
            command_id: command,
            intent,
            runtimes,
            revision: None,
        };
        let mut next = self.saved.clone();
        next.deletions.insert(command, receipt.clone());
        self.commit_deletion(next)?;
        Ok(receipt)
    }
    pub(crate) fn finish_session_deletion(
        &mut self,
        command: CommandId,
        completed: &[RuntimeCompletion],
    ) -> Result<SessionDeletionReceipt, WorkError> {
        if self.poisoned {
            return Err(WorkError::StorageFailed);
        }
        let original = self.deletion_receipt(command).ok_or(WorkError::NotFound)?;
        if original.revision.is_some() {
            return Ok(original);
        }
        if original.runtimes.len() != completed.len()
            || original
                .runtimes
                .iter()
                .any(|runtime| !completed.iter().any(|proof| proof.runtime() == *runtime))
        {
            return Err(WorkError::Rejected);
        }
        if self.saved.revision != original.intent.expected_revision {
            return Err(WorkError::Conflict);
        }
        let mut next = self.saved.clone();
        next.revision += 1;
        let receipt = next.deletions.get_mut(&command).unwrap();
        receipt.revision = Some(next.revision);
        let receipt = receipt.clone();
        self.commit_deletion(next)?;
        Ok(receipt)
    }
    fn commit_deletion(&mut self, next: Saved) -> Result<(), WorkError> {
        next.validate().map_err(|_| WorkError::StorageFailed)?;
        let bytes = serde_json::to_vec(&next).map_err(|_| WorkError::StorageFailed)?;
        if bytes.len() > MAX_BYTES {
            return Err(WorkError::Capacity);
        }
        if persist(&self.root, &bytes).is_err() {
            self.poisoned = true;
            return Err(WorkError::OutcomeUnknown);
        }
        self.saved = next;
        Ok(())
    }
}
impl Saved {
    pub(super) fn valid_deletions(&self) -> bool {
        let mut deleted = BTreeSet::new();
        let mut pending = 0;
        for (command, receipt) in &self.deletions {
            if *command != receipt.command_id
                || self.receipts.contains_key(command)
                || !receipt.intent.valid()
                || receipt.runtimes.len() > 256
            {
                return false;
            }
            match receipt.revision {
                Some(revision)
                    if revision == receipt.intent.expected_revision + 1
                        && revision <= self.revision => {}
                None if receipt.intent.expected_revision == self.revision => pending += 1,
                _ => return false,
            }
            for address in &receipt.intent.sessions {
                if !deleted.insert(address.session_id) {
                    return false;
                }
                let Some(session) = self.sessions.get(&address.session_id) else {
                    return false;
                };
                if session.workspace_id != address.workspace_id {
                    return false;
                }
                let created_before = self.receipts.values().any(|work| {
                    if work.committed.revision > receipt.intent.expected_revision {
                        return false;
                    }
                    match (&work.intent, &work.committed.record) {
                        (
                            WorkIntent::CreateSession { .. }
                            | WorkIntent::CreateStandaloneSession { .. }
                            | WorkIntent::CreateStartupSession { .. },
                            WorkRecord::Session(record),
                        ) => record.session_id == address.session_id,
                        (
                            WorkIntent::CreateLocalWorkspace { .. },
                            WorkRecord::WorkspaceSession { session, .. },
                        ) => session.session_id == address.session_id,
                        _ => false,
                    }
                });
                if !created_before || self.receipts.values().any(|work| matches!(work.intent, WorkIntent::RenameSession { session_id, .. } if session_id == address.session_id) && work.committed.revision > receipt.intent.expected_revision) {
                    return false;
                }
            }
            let mut runtimes = Vec::new();
            for runtime in &receipt.runtimes {
                if !receipt
                    .intent
                    .sessions
                    .iter()
                    .any(|s| s.session_id == runtime.target.session_id)
                    || runtimes.contains(runtime)
                {
                    return false;
                }
                runtimes.push(*runtime);
            }
        }
        pending <= 1
    }
}
