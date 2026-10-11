use crate::{
    journal::Journal, model::*, rpc, runtime::Manager, terminal::ErrorCode,
    test_support::TestDirectory, work::*,
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    fs, thread,
    time::{Duration, Instant},
};

fn session(manager: &Manager, root: &TestDirectory, name: &str) -> (CommandId, SessionRecord) {
    let command = CommandId::new();
    let revision = manager.work.lock().unwrap().revision();
    let committed = manager
        .mutate_work(
            command,
            WorkIntent::CreateStandaloneSession {
                directory: LocalDirectoryPath::parse(
                    fs::canonicalize(root.path())
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .into(),
                )
                .unwrap(),
                name: name.into(),
                expected_revision: revision,
            },
            &BTreeMap::new(),
        )
        .unwrap();
    let WorkRecord::Session(record) = committed.record else {
        panic!("Session receipt");
    };
    (command, record)
}
fn launch(root: &TestDirectory) -> TerminalLaunch {
    TerminalLaunch {
        directory: root.path().to_str().unwrap().into(),
        argv: vec!["/bin/sh".into(), "-c".into(), "sleep 60".into()],
    }
}
fn start(manager: &Manager, root: &TestDirectory, session: SessionId) -> RuntimeRef {
    manager
        .start(
            CommandId::new(),
            TerminalTarget {
                session_id: session,
                pane_id: PaneId::new(),
            },
            &launch(root),
        )
        .unwrap()
        .runtime
}
fn intent(
    manager: &Manager,
    machine: MachineId,
    sessions: &[SessionRecord],
) -> SessionDeletionIntent {
    SessionDeletionIntent {
        target: DeletionTarget {
            machine_id: machine,
            host_generation: manager.generation,
        },
        sessions: sessions
            .iter()
            .map(|session| SessionAddress {
                workspace_id: session.workspace_id,
                session_id: session.session_id,
            })
            .collect(),
        expected_revision: manager.work.lock().unwrap().revision(),
    }
}
fn completed(manager: &Manager, runtime: RuntimeRef) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !manager.runtime_completed(runtime) {
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(10));
    }
}
#[test]
fn reservation_persistence_failure_fences_deletion_without_stopping_owned_work() {
    let root = TestDirectory::new();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    let (_, record) = session(&manager, &root, "Keep");
    let runtime = start(&manager, &root, record.session_id);
    let request = intent(&manager, MachineId::new(), &[record]);
    fs::rename(
        root.path().join("work-records.json"),
        root.path().join("work-records.saved"),
    )
    .unwrap();
    fs::create_dir(root.path().join("work-records.json")).unwrap();
    assert_eq!(
        manager.delete_sessions(CommandId::new(), request),
        Err(WorkError::OutcomeUnknown)
    );
    assert!(!manager.runtime_completed(runtime));
    assert!(manager.work.lock().unwrap().is_fenced());
    manager.shutdown();
}

