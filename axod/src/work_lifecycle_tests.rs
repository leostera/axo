use crate::{
    journal::Journal, model::*, runtime::Manager, terminal::ErrorCode, test_support::TestDirectory,
    work::*,
};
use std::{collections::BTreeMap, fs};

fn launch(root: &TestDirectory) -> TerminalLaunch {
    TerminalLaunch {
        directory: root.path().to_str().unwrap().into(),
        argv: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
    }
}
fn create() -> WorkIntent {
    WorkIntent::CreateWorkspace {
        directory_id: "approved".into(),
        name: "Work".into(),
        expected_revision: 0,
    }
}
fn target() -> TerminalTarget {
    TerminalTarget {
        session_id: SessionId::new(),
        pane_id: PaneId::new(),
    }
}

#[test]
fn uncertain_work_persistence_fences_execution_as_well_as_work_mutations() {
    let root = TestDirectory::new();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    fs::create_dir(root.path().join("work-records.json")).unwrap();
    let policy = BTreeMap::from([("approved".into(), launch(&root))]);
    assert_eq!(
        manager.mutate_work(CommandId::new(), create(), &policy),
        Err(WorkError::OutcomeUnknown)
    );
    assert_eq!(
        manager
            .start(CommandId::new(), target(), &launch(&root))
            .unwrap_err(),
        ErrorCode::StorageFailed
    );
    assert_eq!(
        manager.mutate_work(CommandId::new(), create(), &policy),
        Err(WorkError::StorageFailed)
    );
    assert!(manager.list().is_empty());
    assert!(!root.path().join("runtime-state.json").exists());
}
#[test]
fn uncertain_execution_persistence_fences_work_mutations_without_creating_records() {
    let root = TestDirectory::new();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    fs::create_dir(root.path().join("runtime-state.json")).unwrap();
    assert_eq!(
        manager
            .start(CommandId::new(), target(), &launch(&root))
            .unwrap_err(),
        ErrorCode::StorageFailed
    );
    let policy = BTreeMap::from([("approved".into(), launch(&root))]);
    assert_eq!(
        manager.mutate_work(CommandId::new(), create(), &policy),
        Err(WorkError::StorageFailed)
    );
    assert!(!root.path().join("work-records.json").exists());
}
#[test]
fn duplicate_cross_journal_command_identity_rejects_boot() {
    let root = TestDirectory::new();
    let mut journal = Journal::open(root.path()).unwrap();
    let command = CommandId::new();
    let runtime = RuntimeRef {
        host_generation: HostGeneration::new(),
        runtime_generation: RuntimeGeneration::new(),
        target: target(),
    };
    journal.prepare(command, runtime, &launch(&root)).unwrap();
    journal.update(runtime, ProcessState::Failed {}).unwrap();
    // Simulate incompatible prior writers; the actual dispatcher shares admission and rejects this reuse.
    let policy = BTreeMap::from([("approved".into(), launch(&root))]);
    journal
        .work
        .lock()
        .unwrap()
        .apply(command, create(), &policy)
        .unwrap();
    drop(journal);
    assert!(Journal::open(root.path()).is_err());
}
