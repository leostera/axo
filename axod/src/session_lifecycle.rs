//! Desired-live sessions are daemon policy, independent of frontend attachment.
//! Actual availability is established from owned native resources, never saved PIDs.
use crate::{model::*, runtime::Manager};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Availability {
    Live,
    Restored,
    Waiting,
    Blocked,
}

/// Stable identity for one lifecycle transition. Receipts survive a daemon restart;
/// an uncertain transition therefore cannot acquire a new command and replay effects.
pub(crate) fn command<T: Serialize>(
    domain: &str,
    subject: &T,
) -> Result<CommandId, (i32, &'static str)> {
    let bytes =
        serde_json::to_vec(subject).map_err(|_| (-32008, "Lifecycle intent unavailable"))?;
    let mut hash = Sha256::new();
    hash.update(b"axo.session.lifecycle.v1\0");
    hash.update(domain.as_bytes());
    hash.update([0]);
    hash.update(bytes);
    let digest = hash.finalize();
    let mut identity = [0u8; 16];
    identity.copy_from_slice(&digest[..16]);
    identity[6] = (identity[6] & 0x0f) | 0x40;
    identity[8] = (identity[8] & 0x3f) | 0x80;
    serde_json::from_value(serde_json::json!(uuid::Uuid::from_bytes(identity)))
        .map_err(|_| (-32008, "Lifecycle identity unavailable"))
}

struct Retry {
    after: Instant,
    failures: u32,
}
impl Retry {
    fn new() -> Self {
        Self {
            after: Instant::now(),
            failures: 0,
        }
    }
    fn observe(&mut self, availability: Availability) {
        if availability == Availability::Live {
            self.failures = 0;
            self.after = Instant::now() + Duration::from_secs(1);
        } else {
            self.failures = (self.failures + 1).min(6);
            self.after = Instant::now() + Duration::from_secs(1 << self.failures);
        }
    }
}

