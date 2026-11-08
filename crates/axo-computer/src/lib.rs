//! Native computer use in axod, for local agents over MCP and remote scripts over the relay.
//!
//! Cua's platform runtime is embedded in-process. macOS uses Axo's Accessibility/Screen
//! Recording grants; Linux uses its desktop session's X11, AT-SPI and Wayland capabilities.
//! Missing compositor support, a locked desktop or an unverifiable login fails closed.
//! Linux portal consent is separate from Apple's grants and may require the person.
//!
//! Only an allowlist of Cua's tools is exposed. The driver is built on first use, because most
//! Sessions never touch the screen. It runs on a small tokio runtime of its own, and [`call`]
//! blocks its caller (axod calls it from the blocking pool): the driver's tasks make synchronous
//! Accessibility and window-server calls that can take seconds, and on axod's runtime they would
//! hold the workers every Session's sockets and terminals need.

use serde_json::{Value, json};

pub mod filled;
pub mod form;
pub mod gate;
#[cfg(all(test, target_os = "linux"))]
mod linux_launch_tests;
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod scripts;
#[cfg(target_os = "linux")]
mod input_targets;

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
    #[cfg(target_os = "linux")]
    "input_targets",
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

/// Native AX on macOS and exact AT-SPI object binding on Linux; delivery still needs confirmation.
pub const FORM_INPUT_AVAILABLE: bool = cfg!(any(target_os = "macos", target_os = "linux"));
pub const INPUT_AVAILABLE: bool = cfg!(any(target_os = "macos", target_os = "linux"));

#[cfg(target_os = "linux")]
fn request_input_definition() -> Value {
    let mut definition = form_input_definition();
    let gui = definition["inputSchema"].take();
    let sudo = json!({
        "name": REQUEST_INPUT,
        "description": "Run one noninteractive sudo command with the person's explicit consent and, if needed, a password entered on their own device. Passwords go only through sudo's private askpass pipe, never a terminal, transcript or tool result. The calling Session determines the directory. Returns only an exit receipt; stdout/stderr are discarded. This does not fill existing terminal prompts or GUI fields. Never pass passwords or approval claims, and never automatically retry an uncertain command.",
        "inputSchema": {
            "type":"object", "additionalProperties":false, "required":["target"],
            "properties":{"target":{"type":"object","additionalProperties":false,"required":["kind","argv"],
                "properties":{"kind":{"const":"sudo"},"argv":{"type":"array","minItems":1,"maxItems":32,
                    "items":{"type":"string"},"description":"Exact command argument array; first item is an absolute executable path. No shell wrapping is added."}}}}
        }
    });
    definition["inputSchema"] = json!({"oneOf":[gui,sudo["inputSchema"]]});
    definition["description"] = json!(
        "First use input_targets({pid}) then input_targets({pid,window_id}) to discover and inspect a secure-input target. Ask for person-only input into bound Linux AT-SPI GUI fields using pid, 64-bit accessibility window_id, fields and optional submit. Passwords require a verified secure field; changed, unsupported or unconfirmed targets fail without keyboard/clipboard fallback. Browser origins come from document metadata, never the address bar. Plain text is redacted and screenshots are withheld after GUI fills; protection survives daemon restarts. Native compositor window IDs are not AT-SPI handles. Alternatively use target:{kind:\"sudo\",argv:[\"/absolute/program\",...]} for private sudo askpass input. Never pass values or approvals, or retry an uncertain fill automatically."
    );
    definition
}

#[cfg(not(target_os = "linux"))]
fn request_input_definition() -> Value {
    form_input_definition()
}

fn form_input_definition() -> Value {
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

/// Whether this build can do computer use at all.
pub const AVAILABLE: bool = cfg!(any(target_os = "macos", target_os = "linux", windows));

/// The allowlisted tools' definitions: `{ name, description, inputSchema }`.
pub fn tool_definitions() -> Vec<Value> {
    let mut tools = imp::tool_definitions();
    for tool in &mut tools {
        if let Some(name) = tool["name"].as_str() {
            tool["name"] = json!(our_name(name));
        }
    }
    if INPUT_AVAILABLE {
        tools.push(request_input_definition());
    }
    tools
}

/// Calls one allowlisted tool and returns its MCP result (`content`, optional
/// `structuredContent` and `isError`). Images come back inline as `image` content. The caller has
/// already had `gate` check the call; `gate` checks every action inside a `run_script` itself
/// (RFD0070), learns the elements of every read, and filled values are hidden from the result.
pub fn call(gate: &'static gate::Gate, tool: &str, args: Value) -> Value {
    if !TOOLS.contains(&tool) {
        return error(&format!(
            "{tool} is not a computer tool; available: {}, {REQUEST_INPUT}",
            TOOLS.join(", ")
        ));
    }
    if let Some(refusal) = refusal_while(tool, imp::screen_locked) {
        return refusal;
    }
    imp::call(gate, cua_name(tool), args)
}

/// Whether a read's elements were added for the gate, and so are taken out again.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Read {
    AsAsked,
    ElementsAdded,
}

