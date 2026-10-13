//! Exact resume validation and cooperative managed-writer lease. No transcript writes.
use super::{
    Binding,
    canonical_file::{CanonicalFile, Directory},
};
use crate::pi_control::ChatId;
use serde::Deserialize;
use std::{
    collections::BTreeSet,
    fs::{self, File},
    io,
    os::fd::AsRawFd,
    path::{Path, PathBuf},
};
pub struct WriterLease {
    file: File,
    directory: Directory,
    name: std::ffi::OsString,
}
impl Drop for WriterLease {
    fn drop(&mut self) {
        // Fork can briefly duplicate this open-file description before child FD cleanup.
        // Release our cooperative ownership explicitly, not when the last duplicate closes.
        // If unlock fails, acquisition still fails closed while any copy retains the lock.
        unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}
impl WriterLease {
    pub fn acquire(file: &Path) -> io::Result<Self> {
        let name = file
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| io::Error::other("Invalid writer binding"))?;
        let directory = Directory::open(
            file.parent()
                .ok_or_else(|| io::Error::other("Invalid writer parent"))?,
        )?;
        let name = std::ffi::OsString::from(format!(".{name}.axo-writer.lock"));
        let handle = directory.writer_lock(&name)?;
        if unsafe { libc::flock(handle.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::other("Persistence already has a managed writer"));
        }
        directory.check_leaf(&name, &handle)?;
        Ok(Self {
            file: handle,
            directory,
            name,
        })
    }
    pub(crate) fn check(&self) -> io::Result<()> {
        self.directory.check_leaf(&self.name, &self.file)
    }
}
#[cfg(test)]
mod lease_tests {
    use super::*;
    use std::os::fd::{FromRawFd, OwnedFd};

    #[test]
    fn lease_release_is_not_delayed_by_a_duplicated_open_file_description() {
        let root = crate::test_support::TestDirectory::new();
        let file = root.path().join("writer.jsonl");
        let lease = WriterLease::acquire(&file).unwrap();
        // Model a fork's FD copy without launching or signaling any process.
        let fd = unsafe { libc::fcntl(lease.file.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        assert!(fd >= 0);
        let copy = unsafe { OwnedFd::from_raw_fd(fd) };
        assert!(WriterLease::acquire(&file).is_err());
        drop(lease);
        let successor = WriterLease::acquire(&file).unwrap();
        drop(copy);
        assert!(
            WriterLease::acquire(&file).is_err(),
            "Closing an old FD released its successor's lease"
        );
        drop(successor);
        drop(WriterLease::acquire(&file).unwrap());
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Header {
    #[serde(rename = "type")]
    kind: String,
    version: u16,
    id: ChatId,
    cwd: PathBuf,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    #[serde(rename = "type")]
    kind: String,
    id: String,
    parent_id: Option<String>,
}
pub(super) fn validate_header(line: &str, binding: &Binding) -> io::Result<()> {
    let header: Header =
        serde_json::from_str(line).map_err(|_| io::Error::other("Invalid resume header"))?;
    if header.kind != "session"
        || header.version != 3
        || header.id != binding.chat_id
        || fs::canonicalize(header.cwd)? != binding.directory
    {
        return Err(io::Error::other("Resume canonical binding mismatch"));
    }
    Ok(())
}
pub fn validate_resume(binding: &Binding, directory: &Path, sessions: &Path) -> io::Result<()> {
    let parent = binding
        .file
        .parent()
        .ok_or_else(|| io::Error::other("Missing persistence parent"))?;
    if fs::canonicalize(parent)? != fs::canonicalize(sessions)?
        || fs::canonicalize(directory)? != binding.directory
    {
        return Err(io::Error::other("Resume directory binding mismatch"));
    }
    let bytes = CanonicalFile::open(&binding.file)?.read()?;
    if bytes.len() > 4 * 1024 * 1024 || bytes.last() != Some(&b'\n') {
        return Err(io::Error::other("Incomplete resume history"));
    }
    let text =
        std::str::from_utf8(&bytes).map_err(|_| io::Error::other("Invalid resume encoding"))?;
    let mut lines = text.lines();
    validate_header(
        lines
            .next()
            .ok_or_else(|| io::Error::other("Missing resume header"))?,
        binding,
    )?;
    let mut ids = BTreeSet::new();
    for line in lines {
        let entry: Entry =
            serde_json::from_str(line).map_err(|_| io::Error::other("Invalid canonical entry"))?;
        if entry.kind.is_empty()
            || entry.id.is_empty()
            || entry.id.len() > 128
            || entry.id.chars().any(char::is_control)
            || entry
                .parent_id
                .as_ref()
                .is_some_and(|parent| !ids.contains(parent))
            || !ids.insert(entry.id)
        {
            return Err(io::Error::other("Invalid canonical entry tree"));
        }
    }
    Ok(())
}
