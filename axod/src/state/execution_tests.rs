use super::*;
use crate::test_support::TestDirectory;
#[test]
fn schema_one_upgrade_preserves_graph_and_original_receipt() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let command = CommandId::new();
    let approval = ApprovedDirectory::local_selection(root.path()).unwrap();
    let original = database
        .create_workspace(command, 0, "Original", &approval)
        .unwrap();
    database.mutate(|tx|{tx.execute_batch("ALTER TABLE pi_bindings DROP COLUMN runtime_binding; ALTER TABLE runtime_attempts DROP COLUMN config_capture; PRAGMA user_version=1;")?;Ok(())}).unwrap();
    drop(database);
    let mut database = Database::open(root.path(), machine).unwrap();
    assert_eq!(database.workspaces().unwrap()[0], original.graph.workspace);
    assert_eq!(
        database.sessions().unwrap()[0],
        original.graph.initial_session.session
    );
    assert_eq!(
        database
            .panes(original.graph.initial_session.session.session_id)
            .unwrap(),
        original.graph.initial_session.panes
    );
    let observed = database
        .create_workspace(command, 0, "Original", &approval)
        .unwrap();
    assert_eq!(observed.command_id, original.command_id);
    assert_eq!(observed.graph, original.graph);
    assert_eq!(database.revision().unwrap(), 1);
    assert_eq!(
        database
            .connection
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap(),
        2
    );
}
#[test]
fn ancestor_capture_detects_archive_reopen_even_below_pane_revision() {
    let root = TestDirectory::new();
    let mut database = Database::open(root.path(), MachineId::new()).unwrap();
    let graph = database
        .create_workspace(
            CommandId::new(),
            0,
            "Workspace",
            &ApprovedDirectory::local_selection(root.path()).unwrap(),
        )
        .unwrap()
        .graph;
    let pane = graph.initial_session.panes[1].pane_id;
    database
        .mutate(|tx| {
            tx.execute(
                "UPDATE panes SET config_revision=9 WHERE pane_id=?1",
                [pane.to_string()],
            )?;
            Ok(())
        })
        .unwrap();
    let captured = database.specification(pane).unwrap().configuration;
    let target = LifecycleTarget::Workspace {
        workspace_id: graph.workspace.workspace_id,
    };
    database
        .set_lifecycle(
            CommandId::new(),
            1,
            target.clone(),
            DesiredLifecycle::Archived,
        )
        .unwrap();
    database
        .set_lifecycle(CommandId::new(), 2, target, DesiredLifecycle::Open)
        .unwrap();
    assert_eq!(
        database
            .specification(pane)
            .unwrap()
            .configuration
            .pane_revision,
        9
    );
    assert!(matches!(
        database.reserve_attempt(pane, HostGeneration::new(), captured),
        Err(Error::Conflict)
    ));
    assert!(database.attempt(pane).unwrap().is_none());
}
#[test]
fn launch_cannot_retarget_a_reserved_command_and_cannot_reissue_it() {
    let root = TestDirectory::new();
    let mut database = Database::open(root.path(), MachineId::new()).unwrap();
    let graph = database
        .create_workspace(
            CommandId::new(),
            0,
            "Workspace",
            &ApprovedDirectory::local_selection(root.path()).unwrap(),
        )
        .unwrap()
        .graph;
    let pane = graph.initial_session.panes[1].pane_id;
    let spec = database.specification(pane).unwrap();
    let execution::Reservation::New(original) = database
        .reserve_attempt(pane, HostGeneration::new(), spec.configuration.clone())
        .unwrap()
    else {
        panic!("Expected reservation")
    };
    let mut altered = original.clone();
    altered.runtime.runtime_generation = RuntimeGeneration::new();
    assert_eq!(
        database.mark_launched(&altered, altered.runtime),
        Err(Error::Conflict)
    );
    let execution::Reservation::Existing(observed) = database
        .reserve_attempt(pane, HostGeneration::new(), spec.configuration)
        .unwrap()
    else {
        panic!("Must observe original reservation")
    };
    assert_eq!(original, observed);
    assert_eq!(
        database.attempt(pane).unwrap().unwrap().phase,
        AttemptPhase::Reserved
    );
}
#[test]
fn controller_never_follows_auxiliary_runtime_directory_symlink() {
    let root = TestDirectory::new();
    let target = TestDirectory::new();
    std::os::unix::fs::symlink(target.path(), root.path().join("Runtime")).unwrap();
    assert!(matches!(
        controller::Controller::open(root.path(), MachineId::new(), None),
        Err(Error::UnsafeStorage)
    ));
    assert_eq!(std::fs::read_dir(target.path()).unwrap().count(), 0);
}
