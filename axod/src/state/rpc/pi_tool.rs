//! Exact canonical tool text only: no tool execution, input replay or file target.
use super::*;
use super::{
    pi_history::{CanonicalRead, ReadMode, head},
    pi_observation::BindingTarget,
};
use crate::pi_session::{history::CanonicalTree, projection};
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    target: BindingTarget,
    read_mode: ReadMode,
    entry_id: String,
    tool_call_id: String,
    head_digest: String,
    offset: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Input {
    target: BindingTarget,
    read_mode: ReadMode,
    entry_id: String,
    tool_call_id: String,
    #[serde(default, deserialize_with = "present_cursor")]
    cursor: Option<Cursor>,
    #[serde(default)]
    limit: ByteLimit,
}
struct ByteLimit(usize);
impl Default for ByteLimit {
    fn default() -> Self {
        Self(8192)
    }
}
impl<'de> Deserialize<'de> for ByteLimit {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let bytes = usize::deserialize(d)?;
        if !(4..=8192).contains(&bytes) {
            return Err(serde::de::Error::custom("Invalid tool chunk limit"));
        }
        Ok(Self(bytes))
    }
}
fn present_cursor<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Cursor>, D::Error> {
    Cursor::deserialize(d).map(Some)
}
struct Request(Input);
impl Request {
    fn parse(input: Input) -> Result<Self, (i32, &'static str)> {
        let id = |value: &str| {
            !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control)
        };
        if !id(&input.entry_id) || !id(&input.tool_call_id) {
            return Err((-32602, "Invalid central tool identity"));
        }
        if let Some(cursor) = &input.cursor
            && (cursor.target != input.target
                || cursor.read_mode != input.read_mode
                || cursor.entry_id != input.entry_id
                || cursor.tool_call_id != input.tool_call_id
                || cursor.offset == 0
                || cursor.offset > 4 * 1024 * 1024
                || cursor.head_digest.len() != 64
                || !cursor
                    .head_digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)))
        {
            return Err((-32602, "Invalid central tool cursor"));
        }
        Ok(Self(input))
    }
}
fn chunk(request: &Request, tree: &CanonicalTree<'_>) -> Result<Value, (i32, &'static str)> {
    let request = &request.0;
    let digest = head(tree);
    if request
        .cursor
        .as_ref()
        .is_some_and(|cursor| cursor.head_digest != digest)
    {
        return Err((-32002, "Stale central tool head"));
    }
    let text = projection::tool_text(tree.history(), &request.entry_id, &request.tool_call_id)
        .map_err(|_| (-32009, "Central canonical tool result unavailable"))?;
    let offset = request.cursor.as_ref().map_or(0, |cursor| cursor.offset);
    if offset > text.len() || !text.is_char_boundary(offset) {
        return Err((-32602, "Invalid central tool offset"));
    }
    let mut part = projection::clip(&text[offset..], request.limit.0).0;
    // Decoded-byte bounds alone do not bound JSON escaping. A dense-control
    // chunk falls back to 4096 bytes (at most 24 KiB escaped), without losing
    // text or splitting UTF-8; the continuation uses the actual returned size.
    if serde_json::to_vec(part)
        .map_err(|_| (-32603, "Central encoding failed"))?
        .len()
        > 32 * 1024
    {
        part = projection::clip(part, 4096).0;
    }
    let next_offset = offset + part.len();
    let cursor = if next_offset < text.len() {
        Some(Cursor {
            target: request.target.clone(),
            read_mode: request.read_mode,
            entry_id: request.entry_id.clone(),
            tool_call_id: request.tool_call_id.clone(),
            head_digest: digest.clone(),
            offset: next_offset,
        })
    } else {
        None
    };
    Ok(
        json!({"target":request.target,"readMode":request.read_mode,"entryId":request.entry_id,"toolCallId":request.tool_call_id,"headDigest":digest,"offset":offset,"text":part,"totalBytes":text.len(),"cursor":cursor}),
    )
}
pub(super) fn read(owner: &Controller, machine: MachineId, input: Input) -> Outcome {
    let request = Request::parse(input)?;
    let read = CanonicalRead::capture(owner, machine, &request.0.target, request.0.read_mode)?;
    let tree = CanonicalTree::parse(read.history())
        .map_err(|_| (-32009, "Invalid central canonical history"))?;
    let body = chunk(&request, &tree)?;
    read.publish(owner, body)
}
#[cfg(test)]
mod tests;
