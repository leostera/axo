//! Exact admitted-control live history or completion-proven stopped history.
//! No live-file fallback,
//! additional Pi launcher, canonical writer, history cache or replay path.
#[cfg(test)]
mod tests;
use super::pi_observation::BindingTarget;
use super::*;
use crate::{
    pi_control::History,
    pi_session::{Binding, history, persistence::WriterLease, projection},
};
use sha2::{Digest, Sha256};
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum ReadMode {
    Live,
    Stopped,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum Collection {
    #[default]
    Branch,
    Entries,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    target: BindingTarget,
    read_mode: ReadMode,
    collection: Collection,
    head_digest: String,
    after: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Input {
    target: BindingTarget,
    read_mode: ReadMode,
    #[serde(default)]
    collection: Collection,
    #[serde(default, deserialize_with = "present_cursor")]
    cursor: Option<Cursor>,
    #[serde(default)]
    limit: PageLimit,
}
/// Construction preserves the cross-field cursor correlation before exclusion
/// or file I/O. Only Input can be deserialized from the wire.
struct Request {
    target: BindingTarget,
    read_mode: ReadMode,
    collection: Collection,
    cursor: Option<Cursor>,
    limit: PageLimit,
}
struct PageLimit(usize);
impl Default for PageLimit {
    fn default() -> Self {
        Self(8)
    }
}
impl<'de> Deserialize<'de> for PageLimit {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let value = usize::deserialize(d)?;
        if !(1..=50).contains(&value) {
            return Err(serde::de::Error::custom("Invalid history page limit"));
        }
        Ok(Self(value))
    }
}
fn present_cursor<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Cursor>, D::Error> {
    Cursor::deserialize(d).map(Some)
}
struct CapturedWriter {
    revision: u64,
    binding: Binding,
    attempt: Attempt,
}
fn capture(
    owner: &Controller,
    target: &BindingTarget,
) -> Result<CapturedWriter, (i32, &'static str)> {
    let database = owner.database.lock().unwrap();
    let scope = target.scope();
    let binding = database
        .binding(scope.session_id)
        .map_err(failure)?
        .ok_or((-32009, "Central Pi not admitted"))?;
    if !target.matches(&binding) {
        return Err((-32002, "Stale central Pi binding"));
    }
    let attempt = database
        .attempt(binding.pane_id)
        .map_err(failure)?
        .ok_or((-32009, "Central Pi writer unproven"))?;
    if attempt.runtime != binding.runtime
        || attempt.command_id != binding.start_command_id
        || attempt.phase != AttemptPhase::CompletionProven
        || attempt.configuration.is_none()
        || !database
            .panes(scope.session_id)
            .map_err(failure)?
            .iter()
            .any(|pane| {
                pane.pane_id == binding.pane_id && pane.present && pane.role == PaneRole::Pi
            })
    {
        return Err((-32009, "Central Pi writer unproven"));
    }
    Ok(CapturedWriter {
        revision: database.revision().map_err(failure)?,
        binding,
        attempt,
    })
}
fn head(tree: &history::CanonicalTree<'_>) -> String {
    let history = tree.history();
    let mut digest = Sha256::new();
    for documents in [&history.entries, &history.branch] {
        digest.update((documents.len() as u64).to_be_bytes());
        for document in documents {
            digest.update((document.json().len() as u64).to_be_bytes());
            digest.update(document.json().as_bytes());
        }
    }
    if let Some(leaf) = &history.leaf_id {
        digest.update(leaf.as_bytes());
    }
    format!("{:x}", digest.finalize())
}
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control)
}
fn parse_request(request: Input) -> Result<Request, (i32, &'static str)> {
    if request.read_mode == ReadMode::Live
        && request.target.runtime().host_generation != request.target.scope().host_generation
    {
        return Err((-32602, "Invalid central live history target"));
    }
    if let Some(cursor) = &request.cursor
        && (cursor.target != request.target
            || cursor.read_mode != request.read_mode
            || cursor.collection != request.collection
            || cursor.head_digest.len() != 64
            || !cursor
                .head_digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || !valid_id(&cursor.after))
    {
        return Err((-32602, "Invalid central history cursor"));
    }
    Ok(Request {
        target: request.target,
        read_mode: request.read_mode,
        collection: request.collection,
        cursor: request.cursor,
        limit: request.limit,
    })
}
fn page(request: &Request, history: &History) -> Result<Value, (i32, &'static str)> {
    let tree = history::CanonicalTree::parse(history)
        .map_err(|_| (-32009, "Invalid central canonical history"))?;
    let digest = head(&tree);
    let history = tree.history();
    if request
        .cursor
        .as_ref()
        .is_some_and(|cursor| cursor.head_digest != digest)
    {
        return Err((-32002, "Stale central history head"));
    }
    let documents = match request.collection {
        Collection::Branch => &history.branch,
        Collection::Entries => &history.entries,
    };
    let mut after = request.cursor.as_ref().map(|cursor| cursor.after.as_str());
    let mut entries = Vec::new();
    let mut bytes = 0;
    let mut remaining = false;
    for document in documents {
        let projected = projection::project(document)
            .map_err(|_| (-32009, "Invalid central canonical history"))?;
        if let Some(id) = after {
            if projected.entry_id == id {
                after = None;
            }
            continue;
        }
        let size = serde_json::to_vec(&projected)
            .map_err(|_| (-32603, "Central encoding failed"))?
            .len();
        if entries.len() == request.limit.0 || bytes + size > 40 * 1024 {
            remaining = true;
            break;
        }
        bytes += size;
        entries.push(projected);
    }
    if after.is_some() {
        return Err((-32002, "Stale central history cursor"));
    }
    if remaining && entries.is_empty() {
        return Err((-32006, "Central history page capacity"));
    }
    let cursor = if remaining {
        let after = entries
            .last()
            .ok_or((-32006, "Central history page capacity"))?
            .entry_id
            .clone();
        Some(Cursor {
            target: request.target.clone(),
            read_mode: request.read_mode,
            collection: request.collection,
            head_digest: digest.clone(),
            after,
        })
    } else {
        None
    };
    Ok(
        json!({"target":request.target,"readMode":request.read_mode,"collection":request.collection,"headDigest":digest,"leafId":history.leaf_id,"entries":entries,"cursor":cursor}),
    )
}
pub(super) fn read(owner: &Controller, machine: MachineId, input: Input) -> Outcome {
    let request = parse_request(input)?;
    membership(&request.target.scope(), owner, machine)?;
    match request.read_mode {
        ReadMode::Live => read_live(owner, request),
        ReadMode::Stopped => read_stopped(owner, request),
    }
}
fn envelope(owner: &Controller, request: &Request, revision: u64, body: Value) -> Outcome {
    let result = json!({"hostGeneration":request.target.scope().host_generation,"storeGeneration":owner.generation().map_err(failure)?,"revision":revision,"value":body});
    if serde_json::to_vec(&result)
        .map_err(|_| (-32603, "Central encoding failed"))?
        .len()
        > 48 * 1024
    {
        return Err((-32006, "Central history page capacity"));
    }
    Ok(result)
}
fn read_live(owner: &Controller, request: Request) -> Outcome {
    let read = super::pi_observation::read_history(owner, &request.target)?;
    let body = page(&request, &read.history)?;
    let result = envelope(owner, &request, read.revision(), body)?;
    read.check(owner)?;
    Ok(result)
}
fn read_stopped(owner: &Controller, request: Request) -> Outcome {
    let original = capture(owner, &request.target)?;
    let native = owner.runtime_owner();
    let proof = native
        .completion_evidence(request.target.runtime())
        .ok_or((-32009, "Central Pi writer unproven"))?;
    // Exclusion and canonical I/O occur after the database guard is released.
    let lease = WriterLease::acquire(&original.binding.file)
        .map_err(|_| (-32009, "Central Pi writer exclusion unavailable"))?;
    let history = history::stopped(&original.binding, &proof, &lease)
        .map_err(|_| (-32009, "Central stopped history unavailable"))?;
    let body = page(&request, &history.history)?;
    owner.ensure_owner().map_err(failure)?;
    let current = capture(owner, &request.target)?;
    if current.revision != original.revision
        || current.binding != original.binding
        || current.attempt != original.attempt
        || native
            .completion_evidence(request.target.runtime())
            .is_none()
    {
        return Err((-32002, "Stale central history source"));
    }
    lease
        .check_for(&original.binding.file)
        .map_err(|_| (-32008, "Central Pi storage fenced"))?;
    let result = envelope(owner, &request, original.revision, body)?;
    history
        .check()
        .map_err(|_| (-32008, "Central Pi storage fenced"))?;
    lease
        .check_for(&original.binding.file)
        .map_err(|_| (-32008, "Central Pi storage fenced"))?;
    owner.ensure_owner().map_err(failure)?;
    let published = capture(owner, &request.target)?;
    if published.revision != original.revision
        || published.binding != original.binding
        || published.attempt != original.attempt
    {
        return Err((-32002, "Stale central history source"));
    }
    Ok(result)
}
