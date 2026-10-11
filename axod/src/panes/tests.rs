//! Store evidence only; public_cli.rs supplies real PTY/process acceptance.
use super::store::*;
use crate::{
    model::*,
    terminal::ErrorCode,
    test_support::TestDirectory,
    work::{WorkIntent, WorkRecord, WorkStore},
};
use std::{collections::BTreeMap, fs};
struct Fixture {
    root: TestDirectory,
    work: WorkStore,
    target: SessionTarget,
}
impl Fixture {
    fn new() -> Self {
        let root = TestDirectory::new();
        let mut work = WorkStore::open(root.path()).unwrap();
        let profiles = BTreeMap::from([(
            "shell".into(),
            TerminalLaunch {
                directory: root.path().to_str().unwrap().into(),
                argv: vec!["/bin/sh".into()],
            },
        )]);
        let created = work
            .apply(
                CommandId::new(),
                WorkIntent::CreateWorkspace {
                    directory_id: "shell".into(),
                    name: "Shell work".into(),
                    expected_revision: 0,
                },
                &profiles,
            )
            .unwrap();
        let WorkRecord::Workspace(workspace) = created.record else {
            panic!("Wrong workspace result");
        };
        let created = work
            .apply(
                CommandId::new(),
                WorkIntent::CreateSession {
                    workspace_id: workspace.workspace_id,
                    name: "Shell session".into(),
                    expected_revision: 1,
                },
                &profiles,
            )
            .unwrap();
        let WorkRecord::Session(session) = created.record else {
            panic!("Wrong session result");
        };
        let target = SessionTarget {
            machine_id: MachineId::new(),
            host_generation: HostGeneration::new(),
            workspace_id: Some(workspace.workspace_id),
            session_id: session.session_id,
        };
        Self { root, work, target }
    }
    fn add(&self) -> Intent {
        Intent::AddPane {
            target: self.target,
            profile_id: "shell".into(),
        }
    }
}
#[test]
fn original_add_and_remove_receipts_survive_tombstones_and_reopen_without_reexecution() {
    let fixture = Fixture::new();
    let mut store = Store::open(fixture.root.path(), &fixture.work).unwrap();
    let command = CommandId::new();
    let prepared = store.prepare(command, fixture.add()).unwrap();
    let rejected = store
        .finish_add(command, None, Some(ErrorCode::LaunchFailed))
        .unwrap();
    let remove_command = CommandId::new();
    let intent = Intent::RemovePane {
        target: fixture.target,
        pane_id: prepared.pane_id,
        runtime: None,
    };
    store.prepare(remove_command, intent.clone()).unwrap();
    let removed = store.finish_remove(remove_command, None).unwrap();
    assert_eq!(removed.disposition, Disposition::Removed);
    assert!(store.session_panes(fixture.target.session_id).is_empty());
    let store = Store::open(fixture.root.path(), &fixture.work).unwrap();
    assert_eq!(
        store.reconcile(command, &fixture.add()).unwrap(),
        Some(rejected)
    );
    assert_eq!(
        store.reconcile(remove_command, &intent).unwrap(),
        Some(removed)
    );
    assert!(store.contains_pane(prepared.pane_id));
}
#[test]
fn wrong_runtime_or_second_removal_cannot_retarget_or_remove_a_running_pane_without_completion_evidence()
 {
    let fixture = Fixture::new();
    let mut store = Store::open(fixture.root.path(), &fixture.work).unwrap();
    let command = CommandId::new();
    let prepared = store.prepare(command, fixture.add()).unwrap();
    let runtime = RuntimeRef {
        host_generation: fixture.target.host_generation,
        target: TerminalTarget {
            session_id: fixture.target.session_id,
            pane_id: prepared.pane_id,
        },
        runtime_generation: RuntimeGeneration::new(),
    };
    store.finish_add(command, Some(runtime), None).unwrap();
    let mut stale = runtime;
    stale.runtime_generation = RuntimeGeneration::new();
    assert!(
        store
            .prepare(
                CommandId::new(),
                Intent::RemovePane {
                    target: fixture.target,
                    pane_id: prepared.pane_id,
                    runtime: Some(stale)
                }
            )
            .is_err()
    );
    let remove_command = CommandId::new();
    let intent = Intent::RemovePane {
        target: fixture.target,
        pane_id: prepared.pane_id,
        runtime: Some(runtime),
    };
    store.prepare(remove_command, intent.clone()).unwrap();
    assert!(
        store.finish_remove(remove_command, None).is_err(),
        "Claimed removal lacked native completion evidence"
    );
    assert!(store.prepare(CommandId::new(), intent).is_err());
    assert_eq!(
        store.pane(prepared.pane_id).unwrap().state,
        PaneState::Closing
    );
}
#[test]
fn every_truncation_and_unreceipted_pane_edit_reject_startup_without_repair() {
    let fixture = Fixture::new();
    let mut store = Store::open(fixture.root.path(), &fixture.work).unwrap();
    store.prepare(CommandId::new(), fixture.add()).unwrap();
    let file = fixture.root.path().join("pane-state.json");
    let bytes = fs::read(&file).unwrap();
    for length in 0..bytes.len() {
        fs::write(&file, &bytes[..length]).unwrap();
        assert!(
            Store::open(fixture.root.path(), &fixture.work).is_err(),
            "Truncation accepted at byte {length}"
        );
        assert_eq!(fs::read(&file).unwrap().len(), length);
    }
    let mut corrupt: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    corrupt["receipts"] = serde_json::json!({});
    fs::write(&file, serde_json::to_vec(&corrupt).unwrap()).unwrap();
    assert!(Store::open(fixture.root.path(), &fixture.work).is_err());
}
#[test]
fn uncertain_pane_persistence_fences_mutations_but_preserves_original_receipts() {
    let fixture = Fixture::new();
    let mut store = Store::open(fixture.root.path(), &fixture.work).unwrap();
    let command = CommandId::new();
    let original = store.prepare(command, fixture.add()).unwrap();
    let file = fixture.root.path().join("pane-state.json");
    fs::remove_file(&file).unwrap();
    fs::create_dir(&file).unwrap();
    assert!(matches!(
        store.finish_add(command, None, Some(ErrorCode::LaunchFailed)),
        Err(Error::Unknown)
    ));
    assert!(store.is_fenced());
    assert_eq!(
        store.reconcile(command, &fixture.add()).unwrap(),
        Some(original)
    );
    assert!(matches!(
        store.prepare(CommandId::new(), fixture.add()),
        Err(Error::Fenced)
    ));
}
#[test]
fn pane_reservations_share_command_identity_and_global_admission_fences() {
    use crate::{journal::Journal, runtime::Manager, work::WorkError};
    let fixture = Fixture::new();
    let manager = Manager::new(Journal::open(fixture.root.path()).unwrap());
    let mut target = fixture.target;
    target.host_generation = manager.generation;
    let command = CommandId::new();
    let intent = Intent::AddPane {
        target,
        profile_id: "shell".into(),
    };
    let receipt = manager.prepare_pane(command, intent.clone()).unwrap();
    let launch = TerminalLaunch {
        directory: fixture.root.path().to_str().unwrap().into(),
        argv: vec!["/bin/sh".into()],
    };
    assert_eq!(
        manager
            .start(
                command,
                TerminalTarget {
                    session_id: target.session_id,
                    pane_id: receipt.pane_id
                },
                &launch
            )
            .unwrap_err(),
        ErrorCode::Conflict
    );
    assert!(
        manager
            .mutate_work(
                command,
                WorkIntent::RenameSession {
                    workspace_id: target.workspace_id,
                    session_id: target.session_id,
                    name: "Collision".into(),
                    expected_revision: 2
                },
                &BTreeMap::new()
            )
            .is_err()
    );
    let file = fixture.root.path().join("pane-state.json");
    fs::remove_file(&file).unwrap();
    fs::create_dir(&file).unwrap();
    assert!(matches!(
        manager
            .panes
            .lock()
            .unwrap()
            .finish_add(command, None, Some(ErrorCode::LaunchFailed)),
        Err(Error::Unknown)
    ));
    assert!(matches!(
        manager.mutate_work(
            CommandId::new(),
            WorkIntent::RenameSession {
                workspace_id: target.workspace_id,
                session_id: target.session_id,
                name: "Fenced".into(),
                expected_revision: 2
            },
            &BTreeMap::new()
        ),
        Err(WorkError::StorageFailed)
    ));
    assert_eq!(
        manager
            .start(
                CommandId::new(),
                TerminalTarget {
                    session_id: target.session_id,
                    pane_id: PaneId::new()
                },
                &launch
            )
            .unwrap_err(),
        ErrorCode::StorageFailed
    );
    assert!(matches!(
        manager.prepare_pane(CommandId::new(), intent),
        Err(Error::Fenced)
    ));
    assert!(manager.command_receipt(command).is_some());
}
