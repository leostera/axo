//! Computer use on this Mac: seeing and operating its apps, embedded in `axod mcp` for this Mac's
//! agents and in axod for other Macs' scripts (RFD0028).
//!
//! This wraps Cua Driver's macOS runtime (`platform-macos`) in-process, so its Accessibility
//! and Screen Recording checks are answered with Axo's grants and it never prompts. Actions are
//! delivered in the background where the app allows it: no focus change, no pointer movement.
//!
//! Only an allowlist of Cua's tools is exposed. The runtime is built on first use, because
//! every Pi starts its own `axod mcp` and most never touch the screen.

use serde_json::{Value, json};

pub mod form;

/// Cua tools agents may call. Left out: process killing, updates, extensions, configuration,
/// recordings and replays, the clipboard, and attaching to the person's logged-in browser.
pub const TOOLS: &[&str] = &[
    "check_permissions",
    "list_apps",
    "list_windows",
    "launch_app",
    "bring_to_front",
    "get_accessibility_tree",
    "get_window_state",
    "screenshot",
    "get_screen_size",
    "get_cursor_position",
    "click",
    "double_click",
    "right_click",
    "scroll",
    "drag",
    "type_text",
    "press_key",
    "hotkey",
    "set_value",
    "invoke_menu",
    "set_window_frame",
    "run_steps",
    "run_script",
    "get_guide",
];

/// What Axo calls Cua's tools where Cua's name says less: `screenshot` is `get_desktop_state`.
const RENAMED: &[(&str, &str)] = &[("screenshot", "get_desktop_state")];

fn cua_name(tool: &str) -> &str {
    RENAMED
        .iter()
        .find(|(ours, _)| *ours == tool)
        .map_or(tool, |(_, cua)| cua)
}

fn our_name(tool: &str) -> &str {
    RENAMED
        .iter()
        .find(|(_, cua)| *cua == tool)
        .map_or(tool, |(ours, _)| ours)
}

/// The tool axod runs itself, not Cua: asks the person for values the agent must not see and
/// fills them in (RFD0029). Never reaches `call`.
pub const REQUEST_INPUT: &str = "request_input";

fn request_input_definition() -> Value {
    json!({
        "name": REQUEST_INPUT,
        "description": "Asks the person for values you must not see, such as a password, a login or a one-time code, and fills them into a window's fields; you get a receipt, never the values. Read the window first with get_window_state. The person is shown Axo's own reading of the app, the page's address and the fields, on their phone, in the browser or on the Mac, and can use their password manager. Name each field by what it is for (`kind`) and, when there is more than one candidate, by its `label` as the read shows it. `submit` names a button to press once filled, such as \"Sign in\". Later reads show the filled values as •••• (filled by you). If the page changed before they answered, nothing is filled: read it again and ask again.",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["pid", "window_id", "fields"],
            "properties": {
                "pid": { "type": "integer" },
                "window_id": { "type": "integer" },
                "fields": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 8,
                    "items": {
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["kind"],
                        "properties": {
                            "kind": { "type": "string", "enum": ["username", "email", "password", "code", "text"] },
                            "label": { "type": "string", "description": "The field's label in the read, e.g. \"Email\"; optional for a lone password field and the username before it." }
                        }
                    }
                },
                "submit": { "type": "string", "description": "A button's label to press once filled, e.g. \"Sign in\"." }
            }
        }
    })
}

