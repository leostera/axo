//! `run_script` through the gate (RFD0070): a script's actions are checked one by one.
//!
//! Cua's script tool calls tools by name through the registry it was registered on. A script
//! therefore runs in its own *script registry*: one [`GatedTool`] per tool of the driver's
//! registry, plus Cua's script tool. A gated tool asks the gate about its call, as the `computer`
//! tool does for a direct one, and only on Allow invokes the driver's tool; its result goes
//! through the same settling as a direct call's (the gate learns the read's elements, filled
//! values are hidden), so the script never sees a filled value either.
//!
//! A script cannot ask the person in the middle of running: an action the gate would ask about
//! fails in the script, which tells the agent to make it its own `computer` call, where the person
//! is asked about that action alone.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use cua_driver_core::protocol::ToolResult;
use cua_driver_core::script_tool::RUN_SCRIPT_TOOL;
use cua_driver_core::tool::{Tool, ToolDef, ToolRegistry};
use serde_json::Value;

use crate::gate::{Gate, Verdict};

/// The registry scripts run in, over `driver`'s tools.
pub(crate) fn registry(driver: Arc<ToolRegistry>, gate: &'static Gate) -> Arc<ToolRegistry> {
    let mut scripts = ToolRegistry::new();
    let definitions: Vec<ToolDef> = driver
        .iter_defs()
        .filter(|(name, _)| *name != RUN_SCRIPT_TOOL)
        .map(|(_, definition)| definition.clone())
        .collect();
    for definition in definitions {
        scripts.register(Box::new(GatedTool {
            definition,
            driver: Arc::clone(&driver),
            gate,
        }));
    }
    scripts.register_script_tool();
    // The same lock and preflight checks as the driver's registry, before the script runs.
    scripts.set_invocation_guard(crate::imp::invocation_guard());
    let scripts = Arc::new(scripts);
    scripts.init_self_weak();
    scripts
}

/// One driver tool, as a script reaches it.
struct GatedTool {
    definition: ToolDef,
    driver: Arc<ToolRegistry>,
    gate: &'static Gate,
}

/// What a script hears when its action needs the person.
fn needs_the_person(question: &str) -> String {
    format!(
        "Not done in a script: this needs the person. Do it as its own computer call, so they can be asked.\n{question}"
    )
}

impl GatedTool {
    async fn run(&self, mut args: Value) -> ToolResult {
        let name = self.definition.name.as_str();
        match self.gate.check(name, &args, false).await {
            Verdict::Allow => {}
            Verdict::Ask(question) => {
                log::info!("event=computer.script_action_refused tool={name} reason=ask");
                return ToolResult::error(needs_the_person(&question));
            }
            Verdict::Refuse(why) => {
                log::info!("event=computer.script_action_refused tool={name} reason=refused");
                return ToolResult::error(why);
            }
        }
        let read = crate::ask_for_elements(name, &mut args);
        let mut result = self.driver.invoke(name, args).await;
        crate::imp::settle(self.gate, name, read, &mut result);
        result
    }
}

// `Tool` is an `async_trait`; this is the signature it expands `async fn invoke` to.
impl Tool for GatedTool {
    fn def(&self) -> &ToolDef {
        &self.definition
    }

    /// The driver's registry, which this tool invokes, takes the process-wide input lane for the
    /// real tool. Taking it here too would wait on itself: Cua's lane is not reentrant.
    fn has_independent_input_lane(&self, _args: &Value) -> bool {
        true
    }

    fn invoke<'life0, 'async_trait>(
        &'life0 self,
        args: Value,
    ) -> Pin<Box<dyn Future<Output = ToolResult> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(self.run(args))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cua_driver_core::protocol::Content;
    use serde_json::json;
    use std::sync::Mutex;

    type Calls = Arc<Mutex<Vec<(String, Value)>>>;

    /// Mail's Inbox: a "Send" and a "Cancel" button.
    struct Fake {
        definition: ToolDef,
        calls: Calls,
    }

    impl Tool for Fake {
        fn def(&self) -> &ToolDef {
            &self.definition
        }

