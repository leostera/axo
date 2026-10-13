use super::controller::Controller;
use super::*;
use crate::test_support::TestDirectory;
#[test]
fn schema_two_upgrade_mints_one_store_generation_and_preserves_original() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let command = CommandId::new();
    let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
    let accepted = database
        .create_workspace(command, 0, "Workspace", &directory)
        .unwrap();
    database
        .mutate(|transaction| {
            transaction.execute_batch(
                "DROP TABLE deletion_targets; DROP TABLE deletion_results; DROP TABLE deletion_intents; DROP TABLE submitted_results; DROP TABLE submitted_commands; ALTER TABLE metadata DROP COLUMN store_generation; PRAGMA user_version=2;",
            )?;
            Ok(())
        })
        .unwrap();
    drop(database);
    let database = Database::open(root.path(), machine).unwrap();
    let generation = database.generation().unwrap();
    assert_eq!(database.revision().unwrap(), accepted.revision);
    assert!(
        matches!(database.operation(command).unwrap(),Some(Operation::CreateWorkspace(original)) if original.graph==accepted.graph)
    );
    drop(database);
    let reopened = Database::open(root.path(), machine).unwrap();
    assert_eq!(generation, reopened.generation().unwrap());
}
#[test]
fn schema_four_upgrade_preserves_graph_and_installs_deletion_authority() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let command = CommandId::new();
    let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
    let accepted = database
        .create_workspace(command, 0, "Workspace", &directory)
        .unwrap();
    let generation = database.generation().unwrap();
    database
        .mutate(|transaction| {
            transaction.execute_batch(
                "DROP TABLE deletion_targets; DROP TABLE deletion_results; DROP TABLE deletion_intents; PRAGMA user_version=4;",
            )?;
            Ok(())
        })
        .unwrap();
    drop(database);

    let upgraded = Database::open(root.path(), machine).unwrap();
    assert_eq!(upgraded.generation().unwrap(), generation);
    assert_eq!(upgraded.revision().unwrap(), accepted.revision);
    assert_eq!(
        upgraded.workspaces().unwrap(),
        vec![accepted.graph.workspace.clone()]
    );
    assert!(matches!(
        upgraded.operation(command).unwrap(),
        Some(Operation::CreateWorkspace(original)) if original.graph == accepted.graph
    ));
    let version: i64 = upgraded
        .connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, 5);
    let target_table: bool = upgraded
        .connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='deletion_targets')",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(target_table);
}

#[test]
fn schema_three_upgrade_preserves_source_original_and_opaque_retired_bytes() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    let generation = database.generation().unwrap();
    let command = CommandId::new();
    let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
    let graph = database
        .create_workspace(command, 0, "Workspace", &directory)
        .unwrap()
        .graph;
    database.mutate(|tx| {
        tx.execute_batch("DROP TABLE deletion_targets; DROP TABLE deletion_results; DROP TABLE deletion_intents; DROP TABLE submitted_results; DROP TABLE submitted_commands; CREATE TABLE drafts (opaque BLOB); INSERT INTO drafts VALUES(x'ff00fe'); PRAGMA user_version=3;")?;
        Ok(())
    }).unwrap();
    drop(database);
    let database = Database::open(root.path(), machine).unwrap();
    assert_eq!(database.generation().unwrap(), generation);
    assert_eq!(database.revision().unwrap(), 1);
    assert!(
        matches!(database.operation(command).unwrap(), Some(Operation::CreateWorkspace(original)) if original.graph == graph)
    );
    let opaque: Vec<u8> = database
        .connection
        .query_row("SELECT opaque FROM drafts", [], |row| row.get(0))
        .unwrap();
    assert_eq!(opaque, vec![255, 0, 254]);
}
#[test]
fn schema_upgrade_refuses_to_adopt_unknown_submitted_table() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let mut database = Database::open(root.path(), machine).unwrap();
    database.mutate(|tx| { tx.execute_batch("DROP TABLE deletion_targets; DROP TABLE deletion_results; DROP TABLE deletion_intents; DROP TABLE submitted_results; DROP TABLE submitted_commands; CREATE TABLE submitted_commands (opaque BLOB); INSERT INTO submitted_commands VALUES(x'fffe'); PRAGMA user_version=3;")?; Ok(()) }).unwrap();
    drop(database);
    let path = root.path().join("session-state.sqlite3");
    let before = std::fs::read(&path).unwrap();
    assert!(Database::open(root.path(), machine).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), before);
}
#[test]
fn native_harness_cannot_reopen_a_stopped_central_root() {
    let root = TestDirectory::new();
    drop(Controller::for_service(root.path(), None).unwrap());
    assert!(crate::journal::Journal::open(root.path()).is_err());
}
