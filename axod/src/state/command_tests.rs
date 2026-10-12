use super::*;
use crate::test_support::TestDirectory;
#[test]
fn metadata_cannot_reuse_an_original_materialization_command() {
    let root = TestDirectory::new();
    let mut database = Database::open(root.path(), MachineId::new()).unwrap();
    let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
    let created = database
        .create_workspace(CommandId::new(), 0, "Workspace", &directory)
        .unwrap();
    let pane = created.graph.initial_session.panes[1].pane_id;
    let configuration = database.specification(pane).unwrap().configuration;
    let execution::Reservation::New(attempt) = database
        .reserve_attempt(pane, HostGeneration::new(), configuration)
        .unwrap()
    else {
        panic!("new fixture attempt");
    };
    assert!(matches!(
        database.create_workspace(attempt.command_id, 1, "Another", &directory),
        Err(Error::Conflict)
    ));
    assert_eq!(database.revision().unwrap(), 1);
    assert_eq!(database.workspaces().unwrap().len(), 1);
    assert!(database.operation(attempt.command_id).unwrap().is_none());
    assert_eq!(
        database.attempt(pane).unwrap().unwrap().command_id,
        attempt.command_id
    );
}