        fn invoke<'life0, 'async_trait>(
            &'life0 self,
            args: Value,
        ) -> Pin<Box<dyn Future<Output = ToolResult> + Send + 'async_trait>>
        where
            'life0: 'async_trait,
            Self: 'async_trait,
        {
            let name = self.definition.name.clone();
            self.calls.lock().unwrap().push((name.clone(), args.clone()));
            Box::pin(async move {
                match name.as_str() {
                    "get_window_state" => ToolResult::text("[1] AXButton \"Send\"\n[2] AXButton \"Cancel\"\nTo: me@example.com")
                        .with_structured(json!({
                            "pid": 42, "window_id": 7, "app_name": "Mail", "window_title": "Inbox",
                            "snapshot_id": "s9",
                            "tree_markdown": "[1] AXButton \"Send\"\n[2] AXButton \"Cancel\"\nTo: me@example.com",
                            "elements": [
                                { "element_index": 1, "element_token": "s9:1", "role": "AXButton", "label": "Send", "depth": 1 },
                                { "element_index": 2, "element_token": "s9:2", "role": "AXButton", "label": "Cancel", "depth": 1 },
                            ],
                        })),
                    _ => ToolResult::text(format!("{name} done")),
                }
            })
        }
    }

    fn scripts() -> (Arc<ToolRegistry>, Calls) {
        let calls: Calls = Arc::default();
        let mut driver = ToolRegistry::new();
        for name in ["get_window_state", "click", "press_key", "type_text", "list_windows", "list_apps"] {
            driver.register(Box::new(Fake {
                definition: ToolDef {
                    name: name.into(),
                    description: "fake".into(),
                    input_schema: json!({ "type": "object" }),
                    read_only: name.starts_with("get") || name.starts_with("list"),
                    destructive: false,
                    idempotent: false,
                    open_world: false,
                },
                calls: Arc::clone(&calls),
            }));
        }
        let driver = Arc::new(driver);
        driver.init_self_weak();
        let gate: &'static Gate = Box::leak(Box::new(Gate::new(None)));
        (registry(driver, gate), calls)
    }

    fn run(registry: &ToolRegistry, script: &str) -> ToolResult {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(registry.invoke(RUN_SCRIPT_TOOL, json!({ "script": script })))
    }

    fn text(result: &ToolResult) -> String {
        result
            .content
            .iter()
            .filter_map(|content| match content {
                Content::Text { text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn clicked(calls: &Calls) -> Vec<String> {
        calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(name, _)| name == "click")
            .map(|(_, args)| args["element_token"].as_str().unwrap_or_default().to_owned())
            .collect()
    }

    #[test]
    fn a_flagged_action_in_a_script_never_runs_however_its_source_hides_it() {
        // Before RFD0070 the gate looked only at the source, so this ran and clicked Send.
        let (scripts, calls) = scripts();
        let result = run(
            &scripts,
            r#"await cua.call("get_window_state", { pid: 42, window_id: 7 });
               const word = ["S", "e", "n", "d"].join("");
               await cua.call("click", { pid: 42, window_id: 7, element_token: "s9:1" });
               return word;"#,
        );
        assert_eq!(result.is_error, Some(true), "{}", text(&result));
        assert!(text(&result).contains("needs the person"), "{}", text(&result));
        assert!(clicked(&calls).is_empty(), "Send was clicked");
    }

    #[test]
    fn an_action_the_gate_passes_runs_in_the_script() {
        let (scripts, calls) = scripts();
        let result = run(
            &scripts,
            r#"await cua.call("get_window_state", { pid: 42, window_id: 7 });
               await cua.call("click", { pid: 42, window_id: 7, element_token: "s9:2" });
               return "ok";"#,
        );
        assert_ne!(result.is_error, Some(true), "{}", text(&result));
        assert_eq!(clicked(&calls), ["s9:2"]);
    }

    #[test]
    fn an_element_the_script_never_read_is_not_clicked() {
        let (scripts, calls) = scripts();
        let result = run(
            &scripts,
            r#"await cua.call("click", { pid: 42, window_id: 7, element_token: "s9:2" });"#,
        );
        assert_eq!(result.is_error, Some(true), "{}", text(&result));
        assert!(clicked(&calls).is_empty());
    }

    #[test]
    fn commit_keys_in_any_spelling_fail_in_a_script() {
        let (scripts, calls) = scripts();
        let result = run(
            &scripts,
            r#"await cua.call("press_key", { pid: 42, window_id: 7, key: String.fromCharCode(114, 101, 45, 116, 117, 114, 110) });"#,
        );
        assert_eq!(result.is_error, Some(true), "{}", text(&result));
        assert!(calls.lock().unwrap().iter().all(|(name, _)| name != "press_key"));
    }

    #[test]
    fn a_script_never_sees_a_filled_value() {
        crate::filled::remember("me@example.com");
        let (scripts, _) = scripts();
        let result = run(
            &scripts,
            r#"const read = await cua.call("get_window_state", { pid: 42, window_id: 7 });
               return JSON.stringify(read).split("").reverse().join("");"#,
        );
        let returned: String = text(&result).chars().rev().collect();
        assert!(!returned.contains("me@example.com"), "{returned}");
        assert!(returned.contains(crate::filled::FILLED), "{returned}");
    }
}
