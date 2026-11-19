//! Only an empty MCP form is a yes/no confirmation. Fields need a dedicated safe renderer.
use serde_json::Value;

pub(super) fn confirmation_message(parameters: &Value) -> Option<String> {
    if parameters["mode"] != "form" {
        return None;
    }
    let schema = parameters["requestedSchema"].as_object()?;
    let allowed = [
        "type",
        "properties",
        "required",
        "additionalProperties",
        "title",
        "description",
        "$schema",
    ];
    if schema.keys().any(|key| !allowed.contains(&key.as_str()))
        || schema.get("type")? != "object"
        || !schema.get("properties")?.as_object()?.is_empty()
        || schema
            .get("required")
            .is_some_and(|value| !value.as_array().is_some_and(Vec::is_empty))
    {
        return None;
    }
    let mut message = parameters["message"].as_str()?.to_owned();
    if let Some(server) = parameters["serverName"].as_str() {
        message.push_str(&format!("\nServer: {server}"));
    }
    if let Some(details) = parameters["_meta"].get("tool_params_display") {
        message.push('\n');
        message.push_str(&serde_json::to_string_pretty(details).ok()?);
    }
    if parameters["_meta"]["persist"] == true {
        message.push_str("\nThis request asks to remember permission.");
    }
    Some(message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn only_empty_forms_can_be_confirmed_without_inventing_field_values() {
        let request = json!({"mode":"form","message":"Allow Codex to use Axo?","serverName":"node_repl",
            "requestedSchema":{"type":"object","properties":{}},"_meta":{"persist":true,"tool_params_display":{"tool":"fixture"}}});
        let message = confirmation_message(&request).unwrap();
        assert!(
            message.contains("node_repl")
                && message.contains("remember permission")
                && message.contains("fixture")
        );
        for schema in [
            json!({"type":"object","properties":{"secret":{"type":"string"}}}),
            json!({"type":"object","properties":{},"required":["secret"]}),
            json!({"type":"object","properties":{},"minProperties":1}),
        ] {
            let mut invalid = request.clone();
            invalid["requestedSchema"] = schema;
            assert!(confirmation_message(&invalid).is_none());
        }
    }
}