#[derive(Clone, Copy)]
enum Role {
    Shell,
    Pi,
}
pub(crate) struct Workers {
    shell: thread::JoinHandle<()>,
    pi: thread::JoinHandle<()>,
}
impl Workers {
    pub(crate) fn is_finished(&self) -> bool {
        self.shell.is_finished() || self.pi.is_finished()
    }
    pub(crate) fn join(self) -> thread::Result<()> {
        self.shell.join()?;
        self.pi.join()
    }
}
pub(crate) fn spawn(
    manager: Arc<Manager>,
    machine: MachineId,
    profiles: BTreeMap<String, TerminalLaunch>,
    stopping: Arc<AtomicBool>,
) -> std::io::Result<Workers> {
    let shell = spawn_role(
        Role::Shell,
        manager.clone(),
        machine,
        profiles.clone(),
        stopping.clone(),
    )?;
    match spawn_role(
        Role::Pi,
        manager.clone(),
        machine,
        profiles,
        stopping.clone(),
    ) {
        Ok(pi) => Ok(Workers { shell, pi }),
        Err(error) => {
            stopping.store(true, Ordering::SeqCst);
            manager.stop_admitting();
            let _ = shell.join();
            Err(error)
        }
    }
}
fn spawn_role(
    role: Role,
    manager: Arc<Manager>,
    machine: MachineId,
    profiles: BTreeMap<String, TerminalLaunch>,
    stopping: Arc<AtomicBool>,
) -> std::io::Result<thread::JoinHandle<()>> {
    let name = match role {
        Role::Shell => "axod-shell-lifecycle",
        Role::Pi => "axod-pi-lifecycle",
    };
    thread::Builder::new().name(name.into()).spawn(move || {
        let mut retries = BTreeMap::<SessionId, Retry>::new();
        while !stopping.load(Ordering::SeqCst) {
            let sessions = {
                let work = manager.work.lock().unwrap();
                if work.is_fenced() {
                    Vec::new()
                } else {
                    work.sessions(None).unwrap_or_default()
                }
            };
            // Tombstoned/archived work withdraws desired-live authority. Retained
            // historical records and receipts are never enumerated as live goals.
            retries.retain(|id, _| sessions.iter().any(|session| session.session_id == *id));
            for session in sessions {
                if stopping.load(Ordering::SeqCst) {
                    break;
                }
                let retry = retries.entry(session.session_id).or_insert_with(Retry::new);
                if Instant::now() < retry.after {
                    continue;
                }
                let availability = match role {
                    Role::Shell => {
                        crate::panes::ensure_backing(&manager, machine, &session, &profiles)
                    }
                    // Slow capability admission runs independently of shell restoration.
                    Role::Pi if crate::panes::has_backing(&manager, session.session_id) => {
                        crate::managed::ensure_live(&manager, machine, &session)
                    }
                    Role::Pi => Ok(Availability::Waiting),
                }
                .unwrap_or(Availability::Blocked);
                retry.observe(availability);
            }
            thread::sleep(Duration::from_millis(100));
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: crate::test_support::TestDirectory,
        manager: Arc<Manager>,
        machine: MachineId,
        session: crate::work::SessionRecord,
    }
    impl Fixture {
        fn new() -> Self {
            use crate::work::*;
            use std::os::unix::fs::PermissionsExt;
            let root = crate::test_support::TestDirectory::new();
            let executable = root.path().join("owned-shell");
            std::fs::write(&executable, b"#!/bin/sh\nexec /bin/cat\n").unwrap();
            std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
            let mut manager = Manager::new(crate::journal::Journal::open(root.path()).unwrap());
            manager.user_shell = crate::user_shell::CapturedUserShell::parse(&executable);
            let committed = manager
                .mutate_work(
                    CommandId::new(),
                    WorkIntent::CreateLocalWorkspace {
                        directory: LocalDirectoryPath::parse(
                            root.path().canonicalize().unwrap().to_str().unwrap().into(),
                        )
                        .unwrap(),
                        name: "Owned lifecycle".into(),
                        initial_session_name: Some("Owned session".into()),
                        expected_revision: 0,
                    },
                    &BTreeMap::new(),
                )
                .unwrap();
            let WorkRecord::WorkspaceSession { session, .. } = committed.record else {
                panic!("Missing session")
            };
            Self {
                root,
                manager: Arc::new(manager),
                machine: MachineId::new(),
                session,
            }
        }
        fn runtime(&self) -> RuntimeRef {
            self.manager
                .panes
                .lock()
                .unwrap()
                .session_panes(self.session.session_id)[0]
                .runtime
                .unwrap()
        }
        fn complete(&self, runtime: RuntimeRef) {
            self.manager.stop(runtime).unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            while !self.manager.runtime_completed(runtime) {
                assert!(Instant::now() < deadline, "Owned child did not complete");
                thread::sleep(Duration::from_millis(20));
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.manager.shutdown();
        }
    }

    #[test]
    fn backing_reuses_live_pty_and_replaces_only_completion_proven_exit() {
        let fixture = Fixture::new();
        let ensure = || {
            crate::panes::ensure_backing(
                &fixture.manager,
                fixture.machine,
                &fixture.session,
                &BTreeMap::new(),
            )
            .unwrap()
        };
        assert_eq!(ensure(), Availability::Restored);
        let original = fixture.runtime();
        for _ in 0..10 {
            assert_eq!(ensure(), Availability::Live);
            assert_eq!(fixture.runtime(), original);
        }
        assert_eq!(fixture.manager.list().len(), 1);
        fixture.complete(original);
        assert_eq!(ensure(), Availability::Restored);
        let replacement = fixture.runtime();
        assert_ne!(original, replacement);
        assert!(fixture.manager.owns_running_runtime(replacement));
        assert!(fixture.manager.runtime_completed(original));
        assert_eq!(
            fixture
                .manager
                .work
                .lock()
                .unwrap()
                .sessions(None)
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            fixture
                .manager
                .panes
                .lock()
                .unwrap()
                .session_panes(fixture.session.session_id)
                .len(),
            1
        );
        let saved = std::fs::read(fixture.root.path().join("pane-state.json")).unwrap();
        assert_eq!(ensure(), Availability::Live);
        assert_eq!(
            std::fs::read(fixture.root.path().join("pane-state.json")).unwrap(),
            saved
        );
    }

    #[test]
    fn worker_restores_without_any_frontend_and_stops_before_shutdown() {
        let fixture = Fixture::new();
        let stopping = Arc::new(AtomicBool::new(false));
        let workers = spawn(
            fixture.manager.clone(),
            fixture.machine,
            BTreeMap::new(),
            stopping.clone(),
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !crate::panes::has_backing(&fixture.manager, fixture.session.session_id) {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(20));
        }
        let original = fixture.runtime();
        fixture.complete(original);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !crate::panes::has_backing(&fixture.manager, fixture.session.session_id) {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(20));
        }
        assert_ne!(fixture.runtime(), original);
        stopping.store(true, Ordering::SeqCst);
        fixture.manager.stop_admitting();
        workers.join().unwrap();
        assert!(
            fixture.manager.owns_running_runtime(fixture.runtime()),
            "Stopping supervision stopped an accepted PTY"
        );
    }

    #[test]
    fn unconfirmed_original_shell_reservation_blocks_new_admission() {
        let fixture = Fixture::new();
        let original = CommandId::new();
        fixture
            .manager
            .prepare_pane(
                original,
                crate::panes::store::Intent::AddPane {
                    target: crate::panes::store::SessionTarget {
                        machine_id: fixture.machine,
                        host_generation: fixture.manager.generation,
                        workspace_id: fixture.session.workspace_id,
                        session_id: fixture.session.session_id,
                    },
                    profile_id: crate::user_shell::ShellSource::UserLogin,
                },
            )
            .unwrap();
        let bytes = std::fs::read(fixture.root.path().join("pane-state.json")).unwrap();
        assert_eq!(
            crate::panes::ensure_backing(
                &fixture.manager,
                fixture.machine,
                &fixture.session,
                &BTreeMap::new()
            )
            .unwrap(),
            Availability::Blocked
        );
        assert!(fixture.manager.list().is_empty());
        assert_eq!(
            std::fs::read(fixture.root.path().join("pane-state.json")).unwrap(),
            bytes
        );
    }

    #[test]
    fn prepared_pi_original_is_preserved_without_fresh_writer_or_replay() {
        let fixture = Fixture::new();
        use crate::managed::store::*;
        let intent = Intent::Start {
            target: SessionTarget {
                machine_id: fixture.machine,
                host_generation: fixture.manager.generation,
                workspace_id: fixture.session.workspace_id,
                session_id: fixture.session.session_id,
                pane_id: fixture.session.pi_pane_id,
            },
            persistence: Persistence::Fresh,
        };
        let fingerprint = Store::fingerprint(&intent, &()).unwrap();
        fixture
            .manager
            .prepare_managed(CommandId::new(), intent, fingerprint)
            .unwrap();
        let path = fixture.root.path().join("pi-state.json");
        let original_bytes = std::fs::read(&path).unwrap();
        assert_eq!(
            crate::managed::ensure_live(&fixture.manager, fixture.machine, &fixture.session)
                .unwrap(),
            Availability::Blocked
        );
        assert!(fixture.manager.list().is_empty());
        assert_eq!(std::fs::read(path).unwrap(), original_bytes);
    }

    #[test]
    fn tombstoned_session_withdraws_keepalive_and_retained_receipts_are_not_goals() {
        use crate::work::*;
        let fixture = Fixture::new();
        crate::panes::ensure_backing(
            &fixture.manager,
            fixture.machine,
            &fixture.session,
            &BTreeMap::new(),
        )
        .unwrap();
        let runtime = fixture.runtime();
        let revision = fixture.manager.work.lock().unwrap().revision();
        let receipt = fixture
            .manager
            .delete_sessions(
                CommandId::new(),
                SessionDeletionIntent {
                    target: DeletionTarget {
                        machine_id: fixture.machine,
                        host_generation: fixture.manager.generation,
                    },
                    sessions: vec![SessionAddress {
                        workspace_id: fixture.session.workspace_id,
                        session_id: fixture.session.session_id,
                    }],
                    expected_revision: revision,
                },
            )
            .unwrap();
        assert!(receipt.revision.is_some());
        assert!(fixture.manager.runtime_completed(runtime));
        assert!(
            fixture
                .manager
                .work
                .lock()
                .unwrap()
                .sessions(None)
                .unwrap()
                .is_empty()
        );
        assert!(
            crate::panes::ensure_backing(
                &fixture.manager,
                fixture.machine,
                &fixture.session,
                &BTreeMap::new()
            )
            .is_err()
        );
        assert_eq!(fixture.manager.list().len(), 1);
        assert!(!fixture.manager.owns_running_runtime(runtime));
        assert!(
            fixture
                .manager
                .panes
                .lock()
                .unwrap()
                .session_lineage(fixture.session.session_id)
                .len()
                == 1
        );
    }

    #[test]
    fn completion_rpc_is_bounded_scoped_read_only_and_never_remote_authority() {
        use crate::rpc;
        use serde_json::json;
        let fixture = Fixture::new();
        crate::panes::ensure_backing(
            &fixture.manager,
            fixture.machine,
            &fixture.session,
            &BTreeMap::new(),
        )
        .unwrap();
        let runtime = fixture.runtime();
        let params = json!({"target": {"machineId":fixture.machine,"hostGeneration":fixture.manager.generation,
            "workspaceId":fixture.session.workspace_id,"sessionId":fixture.session.session_id}, "runtimes":[runtime]});
        let call = |params| rpc::Call {
            id: Some(json!(1)),
            method: "axo.session.completion".into(),
            params: Some(params),
        };
        assert_eq!(
            rpc::dispatch(
                call(params.clone()),
                &fixture.manager,
                fixture.machine,
                &BTreeMap::new()
            )
            .unwrap()["error"]["code"],
            -32601
        );
        let proof = rpc::dispatch_local(
            call(params.clone()),
            &fixture.manager,
            fixture.machine,
            &BTreeMap::new(),
        )
        .unwrap();
        assert_eq!(proof["result"]["completed"], json!([]));
        fixture.complete(runtime);
        crate::panes::ensure_backing(
            &fixture.manager,
            fixture.machine,
            &fixture.session,
            &BTreeMap::new(),
        )
        .unwrap();
        let proof = rpc::dispatch_local(
            call(params.clone()),
            &fixture.manager,
            fixture.machine,
            &BTreeMap::new(),
        )
        .unwrap();
        assert_eq!(proof["result"]["completed"], json!([runtime]));
        assert_eq!(
            proof["result"]["retiredShellReceipts"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let mut duplicate = params;
        duplicate["runtimes"] = json!([runtime, runtime]);
        assert_eq!(
            rpc::dispatch_local(
                call(duplicate),
                &fixture.manager,
                fixture.machine,
                &BTreeMap::new()
            )
            .unwrap()["error"]["code"],
            -32602
        );
        assert!(fixture.manager.owns_running_runtime(fixture.runtime()));
    }

    #[test]
    fn goals_are_stable_scoped_and_retry_is_bounded() {
        let machine = MachineId::new();
        let session = SessionId::new();
        let first = command("shell-add", &(machine, session)).unwrap();
        assert_eq!(first, command("shell-add", &(machine, session)).unwrap());
        assert_ne!(first, command("pi-start", &(machine, session)).unwrap());
        assert_ne!(
            first,
            command("shell-add", &(machine, SessionId::new())).unwrap()
        );
        let mut retry = Retry::new();
        for _ in 0..100 {
            retry.observe(Availability::Blocked);
        }
        assert_eq!(retry.failures, 6);
        assert!(retry.after.duration_since(Instant::now()) <= Duration::from_secs(64));
        retry.observe(Availability::Live);
        assert_eq!(retry.failures, 0);
    }
}
