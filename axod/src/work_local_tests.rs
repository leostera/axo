use crate::{
    journal::Journal, model::*, rpc, runtime::Manager, test_support::TestDirectory, work::*,
};
use serde_json::json;
use std::{collections::BTreeMap, fs};

#[test]
fn local_folder_selection_is_durable_without_profiles_and_cloud_cannot_create_it() {
    let root = TestDirectory::new();
    let selected = TestDirectory::new();
    let directory = fs::canonicalize(selected.path())
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    let machine = MachineId::new();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    let command = CommandId::new();
    let params = json!({"target":{"machineId":machine,"hostGeneration":manager.generation},
        "commandId":command,"expectedRevision":0,"directoryPath":directory,"name":"Local project"});
    let call = || rpc::Call {
        id: Some(json!(1)),
        method: "axo.workspace.createLocal".into(),
        params: Some(params.clone()),
    };
    let denied = rpc::dispatch(call(), &manager, machine, &BTreeMap::new()).unwrap();
    assert_eq!(denied["error"]["code"], -32601);
    assert_eq!(manager.work.lock().unwrap().revision(), 0);
    let created = rpc::dispatch_local(call(), &manager, machine, &BTreeMap::new()).unwrap();
    assert!(created.get("error").is_none());
    assert_eq!(
        created,
        rpc::dispatch_local(call(), &manager, machine, &BTreeMap::new()).unwrap()
    );
    let workspace: WorkspaceId =
        serde_json::from_value(created["result"]["workspace"]["workspaceId"].clone()).unwrap();
    let session = manager
        .mutate_work(
            CommandId::new(),
            WorkIntent::CreateSession {
                workspace_id: workspace,
                name: "Build Axo".into(),
                expected_revision: 1,
            },
            &BTreeMap::new(),
        )
        .unwrap();
    let WorkRecord::Session(session) = session.record else {
        panic!("Expected session");
    };
    let context = manager
        .work
        .lock()
        .unwrap()
        .execution_context(workspace, session.session_id, session.pi_pane_id)
        .unwrap();
    assert_eq!(context.directory, std::path::Path::new(&directory));
    assert!(manager.list().is_empty()); // Metadata never launches a process.
    drop(manager);
    let reopened = Manager::new(Journal::open(root.path()).unwrap());
    assert_eq!(reopened.work.lock().unwrap().revision(), 2);
    assert_eq!(
        reopened
            .work
            .lock()
            .unwrap()
            .execution_context(workspace, session.session_id, session.pi_pane_id)
            .unwrap()
            .directory,
        std::path::Path::new(&directory)
    );
    let mut changed = params;
    changed["target"]["hostGeneration"] = json!(reopened.generation);
    changed["name"] = json!("Different intent");
    let conflict = rpc::dispatch_local(
        rpc::Call {
            id: Some(json!(2)),
            method: "axo.workspace.createLocal".into(),
            params: Some(changed),
        },
        &reopened,
        machine,
        &BTreeMap::new(),
    )
    .unwrap();
    assert_eq!(conflict["error"]["code"], -32007);
}

#[test]
fn local_folder_must_be_usable_but_committed_receipts_survive_its_removal() {
    let root = TestDirectory::new();
    let selected = TestDirectory::new();
    let directory = fs::canonicalize(selected.path())
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    let alias = root.path().join("selection-alias");
    std::os::unix::fs::symlink(&directory, &alias).unwrap();
    assert_eq!(
        manager.mutate_work(
            CommandId::new(),
            WorkIntent::CreateLocalWorkspace {
                directory: LocalDirectoryPath::parse(alias.to_str().unwrap().to_owned()).unwrap(),
                name: "Unresolved alias".into(),
                initial_session_name: None,
                expected_revision: 0,
            },
            &BTreeMap::new()
        ),
        Err(WorkError::Invalid)
    );
    let command = CommandId::new();
    let intent = WorkIntent::CreateLocalWorkspace {
        directory: LocalDirectoryPath::parse(directory.clone()).unwrap(),
        name: "Local".into(),
        initial_session_name: None,
        expected_revision: 0,
    };
    let receipt = manager
        .mutate_work(command, intent.clone(), &BTreeMap::new())
        .unwrap();
    fs::remove_dir(&directory).unwrap();
    assert_eq!(
        manager
            .mutate_work(command, intent, &BTreeMap::new())
            .unwrap(),
        receipt
    );
    assert_eq!(
        manager.mutate_work(
            CommandId::new(),
            WorkIntent::CreateLocalWorkspace {
                directory: LocalDirectoryPath::parse(directory).unwrap(),
                name: "Missing".into(),
                initial_session_name: None,
                expected_revision: 1,
            },
            &BTreeMap::new()
        ),
        Err(WorkError::Invalid)
    );
    drop(manager);
    let reopened = Manager::new(Journal::open(root.path()).unwrap());
    assert_eq!(
        reopened.work.lock().unwrap().receipt(command).unwrap(),
        receipt
    );
    assert!(LocalDirectoryPath::parse("relative".into()).is_err());
    assert!(LocalDirectoryPath::parse("/bad\0path".into()).is_err());
}
