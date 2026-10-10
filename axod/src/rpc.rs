//! JSON-RPC control codec and the deliberately small remote method policy.
use crate::{model::*, runtime::Manager};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

pub const FRAME_BYTES: usize = 65_536;
#[derive(Debug)]
pub struct Call {
    pub id: Option<Value>, // Some(Null) is a request; absent is a notification.
    pub method: String,
    pub params: Option<Value>,
}
pub struct Message {
    pub batch: bool,
    pub entries: Vec<Result<Call, Value>>,
}
pub fn error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc":"2.0", "id":id, "error":{"code":code,"message":message}})
}
pub fn parse_call(value: Value) -> Result<Call, Value> {
    let invalid = || error(Value::Null, -32600, "Invalid Request");
    let object = value.as_object().ok_or_else(invalid)?;
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return Err(invalid());
    }
    let method = object
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    if method.is_empty() || method.encode_utf16().count() > 128 {
        return Err(invalid());
    }
    if let Some(id) = object.get("id") {
        let valid = match id {
            Value::Null => true,
            Value::String(value) => value.encode_utf16().count() <= 128,
            Value::Number(value) => value
                .as_f64()
                .is_some_and(|value| value.abs() <= 9_007_199_254_740_991.0),
            _ => false,
        };
        if !valid {
            return Err(invalid());
        }
    }
    if object
        .get("params")
        .is_some_and(|value| !value.is_object() && !value.is_array())
    {
        return Err(invalid());
    }
    Ok(Call {
        id: object.get("id").cloned(),
        method: method.to_owned(),
        params: object.get("params").cloned(),
    })
}
pub fn decode(raw: &str) -> Result<Message, Value> {
    if raw.len() > FRAME_BYTES {
        return Err(error(Value::Null, -32600, "Frame limit"));
    }
    let value: Value =
        serde_json::from_str(raw).map_err(|_| error(Value::Null, -32700, "Parse error"))?;
    match value {
        Value::Array(entries) if entries.is_empty() || entries.len() > 8 => {
            Err(error(Value::Null, -32600, "Batch limit"))
        }
        Value::Array(entries) => Ok(Message {
            batch: true,
            entries: entries.into_iter().map(parse_call).collect(),
        }),
        value => Ok(Message {
            batch: false,
            entries: vec![parse_call(value)],
        }),
    }
}
/// Post-dispatch reply failure is outcome-unknown, never a claim of no execution.
pub(crate) fn bounded_replies(batch: bool, replies: Vec<Value>) -> Option<Value> {
    if replies.is_empty() {
        return None;
    }
    let value = if batch {
        Value::Array(replies)
    } else {
        replies.into_iter().next().expect("Nonempty replies")
    };
    if serde_json::to_vec(&value).is_ok_and(|raw| raw.len() <= FRAME_BYTES) {
        return Some(value);
    }
    let unknown = |reply: &Value| {
        error(
            reply.get("id").cloned().unwrap_or(Value::Null),
            -32004,
            "Outcome unknown; reconcile commandId",
        )
    };
    Some(match value {
        Value::Array(replies) => Value::Array(replies.iter().map(unknown).collect()),
        reply => unknown(&reply),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub(crate) struct Destination {
    pub(crate) machine_id: MachineId,
    pub(crate) host_generation: HostGeneration,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartTarget {
    machine_id: MachineId,
    host_generation: HostGeneration,
    session_id: SessionId,
    pane_id: PaneId,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Start {
    target: StartTarget,
    command_id: CommandId,
    profile_id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct List {
    target: Destination,
    #[serde(default, deserialize_with = "non_null_option")]
    after: Option<PaneId>,
    #[serde(default = "page_limit")]
    limit: usize,
}
/// Optional request fields may be omitted, but explicit null must satisfy their actual type.
/// Cursor scope fields declared nullable use ordinary Option deserialization instead.
pub(crate) fn non_null_option<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}
fn page_limit() -> usize {
    50
}

/// Both RPC adapters invoke this Manager. No raw RPC argv/paths.
pub fn dispatch(
    call: Call,
    manager: &Manager,
    machine: MachineId,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Option<Value> {
    let id = call.id?; // Execution notifications are never admitted.
    let result = match call.method.as_str() {
        "axo.runtime.list" => list(call.params, manager, machine),
        "axo.runtime.startApproved" => start(call.params, manager, machine, profiles),
        method => crate::work_rpc::dispatch(method, call.params, manager, machine, profiles),
    };
    Some(match result {
        Ok(result) => json!({"jsonrpc":"2.0", "id":id, "result":result}),
        Err((code, message)) => error(id, code, message),
    })
}
pub(crate) type Outcome = Result<Value, (i32, &'static str)>;
fn list(params: Option<Value>, manager: &Manager, machine: MachineId) -> Outcome {
    let params: List = serde_json::from_value(params.unwrap_or(Value::Null))
        .map_err(|_| (-32602, "Invalid params"))?;
    validate_target(
        params.target.machine_id,
        params.target.host_generation,
        manager,
        machine,
    )?;
    if params.limit == 0 || params.limit > 50 {
        return Err((-32602, "Invalid params"));
    }
    let mut remaining = manager.list().into_iter().filter(|terminal| {
        params
            .after
            .is_none_or(|id| terminal.runtime.target.pane_id > id)
    });
    let terminals: Vec<_> = remaining.by_ref().take(params.limit).collect();
    let next = remaining
        .next()
        .and_then(|_| terminals.last().map(|value| value.runtime.target.pane_id));
    Ok(json!({"hostGeneration":manager.generation,"terminals":terminals,"next":next}))
}
fn start(
    params: Option<Value>,
    manager: &Manager,
    machine: MachineId,
    profiles: &BTreeMap<String, TerminalLaunch>,
) -> Outcome {
    let params: Start = serde_json::from_value(params.unwrap_or(Value::Null))
        .map_err(|_| (-32602, "Invalid params"))?;
    validate_target(
        params.target.machine_id,
        params.target.host_generation,
        manager,
        machine,
    )?;
    let launch = profiles
        .get(&params.profile_id)
        .ok_or((-32602, "Unknown approved profile"))?;
    let target = TerminalTarget {
        session_id: params.target.session_id,
        pane_id: params.target.pane_id,
    };
    let terminal = manager
        .start(params.command_id, target, launch)
        .map_err(|code| match code {
            crate::terminal::ErrorCode::Conflict => (-32007, "Command conflict"),
            crate::terminal::ErrorCode::StorageFailed => (-32008, "Storage failed"),
            crate::terminal::ErrorCode::RecoveryRequired => (-32009, "Recovery required"),
            crate::terminal::ErrorCode::Capacity => (-32006, "Capacity"),
            _ => (-32010, "Daemon rejected operation"),
        })?;
    Ok(json!({"hostGeneration":manager.generation,"terminal":terminal}))
}
pub(crate) fn validate_target(
    target_machine: MachineId,
    generation: HostGeneration,
    manager: &Manager,
    machine: MachineId,
) -> Result<(), (i32, &'static str)> {
    if target_machine != machine || generation != manager.generation {
        return Err((-32002, "Stale destination"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn absent_and_null_ids_are_different() {
        let notification = parse_call(json!({"jsonrpc":"2.0","method":"test"})).unwrap();
        let request = parse_call(json!({"jsonrpc":"2.0","id":null,"method":"test"})).unwrap();
        assert!(notification.id.is_none());
        assert_eq!(request.id, Some(Value::Null));
    }
    #[test]
    fn oversized_post_dispatch_replies_preserve_ids_and_batch_shape_as_unknown() {
        let large = json!({"jsonrpc":"2.0", "id":"one", "result":"x".repeat(FRAME_BYTES)});
        let reply = bounded_replies(false, vec![large.clone()]).unwrap();
        assert_eq!(reply["id"], "one");
        assert_eq!(reply["error"]["code"], -32004);
        let batch = bounded_replies(true, vec![large]).unwrap();
        assert!(batch.is_array());
        assert_eq!(batch[0]["id"], "one");
        assert!(serde_json::to_vec(&batch).unwrap().len() <= FRAME_BYTES);
        assert!(bounded_replies(false, vec![]).is_none());
    }
    #[test]
    fn omitted_runtime_page_cursor_is_not_the_same_as_explicit_null() {
        let mut params =
            json!({"target":{"machineId":MachineId::new(),"hostGeneration":HostGeneration::new()}});
        let absent: List = serde_json::from_value(params.clone()).unwrap();
        assert!(absent.after.is_none());
        assert_eq!(absent.limit, 50);
        params["after"] = Value::Null;
        assert!(serde_json::from_value::<List>(params.clone()).is_err());
        params["after"] = json!(PaneId::new());
        assert!(
            serde_json::from_value::<List>(params)
                .unwrap()
                .after
                .is_some()
        );
    }
    #[test]
    fn shared_envelope_fixtures() {
        let fixtures: Vec<Value> =
            serde_json::from_str(include_str!("../../protocol/fixtures/envelopes.json")).unwrap();
        for fixture in fixtures {
            let result = decode(fixture["raw"].as_str().unwrap());
            let codes: Vec<Value> = match result {
                Err(reply) => vec![reply["error"]["code"].clone()],
                Ok(message) => message
                    .entries
                    .into_iter()
                    .filter_map(Result::err)
                    .map(|reply| reply["error"]["code"].clone())
                    .collect(),
            };
            assert_eq!(json!(codes), fixture["errors"], "{}", fixture["name"]);
        }
    }
}