/// Cua's `get_window_state` answers Markdown only by default, which names no element for the gate.
/// A read that asked for no format asks for both, so the gate learns each element's role and
/// label; the caller still gets Cua's default shape (RFD0070).
fn ask_for_elements(tool: &str, args: &mut Value) -> Read {
    let asked = !args["tree_format"].is_null() || args["full_output"] == json!(true);
    match (tool, args.as_object_mut()) {
        ("get_window_state", Some(object)) if !asked => {
            object.insert("tree_format".into(), json!("both"));
            Read::ElementsAdded
        }
        _ => Read::AsAsked,
    }
}

/// What every result goes through before anyone sees it: the gate learns from it, the elements
/// it asked for are taken out again, and filled values are hidden.
fn settle_structured(gate: &gate::Gate, tool: &str, read: Read, structured: &mut Value) {
    gate.remember(tool, structured);
    if read == Read::ElementsAdded {
        if let Some(object) = structured.as_object_mut() {
            object.remove("elements");
        }
    }
    filled::hide(structured);
}

/// The refusal for `tool` if the Mac is locked now; the lock is only looked at for tools that
/// need the screen or input.
fn refusal_while(tool: &str, locked: impl Fn() -> bool) -> Option<Value> {
    (!WORKS_LOCKED.contains(&tool) && locked()).then(|| error(LOCKED))
}

/// What a computer call on a locked Mac answers. Locked, the login window owns the screen:
/// screenshots show it, and clicks and keys go to it, not to the apps (RFD0028).
#[cfg(target_os = "linux")]
pub const LOCKED: &str = "Not done: this Linux desktop is locked, inactive or could not be verified. Computer use requires one active, unlocked graphical login for this user; bash and other tools still work.";
#[cfg(not(any(target_os = "linux", windows)))]
pub const LOCKED: &str = "Not done: this Mac is locked, so its screen and input belong to the login window. Computer use needs the person to unlock it; bash and the other tools still work.";
#[cfg(windows)]
pub const LOCKED: &str = "Not done: this computer is locked or its interactive desktop is unavailable. Computer use needs the person to unlock it; the other tools still work.";

/// Tools that touch neither the screen nor input, and answer the same locked or not.
const WORKS_LOCKED: &[&str] = &["check_permissions", "get_guide"];

/// Whether desktop use must be refused for lock state. Linux also refuses inactive,
/// ambiguous or unverifiable graphical sessions instead of treating unknown as unlocked.
pub fn screen_locked() -> bool {
    imp::screen_locked()
}

/// Observed `(accessibility, screen_capture)` capability. macOS uses Cua's TCC probe;
/// Linux does not interpret XWayland or a reachable portal as native capture permission.
pub fn permissions() -> (bool, bool) {
    imp::permissions()
}

