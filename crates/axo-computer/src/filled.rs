//! What the person filled in through `request_input` (RFD0029, RFD0070), hidden from every
//! computer result in this process: the agent's direct calls, other Macs' calls, and the reads a
//! script makes before the script sees them, so no script can transform a value it never got.
//!
//! A value is replaced wherever it occurs inside a string, not only as a whole word. The values
//! stay in axod's memory, wiped when forgotten; nothing exports them or their hashes. Image data
//! is left alone: secure fields are masked by macOS there, plain fields are not (RFD0029).

use std::collections::VecDeque;
use std::sync::Mutex;

use serde_json::Value;
use zeroize::Zeroizing;

#[cfg(target_os = "linux")]
#[path = "filled_linux_privacy.rs"]
mod gui_privacy;
#[cfg(target_os = "linux")]
static GUI_PRIVACY: Mutex<Option<gui_privacy::Privacy>> = Mutex::new(None);

#[cfg(target_os = "linux")]
fn gui_privacy() -> std::sync::MutexGuard<'static, Option<gui_privacy::Privacy>> {
    GUI_PRIVACY
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Load durable protection before this daemon serves any computer observations.
#[cfg(target_os = "linux")]
pub fn keep_gui_privacy(path: std::path::PathBuf) {
    *gui_privacy() = Some(gui_privacy::Privacy::new(Some(path)));
}

/// Register before a GUI write; refuse delivery if durability or capacity is unavailable.
#[cfg(target_os = "linux")]
pub fn remember_gui(value: &str) -> Result<(), ()> {
    gui_privacy()
        .get_or_insert_with(Default::default)
        .remember(value)
}

/// What a hidden value reads as.
pub const FILLED: &str = "\u{2022}\u{2022}\u{2022}\u{2022} (filled by you)";
/// Values remembered at most; the oldest go first.
const MAX_VALUES: usize = 256;
/// Shorter values are too common to hide wherever they appear.
#[cfg(not(windows))]
const SHORTEST: usize = 4;
#[cfg(windows)]
const SHORTEST: usize = 1;

/// The values filled in, oldest first. One store per process: every computer call in axod reads
/// through it.
static VALUES: Mutex<VecDeque<Zeroizing<String>>> = Mutex::new(VecDeque::new());

fn values() -> std::sync::MutexGuard<'static, VecDeque<Zeroizing<String>>> {
    // A list of whole values is never left half-written; hiding must not stop after a panic.
    VALUES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Hides `value` from every later result. Call it before the value is filled in, so no read in
/// between can catch it.
pub fn remember(value: &str) {
    if value.chars().count() < SHORTEST {
        return;
    }
    let mut values = values();
    if values.iter().any(|known| known.as_str() == value) {
        return;
    }
    if values.len() >= MAX_VALUES {
        values.pop_front();
    }
    values.push_back(Zeroizing::new(value.to_owned()));
}

/// Hides every remembered value in a result, image data excepted.
pub fn hide(result: &mut Value) {
    #[cfg(target_os = "linux")]
    if let Some(privacy) = gui_privacy().as_ref() {
        privacy.apply(result);
    }
    let values = values();
    if values.is_empty() {
        return;
    }
    let mut longest_first: Vec<&str> = values.iter().map(|value| value.as_str()).collect();
    longest_first.sort_by_key(|value| std::cmp::Reverse(value.len()));
    hide_in(result, &longest_first);
}

/// Hides the values in one string; `true` if anything was hidden.
pub fn hide_text(text: &mut String) -> bool {
    #[cfg(target_os = "linux")]
    if let Some(privacy) = gui_privacy().as_ref() {
        let mut wrapped = Value::String(text.clone());
        privacy.apply(&mut wrapped);
        let sanitized = wrapped.as_str().unwrap_or(FILLED);
        if sanitized != text.as_str() {
            *text = sanitized.to_owned();
            return true;
        }
    }
    let values = values();
    let mut longest_first: Vec<&str> = values.iter().map(|value| value.as_str()).collect();
    longest_first.sort_by_key(|value| std::cmp::Reverse(value.len()));
    replace(text, &longest_first)
}

fn hide_in(result: &mut Value, values: &[&str]) {
    match result {
        Value::String(text) => {
            replace(text, values);
        }
        Value::Array(items) => items.iter_mut().for_each(|item| hide_in(item, values)),
        Value::Object(object) => {
            let image = object.get("type").and_then(Value::as_str) == Some("image");
            for (key, value) in object.iter_mut() {
                if !(image && key == "data") {
                    hide_in(value, values);
                }
            }
        }
        _ => {}
    }
}

fn replace(text: &mut String, values: &[&str]) -> bool {
    let mut hid = false;
    for value in values {
        if text.contains(value) {
            *text = text.replace(value, FILLED);
            hid = true;
        }
    }
    hid
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_filled_value_is_hidden_wherever_it_shows_but_not_in_images() {
        remember("me@example.com");
        remember("abc");
        remember("∑");
        let mut result = json!({ "content": [
            { "type": "text", "text": "[16] AXTextField = \"me@example.com\" (to me@example.com)" },
            { "type": "text", "text": "Signed in as me@example.com. user:me@example.com! abc ∑" },
            { "type": "image", "data": "me@example.com", "mimeType": "image/png" },
        ], "structuredContent": { "tree_markdown": "me@example.com" } });
        hide(&mut result);
        assert_eq!(
            result["content"][0]["text"],
            format!("[16] AXTextField = \"{FILLED}\" (to {FILLED})")
        );
        // Before RFD0070 only whole words were hidden: a trailing "." or a "user:" leaked it.
        let (short, single) = if cfg!(windows) {
            (FILLED, FILLED)
        } else {
            ("abc", "∑")
        };
        assert_eq!(
            result["content"][1]["text"],
            format!("Signed in as {FILLED}. user:{FILLED}! {short} {single}"),
            "Windows hides even a single character; Unix retains its minimum-length policy"
        );
        assert_eq!(result["content"][2]["data"], "me@example.com");
        assert_eq!(result["structuredContent"]["tree_markdown"], FILLED);
    }

    #[test]
    fn the_longest_value_is_hidden_first() {
        remember("hunter2-secret");
        remember("hunter2-secret-and-more");
        let mut text = "hunter2-secret-and-more".to_owned();
        assert!(hide_text(&mut text));
        assert_eq!(text, FILLED);
    }
}
