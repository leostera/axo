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
    runtime().registry.tools_list()["tools"]
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
        .collect()
}

pub fn call(tool: &str, mut args: Value) -> Value {
    if EXCLUDED.contains(&tool) {
        return super::error(
            "Composite scripts are not available on Windows; call individual computer tools.",
        );
    }
    if tool == "get_window_state" {
        // The gate must see the same token -> label mapping that the agent saw.
        // Cua's compact default omits structured elements; keep them for this
        // embedded caller, with a bounded default walk rather than legacy 5000.
        args["full_output"] = json!(true);
        if args.get("max_elements").is_none() {
            args["max_elements"] = json!(250);
        }
    }
    let result = runtime()
        .tokio
        .block_on(runtime().registry.invoke(tool, args));
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
