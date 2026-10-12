//! Runtime ownership/recovery receipts only. Never stores argv, prompts, or Pi history.
use crate::model::*;
use crate::terminal::ErrorCode;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const MAX_BYTES: u64 = 4 * 1024 * 1024;
// Version 1 could record Exited before PTY EOF; it cannot establish clean-completion evidence.
const JOURNAL_VERSION: u16 = 2;
const MAX_RECORDS: usize = 1000;
const MAX_RECEIPTS: usize = 2000;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    fingerprint: String,
    runtime: RuntimeRef,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u16,
    terminals: BTreeMap<PaneId, TerminalSnapshot>,
    receipts: BTreeMap<CommandId, Receipt>,
}
pub struct Journal {
    pub(crate) work: std::sync::Arc<std::sync::Mutex<crate::work::WorkStore>>,
    pub(crate) managed: std::sync::Arc<std::sync::Mutex<crate::managed::store::Store>>,
    pub(crate) panes: std::sync::Arc<std::sync::Mutex<crate::panes::store::Store>>,
    root: PathBuf,
    saved: Saved,
    _owner_lock: File,
    poisoned: bool,
}
impl Drop for Journal {
    fn drop(&mut self) {
        // Concurrent PTY forks can temporarily retain this open description.
        // Releasing the actual owner must not wait for their CLOEXEC boundary.
        unsafe {
            libc::flock(self._owner_lock.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
impl Journal {
    pub fn open(root: &Path) -> io::Result<Self> {
        let metadata = fs::symlink_metadata(root)?;
        if !root.is_absolute()
            || !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err(io::Error::other(
                "axod requires an owned private state directory",
            ));
        }
        let owner = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(root.join("owner.lock"))?;
        let owner_metadata = owner.metadata()?;
        if !owner_metadata.is_file()
            || owner_metadata.uid() != unsafe { libc::geteuid() }
            || owner_metadata.permissions().mode() & 0o077 != 0
        {
            return Err(io::Error::other("Invalid axod ownership lock"));
        }
        if unsafe { libc::flock(owner.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } < 0 {
            return Err(io::Error::new(
                io::Error::last_os_error().kind(),
                "Another axod owns this state directory",
            ));
        }
        let path = root.join("runtime-state.json");
        let mut saved = match read_saved(&path) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Saved {
                version: JOURNAL_VERSION,
                terminals: BTreeMap::new(),
                receipts: BTreeMap::new(),
            },
            Err(error) => return Err(error),
        };
        if saved.version != JOURNAL_VERSION
            || saved.terminals.len() > MAX_RECORDS
            || saved.receipts.len() > MAX_RECEIPTS
            || saved
                .terminals
                .iter()
                .any(|(id, terminal)| *id != terminal.runtime.target.pane_id)
            || saved.receipts.values().any(|receipt| {
                !saved
                    .terminals
                    .get(&receipt.runtime.target.pane_id)
                    .is_some_and(|terminal| terminal.runtime.target == receipt.runtime.target)
            })
        {
            return Err(io::Error::other("Invalid axod runtime journal"));
        }
        for terminal in saved.terminals.values_mut() {
            terminal.attached = false;
            terminal.backlog_bytes = 0;
            if !matches!(
                terminal.process,
                ProcessState::Exited { .. } | ProcessState::Failed { .. }
            ) {
                // A fresh boot cannot prove whether the previous writer survived. Do not signal it or restart.
                terminal.process = ProcessState::RecoveryRequired {};
            }
        }
        let work = crate::work::WorkStore::open(root)?;
        if !work.validate_deletion_runtimes(&saved.terminals.values().cloned().collect::<Vec<_>>())
        {
            return Err(io::Error::other(
                "Session deletion lacks exact recorded runtime completion",
            ));
        }
        if saved.receipts.keys().any(|id| work.contains_command(*id)) {
            return Err(io::Error::other(
                "Conflicting command identities across journals",
            ));
        }
        let managed = crate::managed::store::Store::open(root, &work)?;
        for command in managed.commands() {
            if work.contains_command(command) {
                return Err(io::Error::other("Conflicting managed command identity"));
            }
            if let Some(runtime) = saved.receipts.get(&command).map(|receipt| receipt.runtime) {
                let receipt = managed.receipt(command).expect("Stored managed receipt");
                let crate::managed::store::Intent::Start { target, .. } = receipt.intent else {
                    return Err(io::Error::other("Conflicting managed runtime receipt"));
                };
                if runtime.target.session_id != target.session_id
                    || runtime.target.pane_id != target.pane_id
                    || runtime.host_generation != target.host_generation
                {
                    return Err(io::Error::other("Conflicting managed runtime target"));
                }
            }
        }
        let panes = crate::panes::store::Store::open(root, &work)?;
        let runtime_receipts = saved
            .receipts
            .iter()
            .map(|(command, receipt)| (*command, receipt.runtime))
            .collect();
        if panes
            .commands()
            .any(|command| work.contains_command(command) || managed.contains_command(command))
            || !panes.validate_runtime(&runtime_receipts)
        {
            return Err(io::Error::other(
                "Conflicting pane command or runtime identity",
            ));
        }
        for command in panes.commands() {
            let receipt = panes.receipt(command).expect("Stored pane receipt");
            if receipt.disposition == crate::panes::store::Disposition::Removed
                && receipt.runtime.is_some_and(|runtime| {
                    !saved.terminals.values().any(|terminal| {
                        terminal.runtime == runtime
                            && matches!(
                                terminal.process,
                                ProcessState::Exited { .. } | ProcessState::Failed { .. }
                            )
                    })
                })
            {
                return Err(io::Error::other(
                    "Pane removed without recorded runtime completion",
                ));
            }
        }
        Ok(Self {
            panes: std::sync::Arc::new(std::sync::Mutex::new(panes)),
            managed: std::sync::Arc::new(std::sync::Mutex::new(managed)),
            work: std::sync::Arc::new(std::sync::Mutex::new(work)),
            root: root.to_path_buf(),
            saved,
            _owner_lock: owner,
            poisoned: false,
        })
    }
    pub(crate) fn is_fenced(&self) -> bool {
        self.poisoned
    }
    pub(crate) fn command_runtime(&self, command: CommandId) -> Option<RuntimeRef> {
        self.saved.receipts.get(&command).map(|r| r.runtime)
    }
    pub(crate) fn contains_command(&self, command: CommandId) -> bool {
        self.saved.receipts.contains_key(&command)
    }
    pub fn snapshots(&self) -> Vec<TerminalSnapshot> {
        self.saved.terminals.values().cloned().collect()
    }
    pub fn lookup(
        &self,
        command: CommandId,
        target: TerminalTarget,
        launch: &TerminalLaunch,
    ) -> Result<Option<RuntimeRef>, ErrorCode> {
        self.lookup_mode(command, target, launch, false)
    }
    pub(crate) fn lookup_mode(
        &self,
        command: CommandId,
        target: TerminalTarget,
        launch: &TerminalLaunch,
        controlled: bool,
    ) -> Result<Option<RuntimeRef>, ErrorCode> {
        match self.saved.receipts.get(&command) {
            Some(receipt)
                if receipt.fingerprint == launch_fingerprint(target, launch, controlled) =>
            {
                Ok(Some(receipt.runtime))
            }
            Some(_) => Err(ErrorCode::Conflict),
            None => Ok(None),
        }
    }
    pub fn prepare(
        &mut self,
        command: CommandId,
        runtime: RuntimeRef,
        launch: &TerminalLaunch,
    ) -> Result<(), ErrorCode> {
        self.prepare_mode(command, runtime, launch, false)
    }
    pub(crate) fn prepare_mode(
        &mut self,
        command: CommandId,
        runtime: RuntimeRef,
        launch: &TerminalLaunch,
        controlled: bool,
    ) -> Result<(), ErrorCode> {
        if self.poisoned {
            return Err(ErrorCode::StorageFailed);
        }
        // A receipt is immutable even when the caller bypasses Manager's reconciliation path.
        if let Some(previous) = self.lookup_mode(command, runtime.target, launch, controlled)? {
            return if previous == runtime {
                Ok(())
            } else {
                Err(ErrorCode::Conflict)
            };
        }
        if self.saved.receipts.len() >= MAX_RECEIPTS
            || (!self.saved.terminals.contains_key(&runtime.target.pane_id)
                && self.saved.terminals.len() >= MAX_RECORDS)
        {
            return Err(ErrorCode::Capacity);
        }
        if let Some(old) = self.saved.terminals.get(&runtime.target.pane_id) {
            if old.runtime.target != runtime.target {
                return Err(ErrorCode::Conflict);
            }
            if matches!(
                old.process,
                ProcessState::RecoveryRequired { .. }
                    | ProcessState::Starting { .. }
                    | ProcessState::Running { .. }
                    | ProcessState::Stopping { .. }
            ) {
                return Err(ErrorCode::RecoveryRequired);
            }
        }
        let mut next = self.saved.clone();
        next.receipts.insert(
            command,
            Receipt {
                fingerprint: launch_fingerprint(runtime.target, launch, controlled),
                runtime,
            },
        );
        next.terminals.insert(
            runtime.target.pane_id,
            TerminalSnapshot {
                runtime,
                process: ProcessState::Starting {},
                attached: false,
                backlog_bytes: 0,
            },
        );
        self.commit(next)
    }
    pub fn update(&mut self, runtime: RuntimeRef, process: ProcessState) -> Result<(), ErrorCode> {
        let mut next = self.saved.clone();
        let record = next
            .terminals
            .get_mut(&runtime.target.pane_id)
            .ok_or(ErrorCode::NotFound)?;
        if record.runtime != runtime {
            return Err(ErrorCode::StaleRuntime);
        }
        if !legal_transition(&record.process, &process) {
            return Err(ErrorCode::InvalidTransition);
        }
        record.process = process;
        self.commit(next)
    }
    fn commit(&mut self, next: Saved) -> Result<(), ErrorCode> {
        if self.poisoned {
            return Err(ErrorCode::StorageFailed);
        }
        if persist(&self.root, &next).is_err() {
            // Rename/fsync failure can leave an uncertain on-disk outcome. Fence further mutations.
            self.poisoned = true;
            return Err(ErrorCode::StorageFailed);
        }
        self.saved = next;
        Ok(())
    }
}
fn legal_transition(previous: &ProcessState, next: &ProcessState) -> bool {
    use ProcessState::*;
    match (previous, next) {
        (Starting {}, Running { .. } | Failed {} | RecoveryRequired {}) => true,
        (Running { pid: old }, Running { pid: new } | Stopping { pid: new })
        | (Stopping { pid: old }, Stopping { pid: new }) => old == new,
        (Running { .. } | Stopping { .. }, Exited { .. } | RecoveryRequired {}) => true,
        // Reaper and drain can establish clean completion after a conservative interim record.
        (RecoveryRequired {}, Exited { .. } | RecoveryRequired {}) => true,
        (Exited { wait_status: old }, Exited { wait_status: new }) => old == new,
        (Failed {}, Failed {}) => true,
        _ => false,
    }
}

fn launch_fingerprint(target: TerminalTarget, launch: &TerminalLaunch, controlled: bool) -> String {
    let original = fingerprint(target, launch);
    if controlled {
        format!("controlled:{original}")
    } else {
        original
    }
}
fn fingerprint(target: TerminalTarget, launch: &TerminalLaunch) -> String {
    let data = serde_json::to_vec(&(target, launch)).expect("Domain values serialize");
    format!("{:x}", Sha256::digest(data))
}
fn read_saved(path: &Path) -> io::Result<Saved> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.len() > MAX_BYTES
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(io::Error::other("Invalid journal file"));
    }
    let mut data = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut data)?;
    if data.len() as u64 > MAX_BYTES {
        return Err(io::Error::other("Journal exceeds bounds"));
    }
    serde_json::from_slice(&data).map_err(io::Error::other)
}
fn persist(root: &Path, next: &Saved) -> io::Result<()> {
    let data = serde_json::to_vec(next).map_err(io::Error::other)?;
    if data.len() as u64 > MAX_BYTES {
        return Err(io::Error::other("Journal exceeds bounds"));
    }
    let temporary = root.join(format!(".runtime-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&data)?;
        file.sync_all()?;
        fs::rename(&temporary, root.join("runtime-state.json"))?;
        File::open(root)?.sync_all()
    })();
    let _ = fs::remove_file(temporary);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;

    fn runtime() -> RuntimeRef {
        RuntimeRef {
            host_generation: HostGeneration::new(),
            target: TerminalTarget {
                session_id: SessionId::new(),
                pane_id: PaneId::new(),
            },
            runtime_generation: RuntimeGeneration::new(),
        }
    }
    fn launch() -> TerminalLaunch {
        TerminalLaunch {
            directory: "/".into(),
            argv: vec!["/bin/sh".into()],
        }
    }

    #[test]
    fn owner_release_does_not_wait_for_a_forked_description_to_close() {
        let directory = TestDirectory::new();
        let journal = Journal::open(directory.path()).unwrap();
        let inherited = journal._owner_lock.try_clone().unwrap();
        drop(journal);
        let successor = Journal::open(directory.path()).unwrap();
        drop(inherited);
        assert!(Journal::open(directory.path()).is_err());
        drop(successor);
        Journal::open(directory.path()).unwrap();
    }
    #[test]
    fn prepare_cannot_reassign_a_command_receipt_or_change_its_arguments() {
        let directory = TestDirectory::new();
        let mut journal = Journal::open(directory.path()).unwrap();
        let command = CommandId::new();
        let original = runtime();
        journal.prepare(command, original, &launch()).unwrap();
        journal.update(original, ProcessState::Failed {}).unwrap();
        let successor = RuntimeRef {
            runtime_generation: RuntimeGeneration::new(),
            ..original
        };
        assert_eq!(
            journal.prepare(command, successor, &launch()),
            Err(ErrorCode::Conflict)
        );
        let changed = TerminalLaunch {
            argv: vec!["/bin/echo".into()],
            ..launch()
        };
        assert_eq!(
            journal.prepare(command, original, &changed),
            Err(ErrorCode::Conflict)
        );
        journal.prepare(command, original, &launch()).unwrap();
        assert_eq!(
            journal.lookup(command, original.target, &launch()).unwrap(),
            Some(original)
        );
        assert_eq!(journal.snapshots()[0].process, ProcessState::Failed {});
    }

    #[test]
    fn completed_records_cannot_be_resurrected_or_have_their_exit_status_rewritten() {
        let directory = TestDirectory::new();
        let mut journal = Journal::open(directory.path()).unwrap();
        let reference = runtime();
        let pid = ChildPid::try_from(42).unwrap();
        journal
            .prepare(CommandId::new(), reference, &launch())
            .unwrap();
        journal
            .update(reference, ProcessState::Running { pid })
            .unwrap();
        journal
            .update(reference, ProcessState::Exited { wait_status: 0 })
            .unwrap();
        assert_eq!(
            journal.update(reference, ProcessState::Running { pid }),
            Err(ErrorCode::InvalidTransition)
        );
        assert_eq!(
            journal.update(reference, ProcessState::Exited { wait_status: 7 }),
            Err(ErrorCode::InvalidTransition)
        );
    }

    #[test]
    fn uncertain_persistence_fences_future_mutations() {
        let directory = TestDirectory::new();
        let mut journal = Journal::open(directory.path()).unwrap();
        let reference = runtime();
        let command = CommandId::new();
        journal.prepare(command, reference, &launch()).unwrap();
        let path = directory.path().join("runtime-state.json");
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert_eq!(
            journal.update(reference, ProcessState::Failed {}),
            Err(ErrorCode::StorageFailed)
        );
        fs::remove_dir(&path).unwrap();
        assert_eq!(
            journal.prepare(CommandId::new(), runtime(), &launch()),
            Err(ErrorCode::StorageFailed)
        );
        assert_eq!(
            journal.prepare(command, reference, &launch()),
            Err(ErrorCode::StorageFailed)
        );
    }

    #[test]
    fn prior_journal_version_is_rejected_without_rewriting_its_completion_claims() {
        let directory = TestDirectory::new();
        let path = directory.path().join("runtime-state.json");
        let data = br#"{"version":1,"terminals":{},"receipts":{}}"#;
        fs::write(&path, data).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(Journal::open(directory.path()).is_err());
        assert_eq!(fs::read(path).unwrap(), data);
    }
}
