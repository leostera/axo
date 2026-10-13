use super::*;
use crate::{
    journal::Journal,
    runtime::Manager,
    state::{ApprovedDirectory, DesiredLifecycle, LifecycleTarget},
    test_support::TestDirectory,
};
use std::{thread, time::Duration};

fn workspace(
    database: &mut Database,
    root: &TestDirectory,
) -> super::super::Accepted<super::super::WorkspaceGraph> {
    let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
    database
        .create_workspace(CommandId::new(), 0, "Workspace", &directory)
        .unwrap()
}

fn intent(
    database: &Database,
    machine_id: MachineId,
    host_generation: HostGeneration,
    revision: u64,
    sessions: Vec<SessionAddress>,
) -> SessionDeletionIntent {
    SessionDeletionIntent {
        target: DeletionSource {
            machine_id,
            host_generation,
            store_generation: database.generation().unwrap(),
        },
        sessions,
        expected_revision: revision,
    }
}

fn address(workspace_id: Option<WorkspaceId>, session_id: SessionId) -> SessionAddress {
    SessionAddress {
        workspace_id,
        session_id,
    }
}

#[test]
fn deletion_is_revision_captured_atomic_and_distinct_from_archive() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let created = workspace(&mut database, &root);
    let session = created.graph.initial_session.session.session_id;
    let workspace_id = created.graph.workspace.workspace_id;

    let archived = database
        .set_lifecycle(
            CommandId::new(),
            1,
            LifecycleTarget::Session {
                workspace_id: Some(workspace_id),
                session_id: session,
            },
            DesiredLifecycle::Archived,
        )
        .unwrap();
    assert_eq!(archived.revision, 2);
    assert_eq!(database.sessions().unwrap().len(), 1);
    assert_eq!(
        database.sessions().unwrap()[0].lifecycle,
        DesiredLifecycle::Archived
    );

    let command = CommandId::new();
    let capture = intent(
        &database,
        machine,
        HostGeneration::new(),
        2,
        vec![address(Some(workspace_id), session)],
    );
    let reservation = database
        .reserve_deletion(command, capture.clone(), Vec::new())
        .unwrap();
    let DeletionPreparation::Reserved(pending) = reservation else {
        panic!("first delete must reserve")
    };
    assert_eq!(pending.revision, None);
    assert_eq!(database.revision().unwrap(), 2);
    assert_eq!(database.sessions().unwrap().len(), 1);
    assert!(database.session_deletion_pending(session).unwrap());
    assert!(
        database
            .connection
            .execute(
                "UPDATE deletion_intents SET capture=capture WHERE command_id=?1",
                [command.to_string()],
            )
            .is_err()
    );
    assert!(
        database
            .connection
            .execute(
                "UPDATE deletion_targets SET workspace_id=workspace_id WHERE command_id=?1",
                [command.to_string()],
            )
            .is_err()
    );

    assert_eq!(
        database.create_session(CommandId::new(), 2, workspace_id, "Concurrent"),
        Err(Error::Conflict),
        "pending Delete fences catalog mutation without publishing a tombstone"
    );

    let committed = database.commit_deletion(command).unwrap().unwrap();
    assert_eq!(committed.revision, Some(3));
    assert!(database.sessions().unwrap().is_empty());
    assert_eq!(database.revision().unwrap(), 3);
    assert!(database
        .connection
        .execute(
            "UPDATE deletion_results SET accepted_revision=accepted_revision WHERE command_id=?1",
            [command.to_string()],
        )
        .is_err());
    assert!(
        database
            .connection
            .execute(
                "DELETE FROM deletion_targets WHERE command_id=?1",
                [command.to_string()],
            )
            .is_err()
    );
    let retained_sessions: u32 = database
        .connection
        .query_row("SELECT count(*) FROM sessions", [], |row| row.get(0))
        .unwrap();
    let retained_panes: u32 = database
        .connection
        .query_row("SELECT count(*) FROM panes", [], |row| row.get(0))
        .unwrap();
    assert_eq!(retained_sessions, 1);
    assert_eq!(retained_panes, 2);

    assert_eq!(
        database
            .reserve_deletion(command, capture.clone(), Vec::new())
            .unwrap(),
        DeletionPreparation::Original(committed.clone()),
        "lost response reconciliation returns the immutable receipt"
    );
    let changed = SessionDeletionIntent {
        expected_revision: 3,
        ..capture
    };
    assert_eq!(
        database.reserve_deletion(command, changed, Vec::new()),
        Err(Error::Conflict),
        "command identity cannot be retargeted"
    );
}

