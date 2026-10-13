//! Metadata-only durability fixtures. These neither spawn/admit a real Pi nor
//! write canonical JSONL; native dispatch/source proof remains a separate gate.
use super::*;
use crate::state::execution::Reservation;
use crate::test_support::TestDirectory;
struct Fixture {
    root: TestDirectory,
    machine: MachineId,
    database: Database,
    input: PiCaptureInput,
    graph_command: CommandId,
}
impl Fixture {
    fn new() -> Self {
        let root = TestDirectory::new();
        let machine = MachineId::new();
        let mut database = Database::open(root.path(), machine).unwrap();
        let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
        let graph_command = CommandId::new();
        let graph = database
            .create_workspace(graph_command, 0, "Workspace", &directory)
            .unwrap()
            .graph;
        let session = graph.initial_session.session.session_id;
        let pane = graph.initial_session.panes[0].pane_id;
        let spec = database.specification(pane).unwrap();
        let host = HostGeneration::new();
        let Reservation::New(attempt) = database
            .reserve_attempt(pane, host, spec.configuration.clone())
            .unwrap()
        else {
            panic!("Fresh fixture attempt")
        };
        database.mark_launched(&attempt, attempt.runtime).unwrap();
        let binding = Binding {
            workspace_id: Some(graph.workspace.workspace_id),
            session_id: session,
            pane_id: pane,
            chat_id: serde_json::from_value(serde_json::json!(uuid::Uuid::new_v4())).unwrap(),
            runtime: attempt.runtime,
            file: spec.directory.join("never-written.jsonl"),
            directory: spec.directory.clone(),
            start_command_id: attempt.command_id,
        };
        database.admit_binding(&attempt, &binding).unwrap();
        let input = PiCaptureInput {
            command_id: CommandId::new(),
            machine_id: machine,
            host_generation: host,
            store_generation: database.generation().unwrap(),
            expected_revision: database.revision().unwrap(),
            binding,
            configuration: spec.configuration,
            action: Action::Send {
                text: "Owned fixture submission".into(),
            },
        };
        Self {
            root,
            machine,
            database,
            input,
            graph_command,
        }
    }
    fn capture(&self) -> PiCapture {
        PiCapture::parse(self.input.clone()).unwrap()
    }
}
fn permit(preparation: PiPreparation) -> PiPermit {
    match preparation {
        PiPreparation::New(permit) => permit,
        PiPreparation::Original(_) => panic!("No new permit"),
    }
}
#[test]
fn unresolved_submitted_input_fences_deletion_of_its_exact_session() {
    let mut fixture = Fixture::new();
    let capture = fixture.capture();
    let command = capture.0.command_id;
    drop(permit(fixture.database.prepare_pi(capture).unwrap()));
    let address = super::super::SessionAddress {
        workspace_id: fixture.input.binding.workspace_id,
        session_id: fixture.input.binding.session_id,
    };
    assert!(
        fixture
            .database
            .has_unconfirmed_pi_in(std::slice::from_ref(&address))
            .unwrap()
    );
    assert!(
        !fixture
            .database
            .has_unconfirmed_pi_in(&[super::super::SessionAddress {
                workspace_id: None,
                session_id: SessionId::new(),
            }])
            .unwrap()
    );
    assert_eq!(
        fixture
            .database
            .pi_original(command)
            .unwrap()
            .unwrap()
            .disposition,
        PiDisposition::Unconfirmed
    );
}
#[test]
fn dropped_or_restarted_original_is_unconfirmed_and_never_another_permit() {
    let mut fixture = Fixture::new();
    let capture = fixture.capture();
    let command = capture.0.command_id;
    drop(permit(
        fixture.database.prepare_pi(capture.clone()).unwrap(),
    ));
    assert!(matches!(
        fixture.database.prepare_pi(capture.clone()).unwrap(),
        PiPreparation::Original(PiOriginal {
            disposition: PiDisposition::Unconfirmed,
            ..
        })
    ));
    fixture
        .database
        .set_lifecycle(
            CommandId::new(),
            fixture.database.revision().unwrap(),
            LifecycleTarget::Session {
                workspace_id: capture.0.binding.workspace_id,
                session_id: capture.0.binding.session_id,
            },
            DesiredLifecycle::Archived,
        )
        .unwrap();
    assert!(
        matches!(
            fixture.database.prepare_pi(capture.clone()).unwrap(),
            PiPreparation::Original(_)
        ),
        "Withdrawal cannot turn an existing capture into dispatch authority"
    );
    drop(fixture.database);
    let before = std::fs::read(fixture.root.path().join("session-state.sqlite3")).unwrap();
    let mut database = Database::open(fixture.root.path(), fixture.machine).unwrap();
    assert!(database.pi_original(command).unwrap().unwrap().capture == capture);
    assert!(matches!(
        database.prepare_pi(capture).unwrap(),
        PiPreparation::Original(_)
    ));
    assert_eq!(
        std::fs::read(fixture.root.path().join("session-state.sqlite3")).unwrap(),
        before
    );
    assert!(!fixture.root.path().join("never-written.jsonl").exists());
}
#[test]
fn storage_owner_exchange_cannot_consume_an_old_local_permit() {
    let mut fixture = Fixture::new();
    let capture = fixture.capture();
    let token = permit(fixture.database.prepare_pi(capture.clone()).unwrap());
    drop(fixture.database);
    let mut database = Database::open(fixture.root.path(), fixture.machine).unwrap();
    assert_eq!(
        database.finish_pi(token, PiTerminal::OutcomeUnknown).err(),
        Some(Error::Conflict)
    );
    assert_eq!(
        database
            .pi_original(capture.0.command_id)
            .unwrap()
            .unwrap()
            .disposition,
        PiDisposition::Unconfirmed
    );
}
#[test]
fn terminal_receipts_are_immutable_and_do_not_reissue_dispatch() {
    for terminal in [
        PiTerminal::Rejected(PiRejection::Busy),
        PiTerminal::OutcomeUnknown,
    ] {
        let mut fixture = Fixture::new();
        let capture = fixture.capture();
        let token = permit(fixture.database.prepare_pi(capture.clone()).unwrap());
        let original = fixture.database.finish_pi(token, terminal).unwrap();
        assert_ne!(original.disposition, PiDisposition::Unconfirmed);
        assert!(matches!(
            fixture.database.prepare_pi(capture.clone()).unwrap(),
            PiPreparation::Original(_)
        ));
        for table in ["submitted_commands", "submitted_results"] {
            assert!(
                fixture
                    .database
                    .connection
                    .execute(&format!("DELETE FROM {table}"), [])
                    .is_err()
            );
        }
        assert!(
            fixture
                .database
                .connection
                .execute("UPDATE submitted_commands SET capture=x'00'", [])
                .is_err()
        );
        assert!(
            fixture
                .database
                .connection
                .execute("UPDATE submitted_results SET result=x'00'", [])
                .is_err()
        );
        let command = capture.0.command_id;
        drop(fixture.database);
        let database = Database::open(fixture.root.path(), fixture.machine).unwrap();
        assert!(database.pi_original(command).unwrap().as_ref() == Some(&original));
    }
}
#[test]
fn malformed_and_foreign_captures_do_not_publish_or_claim_command_ids() {
    let mut fixture = Fixture::new();
    let before = fixture.database.revision().unwrap();
    for change in 0..7 {
        let mut input = fixture.input.clone();
        match change {
            0 => input.machine_id = MachineId::new(),
            1 => input.store_generation = StoreGeneration::new(),
            2 => input.expected_revision += 1,
            3 => input.configuration.session_revision = 0,
            4 => {
                input.binding.chat_id =
                    serde_json::from_value(serde_json::json!(uuid::Uuid::new_v4())).unwrap()
            }
            5 => input.command_id = fixture.graph_command,
            _ => input.command_id = fixture.input.binding.start_command_id,
        }
        assert_eq!(
            fixture
                .database
                .prepare_pi(PiCapture::parse(input).unwrap())
                .err(),
            Some(Error::Conflict)
        );
    }
    assert_eq!(fixture.database.revision().unwrap(), before);
    assert!(
        fixture
            .database
            .pi_original(fixture.input.command_id)
            .unwrap()
            .is_none()
    );
    for text in [
        " \n".into(),
        " \t/slash".into(),
        "x".repeat(65537),
        "\u{0001}".repeat(12000),
    ] {
        let mut input = fixture.input.clone();
        input.action = Action::Send { text };
        assert!(PiCapture::parse(input).is_err());
    }
    let capture = fixture.capture();
    drop(permit(
        fixture.database.prepare_pi(capture.clone()).unwrap(),
    ));
    assert_eq!(
        fixture
            .database
            .set_lifecycle(
                capture.0.command_id,
                fixture.database.revision().unwrap(),
                LifecycleTarget::Session {
                    workspace_id: capture.0.binding.workspace_id,
                    session_id: capture.0.binding.session_id
                },
                DesiredLifecycle::Archived
            )
            .err(),
        Some(Error::Conflict)
    );
    let mut changed = fixture.input.clone();
    changed.action = Action::Send {
        text: "Different captured bytes".into(),
    };
    assert_eq!(
        fixture
            .database
            .prepare_pi(PiCapture::parse(changed).unwrap())
            .err(),
        Some(Error::Conflict)
    );
}
#[test]
fn terminal_publication_is_allowed_at_original_capacity() {
    let mut fixture = Fixture::new();
    let token = permit(fixture.database.prepare_pi(fixture.capture()).unwrap());
    // Owned synthetic inventory: well-formed immutable captures, no claim that
    // these metadata rows dispatched input or owned an execution resource.
    let mut captures = Vec::new();
    for revision in 2..u64::from(MAX_OPERATIONS) {
        let mut input = fixture.input.clone();
        input.command_id = CommandId::new();
        input.expected_revision = revision;
        let capture = PiCapture::parse(input).unwrap();
        captures.push((
            capture.0.command_id,
            capture.encoded().unwrap(),
            revision + 1,
        ));
    }
    fixture
        .database
        .mutate(|tx| {
            for (command, capture, revision) in captures {
                tx.execute(
                    "INSERT INTO submitted_commands VALUES(?1,?2,?3,?4)",
                    params![
                        command.to_string(),
                        capture.fingerprint.as_slice(),
                        capture.bytes,
                        sql_revision(revision)?
                    ],
                )?;
            }
            tx.execute(
                "UPDATE metadata SET revision=?1",
                [i64::from(MAX_OPERATIONS)],
            )?;
            Ok(())
        })
        .unwrap();
    let mut input = fixture.input.clone();
    input.command_id = CommandId::new();
    input.expected_revision = fixture.database.revision().unwrap();
    assert_eq!(
        fixture
            .database
            .prepare_pi(PiCapture::parse(input).unwrap())
            .err(),
        Some(Error::Capacity)
    );
    assert_eq!(
        fixture
            .database
            .add_shell(
                CommandId::new(),
                fixture.database.revision().unwrap(),
                fixture.input.binding.session_id
            )
            .err(),
        Some(Error::Capacity)
    );
    assert_eq!(
        fixture
            .database
            .finish_pi(token, PiTerminal::OutcomeUnknown)
            .unwrap()
            .disposition,
        PiDisposition::OutcomeUnknown
    );
}
#[test]
fn corrupted_original_blocks_startup_without_rewriting_evidence() {
    let mut fixture = Fixture::new();
    let capture = fixture.capture();
    drop(permit(fixture.database.prepare_pi(capture).unwrap()));
    fixture.database.mutate(|tx| { tx.execute_batch("DROP TRIGGER immutable_submitted_commands_update; UPDATE submitted_commands SET fingerprint=zeroblob(32);")?; Ok(()) }).unwrap();
    drop(fixture.database);
    let path = fixture.root.path().join("session-state.sqlite3");
    let before = std::fs::read(&path).unwrap();
    assert_eq!(
        Database::open(fixture.root.path(), fixture.machine).err(),
        Some(Error::Corrupt)
    );
    assert_eq!(std::fs::read(&path).unwrap(), before);
}
#[test]
fn failed_image_publication_returns_no_permit_and_fences_owner() {
    let mut fixture = Fixture::new();
    let capture = fixture.capture();
    let image = fixture.root.path().join("session-state.sqlite3");
    std::fs::rename(&image, fixture.root.path().join("owned-saved-image")).unwrap();
    std::fs::write(&image, b"Owned unsafe successor").unwrap();
    assert!(fixture.database.prepare_pi(capture).is_err());
    assert_eq!(fixture.database.revision().err(), Some(Error::Fenced));
}