/// Hides values in a computer tool's result: every string, quoted part or word for which
/// `hidden` is true becomes `•••• (filled by you)`. Image data is left alone.
pub fn redact(result: &mut Value, hidden: &dyn Fn(&str) -> bool) {
    match result {
        Value::String(text) => {
            if let Some(redacted) = redact_text(text, hidden) {
                *text = redacted;
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|item| redact(item, hidden)),
        Value::Object(object) => {
            let image = object.get("type") == Some(&json!("image"));
            for (key, value) in object.iter_mut() {
                if !(image && key == "data") {
                    redact(value, hidden);
                }
            }
        }
        _ => {}
    }
}

const FILLED: &str = "\u{2022}\u{2022}\u{2022}\u{2022} (filled by you)";

fn redact_text(text: &str, hidden: &dyn Fn(&str) -> bool) -> Option<String> {
    let mut candidates: Vec<&str> = text.split('"').skip(1).step_by(2).collect();
    candidates.extend(text.split(|c: char| c.is_whitespace() || "\"'()[]{},;".contains(c)));
    candidates.push(text);
    let mut found: Vec<&str> = candidates
        .into_iter()
        .filter(|candidate| candidate.chars().count() >= 4 && hidden(candidate))
        .collect();
    if found.is_empty() {
        return None;
    }
    found.sort_by_key(|candidate| std::cmp::Reverse(candidate.len()));
    let mut redacted = text.to_owned();
    for candidate in found {
        redacted = redacted.replace(candidate, FILLED);
    }
    Some(redacted)
}

/// Whether this build can do computer use at all.
pub const AVAILABLE: bool = cfg!(target_os = "macos");

/// The allowlisted tools' definitions: `{ name, description, inputSchema }`.
pub fn tool_definitions() -> Vec<Value> {
    let mut tools = imp::tool_definitions();
    for tool in &mut tools {
        if let Some(name) = tool["name"].as_str() {
            tool["name"] = json!(our_name(name));
        }
    }
    if AVAILABLE {
        tools.push(request_input_definition());
    }
    tools
}

/// Calls one allowlisted tool and returns its MCP result (`content`, optional
/// `structuredContent` and `isError`). Images come back inline as `image` content.
pub fn call(tool: &str, args: Value) -> Value {
    if !TOOLS.contains(&tool) {
        return error(&format!(
            "{tool} is not a computer tool; available: {}, {REQUEST_INPUT}",
            TOOLS.join(", ")
        ));
    }
    imp::call(cua_name(tool), args)
}

/// Whether this process holds the grants computer use needs: `(accessibility, screen_recording)`,
/// from Cua's own probe, which its `check_permissions` tool answers with.
pub fn permissions() -> (bool, bool) {
    imp::permissions()
}

fn error(message: &str) -> Value {
    json!({ "content": [{ "type": "text", "text": message }], "isError": true })
}

#[cfg(target_os = "macos")]
mod imp {
    use std::sync::{Arc, OnceLock};

    use cua_driver_core::tool::ToolRegistry;
    use serde_json::{Value, json};

    struct Runtime {
        tokio: tokio::runtime::Runtime,
        registry: Arc<ToolRegistry>,
    }

    fn runtime() -> &'static Runtime {
        static RUNTIME: OnceLock<Runtime> = OnceLock::new();
        RUNTIME.get_or_init(|| {
            let tokio = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .thread_name("axo-computer")
                .build()
                .expect("the computer-use runtime starts");
            let cursor = cursor_overlay::CursorConfig {
                enabled: false,
                ..Default::default()
            };
            // Axo owns the permission UX (the driver never prompts), and is the host it reports.
            let mut registry = platform_macos::register_tools_with_cursor(
                cursor,
                false,
                true,
                Some("dev.leostera.axo".into()),
            );
            registry.register_script_tool();
            let registry = Arc::new(registry);
            registry.init_self_weak();
            Runtime { tokio, registry }
        })
    }

    pub fn tool_definitions() -> Vec<Value> {
        let list = runtime().registry.tools_list();
        list["tools"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|tool| {
                tool["name"]
                    .as_str()
                    .is_some_and(|name| super::TOOLS.contains(&super::our_name(name)))
            })
            // The script tool is registered twice (by the registry and by register_script_tool).
            .filter({
                let mut seen = std::collections::HashSet::new();
                move |tool| seen.insert(tool["name"].to_string())
            })
            .map(|tool| {
                json!({
                    "name": tool["name"],
                    "description": tool["description"],
                    "inputSchema": tool["inputSchema"],
                })
            })
            .collect()
    }

    pub fn permissions() -> (bool, bool) {
        let status = platform_macos::permissions::current_status();
        (status.accessibility, status.screen_recording)
    }

    pub fn call(tool: &str, args: Value) -> Value {
        let runtime = runtime();
        let result = runtime.tokio.block_on(runtime.registry.invoke(tool, args));
        serde_json::to_value(result).unwrap_or_else(|error| super::error(&error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_filled_value_is_hidden_wherever_it_shows_but_not_in_images() {
        let hidden = |candidate: &str| candidate == "me@example.com";
        let mut result = json!({ "content": [
            { "type": "text", "text": "[16] AXTextField = \"me@example.com\" (to me@example.com)" },
            { "type": "image", "data": "me@example.com", "mimeType": "image/png" },
        ], "structuredContent": { "tree_markdown": "me@example.com" } });
        redact(&mut result, &hidden);
        assert_eq!(
            result["content"][0]["text"],
            format!("[16] AXTextField = \"{FILLED}\" (to {FILLED})")
        );
        assert_eq!(result["content"][1]["data"], "me@example.com");
        assert_eq!(result["structuredContent"]["tree_markdown"], FILLED);
    }

    #[test]
    fn screenshot_is_cua_s_get_desktop_state() {
        assert_eq!(cua_name("screenshot"), "get_desktop_state");
        assert_eq!(our_name("get_desktop_state"), "screenshot");
        assert_eq!(cua_name("click"), "click");
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use serde_json::Value;

    pub fn tool_definitions() -> Vec<Value> {
        Vec::new()
    }

    pub fn call(_tool: &str, _args: Value) -> Value {
        super::error("computer use is only available on macOS")
    }

    pub fn permissions() -> (bool, bool) {
        (false, false)
    }
}
