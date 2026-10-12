use super::*;
use crate::test_support::TestDirectory;
#[test]
fn fresh_central_root_is_empty_and_never_imports_or_changes_legacy_bytes() {
    use std::os::unix::fs::DirBuilderExt;
    let root = TestDirectory::new();
    for name in [
        "work-records.json",
        "pane-state.json",
        "pi-state.json",
        "runtime-state.json",
        "old-drafts",
    ] {
        std::fs::write(root.path().join(name), b"retained opaque original").unwrap();
    }
    let central = root.path().join("central");
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&central)
        .unwrap();
    let database = Database::open(&central, MachineId::new()).unwrap();
    assert_eq!(database.revision().unwrap(), 0);
    assert!(database.workspaces().unwrap().is_empty());
    assert!(database.sessions().unwrap().is_empty());
    assert!(database.desired_panes().unwrap().is_empty());
    let import_tables: u32 = database
        .connection
        .query_row(
            "SELECT count(*) FROM sqlite_schema WHERE name='legacy_originals'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(import_tables, 0);
    for name in [
        "work-records.json",
        "pane-state.json",
        "pi-state.json",
        "runtime-state.json",
        "old-drafts",
    ] {
        assert_eq!(
            std::fs::read(root.path().join(name)).unwrap(),
            b"retained opaque original"
        );
    }
}
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
    database.mutate(|tx|{tx.execute_batch("ALTER TABLE pi_bindings DROP COLUMN runtime_binding; ALTER TABLE runtime_attempts DROP COLUMN config_capture; ALTER TABLE metadata DROP COLUMN store_generation; PRAGMA user_version=1;")?;Ok(())}).unwrap();
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
        3
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
