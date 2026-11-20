//! The same pinned Cua runtime as macOS, using its native UIA/Win32 backend.
use cua_driver_core::tool::ToolRegistry;
use serde_json::{Value, json};
use std::sync::{Arc, OnceLock};

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
        let registry = Arc::new(platform_windows::register_tools_with_cursor(
            cursor_overlay::CursorConfig {
                enabled: false,
                ..Default::default()
            },
            false,
        ));
        registry.init_self_weak();
        Runtime { tokio, registry }
    })
}

// Composite scripts can call arbitrary registry tools internally. Keep them out
// until their individual actions can pass through axod's gate, too.
const EXCLUDED: &[&str] = &["run_script", "run_steps"];

pub fn tool_definitions() -> Vec<Value> {
    let mut tools: Vec<Value> = runtime().registry.tools_list()["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|tool| {
            tool["name"].as_str().is_some_and(|name| {
                let ours = super::our_name(name);
                super::TOOLS.contains(&ours) && !EXCLUDED.contains(&ours)
            })
        })
        .map(|tool| {
            let mut schema = tool["inputSchema"].clone();
            if let Some(properties) = schema["properties"].as_object_mut() {
                properties.remove("screenshot_out_file");
            }
            json!({"name":tool["name"],"description":tool["description"],"inputSchema":schema})
        })
        .collect();
    tools.push(json!({"name":"run_steps","description":"Run 1–32 computer calls in order. Every action passes Axo's gate; a decline, failure, disconnect or permission change stops the sequence. Use current window and element tokens.","inputSchema":{"type":"object","required":["steps"],"additionalProperties":false,"properties":{"steps":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"object","required":["tool","args"],"additionalProperties":false,"properties":{"tool":{"type":"string"},"args":{"type":"object"},"confirm":{"type":"boolean"}}}}}}}));
    tools
}

pub fn call(gate: &'static crate::gate::Gate, tool: &str, mut args: Value) -> Value {
    if EXCLUDED.contains(&tool) {
        return super::error(
            "Composite scripts are not available on Windows; call individual computer tools.",
        );
    }
    let read = super::ask_for_elements(tool, &mut args);
    if tool == "get_window_state" {
        if args.get("max_elements").is_none() {
            args["max_elements"] = json!(250);
        }
    }
    let mut result = runtime()
        .tokio
        .block_on(runtime().registry.invoke(tool, args));
    if let Some(structured) = result.structured_content.as_mut() {
        super::settle_structured(gate, tool, read, structured);
    }
    for content in &mut result.content {
        if let cua_driver_core::protocol::Content::Text { text, .. } = content {
            crate::filled::hide_text(text);
        }
    }
    serde_json::to_value(result).unwrap_or_else(|error| super::error(&error.to_string()))
}

pub fn permissions() -> (bool, bool) {
    let available = !screen_locked();
    (available, available)
}

/// A locked session, UAC secure desktop, disconnected session, or failed probe
/// is unavailable. Never switch desktops, request elevation, or dismiss consent.
pub fn screen_locked() -> bool {
    use std::ffi::c_void;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcessId() -> u32;
        fn ProcessIdToSessionId(process: u32, session: *mut u32) -> i32;
    }
    #[link(name = "Wtsapi32")]
    unsafe extern "system" {
        fn WTSQuerySessionInformationW(
            server: *mut c_void,
            session: u32,
            class: u32,
            buffer: *mut *mut c_void,
            bytes: *mut u32,
        ) -> i32;
        fn WTSFreeMemory(buffer: *mut c_void);
    }
    #[link(name = "user32")]
    unsafe extern "system" {
        fn OpenInputDesktop(flags: u32, inherit: i32, access: u32) -> *mut c_void;
        fn GetUserObjectInformationW(
            handle: *mut c_void,
            index: i32,
            info: *mut c_void,
            length: u32,
            needed: *mut u32,
        ) -> i32;
        fn CloseDesktop(handle: *mut c_void) -> i32;
    }
    // DESKTOP_READOBJECTS; UOI_NAME. Every returned handle is closed.
    unsafe {
        // A disconnected RDP session can still own a desktop named Default. Query our
        // actual session too; neither another user's active session nor Session 0 counts.
        let mut session = 0;
        if ProcessIdToSessionId(GetCurrentProcessId(), &mut session) == 0 {
            return true;
        }
        let mut buffer = std::ptr::null_mut();
        let mut bytes = 0;
        let queried =
            WTSQuerySessionInformationW(std::ptr::null_mut(), session, 8, &mut buffer, &mut bytes);
        let active = queried != 0
            && !buffer.is_null()
            && bytes >= 4
            && std::ptr::read_unaligned(buffer.cast::<u32>()) == 0; // WTSActive
        if !buffer.is_null() {
            WTSFreeMemory(buffer);
        }
        if !active {
            return true;
        }
        let desktop = OpenInputDesktop(0, 0, 1);
        if desktop.is_null() {
            return true;
        }
        let mut name = [0u16; 128];
        let mut needed = 0;
        let ok = GetUserObjectInformationW(
            desktop,
            2,
            name.as_mut_ptr().cast(),
            std::mem::size_of_val(&name) as u32,
            &mut needed,
        );
        CloseDesktop(desktop);
        ok == 0
            || !String::from_utf16_lossy(
                &name[..name.iter().position(|c| *c == 0).unwrap_or(name.len())],
            )
            .eq_ignore_ascii_case("default")
    }
}
