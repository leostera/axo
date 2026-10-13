//! Pure memory fixtures, not canonical JSONL writers or launchers.
use super::*;
use crate::pi_control::History;
fn target() -> Value {
    let host = HostGeneration::new();
    let session = SessionId::new();
    let pane = PaneId::new();
    json!({"machineId":MachineId::new(),"hostGeneration":host,"storeGeneration":StoreGeneration::new(),"workspaceId":null,"sessionId":session,"paneId":pane,"chatId":uuid::Uuid::new_v4(),"runtime":{"host_generation":host,"runtime_generation":RuntimeGeneration::new(),"target":{"session_id":session,"pane_id":pane}}})
}
fn history(text: &str) -> History {
    let document = || {
        serde_json::from_value(json!({"id":"result","parentId":null,"timestamp":"now","type":"message","message":{"role":"toolResult","toolCallId":"call","toolName":"bash","content":[{"type":"text","text":text}]}})).unwrap()
    };
    History {
        leaf_id: Some("result".into()),
        entries: vec![document()],
        branch: vec![document()],
    }
}
fn request(value: Value) -> Request {
    Request::parse(serde_json::from_value(value).unwrap()).unwrap()
}
#[test]
fn utf8_chunks_make_exact_progress_and_reconstruct_one_result() {
    let text = "λ界".repeat(4000);
    let history = history(&text);
    let tree = CanonicalTree::parse(&history).unwrap();
    let scope = target();
    let mut params =
        json!({"target":scope,"readMode":"stopped","entryId":"result","toolCallId":"call"});
    let mut actual = String::new();
    loop {
        let page = chunk(&request(params.clone()), &tree).unwrap();
        let part = page["text"].as_str().unwrap();
        assert!(part.len() <= 8192);
        assert_eq!(page["offset"].as_u64().unwrap() as usize, actual.len());
        actual.push_str(part);
        if page["cursor"].is_null() {
            break;
        }
        assert_eq!(
            page["cursor"]["offset"].as_u64().unwrap() as usize,
            actual.len()
        );
        params["cursor"] = page["cursor"].clone();
    }
    assert_eq!(actual, text);
}
#[test]
fn foreign_calls_heads_modes_and_non_boundary_offsets_are_not_retargeted() {
    let history = history("λ界λ界");
    let tree = CanonicalTree::parse(&history).unwrap();
    let params = json!({"target":target(),"readMode":"stopped","entryId":"result","toolCallId":"call","limit":4});
    let first = chunk(&request(params.clone()), &tree).unwrap();
    let mut continuation = params.clone();
    continuation["cursor"] = first["cursor"].clone();
    continuation["cursor"]["offset"] = json!(1);
    assert_eq!(
        chunk(&request(continuation.clone()), &tree).unwrap_err().0,
        -32602
    );
    continuation["cursor"]["offset"] = json!(2);
    continuation["cursor"]["headDigest"] = json!("a".repeat(64));
    assert_eq!(
        chunk(&request(continuation.clone()), &tree).unwrap_err().0,
        -32002
    );
    continuation["cursor"]["readMode"] = json!("live");
    assert!(Request::parse(serde_json::from_value(continuation).unwrap()).is_err());
    let mut foreign = params;
    foreign["toolCallId"] = json!("other");
    assert_eq!(chunk(&request(foreign), &tree).unwrap_err().0, -32009);
}
#[test]
fn escaping_budget_preserves_text_and_empty_result_has_a_proven_eof() {
    for text in ["\u{0001}".repeat(9000), String::new()] {
        let history = history(&text);
        let tree = CanonicalTree::parse(&history).unwrap();
        let params =
            json!({"target":target(),"readMode":"stopped","entryId":"result","toolCallId":"call"});
        let first = chunk(&request(params), &tree).unwrap();
        assert!(serde_json::to_vec(&first).unwrap().len() < 48 * 1024);
        if text.is_empty() {
            assert_eq!(first["text"], "");
            assert!(first["cursor"].is_null());
        } else {
            assert_eq!(first["text"].as_str().unwrap().len(), 4096);
            assert_eq!(first["cursor"]["offset"], 4096);
        }
    }
    for extra in [
        json!({"limit":3}),
        json!({"limit":8193}),
        json!({"cursor":null}),
        json!({"offset":1}),
    ] {
        let mut input =
            json!({"target":target(),"readMode":"stopped","entryId":"result","toolCallId":"call"});
        input
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        assert!(serde_json::from_value::<Input>(input).is_err());
    }
}
