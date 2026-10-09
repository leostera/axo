//! Runtime ownership/recovery receipts only. Never stores argv, prompts, or Pi history.
use crate::model::*;
use crate::protocol::ErrorCode;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const MAX_BYTES: u64 = 4 * 1024 * 1024;
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
    root: PathBuf,
    saved: Saved,
    _owner_lock: File,
    poisoned: bool,
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
            || unsafe { libc::flock(owner.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } < 0
        {
            return Err(io::Error::other("Another axod owns this state directory"));
        }
        let path = root.join("runtime-state.json");
        let mut saved = match read_saved(&path) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Saved {
                version: 1,
                terminals: BTreeMap::new(),
                receipts: BTreeMap::new(),
            },
            Err(error) => return Err(error),
        };
        if saved.version != 1
            || saved.terminals.len() > 1000
            || saved.receipts.len() > 2000
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
        Ok(Self {
            root: root.to_path_buf(),
            saved,
            _owner_lock: owner,
            poisoned: false,
        })
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
        match self.saved.receipts.get(&command) {
            Some(receipt) if receipt.fingerprint == fingerprint(target, launch) => {
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
        if self.saved.receipts.len() >= 2000
            || (!self.saved.terminals.contains_key(&runtime.target.pane_id)
                && self.saved.terminals.len() >= 1000)
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
                fingerprint: fingerprint(runtime.target, launch),
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
