//! Exact resume validation and cooperative managed-writer lease. No transcript writes.
use super::store::Binding;
use crate::pi_control::ChatId;
use serde::Deserialize;
use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{self, Read},
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
};
pub struct WriterLease {
    _file: File,
}
impl WriterLease {
    pub fn acquire(file: &Path) -> io::Result<Self> {
        let name = file
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| io::Error::other("Invalid writer binding"))?;
        let lock = file.with_file_name(format!(".{name}.axo-writer.lock"));
        let handle = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(lock)?;
        let metadata = handle.metadata()?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err(io::Error::other("Invalid managed writer lease"));
        }
        if unsafe { libc::flock(handle.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::other("Persistence already has a managed writer"));
        }
        Ok(Self { _file: handle })
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
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&binding.file)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.len() > 4 * 1024 * 1024
    {
        return Err(io::Error::other("Invalid resume file"));
    }
    let parent = binding
        .file
        .parent()
        .ok_or_else(|| io::Error::other("Missing persistence parent"))?;
    if fs::canonicalize(parent)? != fs::canonicalize(sessions)?
        || fs::canonicalize(directory)? != binding.directory
    {
        return Err(io::Error::other("Resume directory binding mismatch"));
    }
    let mut bytes = Vec::new();
    file.by_ref()
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
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
