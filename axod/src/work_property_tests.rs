//! Real private-store state-machine properties and deterministic commit-window faults.
use super::*;
use crate::{journal::Journal, test_support::TestDirectory};
use proptest::prelude::*;
use std::cell::Cell;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Stage {
    BeforeFileSync,
    BeforeRename,
    AfterRename,
}
thread_local! { static FAULT: Cell<Option<Stage>> = const { Cell::new(None) }; }
pub(super) fn checkpoint(stage: Stage) -> io::Result<()> {
    if FAULT.get() == Some(stage) {
        FAULT.set(None);
        return Err(io::Error::other("Injected work-store I/O failure"));
    }
    Ok(())
}
fn create() -> WorkIntent {
    WorkIntent::CreateWorkspace {
        directory_id: "approved".into(),
        name: "Seed workspace".into(),
        expected_revision: 0,
    }
}
fn policy(root: &Path) -> BTreeMap<String, TerminalLaunch> {
    BTreeMap::from([(
        "approved".into(),
        TerminalLaunch {
            directory: root.to_str().unwrap().into(),
            argv: vec!["/bin/false".into()],
        },
    )])
}

proptest! {
    #![proptest_config(ProptestConfig { cases:96, max_shrink_iters:4096, ..ProptestConfig::default() })]
    #[test]
    fn receipt_state_machine_preserves_exact_intents_through_reconciliation_and_restarts(
        actions in prop::collection::vec((0u8..6, 0usize..8, 0u16..1000), 1..40)
    ) {
        let root = TestDirectory::new();
        let mut journal = Journal::open(root.path()).unwrap();
        let first = journal.work.lock().unwrap().apply(CommandId::new(), create(), &policy(root.path())).unwrap();
        let WorkRecord::Workspace(workspace) = first.record else { unreachable!() };
        let commands: Vec<_> = (0..8).map(|_| CommandId::new()).collect();
        let mut model: BTreeMap<CommandId, (WorkIntent, CommittedWork)> = BTreeMap::new();
        let mut revision = 1;
        for (operation, slot, suffix) in actions {
            if operation == 5 {
                drop(journal);
                journal = root.reopen_journal();
            } else {
                let mut store = journal.work.lock().unwrap();
                let before = serde_json::to_vec(&store.saved).unwrap();
                let command = commands[slot];
                let original = model.get(&command).cloned();
                let intent = match operation {
                    1 => WorkIntent::CreateSession { workspace_id:workspace.workspace_id, name:format!("Session-{suffix}-😃"), expected_revision:revision },
                    2 if original.is_some() => original.as_ref().unwrap().0.clone(),
                    3 if original.is_some() => WorkIntent::RenameWorkspace { workspace_id:workspace.workspace_id, name:format!("Conflict-{suffix}"), expected_revision:revision+1 },
                    4 => WorkIntent::RenameWorkspace { workspace_id:workspace.workspace_id, name:format!("Stale-{suffix}"), expected_revision:revision-1 },
                    _ => WorkIntent::RenameWorkspace { workspace_id:workspace.workspace_id, name:format!("Name-{suffix}-界"), expected_revision:revision },
                };
                let result = store.apply(command, intent.clone(), &BTreeMap::new());
                if let Some((old_intent, committed)) = original {
                    if old_intent == intent { prop_assert_eq!(result, Ok(committed)); }
                    else { prop_assert_eq!(result, Err(WorkError::Conflict)); }
                    prop_assert_eq!(serde_json::to_vec(&store.saved).unwrap(), before);
                } else if intent.expected_revision() != revision {
                    prop_assert_eq!(result, Err(WorkError::Conflict));
                    prop_assert_eq!(serde_json::to_vec(&store.saved).unwrap(), before);
                } else {
                    let committed = result.unwrap();
                    revision += 1;
                    prop_assert_eq!(committed.revision, revision);
                    model.insert(command, (intent, committed));
                }
            }
            let store = journal.work.lock().unwrap();
            prop_assert_eq!(store.revision(), revision);
            prop_assert!(store.saved.validate().is_ok());
            for (command, (_, committed)) in &model {
                prop_assert_eq!(store.receipt(*command), Some(committed.clone()));
            }
            prop_assert!(!root.path().join("runtime-state.json").exists());
        }
    }
}