fn error(message: &str) -> Value {
    json!({ "content": [{ "type": "text", "text": message }], "isError": true })
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod native;
#[cfg(any(target_os = "macos", target_os = "linux"))]
use native as imp;
#[cfg(target_os = "macos")]
#[path = "macos.rs"]
mod platform;
#[cfg(target_os = "linux")]
#[path = "linux.rs"]
mod platform;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn on_a_locked_mac_only_the_tools_that_need_no_screen_run() {
        for tool in [
            "screenshot",
            "click",
            "type_text",
            "get_window_state",
            "run_steps",
        ] {
            let refused = refusal_while(tool, || true).expect(tool);
            assert_eq!(refused["isError"], true);
            assert!(
                refused["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("locked")
            );
            assert!(
                refusal_while(tool, || false).is_none(),
                "{tool} runs unlocked"
            );
        }
        let looked = std::cell::Cell::new(false);
        for tool in WORKS_LOCKED {
            assert!(
                refusal_while(tool, || {
                    looked.set(true);
                    true
                })
                .is_none()
            );
        }
        assert!(!looked.get(), "the lock is not looked at for them");
        assert!(WORKS_LOCKED.iter().all(|tool| TOOLS.contains(tool)));
    }

    #[test]
    fn a_read_that_named_no_format_carries_elements_for_the_gate_only() {
        let gate = gate::Gate::new(None);
        let mut args = json!({ "pid": 7, "window_id": 9 });
        let read = ask_for_elements("get_window_state", &mut args);
        assert_eq!((read, &args["tree_format"]), (Read::ElementsAdded, &json!("both")));
        let mut structured = json!({ "pid": 7, "window_id": 9, "tree_markdown": "[4] AXButton \"Delete account\"",
            "elements": [{ "element_token": "s1:4", "role": "AXButton", "label": "Delete account" }] });
        settle_structured(&gate, "get_window_state", read, &mut structured);
        assert!(structured.get("elements").is_none(), "the agent gets Cua's default read");
        let verdict = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(
            gate.check("click", &json!({ "pid": 7, "window_id": 9, "element_token": "s1:4" }), false),
        );
        let gate::Verdict::Ask(question) = verdict else { panic!("{verdict:?}") };
        assert!(question.contains("Delete account"), "{question}");

        for asked in [json!({ "tree_format": "markdown" }), json!({ "full_output": true })] {
            let mut args = asked.clone();
            assert_eq!(ask_for_elements("get_window_state", &mut args), Read::AsAsked);
            assert_eq!(args, asked);
        }
        let mut click = json!({ "element_token": "s1:4" });
        assert_eq!(ask_for_elements("click", &mut click), Read::AsAsked);
    }

    #[test]
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    fn advertised_tools_match_the_allowlist_without_duplicates_or_unimplemented_input() {
        let definitions = tool_definitions();
        let names: std::collections::HashSet<_> = definitions
            .iter()
            .map(|tool| tool["name"].as_str().unwrap())
            .collect();
        assert_eq!(names.len(), definitions.len());
        assert!(TOOLS.iter().all(|tool| names.contains(tool)));
        assert_eq!(names.contains(REQUEST_INPUT), INPUT_AVAILABLE);
        assert_eq!(names.len(), TOOLS.len() + usize::from(INPUT_AVAILABLE));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn secure_linux_form_input_refuses_before_collecting_values() {
        assert!(FORM_INPUT_AVAILABLE);
        assert!(INPUT_AVAILABLE);
        let definition = request_input_definition();
        assert_eq!(
            definition["inputSchema"]["oneOf"][0]["required"],
            json!(["pid", "window_id", "fields"])
        );
        assert_eq!(
            definition["inputSchema"]["oneOf"][1]["required"],
            json!(["target"])
        );
        assert!(form::Form::read(std::process::id() as i32, 0).is_err());
    }

    #[test]
    #[cfg(target_os = "linux")]
    #[ignore = "requires the real logind desktop to be locked"]
    fn real_linux_locked_session_refuses_before_driver_dispatch() {
        assert_eq!(std::env::var("AXO_TEST_EXPECT_LOCKED").as_deref(), Ok("1"));
        assert!(
            screen_locked(),
            "the real graphical desktop must be locked for this acceptance test"
        );
        // Invalid self-owned target and a pure script remain harmless even if the person
        // unlocks during this test. Do not use an unscoped screenshot or input action here.
        for (tool, args) in [
            (
                "get_window_state",
                json!({"pid":std::process::id(),"window_id":0}),
            ),
            ("run_script", json!({"script":"return 'harmless fixture';"})),
        ] {
            let gate: &'static gate::Gate = Box::leak(Box::new(gate::Gate::new(None)));
            let result = call(gate, tool, args);
            assert_eq!(result["isError"], true);
            assert!(
                result["content"][0]["text"]
                    .as_str()
                    .unwrap()
                    .contains("locked")
            );
        }
    }

    #[test]
    fn screenshot_is_cua_s_get_desktop_state() {
        assert_eq!(cua_name("screenshot"), "get_desktop_state");
        assert_eq!(our_name("get_desktop_state"), "screenshot");
        assert_eq!(cua_name("click"), "click");
    }
}

#[cfg(windows)]
#[path = "windows.rs"]
mod imp;

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
mod imp {
    use serde_json::Value;

    pub fn tool_definitions() -> Vec<Value> {
        Vec::new()
    }

    pub fn call(_gate: &'static crate::gate::Gate, _tool: &str, _args: Value) -> Value {
        super::error("computer use is only available on macOS")
    }

    pub fn screen_locked() -> bool {
        false
    }

    pub fn permissions() -> (bool, bool) {
        (false, false)
    }
}
