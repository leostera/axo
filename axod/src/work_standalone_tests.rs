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
