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
    "get_desktop_state",
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

/// Whether this build can do computer use at all.
pub const AVAILABLE: bool = cfg!(target_os = "macos");

/// The allowlisted tools' definitions: `{ name, description, inputSchema }`.
pub fn tool_definitions() -> Vec<Value> {
    imp::tool_definitions()
}

/// Calls one allowlisted tool and returns its MCP result (`content`, optional
/// `structuredContent` and `isError`). Images come back inline as `image` content.
pub fn call(tool: &str, args: Value) -> Value {
    if !TOOLS.contains(&tool) {
        return error(&format!(
            "{tool} is not a computer tool; available: {}",
            TOOLS.join(", ")
        ));
    }
    imp::call(tool, args)
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
                    .is_some_and(|name| super::TOOLS.contains(&name))
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
