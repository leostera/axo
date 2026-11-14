//! Shared Cua lifecycle. Platform observations and initialization stay in their modules.
use std::sync::{Arc, OnceLock};

use cua_driver_core::tool::ToolRegistry;
use serde_json::{Value, json};

use super::platform;
pub use platform::screen_locked;

struct Runtime {
    tokio: tokio::runtime::Runtime,
    registry: Arc<ToolRegistry>,
}

fn registry() -> ToolRegistry {
    let mut registry = platform::registry();
    registry.register_script_tool();
    let allowed: Vec<_> = super::TOOLS
        .iter()
        .map(|tool| super::cua_name(tool))
        .collect();
    // Filtering tools/list alone leaves forbidden tools reachable through scripts and batches.
    registry.retain_tools(&allowed);
    registry.set_invocation_guard(Arc::new(|tool| {
        let tool = super::our_name(tool).to_owned();
        Box::pin(async move {
            if super::WORKS_LOCKED.contains(&tool.as_str()) {
                return None;
            }
            if platform::locked().await {
                return Some(super::LOCKED.to_owned());
            }
            platform::preflight().await
        })
    }));
    registry
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
        let registry = {
            let _entered = tokio.enter();
            Arc::new(registry())
        };
        registry.init_self_weak();
        Runtime { tokio, registry }
    })
}

pub(super) fn block_on<F: std::future::Future>(future: F) -> F::Output {
    runtime().tokio.block_on(future)
}

pub fn tool_definitions() -> Vec<Value> {
    let list = runtime().registry.tools_list();
    list["tools"].as_array().into_iter().flatten().map(|tool| json!({
        "name":tool["name"], "description":tool["description"], "inputSchema":tool["inputSchema"],
    })).collect()
}

pub fn permissions() -> (bool, bool) {
    platform::permissions()
}

pub fn call(tool: &str, args: Value) -> Value {
    let result = block_on(runtime().registry.invoke(tool, args));
    serde_json::to_value(result).unwrap_or_else(|error| super::error(&error.to_string()))
}

#[cfg(all(test, target_os = "linux"))]
#[path = "linux_desktop_tests.rs"]
mod linux_desktop_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_tools_are_unreachable_even_by_nested_dispatch() {
        let registry = registry();
        assert!(
            registry
                .tool_names()
                .all(|name| super::super::TOOLS.contains(&super::super::our_name(name)))
        );
        for name in [
            "kill_app",
            "get_config",
            "set_config",
            "replay_trajectory",
            "read_file",
        ] {
            assert!(
                registry.get_def(name).is_none(),
                "{name} escaped the allowlist"
            );
        }
    }

    #[test]
    fn host_guard_cannot_be_replaced_by_call_arguments() {
        let mut registry = registry();
        registry.set_invocation_guard(Arc::new(|_| {
            Box::pin(async { Some("host refused".into()) })
        }));
        let result = block_on(registry.invoke(
            "check_permissions",
            json!({"approved":true,"_skip_guard":true}),
        ));
        let value = serde_json::to_value(result).unwrap();
        assert_eq!(value["isError"], true);
        assert!(value.to_string().contains("host refused"));
    }
}
