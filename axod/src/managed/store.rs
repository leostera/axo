//! Private Pi bindings and mutation dispositions. Never stores message bodies or history.
use crate::{model::*, pi_control::ChatId, private_file::read_private, work::WorkStore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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
    pub pane_id: PaneId,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChatTarget {
    pub machine_id: MachineId,
    pub host_generation: HostGeneration,
    pub runtime_host_generation: HostGeneration,
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
    pub pane_id: PaneId,
    pub runtime_generation: RuntimeGeneration,
    pub chat_id: ChatId,
}
impl ChatTarget {
    pub fn runtime(self) -> RuntimeRef {
        RuntimeRef {
            host_generation: self.runtime_host_generation,
            runtime_generation: self.runtime_generation,
            target: TerminalTarget {
                session_id: self.session_id,
                pane_id: self.pane_id,
            },
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Persistence {
    Fresh,
    #[serde(rename_all = "camelCase")]
    Resume {
        chat_id: ChatId,
        previous_runtime: RuntimeRef,
    },
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum Intent {
    Start {
        target: SessionTarget,
        persistence: Persistence,
    },
    Chat {
        target: ChatTarget,
        operation: Operation,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Operation {
    SendMessage,
    SendSteeringMessage,
    CancelTurn,
    AnswerQuestion,
    SetViewing,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum Disposition {
    Prepared,
    Dispatched,
    #[serde(rename_all = "camelCase")]
    Rejected {
        code: i32,
    },
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Receipt {
    pub command_id: CommandId,
    pub intent: Intent,
    pub fingerprint: String,
    pub preparation_hash: String,
    pub disposition: Disposition,
    pub runtime: Option<RuntimeRef>,
}
#[derive(Clone)]
pub struct Fingerprint {
    value: String,
    preparation_hash: String,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReceiptView {
    pub command_id: CommandId,
    pub intent: Intent,
    pub disposition: Disposition,
    pub runtime: Option<RuntimeRef>,
}
impl Receipt {
    pub fn view(&self) -> ReceiptView {
        ReceiptView {
            command_id: self.command_id,
            intent: self.intent.clone(),
            disposition: self.disposition.clone(),
            runtime: self.runtime,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    pub workspace_id: Option<WorkspaceId>,
    pub session_id: SessionId,
    pub pane_id: PaneId,
    pub chat_id: ChatId,
    pub runtime: RuntimeRef,
    pub file: PathBuf,
    pub directory: PathBuf,
    pub start_command_id: CommandId,
}
impl Binding {
    pub fn target(&self, machine_id: MachineId, host_generation: HostGeneration) -> ChatTarget {
        ChatTarget {
            machine_id,
            host_generation,
            runtime_host_generation: self.runtime.host_generation,
            workspace_id: self.workspace_id,
            session_id: self.session_id,
            pane_id: self.pane_id,
            runtime_generation: self.runtime.runtime_generation,
            chat_id: self.chat_id,
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u16,
    receipts: BTreeMap<CommandId, Receipt>,
    bindings: BTreeMap<SessionId, Binding>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Conflict,
    Capacity,
    StorageFenced,
    OutcomeUnknown,
    Invalid,
}
pub struct Store {
    root: PathBuf,
    saved: Saved,
    fenced: bool,
}
impl Store {
    pub fn open(root: &Path, work: &WorkStore) -> io::Result<Self> {
        let saved: Saved = match read_private(&root.join("pi-state.json"), MAX_BYTES) {
            Ok(raw) => {
                serde_json::from_slice(&raw).map_err(|_| io::Error::other("Invalid Pi state"))?
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Saved {
                version: 1,
                receipts: BTreeMap::new(),
                bindings: BTreeMap::new(),
            },
            Err(error) => return Err(error),
        };
        if !saved.valid(work) {
            return Err(io::Error::other("Invalid Pi state invariants"));
        }
        Ok(Self {
            root: root.to_owned(),
            saved,
            fenced: false,
        })
    }
    pub fn is_fenced(&self) -> bool {
        self.fenced
    }
    pub fn contains_command(&self, id: CommandId) -> bool {
        self.saved.receipts.contains_key(&id)
    }
    pub(crate) fn belongs_to(&self, machine: MachineId) -> bool {
        self.saved
            .receipts
            .values()
            .all(|receipt| match receipt.intent {
                Intent::Start { target, .. } => target.machine_id == machine,
                Intent::Chat { target, .. } => target.machine_id == machine,
            })
    }
    pub fn commands(&self) -> impl Iterator<Item = CommandId> + '_ {
        self.saved.receipts.keys().copied()
    }
    pub fn receipt(&self, id: CommandId) -> Option<Receipt> {
        self.saved.receipts.get(&id).cloned()
    }
    pub fn binding(&self, id: SessionId) -> Option<Binding> {
        self.saved.bindings.get(&id).cloned()
    }
    /// Hash covers normalized intent and transient preparation data. Only the hash is durable.
    pub fn fingerprint<T: Serialize>(
        intent: &Intent,
        preparation: &T,
    ) -> Result<Fingerprint, Error> {
        let raw = serde_json::to_vec(preparation).map_err(|_| Error::Invalid)?;
        let preparation_hash = format!("{:x}", Sha256::digest(raw));
        let raw = serde_json::to_vec(&(intent, &preparation_hash)).map_err(|_| Error::Invalid)?;
        Ok(Fingerprint {
            value: format!("{:x}", Sha256::digest(raw)),
            preparation_hash,
        })
    }
    pub fn reconcile(
        &self,
        id: CommandId,
        intent: &Intent,
        fingerprint: &Fingerprint,
    ) -> Result<Option<Receipt>, Error> {
        match self.saved.receipts.get(&id) {
            Some(receipt)
                if receipt.intent == *intent && receipt.fingerprint == fingerprint.value =>
            {
                Ok(Some(receipt.clone()))
            }
            Some(_) => Err(Error::Conflict),
            None => Ok(None),
        }
    }
    pub fn prepare(
        &mut self,
        id: CommandId,
        intent: Intent,
        fingerprint: Fingerprint,
    ) -> Result<Receipt, Error> {
        if let Some(receipt) = self.reconcile(id, &intent, &fingerprint)? {
            return Ok(receipt);
        }
        if self.fenced {
            return Err(Error::StorageFenced);
        }
        if self.saved.receipts.len() >= 2000 {
            return Err(Error::Capacity);
        }
        let receipt = Receipt {
            command_id: id,
            intent,
            fingerprint: fingerprint.value,
            preparation_hash: fingerprint.preparation_hash,
            disposition: Disposition::Prepared,
            runtime: None,
        };
        let mut next = self.saved.clone();
        next.receipts.insert(id, receipt.clone());
        self.commit(next)?;
        Ok(receipt)
    }
    pub fn finish(
        &mut self,
        id: CommandId,
        disposition: Disposition,
        runtime: Option<RuntimeRef>,
    ) -> Result<Receipt, Error> {
        let mut next = self.saved.clone();
        let receipt = next.receipts.get_mut(&id).ok_or(Error::Invalid)?;
        if receipt.disposition != Disposition::Prepared {
            return Err(Error::Conflict);
        }
        let Intent::Chat { target, .. } = receipt.intent else {
            return Err(Error::Invalid);
        };
        if disposition == Disposition::Prepared || runtime != Some(target.runtime()) {
            return Err(Error::Invalid);
        }
        receipt.disposition = disposition;
        receipt.runtime = runtime;
        let receipt = receipt.clone();
        self.commit(next)?;
        Ok(receipt)
    }
    /// Admission and its original start disposition commit together after actual public Pi binding.
    pub fn admit(&mut self, binding: Binding) -> Result<Receipt, Error> {
        if self.saved.bindings.len() >= 1000
            && !self.saved.bindings.contains_key(&binding.session_id)
        {
            return Err(Error::Capacity);
        }
        let mut next = self.saved.clone();
        let receipt = next
            .receipts
            .get_mut(&binding.start_command_id)
            .ok_or(Error::Invalid)?;
        let Intent::Start {
            target,
            ref persistence,
        } = receipt.intent
        else {
            return Err(Error::Invalid);
        };
        match (persistence, next.bindings.get(&binding.session_id)) {
            (Persistence::Fresh, None) => {}
            (
                Persistence::Resume {
                    chat_id,
                    previous_runtime,
                },
                Some(previous),
            ) if *chat_id == previous.chat_id
                && *previous_runtime == previous.runtime
                && binding.chat_id == previous.chat_id
                && binding.file == previous.file
                && binding.directory == previous.directory => {}
            _ => return Err(Error::Conflict),
        }
        if receipt.disposition != Disposition::Prepared
            || target.workspace_id != binding.workspace_id
            || target.session_id != binding.session_id
            || target.pane_id != binding.pane_id
            || binding.runtime.target.session_id != binding.session_id
            || binding.runtime.target.pane_id != binding.pane_id
            || binding.runtime.host_generation != target.host_generation
        {
            return Err(Error::Conflict);
        }
        if next.bindings.values().any(|other| {
            other.session_id != binding.session_id
                && (other.file == binding.file || other.chat_id == binding.chat_id)
        }) {
            return Err(Error::Conflict);
        }
        receipt.disposition = Disposition::Dispatched;
        receipt.runtime = Some(binding.runtime);
        let receipt = receipt.clone();
        next.bindings.insert(binding.session_id, binding);
        self.commit(next)?;
        Ok(receipt)
    }
    fn commit(&mut self, next: Saved) -> Result<(), Error> {
        if self.fenced {
            return Err(Error::StorageFenced);
        }
        if persist(&self.root, &next).is_err() {
            self.fenced = true;
            return Err(Error::OutcomeUnknown);
        }
        self.saved = next;
        Ok(())
    }
}
impl Saved {
    fn valid(&self, work: &WorkStore) -> bool {
        if self.version != 1 || self.receipts.len() > 2000 || self.bindings.len() > 1000 {
            return false;
        }
        let mut files = std::collections::BTreeSet::new();
        let mut chats = std::collections::BTreeSet::new();
        for (id, receipt) in &self.receipts {
            if receipt.command_id != *id
                || receipt.preparation_hash.len() != 64
                || !receipt
                    .preparation_hash
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
            {
                return false;
            }
            let Ok(raw) = serde_json::to_vec(&(&receipt.intent, &receipt.preparation_hash)) else {
                return false;
            };
            if receipt.fingerprint != format!("{:x}", Sha256::digest(raw)) {
                return false;
            }
            let (workspace, session, pane) = match receipt.intent {
                Intent::Start { target, .. } => {
                    (target.workspace_id, target.session_id, target.pane_id)
                }
                Intent::Chat { target, .. } => {
                    (target.workspace_id, target.session_id, target.pane_id)
                }
            };
            if !work
                .session(workspace, session)
                .is_ok_and(|record| record.pi_pane_id == pane)
            {
                return false;
            }
            if (receipt.disposition == Disposition::Prepared && receipt.runtime.is_some())
                || (receipt.disposition != Disposition::Prepared && receipt.runtime.is_none())
            {
                return false;
            }
            if let Intent::Start {
                persistence:
                    Persistence::Resume {
                        previous_runtime, ..
                    },
                ..
            } = receipt.intent
                && (previous_runtime.target.session_id != session
                    || previous_runtime.target.pane_id != pane)
            {
                return false;
            }
            if let Some(runtime) = receipt.runtime
                && (runtime.target.session_id != session
                    || runtime.target.pane_id != pane
                    || match receipt.intent {
                        Intent::Start { target, .. } => {
                            runtime.host_generation != target.host_generation
                        }
                        Intent::Chat { target, .. } => runtime != target.runtime(),
                    })
            {
                return false;
            }
        }
        for (id, binding) in &self.bindings {
            if *id != binding.session_id
                || !binding.file.is_absolute()
                || !binding.directory.is_absolute()
                || !files.insert(&binding.file)
                || !chats.insert(binding.chat_id)
            {
                return false;
            }
            let Some(receipt) = self.receipts.get(&binding.start_command_id) else {
                return false;
            };
            let Intent::Start { target, .. } = receipt.intent else {
                return false;
            };
            if receipt.disposition != Disposition::Dispatched
                || receipt.runtime != Some(binding.runtime)
                || target.workspace_id != binding.workspace_id
                || target.session_id != binding.session_id
                || target.pane_id != binding.pane_id
            {
                return false;
            }
        }
        true
    }
}
fn persist(root: &Path, saved: &Saved) -> io::Result<()> {
    let bytes = serde_json::to_vec(saved)?;
    if bytes.len() > MAX_BYTES {
        return Err(io::Error::other("Pi state capacity"));
    }
    let temporary = root.join(format!(".pi-state-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, root.join("pi-state.json"))?;
        File::open(root)?.sync_all()
    })();
    let _ = fs::remove_file(temporary);
    result
}
