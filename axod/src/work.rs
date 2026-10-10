//! Private daemon work records. No live Mac registry, Pi history or execution side effects.
use crate::{model::*, private_file::read_private};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_WORKSPACES: usize = 128;
const MAX_SESSIONS: usize = 1000;
const MAX_RECEIPTS: usize = 2000;
pub(crate) const MAX_REVISION: u64 = 9_007_199_254_740_991;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceRecord {
    pub workspace_id: WorkspaceId,
    pub name: String,
    pub directory_id: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionRecord {
    pub session_id: SessionId,
    pub workspace_id: WorkspaceId,
    pub name: String,
    pub pi_pane_id: PaneId,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
pub enum WorkIntent {
    #[serde(rename_all = "camelCase")]
    CreateWorkspace {
        directory_id: String,
        name: String,
        expected_revision: u64,
    },
    #[serde(rename_all = "camelCase")]
    RenameWorkspace {
        workspace_id: WorkspaceId,
        name: String,
        expected_revision: u64,
    },
    #[serde(rename_all = "camelCase")]
    CreateSession {
        workspace_id: WorkspaceId,
        name: String,
        expected_revision: u64,
    },
    #[serde(rename_all = "camelCase")]
    RenameSession {
        workspace_id: WorkspaceId,
        session_id: SessionId,
        name: String,
        expected_revision: u64,
    },
}
impl WorkIntent {
    fn name(&self) -> &str {
        match self {
            Self::CreateWorkspace { name, .. }
            | Self::RenameWorkspace { name, .. }
            | Self::CreateSession { name, .. }
            | Self::RenameSession { name, .. } => name,
        }
    }
    fn expected_revision(&self) -> u64 {
        match self {
            Self::CreateWorkspace {
                expected_revision, ..
            }
            | Self::RenameWorkspace {
                expected_revision, ..
            }
            | Self::CreateSession {
                expected_revision, ..
            }
            | Self::RenameSession {
                expected_revision, ..
            } => *expected_revision,
        }
    }
    fn validate(&self) -> bool {
        valid_name(self.name())
            && self.expected_revision() <= MAX_REVISION
            && match self {
                Self::CreateWorkspace { directory_id, .. } => valid_directory_id(directory_id),
                _ => true,
            }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    content = "record",
    rename_all = "camelCase",
    deny_unknown_fields
)]
pub enum WorkRecord {
    Workspace(WorkspaceRecord),
    Session(SessionRecord),
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommittedWork {
    pub revision: u64,
    pub record: WorkRecord,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    intent: WorkIntent,
    committed: CommittedWork,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Workspace {
    record: WorkspaceRecord,
    directory: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u16,
    revision: u64,
    workspaces: BTreeMap<WorkspaceId, Workspace>,
    sessions: BTreeMap<SessionId, SessionRecord>,
    receipts: BTreeMap<CommandId, Receipt>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkError {
    Invalid,
    NotFound,
    Conflict,
    Capacity,
    Rejected,
    StorageFailed,
    OutcomeUnknown,
}

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CommandReceipt {
    Work {
        committed: CommittedWork,
    },
    Runtime {
        runtime: RuntimeRef,
        terminal: Option<TerminalSnapshot>,
    },
}

pub struct WorkStore {
    root: PathBuf,
    saved: Saved,
    poisoned: bool,
}
impl WorkStore {
    // Journal::open holds the exclusive directory lock before opening this store.
    pub(crate) fn open(root: &Path) -> io::Result<Self> {
        let saved = match read_private(&root.join("work-records.json"), MAX_BYTES) {
            Ok(bytes) => serde_json::from_slice::<Saved>(&bytes)
                .map_err(|_| io::Error::other("Invalid work records"))?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Saved {
                version: 1,
                revision: 0,
                workspaces: BTreeMap::new(),
                sessions: BTreeMap::new(),
                receipts: BTreeMap::new(),
            },
            Err(error) => return Err(error),
        };
        saved.validate()?;
        Ok(Self {
            root: root.to_owned(),
            saved,
            poisoned: false,
        })
    }
    pub(crate) fn is_fenced(&self) -> bool {
        self.poisoned
    }
    pub fn revision(&self) -> u64 {
        self.saved.revision
    }
    pub fn receipt(&self, command: CommandId) -> Option<CommittedWork> {
        self.saved
            .receipts
            .get(&command)
            .map(|r| r.committed.clone())
    }
    pub fn contains_command(&self, command: CommandId) -> bool {
        self.saved.receipts.contains_key(&command)
    }
    pub fn workspaces(&self) -> Vec<WorkspaceRecord> {
        self.saved
            .workspaces
            .values()
            .map(|w| w.record.clone())
            .collect()
    }
    pub fn sessions(
        &self,
        workspace: Option<WorkspaceId>,
    ) -> Result<Vec<SessionRecord>, WorkError> {
        if workspace.is_some_and(|id| !self.saved.workspaces.contains_key(&id)) {
            return Err(WorkError::NotFound);
        }
        Ok(self
            .saved
            .sessions
            .values()
            .filter(|s| workspace.is_none_or(|id| s.workspace_id == id))
            .cloned()
            .collect())
    }
    pub fn session(
        &self,
        workspace: WorkspaceId,
        session: SessionId,
    ) -> Result<SessionRecord, WorkError> {
        self.saved
            .sessions
            .get(&session)
            .filter(|s| s.workspace_id == workspace)
            .cloned()
            .ok_or(WorkError::NotFound)
    }
    pub fn apply(
        &mut self,
        command: CommandId,
        intent: WorkIntent,
        profiles: &BTreeMap<String, TerminalLaunch>,
    ) -> Result<CommittedWork, WorkError> {
        if !intent.validate() {
            return Err(WorkError::Invalid);
        }
        if self.poisoned {
            return Err(WorkError::StorageFailed);
        }
        if let Some(receipt) = self.saved.receipts.get(&command) {
            return if receipt.intent == intent {
                Ok(receipt.committed.clone())
            } else {
                Err(WorkError::Conflict)
            };
        }
        if intent.expected_revision() != self.saved.revision {
            return Err(WorkError::Conflict);
        }
        if self.saved.receipts.len() >= MAX_RECEIPTS || self.saved.revision == MAX_REVISION {
            return Err(WorkError::Capacity);
        }
        let mut next = self.saved.clone();
        let record = next.perform(&intent, profiles)?;
        next.revision += 1;
        let committed = CommittedWork {
            revision: next.revision,
            record,
        };
        next.receipts.insert(
            command,
            Receipt {
                intent,
                committed: committed.clone(),
            },
        );
        let bytes = serde_json::to_vec(&next).map_err(|_| WorkError::StorageFailed)?;
        if bytes.len() > MAX_BYTES {
            return Err(WorkError::Capacity);
        }
        if persist(&self.root, &bytes).is_err() {
            // Rename/directory-sync may already have committed. Do not report rejection or mutate again.
            self.poisoned = true;
            return Err(WorkError::OutcomeUnknown);
        }
        self.saved = next;
        Ok(committed)
    }
}
impl Saved {
    fn perform(
        &mut self,
        intent: &WorkIntent,
        profiles: &BTreeMap<String, TerminalLaunch>,
    ) -> Result<WorkRecord, WorkError> {
        match intent {
            WorkIntent::CreateWorkspace {
                directory_id, name, ..
            } => {
                if self.workspaces.len() >= MAX_WORKSPACES {
                    return Err(WorkError::Capacity);
                }
                let profile = profiles.get(directory_id).ok_or(WorkError::Invalid)?;
                let directory =
                    fs::canonicalize(&profile.directory).map_err(|_| WorkError::Invalid)?;
                if !directory.is_dir() {
                    return Err(WorkError::Invalid);
                }
                let directory = directory.to_str().ok_or(WorkError::Invalid)?.to_owned();
                if !valid_directory(&directory) {
                    return Err(WorkError::Invalid);
                }
                let record = WorkspaceRecord {
                    workspace_id: WorkspaceId::new(),
                    directory_id: directory_id.clone(),
                    name: name.clone(),
                };
                self.workspaces.insert(
                    record.workspace_id,
                    Workspace {
                        record: record.clone(),
                        directory,
                    },
                );
                Ok(WorkRecord::Workspace(record))
            }
            WorkIntent::RenameWorkspace {
                workspace_id, name, ..
            } => {
                let workspace = self
                    .workspaces
                    .get_mut(workspace_id)
                    .ok_or(WorkError::NotFound)?;
                workspace.record.name = name.clone();
                Ok(WorkRecord::Workspace(workspace.record.clone()))
            }
            WorkIntent::CreateSession {
                workspace_id, name, ..
            } => {
                if !self.workspaces.contains_key(workspace_id) {
                    return Err(WorkError::NotFound);
                }
                if self.sessions.len() >= MAX_SESSIONS {
                    return Err(WorkError::Capacity);
                }
                let record = SessionRecord {
                    session_id: SessionId::new(),
                    workspace_id: *workspace_id,
                    name: name.clone(),
                    pi_pane_id: PaneId::new(),
                };
                self.sessions.insert(record.session_id, record.clone());
                Ok(WorkRecord::Session(record))
            }
            WorkIntent::RenameSession {
                workspace_id,
                session_id,
                name,
                ..
            } => {
                let session = self
                    .sessions
                    .get_mut(session_id)
                    .filter(|s| s.workspace_id == *workspace_id)
                    .ok_or(WorkError::NotFound)?;
                session.name = name.clone();
                Ok(WorkRecord::Session(session.clone()))
            }
        }
    }
    fn validate(&self) -> io::Result<()> {
        let valid = self.version == 1
            && self.revision <= MAX_REVISION
            && self.workspaces.len() <= MAX_WORKSPACES
            && self.sessions.len() <= MAX_SESSIONS
            && self.receipts.len() <= MAX_RECEIPTS
            && self.revision == self.receipts.len() as u64
            && self.workspaces.iter().all(|(id, w)| {
                *id == w.record.workspace_id
                    && valid_name(&w.record.name)
                    && valid_directory_id(&w.record.directory_id)
                    && valid_directory(&w.directory)
            })
            && self.sessions.iter().all(|(id, s)| {
                *id == s.session_id
                    && valid_name(&s.name)
                    && self.workspaces.contains_key(&s.workspace_id)
            })
            && self.receipts.values().all(|r| self.valid_receipt(r))
            && self.records_match_receipts();
        let mut revisions: Vec<_> = self
            .receipts
            .values()
            .map(|r| r.committed.revision)
            .collect();
        revisions.sort_unstable();
        let mut panes: Vec<_> = self.sessions.values().map(|s| s.pi_pane_id).collect();
        panes.sort_unstable();
        if !valid
            || !revisions
                .iter()
                .enumerate()
                .all(|(i, r)| *r == i as u64 + 1)
            || panes.windows(2).any(|p| p[0] == p[1])
        {
            return Err(io::Error::other("Invalid work records"));
        }
        Ok(())
    }
    fn records_match_receipts(&self) -> bool {
        let mut receipts: Vec<_> = self.receipts.values().collect();
        receipts.sort_by_key(|r| r.committed.revision);
        let mut workspaces = BTreeMap::new();
        let mut sessions = BTreeMap::new();
        for receipt in receipts {
            match (&receipt.intent, &receipt.committed.record) {
                (WorkIntent::CreateWorkspace { .. }, WorkRecord::Workspace(record)) => {
                    if workspaces
                        .insert(record.workspace_id, record.clone())
                        .is_some()
                    {
                        return false;
                    }
                }
                (
                    WorkIntent::RenameWorkspace { workspace_id, .. },
                    WorkRecord::Workspace(record),
                ) => {
                    if !workspaces.contains_key(workspace_id) {
                        return false;
                    }
                    workspaces.insert(*workspace_id, record.clone());
                }
                (WorkIntent::CreateSession { workspace_id, .. }, WorkRecord::Session(record)) => {
                    if !workspaces.contains_key(workspace_id)
                        || sessions.insert(record.session_id, record.clone()).is_some()
                    {
                        return false;
                    }
                }
                (WorkIntent::RenameSession { session_id, .. }, WorkRecord::Session(record)) => {
                    if !sessions.contains_key(session_id) {
                        return false;
                    }
                    sessions.insert(*session_id, record.clone());
                }
                _ => return false,
            }
        }
        workspaces
            == self
                .workspaces
                .iter()
                .map(|(id, w)| (*id, w.record.clone()))
                .collect()
            && sessions == self.sessions
    }
    fn valid_receipt(&self, receipt: &Receipt) -> bool {
        if !receipt.intent.validate()
            || receipt.intent.expected_revision().checked_add(1) != Some(receipt.committed.revision)
        {
            return false;
        }
        match (&receipt.intent, &receipt.committed.record) {
            (
                WorkIntent::CreateWorkspace {
                    directory_id, name, ..
                },
                WorkRecord::Workspace(record),
            ) => {
                record.name == *name
                    && record.directory_id == *directory_id
                    && self.valid_workspace_result(record)
            }
            (
                WorkIntent::RenameWorkspace {
                    workspace_id, name, ..
                },
                WorkRecord::Workspace(record),
            ) => {
                record.workspace_id == *workspace_id
                    && record.name == *name
                    && self.valid_workspace_result(record)
            }
            (
                WorkIntent::CreateSession {
                    workspace_id, name, ..
                },
                WorkRecord::Session(record),
            ) => {
                record.workspace_id == *workspace_id
                    && record.name == *name
                    && self.valid_session_result(record)
            }
            (
                WorkIntent::RenameSession {
                    workspace_id,
                    session_id,
                    name,
                    ..
                },
                WorkRecord::Session(record),
            ) => {
                record.session_id == *session_id
                    && record.workspace_id == *workspace_id
                    && record.name == *name
                    && self.valid_session_result(record)
            }
            _ => false,
        }
    }
    fn valid_workspace_result(&self, record: &WorkspaceRecord) -> bool {
        self.workspaces
            .get(&record.workspace_id)
            .is_some_and(|w| w.record.directory_id == record.directory_id)
    }
    fn valid_session_result(&self, record: &SessionRecord) -> bool {
        self.sessions.get(&record.session_id).is_some_and(|s| {
            s.workspace_id == record.workspace_id && s.pi_pane_id == record.pi_pane_id
        })
    }
}
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.trim() == name
        && !name.starts_with('\u{feff}')
        && !name.ends_with('\u{feff}')
        && name.chars().count() <= 80
        && !name.chars().any(char::is_control)
}
fn valid_directory_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
fn valid_directory(directory: &str) -> bool {
    Path::new(directory).is_absolute() && directory.len() <= 16384 && !directory.contains('\0')
}
fn persist(root: &Path, bytes: &[u8]) -> io::Result<()> {
    let temporary = root.join(format!(".work-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(bytes)?;
        #[cfg(test)]
        property_tests::checkpoint(property_tests::Stage::BeforeFileSync)?;
        file.sync_all()?;
        #[cfg(test)]
        property_tests::checkpoint(property_tests::Stage::BeforeRename)?;
        fs::rename(&temporary, root.join("work-records.json"))?;
        #[cfg(test)]
        property_tests::checkpoint(property_tests::Stage::AfterRename)?;
        File::open(root)?.sync_all()
    })();
    let _ = fs::remove_file(temporary);
    result
}

#[cfg(test)]
#[path = "work_property_tests.rs"]
mod property_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{journal::Journal, test_support::TestDirectory};
    fn create(name: &str, revision: u64) -> WorkIntent {
        WorkIntent::CreateWorkspace {
            directory_id: "approved".into(),
            name: name.into(),
            expected_revision: revision,
        }
    }
    fn policy(root: &Path) -> BTreeMap<String, TerminalLaunch> {
        BTreeMap::from([(
            "approved".into(),
            TerminalLaunch {
                directory: root.to_str().unwrap().into(),
                argv: vec!["/bin/sh".into()],
            },
        )])
    }
    #[test]
    fn durable_records_and_receipts_reconcile_without_reinterpreting_directory_policy() {
        let root = TestDirectory::new();
        let journal = Journal::open(root.path()).unwrap();
        let mut store = journal.work.lock().unwrap();
        let command = CommandId::new();
        let original = store
            .apply(command, create("Manual", 0), &policy(root.path()))
            .unwrap();
        assert_eq!(
            store
                .apply(command, create("Manual", 0), &BTreeMap::new())
                .unwrap(),
            original
        );
        assert_eq!(
            store.apply(command, create("Changed", 0), &policy(root.path())),
            Err(WorkError::Conflict)
        );
        let WorkRecord::Workspace(workspace) = &original.record else {
            panic!()
        };
        let session = store
            .apply(
                CommandId::new(),
                WorkIntent::CreateSession {
                    workspace_id: workspace.workspace_id,
                    name: "Work".into(),
                    expected_revision: 1,
                },
                &BTreeMap::new(),
            )
            .unwrap();
        let WorkRecord::Session(session) = session.record else {
            panic!()
        };
        assert_eq!(
            store.session(WorkspaceId::new(), session.session_id),
            Err(WorkError::NotFound)
        );
        store
            .apply(
                CommandId::new(),
                WorkIntent::RenameSession {
                    workspace_id: workspace.workspace_id,
                    session_id: session.session_id,
                    name: "Protected label".into(),
                    expected_revision: 2,
                },
                &BTreeMap::new(),
            )
            .unwrap();
        drop(store);
        drop(journal);
        let journal = Journal::open(root.path()).unwrap();
        let mut store = journal.work.lock().unwrap();
        assert_eq!(store.revision(), 3);
        assert_eq!(
            store
                .session(workspace.workspace_id, session.session_id)
                .unwrap()
                .name,
            "Protected label"
        );
        assert_eq!(
            store
                .apply(command, create("Manual", 0), &BTreeMap::new())
                .unwrap(),
            original
        );
        assert!(!root.path().join("runtime-state.json").exists());
    }
    #[test]
    fn invalid_names_revision_and_directory_intents_never_commit() {
        let root = TestDirectory::new();
        let journal = Journal::open(root.path()).unwrap();
        let mut store = journal.work.lock().unwrap();
        for name in [
            "",
            " leading",
            "trailing ",
            "line\nbreak",
            "\u{0085}",
            "\u{feff}leading",
            "trailing\u{feff}",
            &"😃".repeat(81),
        ] {
            assert_eq!(
                store.apply(CommandId::new(), create(name, 0), &policy(root.path())),
                Err(WorkError::Invalid)
            );
        }
        assert_eq!(
            store.apply(CommandId::new(), create("Valid", 1), &policy(root.path())),
            Err(WorkError::Conflict)
        );
        assert_eq!(
            store.apply(CommandId::new(), create("Valid", 0), &BTreeMap::new()),
            Err(WorkError::Invalid)
        );
        assert_eq!(store.revision(), 0);
        assert!(!root.path().join("work-records.json").exists());
        assert!(
            store
                .apply(
                    CommandId::new(),
                    create(&"😃".repeat(80), 0),
                    &policy(root.path())
                )
                .is_ok()
        );
    }
    #[test]
    fn persistence_failure_poisoning_is_unknown_then_fails_closed() {
        let root = TestDirectory::new();
        let journal = Journal::open(root.path()).unwrap();
        let mut store = journal.work.lock().unwrap();
        fs::create_dir(root.path().join("work-records.json")).unwrap();
        assert_eq!(
            store.apply(CommandId::new(), create("First", 0), &policy(root.path())),
            Err(WorkError::OutcomeUnknown)
        );
        assert_eq!(
            store.apply(CommandId::new(), create("Second", 0), &policy(root.path())),
            Err(WorkError::StorageFailed)
        );
        assert_eq!(store.revision(), 0);
    }
    #[test]
    fn tampered_records_and_unsafe_owned_file_metadata_reject_startup() {
        use std::os::unix::fs::PermissionsExt;
        let root = TestDirectory::new();
        let journal = Journal::open(root.path()).unwrap();
        journal
            .work
            .lock()
            .unwrap()
            .apply(CommandId::new(), create("One", 0), &policy(root.path()))
            .unwrap();
        drop(journal);
        let path = root.path().join("work-records.json");
        let bytes = fs::read(&path).unwrap();
        let mut saved: Saved = serde_json::from_slice(&bytes).unwrap();
        saved.revision = 2;
        fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
        assert!(Journal::open(root.path()).is_err());
        let mut saved: Saved = serde_json::from_slice(&bytes).unwrap();
        saved.workspaces.values_mut().next().unwrap().record.name = "Unreceipted edit".into();
        fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
        assert!(Journal::open(root.path()).is_err());
        fs::write(&path, &bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Journal::open(root.path()).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::hard_link(&path, root.path().join("alias")).unwrap();
        assert!(Journal::open(root.path()).is_err());
    }
}
