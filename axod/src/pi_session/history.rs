//! Explicit stopped-file reads of public Pi JSONL v3: reconstruct the tree, not a flat transcript.
use super::{Binding, CanonicalReadError as Error, canonical_file::CanonicalFile, persistence};
use crate::pi_control::{CanonicalDocument, History};
/// Completion was proved and bytes were read under caller-held exclusion.
/// The pinned source remains available for a final publication check.
pub(crate) struct StoppedHistory {
    pub(crate) history: History,
    source: super::canonical_file::PinnedRead,
}
impl StoppedHistory {
    pub(crate) fn check(&self) -> Result<(), Error> {
        self.source.check().map_err(|_| Error::Changed)
    }
}
use serde::Deserialize;
use std::collections::BTreeMap;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Link {
    id: String,
    parent_id: Option<String>,
}
/// Exact native completion and a bound writer-exclusion lease are mandatory.
/// A successful file read never authorizes a replacement writer.
pub(crate) fn stopped(
    binding: &Binding,
    proof: &crate::runtime::RuntimeCompletion,
    lease: &persistence::WriterLease,
) -> Result<StoppedHistory, Error> {
    if proof.runtime() != binding.runtime {
        return Err(Error::Invalid);
    }
    lease
        .check_for(&binding.file)
        .map_err(|_| Error::Unavailable)?;
    let parent = binding.file.parent().ok_or(Error::Invalid)?;
    persistence::validate_resume(binding, &binding.directory, parent)
        .map_err(|_| Error::Invalid)?;
    let bytes = CanonicalFile::open(&binding.file)
        .map_err(|_| Error::Unavailable)?
        .read()
        .map_err(|_| Error::Changed)?;
    if bytes.bytes().len() > 4 * 1024 * 1024 || bytes.bytes().last() != Some(&b'\n') {
        return Err(Error::Invalid);
    }
    let text = std::str::from_utf8(bytes.bytes()).map_err(|_| Error::Invalid)?;
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
    lease.check_for(&binding.file).map_err(|_| Error::Changed)?;
    bytes.check().map_err(|_| Error::Changed)?;
    Ok(StoppedHistory {
        history: History {
            leaf_id,
            entries,
            branch,
        },
        source: bytes,
    })
}