#[test]
fn confirmed_batch_stops_exact_owned_children_tombstones_atomically_and_keeps_receipts_and_history()
{
    let root = TestDirectory::new();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    let machine = MachineId::new();
    let (original, a) = session(&manager, &root, "A");
    let (_, b) = session(&manager, &root, "B");
    let (_, keep) = session(&manager, &root, "Keep");
    let before = manager.work.lock().unwrap().receipt(original).unwrap();
    let history = root.path().join("retained-history.fixture");
    fs::write(&history, b"synthetic retained canonical bytes\n").unwrap();
    let a1 = start(&manager, &root, a.session_id);
    let a2 = start(&manager, &root, a.session_id);
    let b1 = start(&manager, &root, b.session_id);
    let survivor = start(&manager, &root, keep.session_id);
    let request = intent(&manager, machine, &[a.clone(), b.clone()]);
    let command = CommandId::new();
    let receipt = manager.delete_sessions(command, request.clone()).unwrap();
    assert_eq!(receipt.revision, Some(4));
    assert_eq!(receipt.runtimes.len(), 3);
    for runtime in [a1, a2, b1] {
        assert!(manager.runtime_completed(runtime));
    }
    assert!(!manager.runtime_completed(survivor));
    assert_eq!(
        manager.work.lock().unwrap().sessions(None).unwrap(),
        vec![keep.clone()]
    );
    assert_eq!(manager.work.lock().unwrap().receipt(original), Some(before));
    assert_eq!(
        manager.work.lock().unwrap().session(None, a.session_id),
        Err(WorkError::NotFound)
    );
    assert_eq!(
        fs::read(&history).unwrap(),
        b"synthetic retained canonical bytes\n"
    );
    assert_eq!(
        manager.delete_sessions(command, request.clone()).unwrap(),
        receipt
    );
    assert_eq!(
        manager.delete_sessions(
            CommandId::new(),
            SessionDeletionIntent {
                expected_revision: 4,
                ..request
            }
        ),
        Err(WorkError::NotFound)
    );
    assert_eq!(
        manager
            .start(
                CommandId::new(),
                TerminalTarget {
                    session_id: a.session_id,
                    pane_id: PaneId::new()
                },
                &launch(&root)
            )
            .unwrap_err(),
        ErrorCode::Conflict
    );
    manager.shutdown();
    completed(&manager, survivor);
    drop(manager);
    let reopened = Manager::new(root.reopen_journal());
    assert_eq!(
        reopened.work.lock().unwrap().sessions(None).unwrap(),
        vec![keep]
    );
    assert!(
        matches!(reopened.command_receipt(command), Some(CommandReceipt::Deletion { receipt: actual }) if actual == receipt)
    );
    drop(reopened);
    let path = root.path().join("work-records.json");
    let mut corrupt: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    for receipt in corrupt["deletions"].as_object_mut().unwrap().values_mut() {
        receipt["runtimes"] = json!([]);
    }
    let bytes = serde_json::to_vec(&corrupt).unwrap();
    fs::write(&path, &bytes).unwrap();
    assert!(
        root.try_reopen_journal().is_err(),
        "An omitted runtime cannot manufacture deletion completion"
    );
    assert!(
        fs::read(path).unwrap() == bytes,
        "Unsafe deletion evidence was repaired"
    );
}
#[test]
fn prepared_deletion_fences_target_and_metadata_but_reconcile_never_reissues_stop() {
    let root = TestDirectory::new();
    let manager = Manager::new(Journal::open(root.path()).unwrap());
    let (_, a) = session(&manager, &root, "A");
    let runtime = start(&manager, &root, a.session_id);
    let request = intent(&manager, MachineId::new(), &[a]);
    let command = CommandId::new();
    let original = manager
        .work
        .lock()
        .unwrap()
        .prepare_session_deletion(command, request.clone(), vec![runtime])
        .unwrap();
    assert_eq!(manager.delete_sessions(command, request).unwrap(), original);
    assert_eq!(
        manager.mutate_work(
            CommandId::new(),
            WorkIntent::RenameSession {
                workspace_id: None,
                session_id: runtime.target.session_id,
                name: "No rename".into(),
                expected_revision: 1,
            },
            &BTreeMap::new()
        ),
        Err(WorkError::Conflict)
    );
    assert!(!manager.runtime_completed(runtime));
    assert!(
        matches!(manager.command_receipt(command), Some(CommandReceipt::Deletion { receipt }) if receipt.revision.is_none())
    );
    assert_eq!(
        manager
            .start(
                CommandId::new(),
                TerminalTarget {
                    session_id: runtime.target.session_id,
                    pane_id: PaneId::new()
                },
                &launch(&root)
            )
            .unwrap_err(),
        ErrorCode::Conflict
    );
    // Simulate completion of the original owned stop, not a replay from lookup.
    manager.stop(runtime).unwrap();
    completed(&manager, runtime);
    assert!(
        matches!(manager.command_receipt(command), Some(CommandReceipt::Deletion { receipt }) if receipt.revision == Some(2))
    );
    assert!(
        manager
            .work
            .lock()
            .unwrap()
            .sessions(None)
            .unwrap()
            .is_empty()
    );
}
#[test]
fn historical_uncertainty_refuses_the_whole_batch_before_any_signal_and_cloud_cannot_delete() {
    let root = TestDirectory::new();
    let journal = Journal::open(root.path()).unwrap();
    let manager = Manager::new(journal);
    let (_, a) = session(&manager, &root, "A");
    let (_, b) = session(&manager, &root, "B");
    let live = start(&manager, &root, a.session_id);
    // Another birth epoch has no durable completion; no historical PID is adopted.
    let historical = RuntimeRef {
        host_generation: HostGeneration::new(),
        runtime_generation: RuntimeGeneration::new(),
        target: TerminalTarget {
            session_id: b.session_id,
            pane_id: PaneId::new(),
        },
    };
    // A private production journal reservation models accepted uncertain ownership.
    // Release the manager only after stopping its exact owned child, then reopen.
    manager.stop(live).unwrap();
    completed(&manager, live);
    drop(manager);
    let mut journal = root.reopen_journal();
    journal
        .prepare(CommandId::new(), historical, &launch(&root))
        .unwrap();
    let manager = Manager::new(journal);
    let live = start(&manager, &root, a.session_id);
    let machine = MachineId::new();
    let request = intent(&manager, machine, &[a, b]);
    let bytes = fs::read(root.path().join("work-records.json")).unwrap();
    assert_eq!(
        manager.delete_sessions(CommandId::new(), request.clone()),
        Err(WorkError::Rejected)
    );
    assert!(!manager.runtime_completed(live));
    assert_eq!(
        fs::read(root.path().join("work-records.json")).unwrap(),
        bytes
    );
    let params = json!({"target":request.target,"sessions":request.sessions,"expectedRevision":request.expected_revision,"commandId":CommandId::new()});
    let reply = rpc::dispatch(
        rpc::Call {
            id: Some(json!("delete")),
            method: "axo.session.delete".into(),
            params: Some(params),
        },
        &manager,
        machine,
        &BTreeMap::new(),
    )
    .unwrap();
    assert_eq!(reply["error"]["code"], -32601);
    assert!(!manager.runtime_completed(live));
    manager.shutdown();
}
