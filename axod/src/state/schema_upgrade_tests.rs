use super::*;
use super::controller::Controller;
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
                "ALTER TABLE metadata DROP COLUMN store_generation; PRAGMA user_version=2;",
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
fn native_harness_cannot_reopen_a_stopped_central_root() {
    let root = TestDirectory::new();
    drop(Controller::for_service(root.path(), None).unwrap());
    assert!(crate::journal::Journal::open(root.path()).is_err());
}
