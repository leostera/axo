use super::{tests::Fixture, *};
#[test]
fn live_predecessor_is_not_ready_for_reopened_configuration() {
    let fixture = Fixture::new();
    let created = fixture.create(CommandId::new());
    let graph: WorkspaceGraph = serde_json::from_value(
        created["result"]["value"]["operation"]["accepted"]["graph"].clone(),
    )
    .unwrap();
    let shell = graph
        .initial_session
        .panes
        .iter()
        .find(|pane| pane.role == PaneRole::AccountShell)
        .unwrap();
    fixture.owner.reconcile_pane(shell.pane_id).unwrap();
    assert_eq!(
        fixture
            .owner
            .observations()
            .unwrap()
            .iter()
            .find(|observation| observation.pane_id == shell.pane_id)
            .unwrap()
            .availability,
        Availability::Live
    );
    fixture
        .owner
        .set_lifecycle(
            CommandId::new(),
            1,
            LifecycleTarget::Workspace {
                workspace_id: graph.workspace.workspace_id,
            },
            DesiredLifecycle::Archived,
        )
        .unwrap();
    fixture
        .owner
        .set_lifecycle(
            CommandId::new(),
            2,
            LifecycleTarget::Workspace {
                workspace_id: graph.workspace.workspace_id,
            },
            DesiredLifecycle::Open,
        )
        .unwrap();
    let view = session_view(&fixture.owner, graph.initial_session.session).unwrap();
    let shell = view
        .panes
        .iter()
        .find(|pane| pane.desired.pane_id == shell.pane_id)
        .unwrap();
    assert_eq!(shell.availability, Availability::Stopping);
    assert!(shell.terminal.is_none());
}
