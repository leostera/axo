use crate::{
    journal::Journal, model::*, rpc, runtime::Manager, test_support::TestDirectory, work::*,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs};

fn startup(manager: &Manager, machine: MachineId, command: CommandId) -> Value {
    rpc::dispatch_local(
        rpc::Call {
            id: Some(json!(1)),
            method: "axo.session.createIfEmpty".into(),
            params: Some(
                json!({"target":{"machineId":machine,"hostGeneration":manager.generation},
            "commandId":command,"expectedRevision":0,"name":"New Session"}),
            ),
        },
        manager,
        machine,
        &BTreeMap::new(),
    )
    .unwrap()
}
fn fixture(root: &TestDirectory, home: &TestDirectory) -> Manager {
    let mut manager = Manager::new(Journal::open(root.path()).unwrap());
    manager.user_home = Some(
        LocalDirectoryPath::parse(
            fs::canonicalize(home.path())
                .unwrap()
                .to_str()
                .unwrap()
                .into(),
        )
        .unwrap(),
    );
    manager
}
#[test]
fn empty_startup_commits_once_and_reconciles_original_after_home_loss_and_reopen() {
    let root = TestDirectory::new();
    let home = TestDirectory::new();
    let machine = MachineId::new();
    let command = CommandId::new();
    let mut manager = fixture(&root, &home);
    let created = startup(&manager, machine, command);
    assert!(created.get("error").is_none());
    assert!(created["result"]["session"]["workspaceId"].is_null());
    assert!(
        manager.list().is_empty(),
        "Metadata must not execute Pi or shells"
    );
    manager.user_home = None;
    assert_eq!(startup(&manager, machine, command), created);
    assert_eq!(
        startup(&manager, machine, CommandId::new())["error"]["code"],
        -32003
    );
    drop(manager);
    let mut reopened = fixture(&root, &home);
    reopened.user_home = None;
    let original = startup(&reopened, machine, command);
    assert_eq!(original["result"]["session"], created["result"]["session"]);
    assert_eq!(original["result"]["revision"], 1);
    assert_eq!(
        reopened.work.lock().unwrap().sessions(None).unwrap().len(),
        1
    );
}
#[test]
fn concurrent_empty_startup_commands_commit_only_one_session() {
    let root = TestDirectory::new();
    let home = TestDirectory::new();
    let manager = fixture(&root, &home);
    let machine = MachineId::new();
    let results = std::thread::scope(|scope| {
        let first = scope.spawn(|| startup(&manager, machine, CommandId::new()));
        let second = scope.spawn(|| startup(&manager, machine, CommandId::new()));
        [first.join().unwrap(), second.join().unwrap()]
    });
    assert_eq!(
        results
            .iter()
            .filter(|result| result.get("error").is_none())
            .count(),
        1
    );
    assert_eq!(
        results
            .iter()
            .filter(|result| result["error"]["code"] == -32007)
            .count(),
        1
    );
    assert_eq!(
        manager.work.lock().unwrap().sessions(None).unwrap().len(),
        1
    );
    assert!(manager.list().is_empty());
}
#[test]
fn retained_runtime_and_nonempty_work_block_startup_without_execution() {
    let root = TestDirectory::new();
    let home = TestDirectory::new();
    let manager = fixture(&root, &home);
    let machine = MachineId::new();
    let launch = TerminalLaunch {
        directory: home.path().to_str().unwrap().into(),
        argv: vec!["/nonexistent/axo-owned-fixture".into()],
    };
    // PTY/process admission can succeed even when the child subsequently fails exec.
    // Either outcome leaves a retained runtime, not an authoritative empty namespace.
    manager
        .start(
            CommandId::new(),
            TerminalTarget {
                session_id: SessionId::new(),
                pane_id: PaneId::new(),
            },
            &launch,
        )
        .unwrap();
    assert!(!manager.list().is_empty());
    assert_eq!(
        startup(&manager, machine, CommandId::new())["error"]["code"],
        -32007
    );
    assert!(manager.work.lock().unwrap().is_empty());
    let other_root = TestDirectory::new();
    let other = fixture(&other_root, &home);
    other
        .mutate_work(
            CommandId::new(),
            WorkIntent::CreateStandaloneSession {
                directory: other.user_home.clone().unwrap(),
                name: "Existing".into(),
                expected_revision: 0,
            },
            &BTreeMap::new(),
        )
        .unwrap();
    assert_eq!(
        startup(&other, machine, CommandId::new())["error"]["code"],
        -32007
    );
    assert_eq!(other.work.lock().unwrap().sessions(None).unwrap().len(), 1);
}
#[test]
fn startup_is_local_only_and_rejects_path_workspace_and_argv_authority() {
    let root = TestDirectory::new();
    let home = TestDirectory::new();
    let manager = fixture(&root, &home);
    let machine = MachineId::new();
    let params = json!({"target":{"machineId":machine,"hostGeneration":manager.generation},
        "commandId":CommandId::new(),"expectedRevision":0,"name":"New Session"});
    let remote = rpc::dispatch(
        rpc::Call {
            id: Some(json!(1)),
            method: "axo.session.createIfEmpty".into(),
            params: Some(params.clone()),
        },
        &manager,
        machine,
        &BTreeMap::new(),
    )
    .unwrap();
    assert_eq!(remote["error"]["code"], -32601);
    for (key, value) in [
        ("directoryPath", json!("/tmp")),
        ("argv", json!(["/bin/sh"])),
        ("workspaceId", json!(WorkspaceId::new())),
    ] {
        let mut injected = params.clone();
        injected[key] = value;
        let result = rpc::dispatch_local(
            rpc::Call {
                id: Some(json!(1)),
                method: "axo.session.createIfEmpty".into(),
                params: Some(injected),
            },
            &manager,
            machine,
            &BTreeMap::new(),
        )
        .unwrap();
        assert_eq!(result["error"]["code"], -32602);
    }
    assert!(manager.work.lock().unwrap().is_empty());
    assert!(manager.list().is_empty());
}
