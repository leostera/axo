//! Demand-driven canonical projections. Never invents entries or transports image/file bodies.
use super::CanonicalReadError as Error;
use crate::pi_control::{CanonicalDocument, History};
use serde::{Deserialize, Serialize};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: String,
    parent_id: Option<String>,
    timestamp: String,
    #[serde(rename = "type")]
    kind: String,
    message: Option<Message>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Message {
    role: String,
    content: Content,
    tool_call_id: Option<String>,
    tool_name: Option<String>,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum Content {
    Text(String),
    Parts(Vec<Part>),
}
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Part {
    Text { text: String },
    Image,
    ToolCall { id: String, name: String },
    Thinking,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Projection {
    pub entry_id: String,
    pub parent_id: Option<String>,
    pub timestamp: String,
    pub kind: String,
    pub role: Option<String>,
    pub text: String,
    pub truncated: bool,
    pub tool_call_id: Option<String>,
    pub tool_name: Option<String>,
    pub tool_calls: Vec<ToolCall>,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCall {
    pub id: String,
    pub name: String,
}
fn text(content: &Content) -> String {
    match content {
        Content::Text(text) => text.clone(),
        Content::Parts(parts) => parts
            .iter()
            .filter_map(|part| match part {
                Part::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}
pub fn clip(text: &str, bytes: usize) -> (&str, bool) {
    if text.len() <= bytes {
        return (text, false);
    }
    let mut end = bytes;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (&text[..end], true)
}
pub fn project(document: &CanonicalDocument) -> Result<Projection, Error> {
    let entry: Entry = serde_json::from_str(document.json()).map_err(|_| Error::Invalid)?;
    let (role, text, call, tool, calls) = if let Some(message) = entry.message {
        let text = text(&message.content);
        let calls = match message.content {
            Content::Parts(parts) => parts
                .into_iter()
                .filter_map(|part| match part {
                    Part::ToolCall { id, name } => Some(ToolCall { id, name }),
                    _ => None,
                })
                .collect(),
            _ => Vec::new(),
        };
        (
            Some(message.role),
            text,
            message.tool_call_id,
            message.tool_name,
            calls,
        )
    } else {
        (None, String::new(), None, None, Vec::new())
    };
    let bounded = |value: &str, max: usize| {
        !value.is_empty() && value.len() <= max && !value.chars().any(char::is_control)
    };
    let calls: Vec<ToolCall> = calls;
    if !bounded(&entry.id, 128)
        || !bounded(&entry.kind, 128)
        || entry.timestamp.len() > 128
        || entry.parent_id.as_ref().is_some_and(|id| !bounded(id, 128))
        || role.as_ref().is_some_and(|role| !bounded(role, 64))
        || call.as_ref().is_some_and(|id| !bounded(id, 128))
        || tool.as_ref().is_some_and(|name| !bounded(name, 128))
        || calls.len() > 32
        || calls
            .iter()
            .any(|call| !bounded(&call.id, 128) || !bounded(&call.name, 128))
    {
        return Err(Error::Invalid);
    }
    let (preview, truncated) = clip(&text, 2048);
    Ok(Projection {
        entry_id: entry.id,
        parent_id: entry.parent_id,
        timestamp: entry.timestamp,
        kind: entry.kind,
        role,
        text: preview.to_owned(),
        truncated,
        tool_call_id: call,
        tool_name: tool,
        tool_calls: calls,
    })
}
pub fn recent(history: &History) -> Result<Vec<Projection>, Error> {
    let mut entries = Vec::new();
    let mut bytes = 0;
    for document in history.branch.iter().rev().take(10) {
        let entry = project(document)?;
        let size = serde_json::to_vec(&entry)
            .map_err(|_| Error::Invalid)?
            .len();
        // Reserve the public frame's remaining space for the bounded current question and source.
        if bytes + size > 32 * 1024 {
            break;
        }
        bytes += size;
        entries.push(entry);
    }
    entries.reverse();
    Ok(entries)
}
pub fn tool_text(history: &History, entry_id: &str, tool_call_id: &str) -> Result<String, Error> {
    for document in &history.entries {
        let entry: Entry = serde_json::from_str(document.json()).map_err(|_| Error::Invalid)?;
        if entry.id == entry_id {
            let message = entry.message.ok_or(Error::Invalid)?;
            if message.role != "toolResult" || message.tool_call_id.as_deref() != Some(tool_call_id)
            {
                return Err(Error::Invalid);
            }
            return Ok(text(&message.content));
        }
    }
    Err(Error::NotFound)
}
