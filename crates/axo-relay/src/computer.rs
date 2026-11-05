//! Computer use on this Mac from another Mac's script (RFD0028, Computer use from anywhere).
//!
//! The account sends `axo.connections.computer` down this Mac's socket. The host (axod's session
//! manager) runs the gate, asks the person in the calling Session if it must, and runs the tool;
//! this module checks the request, and swaps the images in the answer for attachments uploaded
//! to the account's assets (RFD0030), so the answer stays small and the images show wherever
//! assets do.

use axo_protocol::SessionId;
use axo_protocol::asset::{AssetName, AssetType};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::assets::AssetSource;

pub const METHOD: &str = "axo.connections.computer";
pub const STATUS_METHOD: &str = "axo.connections.computer.status";
/// Images uploaded per answer; more are dropped with a note.
const MAX_IMAGES: usize = 8;
/// `structuredContent` larger than this is dropped with a note: it would not fit a reply.
const MAX_STRUCTURED_BYTES: usize = 512 * 1024;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComputerParams {
    /// The account that sent it; axod refuses a call for any other.
    pub account_id: String,
    pub call_id: String,
    pub tool: String,
    #[serde(default)]
    pub args: Value,
    /// The agent asked for the person to be asked; it never approves.
    #[serde(default)]
    pub confirm: bool,
    /// The Session that called, on another Mac or this one: where the person is asked.
    pub session_id: SessionId,
    /// The calling Mac's label, for the question.
    pub from: String,
    /// How long this call may take in all, the person's answer included.
    pub timeout_ms: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StatusParams {
    account_id: String,
}

/// Checks a request: `Err` is a JSON-RPC error for the reply.
pub fn parse(params: &Value, account_id: &str) -> Result<ComputerParams, (i64, String)> {
    let params: ComputerParams = serde_json::from_value(params.clone())
        .map_err(|error| (-32602, format!("Invalid params: {error}")))?;
    if params.account_id != account_id {
        return Err((-32003, "this Mac belongs to another account".into()));
    }
    if !params.args.is_object() && !params.args.is_null() {
        return Err((-32602, "args must be an object".into()));
    }
    Ok(params)
}

/// Checks a status request.
pub fn parse_status(params: &Value, account_id: &str) -> Result<(), (i64, String)> {
    let params: StatusParams = serde_json::from_value(params.clone())
        .map_err(|error| (-32602, format!("Invalid params: {error}")))?;
    if params.account_id != account_id {
        return Err((-32003, "this Mac belongs to another account".into()));
    }
    Ok(())
}

/// A tool's MCP answer as the account takes it: text as it is, each image uploaded and named by
/// its attachment, anything else said in words. Without a way to upload, images become a note.
pub fn to_account(result: Value, assets: Option<&AssetSource>, tool: &str) -> Value {
    let mut images = 0;
    let content: Vec<Value> = result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|item| match item["type"].as_str() {
            Some("text") => {
                json!({ "type": "text", "text": item["text"].as_str().unwrap_or_default() })
            }
            Some("image") => {
                images += 1;
                if images > MAX_IMAGES {
                    return note(&format!(
                        "[more than {MAX_IMAGES} images; the rest were left out]"
                    ));
                }
                match (assets, upload_image(assets, item, tool, images)) {
                    (_, Ok(attachment)) => json!({ "type": "image", "attachment": attachment }),
                    (None, Err(_)) => note(
                        "[an image this Mac can't store: it is not linked to the account's assets]",
                    ),
                    (Some(_), Err(error)) => {
                        note(&format!("[an image could not be stored: {error}]"))
                    }
                }
            }
            Some(other) => note(&format!("[{other} content left out]")),
            None => note("[content without a type left out]"),
        })
        .collect();
    let mut answer = json!({ "content": content });
    if let Some(structured) = result
        .get("structuredContent")
        .filter(|value| !value.is_null())
    {
        if serde_json::to_vec(structured).map_or(0, |bytes| bytes.len()) <= MAX_STRUCTURED_BYTES {
            answer["structuredContent"] = structured.clone();
        } else if let Some(content) = answer["content"].as_array_mut() {
            content.push(note(
                "[structuredContent was too large to send and was left out]",
            ));
        }
    }
    if result["isError"] == json!(true) {
        answer["isError"] = json!(true);
    }
    answer
}

fn note(text: &str) -> Value {
    json!({ "type": "text", "text": text })
}

fn upload_image(
    assets: Option<&AssetSource>,
    item: &Value,
    tool: &str,
    index: usize,
) -> std::io::Result<axo_protocol::asset::Attachment> {
    let assets = assets.ok_or_else(|| std::io::Error::other("no asset source"))?;
    let data = item["data"].as_str().unwrap_or_default();
    let bytes = axo_protocol::base64::decode(data)?;
    let mime = item["mimeType"].as_str().unwrap_or("image/png");
    let mime_type = AssetType::parse(mime)
        .map_err(|_| std::io::Error::other(format!("{mime} is not an image type assets take")))?;
    let extension = mime.rsplit('/').next().unwrap_or("png");
    let name = AssetName::parse(format!("{tool}-{index}.{extension}"))
        .map_err(|_| std::io::Error::other("the image's name was refused"))?;
    crate::assets::upload(assets, &bytes, name, mime_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_names_this_mac_s_account_and_an_object_for_args() {
        let request = json!({
            "accountId": "a", "callId": "c", "tool": "click", "args": { "pid": 7 }, "confirm": true,
            "sessionId": "00000001-0000-4000-8000-000000000001", "from": "Laptop", "timeoutMs": 60000,
        });
        let parsed = parse(&request, "a").unwrap();
        assert!(parsed.confirm);
        assert_eq!(parse(&request, "b").unwrap_err().0, -32003);
        let mut bad = request.clone();
        bad["args"] = json!([1]);
        assert_eq!(parse(&bad, "a").unwrap_err().0, -32602);
        let mut extra = request;
        extra["approved"] = json!(true);
        assert_eq!(parse(&extra, "a").unwrap_err().0, -32602);
    }

    #[test]
    fn text_passes_and_images_without_assets_become_a_note() {
        let answer = to_account(
            json!({
                "content": [
                    { "type": "text", "text": "Mail — Inbox" },
                    { "type": "image", "data": "aGk=", "mimeType": "image/png" },
                    { "type": "resource", "resource": {} },
                ],
                "structuredContent": { "elements": [] },
                "isError": false,
            }),
            None,
            "get_window_state",
        );
        assert_eq!(
            answer["content"][0],
            json!({ "type": "text", "text": "Mail — Inbox" })
        );
        assert!(
            answer["content"][1]["text"]
                .as_str()
                .unwrap()
                .contains("not linked")
        );
        assert!(
            answer["content"][2]["text"]
                .as_str()
                .unwrap()
                .contains("resource")
        );
        assert_eq!(answer["structuredContent"], json!({ "elements": [] }));
        assert!(answer.get("isError").is_none());
    }
}