#[test]
fn commit_window_faults_fence_memory_and_recover_only_the_atomic_disk_outcome() {
    for stage in [
        Stage::BeforeFileSync,
        Stage::BeforeRename,
        Stage::AfterRename,
    ] {
        let root = TestDirectory::new();
        let journal = Journal::open(root.path()).unwrap();
        let known = CommandId::new();
        let uncertain = CommandId::new();
        let original = journal
            .work
            .lock()
            .unwrap()
            .apply(known, create(), &policy(root.path()))
            .unwrap();
        let WorkRecord::Workspace(workspace) = original.record.clone() else {
            unreachable!()
        };
        let intent = WorkIntent::RenameWorkspace {
            workspace_id: workspace.workspace_id,
            name: "After uncertain commit".into(),
            expected_revision: 1,
        };
        {
            let mut store = journal.work.lock().unwrap();
            FAULT.set(Some(stage));
            assert_eq!(
                store.apply(uncertain, intent.clone(), &BTreeMap::new()),
                Err(WorkError::OutcomeUnknown)
            );
            assert!(store.is_fenced());
            assert_eq!(store.revision(), 1);
            assert_eq!(store.receipt(known), Some(original.clone()));
            assert_eq!(store.receipt(uncertain), None);
            assert_eq!(
                store.apply(CommandId::new(), intent, &BTreeMap::new()),
                Err(WorkError::StorageFailed)
            );
            assert!(store.saved.validate().is_ok());
        }
        assert!(fs::read_dir(root.path()).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
        drop(journal);
        let journal = root.reopen_journal();
        let store = journal.work.lock().unwrap();
        let committed = stage == Stage::AfterRename;
        assert_eq!(store.revision(), if committed { 2 } else { 1 });
        assert_eq!(store.receipt(uncertain).is_some(), committed);
        assert_eq!(store.receipt(known), Some(original));
        assert!(store.saved.validate().is_ok());
        // A same-kernel reopen is not evidence of durability under power loss/fsync failure.
    }
}

#[test]
fn concurrent_ownership_is_a_distinct_fail_closed_error_not_corruption() {
    let root = TestDirectory::new();
    let owner = Journal::open(root.path()).unwrap();
    assert_eq!(
        Journal::open(root.path())
            .err()
            .expect("Second owner must fail")
            .kind(),
        io::ErrorKind::WouldBlock
    );
    drop(owner);
    drop(root.reopen_journal());
}

#[test]
fn every_truncated_store_and_each_receipt_invariant_violation_fails_closed() {
    let root = TestDirectory::new();
    let journal = Journal::open(root.path()).unwrap();
    journal
        .work
        .lock()
        .unwrap()
        .apply(CommandId::new(), create(), &policy(root.path()))
        .unwrap();
    drop(journal);
    let path = root.path().join("work-records.json");
    let bytes = fs::read(&path).unwrap();
    for length in 0..bytes.len() {
        fs::write(&path, &bytes[..length]).unwrap();
        assert_eq!(
            root.try_reopen_journal()
                .err()
                .expect("Truncated store must fail")
                .kind(),
            io::ErrorKind::Other,
            "Corruption, not lock contention, must reject the truncated store"
        );
    }
    let original: Saved = serde_json::from_slice(&bytes).unwrap();
    for field in 0..6 {
        let mut saved = original.clone();
        match field {
            0 => saved.version += 1,
            1 => saved.revision += 1,
            2 => saved.receipts.clear(),
            3 => {
                saved
                    .receipts
                    .values_mut()
                    .next()
                    .unwrap()
                    .committed
                    .revision += 1
            }
            4 => saved.workspaces.values_mut().next().unwrap().record.name = "Unreceipted".into(),
            _ => {
                saved
                    .workspaces
                    .values_mut()
                    .next()
                    .unwrap()
                    .record
                    .workspace_id = WorkspaceId::new()
            }
        }
        fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
        assert_eq!(
            root.try_reopen_journal()
                .err()
                .expect("Invalid store must fail")
                .kind(),
            io::ErrorKind::Other
        );
    }
    fs::write(&path, &bytes).unwrap();
    drop(root.reopen_journal());
}
