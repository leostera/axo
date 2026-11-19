use super::*;
use serde_json::{Value, json};

fn parse(text: &str) -> Vec<Value> {
    text.lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

#[test]
fn rich_conversion_preserves_tools_and_exposed_reasoning_on_every_platform() {
    let header = PiHeader {
        session_id: "session".into(),
        timestamp: rfc3339_utc(0),
        cwd: "/work".into(),
    };
    let native = include_str!("../testdata/atxf/rollout-hand-built.jsonl");
    let converted = pi_lines(AgentKind::Codex, native, &header).unwrap();
    let entries = parse(&converted);
    assert!(
        entries
            .iter()
            .any(|entry| entry["message"]["role"] == "toolResult")
    );
    let blocks: Vec<_> = entries
        .iter()
        .filter_map(|entry| entry["message"]["content"].as_array())
        .flatten()
        .collect();
    assert!(blocks.iter().any(|block| block["type"] == "toolCall"));
    assert!(blocks.iter().any(|block| {
        block["type"] == "thinking"
            && block["thinking"]
                .as_str()
                .is_some_and(|text| text.contains("Listing files"))
    }));
}

#[test]
fn enrichment_preserves_receipts_reply_identity_and_repeated_text_without_matching_content() {
    let presentation = [
        json!({"type":"session","version":3,"id":"session"}),
        json!({"type":"custom","id":"receipt-1","customType":"axo.command","data":{"commandId":"command-1"}}),
        json!({"type":"message","id":"user-1","message":{"role":"user","content":[{"type":"text","text":"same"}],"timestamp":1000}}),
        json!({"type":"message","id":"assistant-1","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"timestamp":4000}}),
        json!({"type":"custom","id":"receipt-2","customType":"axo.command","data":{"commandId":"command-2"}}),
        json!({"type":"message","id":"user-2","message":{"role":"user","content":[{"type":"text","text":"same"}],"timestamp":5000}}),
    ].iter().map(Value::to_string).collect::<Vec<_>>().join("\n");
    let native = [
        json!({"type":"message","id":"native-user","message":{"role":"user","content":[{"type":"text","text":"same"}],"timestamp":1001}}),
        json!({"type":"message","id":"reasoning","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Exposed summary"}],"timestamp":2000}}),
        json!({"type":"message","id":"call","message":{"role":"assistant","content":[{"type":"toolCall","id":"tool-1","name":"bash","arguments":{"command":"fixture"}}],"timestamp":2000}}),
        json!({"type":"message","id":"result","message":{"role":"toolResult","toolCallId":"tool-1","content":[{"type":"text","text":"tool output"}],"timestamp":3000}}),
        json!({"type":"message","id":"native-assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"timestamp":4001}}),
        json!({"type":"message","id":"hidden","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","thinkingSignature":"opaque encrypted data"}],"timestamp":3500}}),
    ].iter().map(Value::to_string).collect::<Vec<_>>().join("\n");
    let enriched = with_activity(&presentation, &native).unwrap();
    assert_eq!(enriched, with_activity(&presentation, &native).unwrap());
    assert_eq!(enriched, with_activity(&presentation, &enriched).unwrap());
    assert!(!enriched.contains("opaque encrypted data"));
    let entries = parse(&enriched);
    let ids: Vec<_> = entries
        .iter()
        .skip(1)
        .map(|entry| entry["id"].as_str().unwrap())
        .collect();
    assert_eq!(
        ids,
        [
            "receipt-1",
            "user-1",
            "axo:native:reasoning",
            "axo:native:call",
            "axo:native:result",
            "assistant-1",
            "receipt-2",
            "user-2"
        ]
    );
    let assistant = entries
        .iter()
        .find(|entry| entry["id"] == "assistant-1")
        .unwrap();
    assert_eq!(assistant["message"]["timestamp"], 4000);
    for (index, entry) in entries.iter().enumerate().skip(1) {
        assert_eq!(
            entry["parentId"],
            if index == 1 {
                Value::Null
            } else {
                entries[index - 1]["id"].clone()
            }
        );
    }
}

#[test]
fn malformed_presentation_is_an_error_not_silently_missing_activity() {
    assert!(with_activity("not json", "").is_err());
    assert!(with_activity("{}", "").is_err());
    let dangling = "{\"type\":\"session\"}\n{\"type\":\"custom\",\"customType\":\"axo.command\"}\n";
    assert!(with_activity(dangling, "").is_err());
}
