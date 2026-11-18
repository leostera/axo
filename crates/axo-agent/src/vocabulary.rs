//! Axo's agent event vocabulary (pi-axo's names, RFD0072) as every adapter other than Pi's
//! writes it: what a link reports, before the link numbers it.

use axo_protocol::asset::FetchedAttachment;
use serde_json::{Value, json};

/// An event in Axo's vocabulary, for the link to number and report.
#[derive(Clone, Debug, PartialEq)]
pub struct Emitted {
    pub name: &'static str,
    pub data: Value,
}

pub fn emit(name: &'static str, data: Value) -> Emitted {
    Emitted { name, data }
}

pub fn assistant_message(text: &str) -> Value {
    json!({ "role": "assistant", "content": [{ "type": "text", "text": text }] })
}

pub fn user_message(text: &str) -> Value {
    json!({ "role": "user", "content": [{ "type": "text", "text": text }] })
}

/// A whole message: its start and its end, as pi-axo reports a message it did not stream.
pub fn whole_message(message: Value) -> [Emitted; 2] {
    [
        emit("message.start", json!({ "type": "message_start", "message": message })),
        emit("message.end", json!({ "type": "message_end", "message": message })),
    ]
}

pub fn message_update(text: &str) -> Emitted {
    emit(
        "message.update",
        json!({ "type": "message_update", "message": assistant_message(text) }),
    )
}

pub fn message_end(text: &str) -> Emitted {
    emit(
        "message.end",
        json!({ "type": "message_end", "message": assistant_message(text) }),
    )
}

pub fn tool_start(id: &str, name: &str, arguments: Value) -> Emitted {
    emit(
        "tool.start",
        json!({ "toolCallId": id, "toolName": name, "args": arguments }),
    )
}

pub fn tool_end(id: &str, name: &str, output: &str, failed: bool) -> Emitted {
    emit(
        "tool.end",
        json!({
            "toolCallId": id,
            "toolName": name,
            "result": { "content": [{ "type": "text", "text": output }] },
            "isError": failed,
        }),
    )
}

/// The person is asked something in the agent's own UI: `approval` or `question`.
pub fn prompt_start(kind: &'static str) -> Emitted {
    emit("ui.prompt.start", json!({ "kind": kind }))
}

pub fn prompt_end(kind: &'static str) -> Emitted {
    emit("ui.prompt.end", json!({ "kind": kind }))
}

pub fn activity(working: bool) -> Emitted {
    emit("activity.snapshot", json!({ "working": working }))
}

pub fn pi_state(provider: &str, model: &str, thinking_level: &str) -> Emitted {
    emit(
        "pi.state",
        json!({
            "model": { "provider": provider, "id": model, "name": model },
            "thinkingLevel": thinking_level,
        }),
    )
}

/// The prompt's text with a line for each attachment, as pi-axo writes them for Pi: the agent
/// reads each file at its path.
pub fn text_with_attachments(text: &str, attachments: &[FetchedAttachment]) -> String {
    std::iter::once(text.to_owned())
        .chain(attachments.iter().map(attachment_line))
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

pub fn attachment_line(attachment: &FetchedAttachment) -> String {
    format!(
        "[Attached file: {} ({}, {}) at {} axo-asset:{}]",
        attachment.name.as_str(),
        attachment.mime_type.as_str(),
        format_size(attachment.size),
        attachment.path.display(),
        attachment.asset
    )
}

pub fn format_size(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    }
}
