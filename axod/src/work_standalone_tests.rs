use crate::{
    journal::Journal, model::*, rpc, runtime::Manager, test_support::TestDirectory, work::*,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs};

fn call(manager: &Manager, machine: MachineId, method: &str, params: Value) -> Value {
    rpc::dispatch_local(
        rpc::Call {
            id: Some(json!(1)),
            method: method.into(),
            params: Some(params),
        },
        manager,
        machine,
        &BTreeMap::new(),
    )
    .unwrap()
}
#[test]
fn standalone_creation_captures_home_without_inventing_workspace_or_executing() {
    let root = TestDirectory::new();
    let home = TestDirectory::new();
    let directory = fs::canonicalize(home.path()).unwrap();
    let home = LocalDirectoryPath::parse(directory.to_str().unwrap().into()).unwrap();
    let mut manager = Manager::new(Journal::open(root.path()).unwrap());
    manager.user_home = Some(home);
    let machine = MachineId::new();
    let command = CommandId::new();
    let target = json!({"machineId":machine,"hostGeneration":manager.generation});
    let params = json!({"target":target,"commandId":command,"expectedRevision":0,"name":"Home"});
    let created = call(&manager, machine, "axo.session.create", params.clone());
    assert!(created.get("error").is_none());
    assert!(created["result"]["session"]["workspaceId"].is_null());
    assert!(!created.to_string().contains(directory.to_str().unwrap()));
    assert_eq!(
        created,
        call(&manager, machine, "axo.session.create", params.clone())
    );
    let session: SessionId =
        serde_json::from_value(created["result"]["session"]["sessionId"].clone()).unwrap();
    let pane: PaneId =
        serde_json::from_value(created["result"]["session"]["pi"]["paneId"].clone()).unwrap();
    {
        let work = manager.work.lock().unwrap();
        assert!(work.workspaces().is_empty());
        let context = work.execution_context(None, session, pane).unwrap();
        assert_eq!(context.approval, DirectoryApproval::UserHome);
        assert_eq!(context.directory, directory);
        assert_eq!(
            work.session(WorkspaceId::new(), session),
            Err(WorkError::NotFound)
        );
    }
    assert!(manager.list().is_empty());
    let mut path_injection = params.clone();
    path_injection["directoryPath"] = json!("/tmp");
    assert_eq!(
        call(&manager, machine, "axo.session.create", path_injection)["error"]["code"],
        -32602
    );
    drop(manager);
    let reopened = Manager::new(Journal::open(root.path()).unwrap());
    let work = reopened.work.lock().unwrap();
    assert_eq!(
        work.execution_context(None, session, pane)
            .unwrap()
            .directory,
        directory
    );
    assert_eq!(work.receipt(command).unwrap().revision, 1);
    assert!(work.workspaces().is_empty());
}
#[test]
fn unrecorded_name_protection_preserves_original_record_shape_without_inference() {
    let original = json!({"sessionId":SessionId::new(),"workspaceId":null,"name":"An existing name","piPaneId":PaneId::new()});
    let parsed: SessionRecord = serde_json::from_value(original.clone()).unwrap();
    assert_eq!(parsed.manual_name, None);
    assert_eq!(serde_json::to_value(parsed).unwrap(), original);
    for invalid in [json!(null), json!("true"), json!(1)] {
        let mut record = original.clone();
        record["manualName"] = invalid;
        assert!(serde_json::from_value::<SessionRecord>(record).is_err());
    }
}

#[test]
fn explicit_rename_protection_is_durable_and_original_creation_receipt_is_immutable() {
    let root = TestDirectory::new();
    let home = TestDirectory::new();
    let directory = fs::canonicalize(home.path()).unwrap();
    let mut manager = Manager::new(Journal::open(root.path()).unwrap());
    manager.user_home =
        Some(LocalDirectoryPath::parse(directory.to_str().unwrap().into()).unwrap());
    let machine = MachineId::new();
    let source = json!({"machineId":machine,"hostGeneration":manager.generation});
    let creation_id = CommandId::new();
    let creation =
        json!({"target":source,"commandId":creation_id,"expectedRevision":0,"name":"New Session"});
    let created = call(&manager, machine, "axo.session.create", creation.clone());
    assert_eq!(created["result"]["session"]["manualName"], false);
    let session = created["result"]["session"]["sessionId"].clone();
    let target = json!({"machineId":machine,"hostGeneration":manager.generation,"workspaceId":null,"sessionId":session});
    let command = CommandId::new();
    let rename =
        json!({"target":target,"commandId":command,"expectedRevision":1,"name":"Daily work"});
    let renamed = call(&manager, machine, "axo.session.rename", rename.clone());
    assert_eq!(renamed["result"]["session"]["manualName"], true);
    assert_eq!(renamed["result"]["session"]["name"], "Daily work");
    assert_eq!(
        renamed,
        call(&manager, machine, "axo.session.rename", rename.clone())
    );
    assert_eq!(
        created,
        call(&manager, machine, "axo.session.create", creation)
    );
    let mut stale = rename;
    stale["commandId"] = json!(CommandId::new());
    assert_eq!(
        call(&manager, machine, "axo.session.rename", stale)["error"]["code"],
        -32007
    );
    assert!(manager.list().is_empty());
    drop(manager);
    let reopened = Manager::new(Journal::open(root.path()).unwrap());
    let current = json!({"machineId":machine,"hostGeneration":reopened.generation,"workspaceId":null,"sessionId":session});
    let record = call(
        &reopened,
        machine,
        "axo.session.get",
        json!({"target":current}),
    );
    assert_eq!(record["result"]["session"]["manualName"], true);
    assert_eq!(record["result"]["session"]["name"], "Daily work");
    assert!(reopened.list().is_empty());
    let original = reopened.work.lock().unwrap().receipt(creation_id).unwrap();
    match original.record {
        WorkRecord::Session(record) => assert_eq!(record.manual_name, Some(false)),
        _ => panic!("wrong receipt domain"),
    }
}

#[test]
fn standalone_directory_cannot_be_changed_without_changing_original_receipt() {
    let root = TestDirectory::new();
    let home = TestDirectory::new();
    let directory = fs::canonicalize(home.path()).unwrap();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    manager
        .mutate_work(
            CommandId::new(),
            WorkIntent::CreateStandaloneSession {
                directory: LocalDirectoryPath::parse(directory.to_str().unwrap().into()).unwrap(),
                name: "Home".into(),
                expected_revision: 0,
            },
            &BTreeMap::new(),
        )
        .unwrap();
    drop(manager);
    let file = root.path().join("work-records.json");
    let mut saved: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    let directories = saved["standalone_directories"].as_object_mut().unwrap();
    *directories.values_mut().next().unwrap() = json!("/tmp");
    fs::write(file, serde_json::to_vec(&saved).unwrap()).unwrap();
    assert!(Journal::open(root.path()).is_err());
}
