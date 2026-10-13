//! Explicit stopped-file reads of public Pi JSONL v3: reconstruct the tree, not a flat transcript.
use super::{Binding, CanonicalReadError as Error, canonical_file::CanonicalFile, persistence};
use crate::pi_control::{CanonicalDocument, History};
use serde::Deserialize;
use std::collections::BTreeMap;
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
    persistence::validate_resume(binding, &binding.directory, parent)
        .map_err(|_| Error::Invalid)?;
    let bytes = CanonicalFile::open(&binding.file)
        .map_err(|_| Error::Unavailable)?
        .read()
        .map_err(|_| Error::Changed)?;
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
