use super::*;
use crate::test_support::TestDirectory;
use std::{fs, os::unix::fs::PermissionsExt};

fn controller(root: &TestDirectory) -> Arc<Controller> {
    with_machine(root, MachineId::new())
}
fn with_machine(root: &TestDirectory, machine: MachineId) -> Arc<Controller> {
    let mut controller = Controller::open(root.path(), machine, None).unwrap();
    let executable = root.path().join("owned-shell");
    fs::write(&executable, "#!/bin/sh\nexec /bin/cat\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    Arc::get_mut(&mut controller.native).unwrap().user_shell =
        crate::user_shell::CapturedUserShell::parse(&executable);
    Arc::new(controller)
}
fn wait(condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "Owned materialization deadline elapsed"
        );
        thread::sleep(Duration::from_millis(25));
    }
}
fn workspace(controller: &Controller, root: &TestDirectory) -> WorkspaceGraph {
    controller
        .create_workspace(
            CommandId::new(),
            controller.revision().unwrap(),
            "Workspace",
            &ApprovedDirectory::local_selection(root.path()).unwrap(),
        )
        .unwrap()
        .graph
}
#[test]
fn all_twenty_four_shells_materialize_without_frontend_or_pi_policy() {
    let root = TestDirectory::new();
    let controller = controller(&root);
    for _ in 0..3 {
        let graph = workspace(&controller, &root);
        let mut sessions = vec![graph.initial_session.session.session_id];
        for _ in 1..4 {
            sessions.push(
                controller
                    .create_session(
                        CommandId::new(),
                        controller.revision().unwrap(),
                        graph.workspace.workspace_id,
                        "Session",
                    )
                    .unwrap()
                    .graph
                    .session
                    .session_id,
            );
        }
        for session in sessions {
            controller
                .add_shell(CommandId::new(), controller.revision().unwrap(), session)
                .unwrap();
        }
    }
    let workers = controller.supervise().unwrap();
    assert!(matches!(controller.supervise(), Err(Error::Conflict)));
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .filter(|observation| observation.availability == Availability::Live)
            .count()
            == 24
    });
    let observations = controller.observations().unwrap();
    assert_eq!(observations.len(), 36);
    assert_eq!(
        controller
            .native
            .list()
            .iter()
            .filter(|snapshot| matches!(snapshot.process, ProcessState::Running { .. }))
            .count(),
        24
    );
    for observation in observations
        .iter()
        .filter(|observation| observation.availability == Availability::Live)
    {
        assert!(
            controller
                .native
                .owns_running_runtime(observation.runtime.unwrap())
        );
    }
    workers.shutdown().unwrap();
}
#[test]
fn clean_exit_replaces_runtime_but_not_pane_identity() {
    let root = TestDirectory::new();
    let controller = controller(&root);
    let graph = workspace(&controller, &root);
    let pane = graph.initial_session.panes[1].pane_id;
    let workers = controller.supervise().unwrap();
    wait(|| {
        controller.native.list().iter().any(|snapshot| {
            snapshot.runtime.target.pane_id == pane
                && matches!(snapshot.process, ProcessState::Running { .. })
        })
    });
    let original = controller
        .native
        .list()
        .into_iter()
        .find(|snapshot| snapshot.runtime.target.pane_id == pane)
        .unwrap()
        .runtime;
    controller.native.stop(original).unwrap();
    wait(|| {
        controller.native.list().iter().any(|snapshot| {
            snapshot.runtime.target.pane_id == pane
                && snapshot.runtime != original
                && matches!(snapshot.process, ProcessState::Running { .. })
        })
    });
    let replacement = controller
        .native
        .list()
        .into_iter()
        .find(|snapshot| snapshot.runtime.target.pane_id == pane)
        .unwrap()
        .runtime;
    assert_eq!(replacement.target, original.target);
    let attempt = controller
        .database
        .lock()
        .unwrap()
        .attempt(pane)
        .unwrap()
        .unwrap();
    assert_eq!(attempt.runtime, replacement);
    assert!(attempt.predecessor.is_some());
    assert_eq!(
        controller
            .database
            .lock()
            .unwrap()
            .panes(graph.initial_session.session.session_id)
            .unwrap(),
        graph.initial_session.panes
    );
    workers.shutdown().unwrap();
}
#[test]
fn archive_completes_owned_shell_and_reopen_keeps_the_graph() {
    let root = TestDirectory::new();
    let controller = controller(&root);
    let graph = workspace(&controller, &root);
    let pane = graph.initial_session.panes[1].pane_id;
    let workers = controller.supervise().unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .any(|observation| {
                observation.pane_id == pane && observation.availability == Availability::Live
            })
    });
    let original = controller
        .native
        .list()
        .into_iter()
        .find(|snapshot| snapshot.runtime.target.pane_id == pane)
        .unwrap()
        .runtime;
    let target = LifecycleTarget::Workspace {
        workspace_id: graph.workspace.workspace_id,
    };
    controller
        .set_lifecycle(
            CommandId::new(),
            controller.revision().unwrap(),
            target.clone(),
            DesiredLifecycle::Archived,
        )
        .unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .all(|observation| observation.availability == Availability::Stopped)
    });
    assert!(controller.native.runtime_completed(original));
    controller
        .set_lifecycle(
            CommandId::new(),
            controller.revision().unwrap(),
            target,
            DesiredLifecycle::Open,
        )
        .unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .any(|observation| {
                observation.pane_id == pane
                    && observation.availability == Availability::Live
                    && observation.runtime != Some(original)
            })
    });
    workers.shutdown().unwrap();
}
#[test]
fn original_unissued_reservation_survives_restart_without_spawning() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let controller = Controller::open(root.path(), machine, None).unwrap();
    let graph = workspace(&controller, &root);
    let pane = graph.initial_session.panes[1].pane_id;
    let original = {
        let mut database = controller.database.lock().unwrap();
        let spec = database.specification(pane).unwrap();
        let Reservation::New(attempt) = database
            .reserve_attempt(pane, controller.native.generation, spec.configuration)
            .unwrap()
        else {
            panic!("Expected first reservation")
        };
        attempt
    };
    drop(controller);
    let controller = Arc::new(Controller::open(root.path(), machine, None).unwrap());
    let workers = controller.supervise().unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .any(|observation| {
                observation.pane_id == pane && observation.availability == Availability::Blocked
            })
    });
    assert!(controller.native.list().is_empty());
    assert_eq!(
        controller
            .database
            .lock()
            .unwrap()
            .attempt(pane)
            .unwrap()
            .unwrap(),
        original
    );
    workers.shutdown().unwrap();
}
#[test]
fn service_shutdown_preserves_desired_state_and_next_owner_restores_shell() {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let controller = with_machine(&root, machine);
    let graph = workspace(&controller, &root);
    let pane = graph.initial_session.panes[1].pane_id;
    let workers = controller.supervise().unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .any(|observation| {
                observation.pane_id == pane && observation.availability == Availability::Live
            })
    });
    let original = controller
        .native
        .list()
        .into_iter()
        .find(|snapshot| snapshot.runtime.target.pane_id == pane)
        .unwrap()
        .runtime;
    workers.shutdown().unwrap();
    assert_eq!(
        controller.database.lock().unwrap().desired_panes().unwrap(),
        graph.initial_session.panes
    );
    drop(controller);
    let controller = with_machine(&root, machine);
    let workers = controller.supervise().unwrap();
    wait(|| {
        controller
            .observations()
            .unwrap()
            .iter()
            .any(|observation| {
                observation.pane_id == pane && observation.availability == Availability::Live
            })
    });
    let replacement = controller
        .native
        .list()
        .into_iter()
        .find(|snapshot| snapshot.runtime.target.pane_id == pane)
        .unwrap()
        .runtime;
    assert_eq!(original.target, replacement.target);
    assert_ne!(original.host_generation, replacement.host_generation);
    workers.shutdown().unwrap();
}
