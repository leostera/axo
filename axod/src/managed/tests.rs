//! Synthetic metadata/store invariants, not Pi execution evidence.
use super::{persistence::WriterLease, store::*};
use crate::{
    model::*,
    pi_control::ChatId,
    terminal::ErrorCode,
    test_support::TestDirectory,
    work::{WorkIntent, WorkRecord, WorkStore},
};
use std::{collections::BTreeMap, fs, os::unix::fs::PermissionsExt};
struct Fixture {
    root: TestDirectory,
    work: WorkStore,
    target: SessionTarget,
}
impl Fixture {
    fn new() -> Self {
        let root = TestDirectory::new();
        let mut work = WorkStore::open(root.path()).unwrap();
        let profiles = BTreeMap::from([(
            "work".into(),
            TerminalLaunch {
                directory: root.path().to_str().unwrap().into(),
                argv: vec!["/bin/sh".into()],
            },
        )]);
        let created = work
            .apply(
                CommandId::new(),
                WorkIntent::CreateWorkspace {
                    directory_id: "work".into(),
                    name: "Synthetic work".into(),
                    expected_revision: 0,
                },
                &profiles,
            )
            .unwrap();
        let WorkRecord::Workspace(workspace) = created.record else {
            panic!("Wrong work record");
        };
        let created = work
            .apply(
                CommandId::new(),
                WorkIntent::CreateSession {
                    workspace_id: workspace.workspace_id,
                    name: "Synthetic session".into(),
                    expected_revision: 1,
                },
                &profiles,
            )
            .unwrap();
        let WorkRecord::Session(session) = created.record else {
            panic!("Wrong session record");
        };
        let target = SessionTarget {
            machine_id: MachineId::new(),
            host_generation: HostGeneration::new(),
            workspace_id: workspace.workspace_id,
            session_id: session.session_id,
            pane_id: session.pi_pane_id,
        };
        Self { root, work, target }
    }
    fn bind(&self, store: &mut Store) -> Binding {
        let command = CommandId::new();
        let intent = Intent::Start {
            target: self.target,
            persistence: Persistence::Fresh,
        };
        store
            .prepare(
                command,
                intent.clone(),
                Store::fingerprint(&intent, &()).unwrap(),
            )
            .unwrap();
        let runtime = RuntimeRef {
            host_generation: self.target.host_generation,
            runtime_generation: RuntimeGeneration::new(),
            target: TerminalTarget {
                session_id: self.target.session_id,
                pane_id: self.target.pane_id,
            },
        };
        let chat_id: ChatId =
            serde_json::from_str(&format!("\"{}\"", uuid::Uuid::new_v4())).unwrap();
        let binding = Binding {
            workspace_id: self.target.workspace_id,
            session_id: self.target.session_id,
            pane_id: self.target.pane_id,
            runtime,
            chat_id,
            directory: self.root.path().to_path_buf(),
            file: self.root.path().join("canonical.jsonl"),
            start_command_id: command,
        };
        store.admit(binding.clone()).unwrap();
        binding
    }
}
#[test]
fn normalized_body_hash_and_original_disposition_survive_reopen_without_storing_text() {
    let f = Fixture::new();
    let mut store = Store::open(f.root.path(), &f.work).unwrap();
    let binding = f.bind(&mut store);
    let command = CommandId::new();
    let intent = Intent::Chat {
        target: binding.target(f.target.machine_id, f.target.host_generation),
        operation: Operation::SendMessage,
    };
    let body = "PRIVATE_BODY_MUST_NOT_PERSIST_λ";
    let fingerprint = Store::fingerprint(&intent, &body).unwrap();
    store
        .prepare(command, intent.clone(), fingerprint.clone())
        .unwrap();
    assert_eq!(
        store
            .reconcile(
                command,
                &intent,
                &Store::fingerprint(&intent, &"changed").unwrap()
            )
            .unwrap_err(),
        Error::Conflict
    );
    let original = store
        .finish(command, Disposition::Dispatched, Some(binding.runtime))
        .unwrap();
    assert_eq!(
        store
            .finish(
                command,
                Disposition::Rejected { code: -32010 },
                Some(binding.runtime)
            )
            .unwrap_err(),
        Error::Conflict
    );
    let bytes = fs::read(f.root.path().join("pi-state.json")).unwrap();
    assert!(
        !bytes
            .windows(body.len())
            .any(|window| window == body.as_bytes())
    );
    let reopened = Store::open(f.root.path(), &f.work).unwrap();
    assert_eq!(
        serde_json::to_vec(&original.view()).unwrap(),
        serde_json::to_vec(
            &reopened
                .reconcile(command, &intent, &fingerprint)
                .unwrap()
                .unwrap()
                .view()
        )
        .unwrap()
    );
}
#[test]
fn every_truncation_and_corrupt_intent_fails_closed_without_rewriting_owned_state() {
    let f = Fixture::new();
    let mut store = Store::open(f.root.path(), &f.work).unwrap();
    f.bind(&mut store);
    let path = f.root.path().join("pi-state.json");
    let valid = fs::read(&path).unwrap();
    for length in 0..valid.len() {
        fs::write(&path, &valid[..length]).unwrap();
        assert!(Store::open(f.root.path(), &f.work).is_err());
        assert_eq!(fs::read(&path).unwrap().len(), length);
    }
    let mut corrupted: serde_json::Value = serde_json::from_slice(&valid).unwrap();
    let receipt = corrupted["receipts"]
        .as_object_mut()
        .unwrap()
        .values_mut()
        .next()
        .unwrap();
    receipt["intent"]["target"]["hostGeneration"] = serde_json::json!(HostGeneration::new());
    fs::write(&path, serde_json::to_vec(&corrupted).unwrap()).unwrap();
    assert!(Store::open(f.root.path(), &f.work).is_err());
}
#[test]
fn persistence_failure_fences_mutations_but_keeps_original_receipts_readable() {
    let f = Fixture::new();
    let mut store = Store::open(f.root.path(), &f.work).unwrap();
    let binding = f.bind(&mut store);
    let path = f.root.path().join("pi-state.json");
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    let intent = Intent::Chat {
        target: binding.target(f.target.machine_id, f.target.host_generation),
        operation: Operation::CancelTurn,
    };
    assert_eq!(
        store
            .prepare(
                CommandId::new(),
                intent.clone(),
                Store::fingerprint(&intent, &()).unwrap()
            )
            .unwrap_err(),
        Error::OutcomeUnknown
    );
    assert_eq!(
        store
            .prepare(
                CommandId::new(),
                intent.clone(),
                Store::fingerprint(&intent, &()).unwrap()
            )
            .unwrap_err(),
        Error::StorageFenced
    );
    assert!(store.receipt(binding.start_command_id).is_some());
}
#[test]
fn managed_reservations_share_command_identity_and_storage_fencing_with_other_domains() {
    let f = Fixture::new();
    let manager = crate::runtime::Manager::new(f.root.reopen_journal());
    let target = SessionTarget {
        host_generation: manager.generation,
        ..f.target
    };
    let intent = Intent::Start {
        target,
        persistence: Persistence::Fresh,
    };
    let command = CommandId::new();
    assert!(matches!(
        manager
            .prepare_managed(
                command,
                intent.clone(),
                Store::fingerprint(&intent, &()).unwrap()
            )
            .unwrap(),
        super::Reservation::New
    ));
    let terminal_target = TerminalTarget {
        session_id: target.session_id,
        pane_id: target.pane_id,
    };
    let launch = TerminalLaunch {
        directory: f.root.path().to_str().unwrap().into(),
        argv: vec!["/bin/sh".into()],
    };
    assert_eq!(
        manager
            .start(command, terminal_target, &launch)
            .unwrap_err(),
        ErrorCode::Conflict
    );
    let work = WorkIntent::RenameSession {
        workspace_id: target.workspace_id,
        session_id: target.session_id,
        name: "Must not cross domains".into(),
        expected_revision: 2,
    };
    assert_eq!(
        manager
            .mutate_work(command, work.clone(), &BTreeMap::new())
            .unwrap_err(),
        crate::work::WorkError::Conflict
    );
    assert!(manager.list().is_empty());
    let path = f.root.path().join("pi-state.json");
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    assert!(matches!(
        manager.prepare_managed(
            CommandId::new(),
            intent.clone(),
            Store::fingerprint(&intent, &()).unwrap()
        ),
        Err(Error::OutcomeUnknown)
    ));
    assert_eq!(
        manager
            .start(CommandId::new(), terminal_target, &launch)
            .unwrap_err(),
        ErrorCode::StorageFailed
    );
    assert_eq!(
        manager
            .mutate_work(CommandId::new(), work, &BTreeMap::new())
            .unwrap_err(),
        crate::work::WorkError::StorageFailed
    );
    assert!(manager.command_receipt(command).is_some());
    assert!(manager.list().is_empty());
}
#[test]
fn stopped_jsonl_v3_reconstructs_the_persisted_resume_branch_not_a_flat_event_stream() {
    let f = Fixture::new();
    let mut store = Store::open(f.root.path(), &f.work).unwrap();
    let mut binding = f.bind(&mut store);
    binding.directory = fs::canonicalize(f.root.path()).unwrap();
    let lines = [
        serde_json::json!({"type":"session","version":3,"id":binding.chat_id,"cwd":binding.directory}),
        serde_json::json!({"type":"message","id":"root","parentId":null,"timestamp":"synthetic","message":{"role":"user","content":"root"}}),
        serde_json::json!({"type":"message","id":"off-branch","parentId":"root","timestamp":"synthetic","message":{"role":"user","content":"off"}}),
        serde_json::json!({"type":"message","id":"active-leaf","parentId":"root","timestamp":"synthetic","message":{"role":"user","content":"active"}}),
    ];
    let body = lines
        .iter()
        .map(|line| serde_json::to_string(line).unwrap() + "\n")
        .collect::<String>();
    fs::write(&binding.file, body).unwrap();
    fs::set_permissions(&binding.file, fs::Permissions::from_mode(0o600)).unwrap();
    let history = super::history::stopped(&binding).unwrap();
    assert_eq!(history.entries.len(), 3);
    assert_eq!(history.branch.len(), 2);
    assert_eq!(history.leaf_id.as_deref(), Some("active-leaf"));
    assert!(
        history.branch[0].json().contains("root")
            && !history.branch[1].json().contains("off-branch")
    );
}
#[test]
fn managed_writer_leases_are_exclusive_and_reject_symlinks_or_public_modes() {
    let root = TestDirectory::new();
    let file = root.path().join("writer.jsonl");
    let lease = WriterLease::acquire(&file).unwrap();
    assert!(WriterLease::acquire(&file).is_err());
    drop(lease);
    drop(WriterLease::acquire(&file).unwrap());
    let path = root.path().join(".writer.jsonl.axo-writer.lock");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(WriterLease::acquire(&file).is_err());
    fs::remove_file(&path).unwrap();
    std::os::unix::fs::symlink(root.path().join("other"), path).unwrap();
    assert!(WriterLease::acquire(&file).is_err());
}
