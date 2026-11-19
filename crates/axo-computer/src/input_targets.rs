//! Read-only discovery for the exact Linux handles accepted by request_input.
use cua_driver_core::{
    protocol::ToolResult,
    tool::{Tool, ToolDef},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{future::Future, pin::Pin};
use tokio::sync::Semaphore;

static ACTIVE: Semaphore = Semaphore::const_new(4);
const SHAPE: &str = "input_targets takes {pid, window_id?}: a positive process ID and optional positive 64-bit AT-SPI handle; no values or approval claims.";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
#[serde(untagged)]
enum RawQuery {
    Form { pid: i32, window_id: u64 },
    Windows { pid: i32 },
}
enum Query {
    Windows { pid: i32 },
    Form { pid: i32, window_id: u64 },
}
impl Query {
    fn from_runtime(mut args: Value) -> Result<Self, ()> {
        // The canonical registry has already authorized these context keys.
        // We neither use them as authority nor pass them to AT-SPI.
        let object = args.as_object_mut().ok_or(())?;
        for key in [
            "session",
            "_session_id",
            "_transport_session_id",
            "_public_session_label",
            "_session_idle_ttl_ms",
        ] {
            object.remove(key);
        }
        Self::parse(args)
    }
    fn parse(args: Value) -> Result<Self, ()> {
        let raw: RawQuery = serde_json::from_value(args).map_err(|_| ())?;
        match raw {
            RawQuery::Windows { pid } if pid > 0 => Ok(Self::Windows { pid }),
            RawQuery::Form { pid, window_id } if pid > 0 && window_id > 0 => {
                Ok(Self::Form { pid, window_id })
            }
            _ => Err(()),
        }
    }
}
#[derive(Serialize)]
struct Field {
    label: String,
    secure: bool,
}
#[derive(Serialize)]
pub(super) struct FormReading {
    pid: i32,
    window_id: u64,
    app: String,
    window_title: String,
    origin: Option<String>,
    fields: Vec<Field>,
    buttons: Vec<String>,
    binding_available: bool,
    delivery_confirmation: &'static str,
}
impl From<crate::form::Form> for FormReading {
    fn from(form: crate::form::Form) -> Self {
        Self {
            pid: form.pid,
            window_id: form.window_id,
            app: form.app.clone(),
            window_title: form.window_title.clone(),
            origin: form.origin.clone(),
            fields: form
                .fields
                .iter()
                .map(|field| Field {
                    label: field.label.clone(),
                    secure: field.secure,
                })
                .collect(),
            buttons: form.buttons.clone(),
            binding_available: !form.fields.is_empty(),
            delivery_confirmation: "required_per_operation",
        }
    }
}

pub(super) struct InputTargets {
    definition: ToolDef,
}
impl InputTargets {
    pub(super) fn new() -> Self {
        Self {
            definition: ToolDef {
                name: "input_targets".into(),
                description: concat!(
                    "Discover secure-input targets without reading field values, filling anything or asking the person. ",
                    "Call with {pid} to list 64-bit AT-SPI window handles, then {pid,window_id} to inspect ",
                    "verified executable/window/document identity, field labels, secure roles and submit buttons. ",
                    "These are accessibility handles, not compositor IDs. Binding metadata is not proof an ",
                    "application will accept a write; request_input must confirm each operation and re-read the target. ",
                    "Discovery IDs can become stale. Unsupported, locked or unverified targets return an error; ",
                    "never substitute foreground typing. Scoped observation-grant modes fail closed until exact ",
                    "AT-SPI scopes are implemented. Results use source-level privacy filtering, including inside scripts."
                ).into(),
                input_schema: json!({
                    "type": "object", "additionalProperties": false, "required": ["pid"],
                    "properties": {
                        "pid": {"type": "integer", "minimum": 1, "maximum": i32::MAX},
                        "window_id": {
                            "type": "integer", "minimum": 1,
                            "description": "Optional 64-bit accessibility handle returned by input_targets, not a compositor ID."
                        }
                    }
                }),
                read_only: true,
                destructive: false,
                idempotent: true,
                open_world: false,
            },
        }
    }
}
fn inspect(query: Query) -> ToolResult {
    let result = match query {
        Query::Windows { pid } => crate::form::input_windows(pid)
            .map(|windows| json!({"kind":"windows","windows":windows})),
        Query::Form { pid, window_id } => crate::form::Form::read(pid, window_id)
            .map(|form| json!({"kind":"form","target":FormReading::from(form)})),
    };
    match result {
        Ok(reading) => ToolResult::text(reading.to_string()).with_structured(reading),
        Err(error) => ToolResult::error(error.to_string()),
    }
}
impl Tool for InputTargets {
    fn def(&self) -> &ToolDef {
        &self.definition
    }
    fn has_independent_input_lane(&self, _: &Value) -> bool {
        true
    }
    fn protected_resource_scope<'a, 'b, 'c, 'async_trait>(
        &'a self,
        _: &'b str,
        _: &'c Value,
    ) -> Pin<Box<dyn Future<Output = Result<Option<Value>, String>> + Send + 'async_trait>>
    where
        'a: 'async_trait,
        'b: 'async_trait,
        'c: 'async_trait,
        Self: 'async_trait,
    {
        // A compositor-window grant cannot authorize a different AT-SPI handle.
        // Standard observation is promptless; modes requiring scoped grants
        // must refuse until we implement an exact AT-SPI resource scope.
        Box::pin(async {
            Err("Scoped AT-SPI observation grants are not implemented; input discovery is unavailable in this permission mode.".into())
        })
    }
    fn invoke<'life0, 'async_trait>(
        &'life0 self,
        args: Value,
    ) -> Pin<Box<dyn Future<Output = ToolResult> + Send + 'async_trait>>
    where
        'life0: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let query = match Query::from_runtime(args) {
                Ok(query) => query,
                Err(()) => return ToolResult::error(SHAPE),
            };
            let permit = match ACTIVE.try_acquire() {
                Ok(permit) => permit,
                Err(_) => {
                    return ToolResult::error(
                        "Input target discovery is busy; no fields were read or filled.",
                    );
                }
            };
            // Keep the permit inside the worker: cancelling its caller cannot admit
            // unbounded replacement workers while a bounded AT-SPI query is finishing.
            match tokio::task::spawn_blocking(move || {
                let _permit = permit;
                inspect(query)
            })
            .await
            {
                Ok(result) => result,
                Err(_) => ToolResult::error(
                    "Input target discovery did not complete; no fill was attempted.",
                ),
            }
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_bounded_inspection_intents_parse() {
        assert!(matches!(
            Query::parse(json!({"pid":42})),
            Ok(Query::Windows { pid: 42 })
        ));
        assert!(matches!(
            Query::parse(json!({"pid":42,"window_id":u64::from(u32::MAX)+1})),
            Ok(Query::Form { .. })
        ));
        for args in [
            json!({}),
            json!({"pid":0}),
            json!({"pid":-1}),
            json!({"pid":"42"}),
            json!({"pid":42,"window_id":null}),
            json!({"pid":42,"window_id":0}),
            json!({"pid":42,"window_id":-1}),
            json!({"pid":42,"window_id":"1"}),
            json!({"pid":42,"value":"not-accepted"}),
            json!({"pid":42,"approval":true}),
        ] {
            assert!(Query::parse(args).is_err());
        }
    }
    #[test]
    fn runtime_context_is_not_a_caller_approval() {
        assert!(matches!(
            Query::from_runtime(
                json!({"pid":42,"session":"public","_session_id":"private","_transport_session_id":"owner"})
            ),
            Ok(Query::Windows { pid: 42 })
        ));
        assert!(Query::from_runtime(json!({"pid":42,"session":"public","approved":true})).is_err());
    }

    #[test]
    fn discovery_retains_private_observation_authorization() {
        use cua_driver_core::authorization::{self, RiskClass, RiskEnforcement};
        let args = json!({"pid":42});
        let risk = authorization::classify_tool_call("input_targets", &args);
        assert_eq!(risk.class, RiskClass::R2);
        assert_eq!(risk.enforcement, RiskEnforcement::Active);
        assert!(
            authorization::enforcement_adapters_for_call("input_targets", &args)
                .iter()
                .any(|adapter| adapter.id == "private_observation")
        );
    }

    #[test]
    fn busy_and_malformed_queries_do_not_start_discovery_or_echo_values() {
        let _all_workers = ACTIVE.try_acquire_many(4).unwrap();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let tool = InputTargets::new();
        let busy = runtime.block_on(tool.invoke(json!({"pid":42})));
        assert_eq!(busy.is_error, Some(true));
        assert!(serde_json::to_string(&busy).unwrap().contains("busy"));
        let malformed =
            runtime.block_on(tool.invoke(json!({"pid":42,"value":"never-echo-this-value"})));
        assert_eq!(malformed.is_error, Some(true));
        let receipt = serde_json::to_string(&malformed).unwrap();
        assert!(!receipt.contains("never-echo-this-value"));
        assert!(receipt.contains(SHAPE));
        assert!(
            runtime
                .block_on(tool.protected_resource_scope("private_observation", &json!({"pid":42})))
                .is_err()
        );
    }

    #[test]
    fn discovery_is_a_read_not_an_input_or_permission_request() {
        let tool = InputTargets::new();
        assert!(tool.def().read_only);
        assert!(!tool.def().destructive);
        assert!(tool.has_independent_input_lane(&json!({"pid":42})));
    }
}