#[test]
fn delete_batch_is_bounded_unique_and_requires_explicit_nullable_scope() {
    let source = DeletionSource {
        machine_id: MachineId::new(),
        host_generation: HostGeneration::new(),
        store_generation: StoreGeneration::new(),
    };
    let addresses = (0..33)
        .map(|_| address(Some(WorkspaceId::new()), SessionId::new()))
        .collect();
    let too_many = SessionDeletionIntent {
        target: source.clone(),
        sessions: addresses,
        expected_revision: 0,
    };
    assert_eq!(validate_intent(&too_many, &[]), Err(Error::Invalid));
    let duplicate = SessionAddress {
        workspace_id: None,
        session_id: SessionId::new(),
    };
    let duplicates = SessionDeletionIntent {
        target: source.clone(),
        sessions: vec![duplicate.clone(), duplicate],
        expected_revision: 0,
    };
    assert_eq!(validate_intent(&duplicates, &[]), Err(Error::Invalid));
    let missing_scope = serde_json::from_str::<SessionAddress>(&format!(
        "{{\"sessionId\":\"{}\"}}",
        SessionId::new()
    ));
    assert!(missing_scope.is_err());
    assert!(
        serde_json::from_str::<SessionAddress>(&format!(
            "{{\"workspaceId\":null,\"sessionId\":\"{}\"}}",
            SessionId::new()
        ))
        .is_ok()
    );
}

#[test]
fn pending_delete_fences_new_runtime_materialization() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let created = workspace(&mut database, &root);
    let session = created.graph.initial_session.session.session_id;
    let intent = intent(
        &database,
        machine,
        HostGeneration::new(),
        1,
        vec![address(Some(created.graph.workspace.workspace_id), session)],
    );
    database
        .reserve_deletion(CommandId::new(), intent, Vec::new())
        .unwrap();
    assert!(matches!(
        database.specification(created.graph.initial_session.panes[1].pane_id),
        Err(Error::Conflict)
    ));
}

#[test]
fn pending_delete_reconciles_only_after_exact_runtime_completion() {
    let root = TestDirectory::new();
    let journal_root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let created = workspace(&mut database, &root);
    let session = created.graph.initial_session.session.session_id;
    let pane = created.graph.initial_session.panes[1].pane_id;

    let manager = Manager::new(Journal::open(journal_root.path()).unwrap());
    let specification = database.specification(pane).unwrap();
    let attempt = match database
        .reserve_attempt(pane, manager.generation, specification.configuration)
        .unwrap()
    {
        super::super::execution::Reservation::New(attempt) => attempt,
        super::super::execution::Reservation::Existing(_) => panic!("new pane attempt"),
    };
    let launch = TerminalLaunch {
        directory: root.path().to_string_lossy().into_owned(),
        argv: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
    };
    manager
        .start_materialized(attempt.command_id, attempt.runtime, &launch, false)
        .unwrap();
    database.mark_launched(&attempt, attempt.runtime).unwrap();

    let command = CommandId::new();
    let capture = intent(
        &database,
        machine,
        manager.generation,
        1,
        vec![address(Some(created.graph.workspace.workspace_id), session)],
    );
    let reserved = database
        .reserve_deletion(command, capture, vec![attempt.runtime])
        .unwrap();
    assert!(matches!(reserved, DeletionPreparation::Reserved(_)));
    assert_eq!(
        database.commit_deletion(command).unwrap().unwrap().revision,
        None
    );
    assert_eq!(database.sessions().unwrap().len(), 1);

    let proof = (0..200)
        .find_map(|_| {
            let proof = manager.completion_evidence(attempt.runtime);
            if proof.is_none() {
                thread::sleep(Duration::from_millis(10));
            }
            proof
        })
        .expect("owned child completion is persisted");
    database.complete_attempt(&attempt, proof).unwrap();
    let committed = database.commit_deletion(command).unwrap().unwrap();
    assert_eq!(committed.revision, Some(2));
    assert!(database.sessions().unwrap().is_empty());
}
