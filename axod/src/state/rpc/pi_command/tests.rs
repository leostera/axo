//! Metadata-only RPC fixtures. No Pi, PTY, canonical writer or UI readiness is
//! simulated: these test original observation and refusal without native proof.
use super::*;
use crate::{pi_session::Binding, state::execution::Reservation, test_support::TestDirectory};
fn fixture() -> (TestDirectory, Controller, MachineId, PiCapture) {
    let root = TestDirectory::new();
    let machine = MachineId::new();
    let owner = Controller::open(root.path(), machine, None).unwrap();
    let directory = ApprovedDirectory::local_selection(root.path()).unwrap();
    let graph = owner
        .create_workspace(CommandId::new(), 0, "Workspace", &directory)
        .unwrap()
        .graph;
    let mut database = owner.database.lock().unwrap();
    let pane = graph.initial_session.panes[0].pane_id;
    let spec = database.specification(pane).unwrap();
    let host = owner.runtime_owner().generation;
    let Reservation::New(attempt) = database
        .reserve_attempt(pane, host, spec.configuration.clone())
        .unwrap()
    else {
        panic!("Fresh fixture")
    };
    database.mark_launched(&attempt, attempt.runtime).unwrap();
    let binding = Binding {
        workspace_id: Some(graph.workspace.workspace_id),
        session_id: spec.pane.session_id,
        pane_id: pane,
        chat_id: serde_json::from_value(json!(uuid::Uuid::new_v4())).unwrap(),
        runtime: attempt.runtime,
        file: spec.directory.join("never-written.jsonl"),
        directory: spec.directory.clone(),
        start_command_id: attempt.command_id,
    };
    database.admit_binding(&attempt, &binding).unwrap();
    let capture = PiCapture::parse(PiCaptureInput {
        command_id: CommandId::new(),
        machine_id: machine,
        host_generation: host,
        store_generation: database.generation().unwrap(),
        expected_revision: database.revision().unwrap(),
        binding,
        configuration: spec.configuration,
        action: Action::Send {
            text: "Owned original fixture".into(),
        },
    })
    .unwrap();
    drop(database);
    (root, owner, machine, capture)
}
fn params(capture: &PiCapture) -> Value {
    let input = capture.input();
    json!({"target":BindingTarget::captured(capture),"commandId":input.command_id,"expectedRevision":input.expected_revision,"action":input.action})
}
fn call(owner: &Controller, machine: MachineId, method: &str, params: Value) -> Value {
    super::super::dispatch(
        Call {
            id: Some(json!(1)),
            method: method.into(),
            params: Some(params),
        },
        owner,
        machine,
        false,
    )
    .unwrap()
}
#[test]
fn existing_original_is_observation_without_any_native_admission_or_replay() {
    let (_root, owner, machine, capture) = fixture();
    let PiPreparation::New(permit) = owner
        .database
        .lock()
        .unwrap()
        .prepare_pi(capture.clone())
        .unwrap()
    else {
        panic!("Fresh fixture")
    };
    drop(permit);
    let original = call(
        &owner,
        machine,
        "axo.state.chat.command.submit",
        params(&capture),
    );
    assert_eq!(
        original["result"]["value"]["disposition"]["kind"],
        "unconfirmed"
    );
    let view = &original["result"]["value"];
    assert_eq!(view["action"], json!({"kind":"send"}));
    assert!(view.get("text").is_none());
    assert!(view.get("fingerprint").is_none());
    assert!(view["target"].get("file").is_none());
    let mut changed = params(&capture);
    changed["action"]["text"] = json!("Different original bytes");
    assert_eq!(
        call(&owner, machine, "axo.state.chat.command.submit", changed)["error"]["code"],
        -32007
    );
    assert!(owner.runtime_owner().list().is_empty());
    let query = json!({"target":BindingTarget::captured(&capture).scope().source(),"capture":params(&capture)});
    assert_eq!(
        call(&owner, machine, "axo.state.chat.command.get", query.clone())["result"]["value"],
        *view
    );
    let mut wrong = query;
    wrong["capture"]["action"]["text"] = json!("Foreign lookup text");
    assert_eq!(
        call(&owner, machine, "axo.state.chat.command.get", wrong)["error"]["code"],
        -32007
    );
}
#[test]
fn new_input_without_native_writer_proof_is_not_captured_or_launched() {
    let (_root, owner, machine, capture) = fixture();
    assert_eq!(
        call(
            &owner,
            machine,
            "axo.state.chat.command.submit",
            params(&capture)
        )["error"]["code"],
        -32009
    );
    assert!(
        owner
            .database
            .lock()
            .unwrap()
            .pi_original(capture.input().command_id)
            .unwrap()
            .is_none()
    );
    assert!(owner.runtime_owner().list().is_empty());
    assert!(
        super::super::dispatch(
            Call {
                id: None,
                method: "axo.state.chat.command.submit".into(),
                params: Some(params(&capture))
            },
            &owner,
            machine,
            false
        )
        .is_none()
    );
    assert!(
        owner
            .database
            .lock()
            .unwrap()
            .pi_original(capture.input().command_id)
            .unwrap()
            .is_none()
    );
    let mut malformed = params(&capture);
    malformed["file"] = json!("arbitrary");
    assert_eq!(
        call(&owner, machine, "axo.state.chat.command.submit", malformed)["error"]["code"],
        -32602
    );
}
#[test]
fn missing_lookup_and_foreign_source_never_create_a_submission() {
    let (_root, owner, machine, capture) = fixture();
    let mut query = json!({"target":BindingTarget::captured(&capture).scope().source(),"capture":params(&capture)});
    assert!(
        call(&owner, machine, "axo.state.chat.command.get", query.clone())["result"]["value"]
            .is_null()
    );
    query["target"]["storeGeneration"] = json!(StoreGeneration::new());
    assert_eq!(
        call(&owner, machine, "axo.state.chat.command.get", query)["error"]["code"],
        -32002
    );
    assert!(owner.runtime_owner().list().is_empty());
}
