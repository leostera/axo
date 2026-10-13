//! In-memory public-document fixtures only: no canonical JSONL writer.
use super::*;
use crate::pi_control::CanonicalDocument;
fn target() -> Value {
    let session = SessionId::new();
    let pane = PaneId::new();
    json!({"machineId":MachineId::new(),"hostGeneration":HostGeneration::new(),"storeGeneration":StoreGeneration::new(),"workspaceId":null,"sessionId":session,"paneId":pane,"chatId":uuid::Uuid::new_v4(),"runtime":{"host_generation":HostGeneration::new(),"runtime_generation":RuntimeGeneration::new(),"target":{"session_id":session,"pane_id":pane}}})
}
fn document(id: &str, parent: Option<&str>, text: &str) -> CanonicalDocument {
    serde_json::from_value(json!({"id":id,"parentId":parent,"timestamp":"now","type":"message","message":{"role":"user","content":text}})).unwrap()
}
fn history() -> History {
    History {
        leaf_id: Some("fork".into()),
        entries: vec![
            document("root", None, "first"),
            document("other", Some("root"), "other branch"),
            document("fork", Some("root"), "selected branch"),
        ],
        branch: vec![
            document("root", None, "first"),
            document("fork", Some("root"), "selected branch"),
        ],
    }
}
#[test]
fn branch_pagination_is_bound_to_collection_and_complete_head() {
    let request = parse_request(
        serde_json::from_value(json!({"target":target(),"readMode":"stopped","limit":1})).unwrap(),
    )
    .unwrap();
    let first = page(&request, &history()).unwrap();
    assert_eq!(first["entries"][0]["entryId"], "root");
    let next = parse_request(serde_json::from_value(json!({"target":request.target,"readMode":"stopped","cursor":first["cursor"],"limit":1})).unwrap()).unwrap();
    let last = page(&next, &history()).unwrap();
    assert_eq!(last["entries"][0]["entryId"], "fork");
    assert!(last["cursor"].is_null());
    let mut changed = history();
    changed
        .entries
        .push(document("new", Some("fork"), "new metadata"));
    assert_eq!(page(&next, &changed).unwrap_err().0, -32002);
    let wrong = serde_json::from_value(json!({"target":request.target,"readMode":"stopped","collection":"entries","cursor":first["cursor"]})).unwrap();
    assert_eq!(parse_request(wrong).err().unwrap().0, -32602);
}
#[test]
fn requests_reject_live_null_cursor_and_unbounded_pages_before_file_effects() {
    for invalid in [
        json!({"target":target(),"readMode":"live"}),
        json!({"target":target(),"readMode":"stopped","cursor":null}),
        json!({"target":target(),"readMode":"stopped","limit":0}),
        json!({"target":target(),"readMode":"stopped","limit":51}),
        json!({"target":target(),"readMode":"stopped","file":"/not-authority"}),
    ] {
        assert!(serde_json::from_value::<Input>(invalid).is_err());
    }
}
#[test]
fn serialized_page_budget_never_truncates_a_record_without_continuation() {
    let request = parse_request(
        serde_json::from_value(json!({"target":target(),"readMode":"stopped","limit":50})).unwrap(),
    )
    .unwrap();
    let documents = (0..50)
        .map(|index| document(&format!("entry-{index}"), None, &"\u{0001}".repeat(2048)))
        .collect();
    let history = History {
        leaf_id: None,
        entries: Vec::new(),
        branch: documents,
    };
    let result = page(&request, &history).unwrap();
    assert!(result["entries"].as_array().unwrap().len() < 50);
    assert!(!result["cursor"].is_null());
    assert!(serde_json::to_vec(&result).unwrap().len() < 48 * 1024);
    assert_eq!(
        result["cursor"]["after"],
        result["entries"].as_array().unwrap().last().unwrap()["entryId"]
    );
}
