//! Explicit stopped-file reads of public Pi JSONL v3: reconstruct the tree, not a flat transcript.
use super::{Binding, CanonicalReadError as Error, persistence};
use crate::pi_control::{CanonicalDocument, History};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Link {
    id: String,
    parent_id: Option<String>,
}
/// Caller must possess completion evidence for the exact bound writer. A file
/// read alone never establishes that Pi has stopped or authorizes replacement.
pub fn stopped(binding: &Binding) -> Result<History, Error> {
    let parent = binding.file.parent().ok_or(Error::Invalid)?;
    let metadata = std::fs::symlink_metadata(parent).map_err(|_| Error::Unavailable)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(Error::Invalid);
    }
    persistence::validate_resume(binding, &binding.directory, parent)
        .map_err(|_| Error::Invalid)?;
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&binding.file)
        .map_err(|_| Error::Unavailable)?;
    let before = file.metadata().map_err(|_| Error::Unavailable)?;
    if !before.is_file() || before.nlink() != 1 || before.len() > 4 * 1024 * 1024 {
        return Err(Error::Invalid);
    }
    let mut bytes = Vec::new();
    file.by_ref()
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Unavailable)?;
    let after = file.metadata().map_err(|_| Error::Unavailable)?;
    if before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
    {
        return Err(Error::Changed);
    }
    if bytes.len() > 4 * 1024 * 1024 || bytes.last() != Some(&b'\n') {
        return Err(Error::Invalid);
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| Error::Invalid)?;
    persistence::validate_header(text.lines().next().ok_or(Error::Invalid)?, binding)
        .map_err(|_| Error::Invalid)?;
    let mut entries = Vec::new();
    let mut links = BTreeMap::new();
    let mut leaf_id = None;
    for line in text.lines().skip(1) {
        let link: Link = serde_json::from_str(line).map_err(|_| Error::Invalid)?;
        if links.contains_key(&link.id)
            || link
                .parent_id
                .as_ref()
                .is_some_and(|id| !links.contains_key(id))
        {
            return Err(Error::Invalid);
        }
        leaf_id = Some(link.id.clone());
        links.insert(link.id, (link.parent_id, line));
        entries.push(serde_json::from_str::<CanonicalDocument>(line).map_err(|_| Error::Invalid)?);
    }
    let mut branch = Vec::new();
    let mut cursor = leaf_id.clone();
    while let Some(id) = cursor {
        let (parent, line) = links.get(&id).ok_or(Error::Invalid)?;
        branch.push(serde_json::from_str::<CanonicalDocument>(line).map_err(|_| Error::Invalid)?);
        cursor = parent.clone();
    }
    branch.reverse();
    Ok(History {
        leaf_id,
        entries,
        branch,
    })
}
