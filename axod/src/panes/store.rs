//! Shell-pane identities and immutable operation receipts. No geometry, argv or terminal bytes.
use crate::{model::*, private_file::read_private, terminal::ErrorCode, work::WorkStore};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};
const MAX_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionTarget {
    pub machine_id: MachineId,
    pub host_generation: HostGeneration,
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "operation",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Intent {
    AddPane {
        target: SessionTarget,
        profile_id: crate::user_shell::ShellSource,
    },
    RemovePane {
        target: SessionTarget,
        pane_id: PaneId,
        runtime: Option<RuntimeRef>,
    },
}
impl Intent {
    pub fn target(&self) -> SessionTarget {
        match self {
            Self::AddPane { target, .. } | Self::RemovePane { target, .. } => *target,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneState {
    Adding,
    Open,
    Failed,
    Closing,
    Removed,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PaneRecord {
    pub pane_id: PaneId,
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
    pub profile_id: crate::user_shell::ShellSource,
    pub add_command: CommandId,
    pub runtime: Option<RuntimeRef>,
    pub state: PaneState,
    pub remove_command: Option<CommandId>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum Disposition {
    Prepared,
    Added,
    Removed,
    Rejected { reason: ErrorCode },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Receipt {
    pub command_id: CommandId,
    pub intent: Intent,
    pub pane_id: PaneId,
    pub runtime: Option<RuntimeRef>,
    pub disposition: Disposition,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u16,
    panes: BTreeMap<PaneId, PaneRecord>,
    receipts: BTreeMap<CommandId, Receipt>,
}
#[derive(Clone, Copy, Debug)]
pub enum Error {
    Conflict,
    NotFound,
    Capacity,
    Fenced,
    Unknown,
}
pub struct Store {
    root: PathBuf,
    saved: Saved,
    fenced: bool,
}
impl Store {
    pub fn open(root: &Path, work: &WorkStore) -> io::Result<Self> {
        let saved = match read_private(&root.join("pane-state.json"), MAX_BYTES) {
            Ok(bytes) => serde_json::from_slice::<Saved>(&bytes)
                .map_err(|_| io::Error::other("Invalid pane state"))?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Saved {
                version: 1,
                panes: BTreeMap::new(),
                receipts: BTreeMap::new(),
            },
            Err(error) => return Err(error),
        };
        let store = Self {
            root: root.into(),
            saved,
            fenced: false,
        };
        if !store.valid(work) {
            return Err(io::Error::other("Invalid pane state invariants"));
        }
        Ok(store)
    }
    pub fn is_fenced(&self) -> bool {
        self.fenced
    }
    pub fn receipt(&self, command: CommandId) -> Option<Receipt> {
        self.saved.receipts.get(&command).cloned()
    }
    pub fn contains_command(&self, command: CommandId) -> bool {
        self.saved.receipts.contains_key(&command)
    }
    pub fn commands(&self) -> impl Iterator<Item = CommandId> + '_ {
        self.saved.receipts.keys().copied()
    }
    pub fn contains_pane(&self, pane: PaneId) -> bool {
        self.saved.panes.contains_key(&pane)
    }
    #[cfg(test)]
    pub(crate) fn session_lineage(&self, session: SessionId) -> Vec<PaneRecord> {
        self.saved
            .panes
            .values()
            .filter(|pane| pane.session_id == session)
            .cloned()
            .collect()
    }

    pub fn pane(&self, pane: PaneId) -> Option<PaneRecord> {
        self.saved.panes.get(&pane).cloned()
    }
    pub fn session_panes(&self, session: SessionId) -> Vec<PaneRecord> {
        self.saved
            .panes
            .values()
            .filter(|pane| pane.session_id == session && pane.state != PaneState::Removed)
            .cloned()
            .collect()
    }
    pub fn belongs_to(&self, machine: MachineId) -> bool {
        self.saved
            .receipts
            .values()
            .all(|receipt| receipt.intent.target().machine_id == machine)
    }
    pub fn reconcile(&self, command: CommandId, intent: &Intent) -> Result<Option<Receipt>, Error> {
        match self.saved.receipts.get(&command) {
            Some(receipt) if receipt.intent != *intent => Err(Error::Conflict),
            receipt => Ok(receipt.cloned()),
        }
    }
    pub fn prepare(&mut self, command: CommandId, intent: Intent) -> Result<Receipt, Error> {
        if let Some(receipt) = self.reconcile(command, &intent)? {
            return Ok(receipt);
        }
        if self.fenced {
            return Err(Error::Fenced);
        }
        if self.saved.receipts.len() >= 2000 {
            return Err(Error::Capacity);
        }
        let mut next = self.saved.clone();
        let target = intent.target();
        let (pane_id, runtime) = match &intent {
            Intent::AddPane { profile_id, .. } => {
                if next.panes.len() >= 1000 || self.session_panes(target.session_id).len() >= 32 {
                    return Err(Error::Capacity);
                }
                let pane_id = PaneId::new();
                next.panes.insert(
                    pane_id,
                    PaneRecord {
                        pane_id,
                        workspace_id: target.workspace_id,
                        session_id: target.session_id,
                        profile_id: profile_id.clone(),
                        add_command: command,
                        runtime: None,
                        state: PaneState::Adding,
                        remove_command: None,
                    },
                );
                (pane_id, None)
            }
            Intent::RemovePane {
                pane_id, runtime, ..
            } => {
                let pane = next.panes.get_mut(pane_id).ok_or(Error::NotFound)?;
                if pane.workspace_id != target.workspace_id
                    || pane.session_id != target.session_id
                    || pane.runtime != *runtime
                    || !matches!(pane.state, PaneState::Open | PaneState::Failed)
                {
                    return Err(Error::Conflict);
                }
                pane.state = PaneState::Closing;
                pane.remove_command = Some(command);
                (*pane_id, *runtime)
            }
        };
        let receipt = Receipt {
            command_id: command,
            intent,
            pane_id,
            runtime,
            disposition: Disposition::Prepared,
        };
        next.receipts.insert(command, receipt.clone());
        self.commit(next)?;
        Ok(receipt)
    }
    pub fn finish_add(
        &mut self,
        command: CommandId,
        runtime: Option<RuntimeRef>,
        rejection: Option<ErrorCode>,
    ) -> Result<Receipt, Error> {
        let mut next = self.saved.clone();
        let receipt = next.receipts.get_mut(&command).ok_or(Error::NotFound)?;
        if receipt.disposition != Disposition::Prepared
            || !matches!(receipt.intent, Intent::AddPane { .. })
        {
            return Err(Error::Conflict);
        }
        let pane = next
            .panes
            .get_mut(&receipt.pane_id)
            .ok_or(Error::NotFound)?;
        if runtime.is_some_and(|r| {
            r.target.session_id != pane.session_id
                || r.target.pane_id != pane.pane_id
                || r.host_generation != receipt.intent.target().host_generation
        }) || (runtime.is_none() && rejection.is_none())
        {
            return Err(Error::Conflict);
        }
        receipt.runtime = runtime;
        pane.runtime = runtime;
        receipt.disposition = match rejection {
            Some(reason) => Disposition::Rejected { reason },
            None => Disposition::Added,
        };
        pane.state = if rejection.is_some() {
            PaneState::Failed
        } else {
            PaneState::Open
        };
        let result = receipt.clone();
        self.commit(next)?;
        Ok(result)
    }
    pub fn finish_remove(
        &mut self,
        command: CommandId,
        completion: Option<crate::runtime::RuntimeCompletion>,
    ) -> Result<Receipt, Error> {
        let mut next = self.saved.clone();
        let receipt = next.receipts.get_mut(&command).ok_or(Error::NotFound)?;
        if receipt.disposition != Disposition::Prepared
            || !matches!(receipt.intent, Intent::RemovePane { .. })
        {
            return Err(Error::Conflict);
        }
        let pane = next
            .panes
            .get_mut(&receipt.pane_id)
            .ok_or(Error::NotFound)?;
        if pane.state != PaneState::Closing
            || completion.as_ref().map(|proof| proof.runtime()) != receipt.runtime
            || pane.runtime != receipt.runtime
            || pane.remove_command != Some(command)
        {
            return Err(Error::Conflict);
        }
        receipt.disposition = Disposition::Removed;
        pane.state = PaneState::Removed;
        let result = receipt.clone();
        self.commit(next)?;
        Ok(result)
    }
    pub fn validate_runtime(&self, runtimes: &BTreeMap<CommandId, RuntimeRef>) -> bool {
        self.saved
            .receipts
            .values()
            .all(|receipt| match &receipt.intent {
                Intent::AddPane { target, .. } => match runtimes.get(&receipt.command_id) {
                    Some(runtime) => {
                        runtime.target.session_id == target.session_id
                            && runtime.target.pane_id == receipt.pane_id
                            && runtime.host_generation == target.host_generation
                            && receipt.runtime.is_none_or(|recorded| recorded == *runtime)
                    }
                    None => receipt.runtime.is_none() && receipt.disposition != Disposition::Added,
                },
                Intent::RemovePane { .. } => !runtimes.contains_key(&receipt.command_id),
            })
    }
    fn valid(&self, work: &WorkStore) -> bool {
        if self.saved.version != 1
            || self.saved.panes.len() > 1000
            || self.saved.receipts.len() > 2000
        {
            return false;
        }
        for (id, pane) in &self.saved.panes {
            let Ok(_session) = work.recorded_session(pane.workspace_id, pane.session_id) else {
                return false;
            };
            if *id != pane.pane_id
                || work.is_pi_pane(*id)
                || self.session_panes(pane.session_id).len() > 32
            {
                return false;
            }
            let Some(add) = self.saved.receipts.get(&pane.add_command) else {
                return false;
            };
            if add.pane_id != *id
                || add.runtime != pane.runtime
                || !matches!(&add.intent, Intent::AddPane { target, profile_id } if target.workspace_id == pane.workspace_id && target.session_id == pane.session_id && profile_id == &pane.profile_id)
            {
                return false;
            }
            if pane.runtime.is_some_and(|r| {
                r.target.pane_id != *id
                    || r.target.session_id != pane.session_id
                    || r.host_generation != add.intent.target().host_generation
            }) {
                return false;
            }
            let expected = match &add.disposition {
                Disposition::Prepared => PaneState::Adding,
                Disposition::Added => PaneState::Open,
                Disposition::Rejected { reason }
                    if !matches!(
                        reason,
                        ErrorCode::StorageFailed | ErrorCode::RecoveryRequired
                    ) =>
                {
                    PaneState::Failed
                }
                Disposition::Rejected { .. } => return false,
                Disposition::Removed => return false,
            };
            match pane.remove_command {
                None => {
                    if pane.state != expected {
                        return false;
                    }
                }
                Some(command) => {
                    if !matches!(expected, PaneState::Open | PaneState::Failed) {
                        return false;
                    }
                    let Some(remove) = self.saved.receipts.get(&command) else {
                        return false;
                    };
                    if remove.pane_id != *id
                        || remove.runtime != pane.runtime
                        || !matches!(&remove.intent, Intent::RemovePane { target, pane_id, runtime } if *pane_id == *id && *runtime == pane.runtime && target.workspace_id == pane.workspace_id && target.session_id == pane.session_id)
                    {
                        return false;
                    }
                    let state = match remove.disposition {
                        Disposition::Prepared => PaneState::Closing,
                        Disposition::Removed => PaneState::Removed,
                        _ => return false,
                    };
                    if state != pane.state {
                        return false;
                    }
                }
            }
        }
        self.saved.receipts.iter().all(|(command, receipt)| {
            let Some(pane) = self.saved.panes.get(&receipt.pane_id) else {
                return false;
            };
            *command == receipt.command_id
                && match receipt.intent {
                    Intent::AddPane { .. } => pane.add_command == *command,
                    Intent::RemovePane { .. } => pane.remove_command == Some(*command),
                }
        })
    }
    fn commit(&mut self, next: Saved) -> Result<(), Error> {
        if self.fenced {
            return Err(Error::Fenced);
        }
        let bytes = serde_json::to_vec(&next).map_err(|_| Error::Capacity)?;
        if bytes.len() > MAX_BYTES {
            return Err(Error::Capacity);
        }
        let temporary = self
            .root
            .join(format!(".pane-state-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> io::Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, self.root.join("pane-state.json"))?;
            File::open(&self.root)?.sync_all()
        })();
        let _ = fs::remove_file(&temporary);
        if result.is_err() {
            self.fenced = true;
            return Err(Error::Unknown);
        }
        self.saved = next;
        Ok(())
    }
}
