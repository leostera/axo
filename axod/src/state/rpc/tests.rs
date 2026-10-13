use super::*;
use crate::{journal::Journal, rpc_owner::RpcOwner, test_support::TestDirectory};
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
pub(super) struct Fixture {
    pub(super) root: TestDirectory,
    pub(super) owner: Arc<Controller>,
    pub(super) machine: MachineId,
}
impl Fixture {
    pub(super) fn new() -> Self {
        let root = TestDirectory::new();
        fs::write(root.path().join("work-records.json"), b"opaque old catalog").unwrap();
        let (machine, mut owner) = Controller::for_service(root.path(), None).unwrap();
        let shell = root.path().join("owned-shell");
        fs::write(&shell, "#!/bin/sh\nexec /bin/cat\n").unwrap();
        fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
        Arc::get_mut(&mut owner.native).unwrap().user_shell =
            crate::user_shell::CapturedUserShell::parse(&shell);
        Self {
            root,
            owner: Arc::new(owner),
            machine,
        }
    }
    fn target(&self) -> Value {
        json!({"machineId":self.machine,"hostGeneration":self.owner.native.generation,"storeGeneration":self.owner.generation().unwrap()})
    }
    fn call(&self, method: &str, params: Value, local: bool) -> Value {
        RpcOwner::Central(self.owner.clone())
            .dispatch(
                Call {
                    id: Some(json!(1)),
                    method: method.into(),
                    params: Some(params),
                },
                self.machine,
                &Default::default(),
                local,
            )
            .unwrap()
    }
    pub(super) fn create(&self, command: CommandId) -> Value {
        self.call("axo.state.workspace.create",json!({"target":self.target(),"commandId":command,"expectedRevision":0,"name":"Workspace","directoryPath":self.root.path()}),true)
    }
}
#[test]
fn central_session_pages_are_sorted_by_identity_not_insertion_order() {
    let fixture = Fixture::new();
    let created = fixture.create(CommandId::new());
    let workspace_id =
        created["result"]["value"]["operation"]["accepted"]["graph"]["workspace"]["workspaceId"]
            .as_str()
            .unwrap();
    for index in 0..4 {
        let expected_revision = fixture.owner.revision().unwrap();
        let result = fixture.call(
            "axo.state.session.create",
            json!({"target":fixture.target(),"commandId":CommandId::new(),"expectedRevision":expected_revision,"workspaceId":workspace_id,"name":format!("Session {index}")}),
            true,
        );
        assert!(
            result.get("result").is_some(),
            "session creation must succeed: {result}"
        );
    }
    let sessions = fixture.call(
        "axo.state.session.list",
        json!({"target":fixture.target(),"workspaceId":workspace_id,"limit":50}),
        false,
    );
    let ids: Vec<_> = sessions["result"]["value"]["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|record| record["session"]["sessionId"].as_str().unwrap().to_owned())
        .collect();
    let mut sorted = ids.clone();
    sorted.sort();
    assert_eq!(
        ids, sorted,
        "session list order must be stable by UUID across clients"
    );
}
#[test]
fn central_pi_observation_requires_closed_current_scope_and_never_starts_work() {
    let fixture = Fixture::new();
    let created = fixture.create(CommandId::new());
    let session =
        &created["result"]["value"]["operation"]["accepted"]["graph"]["initialSession"]["session"];
    let mut scope = fixture.target();
    scope["workspaceId"] = session["workspaceId"].clone();
    scope["sessionId"] = session["sessionId"].clone();
    let observation = fixture.call("axo.state.chat.observe", json!({"target":scope}), false);
    assert_eq!(
        observation["result"]["value"],
        json!({"kind":"notAdmitted"})
    );
    assert!(fixture.owner.runtime_owner().list().is_empty());
    let original_revision = fixture.owner.revision().unwrap();
    for key in ["workspaceId", "storeGeneration"] {
        let mut missing = scope.clone();
        missing.as_object_mut().unwrap().remove(key);
        assert_eq!(
            fixture.call("axo.state.chat.observe", json!({"target":missing}), false)["error"]["code"],
            -32602
        );
    }
    let mut stale = scope.clone();
    stale["storeGeneration"] = json!(StoreGeneration::new());
    assert_eq!(
        fixture.call("axo.state.chat.observe", json!({"target":stale}), false)["error"]["code"],
        -32002
    );
    let mut foreign = scope.clone();
    foreign["workspaceId"] = json!(WorkspaceId::new());
    assert_eq!(
        fixture.call("axo.state.chat.observe", json!({"target":foreign}), false)["error"]["code"],
        -32010
    );
    assert_eq!(
        fixture.call(
            "axo.state.chat.observe",
            json!({"target":scope,"argv":["forbidden"]}),
            false
        )["error"]["code"],
        -32602
    );
    let mut exact = scope.clone();
    exact["paneId"] = json!(PaneId::new());
    exact["chatId"] = json!(uuid::Uuid::new_v4());
    exact["runtime"] = json!({"host_generation":fixture.owner.native.generation,"runtime_generation":RuntimeGeneration::new(),"target":{"session_id":scope["sessionId"],"pane_id":exact["paneId"]}});
    assert_eq!(
        fixture.call("axo.state.chat.get", json!({"target":exact}), false)["error"]["code"],
        -32009
    );
    assert_eq!(
        fixture.call(
            "axo.state.chat.history",
            json!({"target":exact,"readMode":"stopped"}),
            false
        )["error"]["code"],
        -32009
    );
    assert_eq!(
        fixture.call(
            "axo.state.chat.history",
            json!({"target":exact,"readMode":"live"}),
            false
        )["error"]["code"],
        -32009
    );
    assert_eq!(
        fixture.call(
            "axo.state.chat.tool.get",
            json!({"target":exact,"readMode":"live","entryId":"result","toolCallId":"call"}),
            false
        )["error"]["code"],
        -32009
    );
    assert_eq!(fixture.call("axo.state.chat.tool.get", json!({"target":exact,"readMode":"live","entryId":"result","toolCallId":"call","offset":1}), false)["error"]["code"], -32602);
    for key in ["runtime", "chatId", "workspaceId"] {
        let mut missing = exact.clone();
        missing.as_object_mut().unwrap().remove(key);
        assert_eq!(
            fixture.call("axo.state.chat.get", json!({"target":missing}), false)["error"]["code"],
            -32602
        );
        assert_eq!(
            fixture.call(
                "axo.state.chat.history",
                json!({"target":missing,"readMode":"stopped"}),
                false
            )["error"]["code"],
            -32602
        );
    }
    assert!(
        fixture.owner.runtime_owner().list().is_empty(),
        "Canonical reads cannot start a runtime"
    );
    assert_eq!(fixture.owner.revision().unwrap(), original_revision);
    assert!(fixture.owner.runtime_owner().list().is_empty());
}
#[test]
fn service_claims_parent_lease_without_reading_or_replacing_legacy_catalog() {
    let fixture = Fixture::new();
    assert!(
        fixture
            .owner
            .database
            .lock()
            .unwrap()
            .workspaces()
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        fs::read(fixture.root.path().join("work-records.json")).unwrap(),
        b"opaque old catalog"
    );
    assert!(matches!(
        Controller::for_service(fixture.root.path(), None),
        Err(Error::OwnerConflict)
    ));
    assert!(Journal::open(fixture.root.path()).is_err());
    assert!(
        fixture
            .root
            .path()
            .join("CentralSessions/session-state.sqlite3")
            .is_file()
    );
}
#[test]
fn old_owner_contention_never_creates_the_new_root() {
    let root = TestDirectory::new();
    let journal = Journal::open(root.path()).unwrap();
    assert!(matches!(
        Controller::for_service(root.path(), None),
        Err(Error::OwnerConflict)
    ));
    assert!(!root.path().join("CentralSessions").exists());
    drop(journal);
    Controller::for_service(root.path(), None).unwrap();
}
#[test]
fn new_store_generation_survives_owner_restart_and_old_sources_cannot_mutate() {
    let root = TestDirectory::new();
    let (machine, owner) = Controller::for_service(root.path(), None).unwrap();
    let generation = owner.generation().unwrap();
    drop(owner);
    let (reopened_machine, owner) = Controller::for_service(root.path(), None).unwrap();
    assert_eq!(machine, reopened_machine);
    assert_eq!(generation, owner.generation().unwrap());
    let call = Call {
        id: Some(json!(1)),
        method: "axo.state.session.create".into(),
        params: Some(
            json!({"target":{"machineId":machine,"hostGeneration":owner.native.generation,"storeGeneration":StoreGeneration::new()},"commandId":CommandId::new(),"expectedRevision":0,"workspaceId":null,"name":"Session"}),
        ),
    };
    assert_eq!(
        dispatch(call, &owner, machine, true).unwrap()["error"]["code"],
        -32002
    );
    assert_eq!(owner.revision().unwrap(), 0);
}
#[test]
fn creation_reserves_complete_original_and_shell_materializes_without_client_starts() {
    let fixture = Fixture::new();
    let workers = fixture.owner.supervise().unwrap();
    let command = CommandId::new();
    let created = fixture.create(command);
    assert!(created.get("error").is_none(), "Creation failed");
    assert_eq!(
        created["result"]["value"]["operation"]["kind"],
        "createWorkspace"
    );
    assert_eq!(
        created["result"]["value"]["operation"]["accepted"]["graph"]["initialSession"]["panes"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_ne!(created["result"]["value"]["session"]["readiness"], "ready");
    let original = created["result"]["value"]["operation"].clone();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let observation = fixture.call(
            "axo.state.operation.get",
            json!({"target":fixture.target(),"commandId":command}),
            true,
        );
        assert_eq!(observation["result"]["value"]["operation"], original);
        if observation["result"]["value"]["session"]["panes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|pane| pane["availability"] == "live" && pane["terminal"].is_object())
        {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(25));
    }
    assert_eq!(
        fixture.create(command)["result"]["value"]["operation"],
        original
    );
    assert_eq!(
        fixture
            .owner
            .database
            .lock()
            .unwrap()
            .sessions()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(fixture.owner.native.list().len(), 1);
    for method in [
        "axo.workspace.createLocal",
        "axo.session.create",
        "axo.session.start",
        "axo.session.pane.add",
        "axo.runtime.startApproved",
        "axo.chat.send",
    ] {
        assert_eq!(
            fixture.call(method, json!({}), true)["error"]["code"],
            -32601
        );
    }
    assert_eq!(
        fs::read(fixture.root.path().join("work-records.json")).unwrap(),
        b"opaque old catalog"
    );
    workers.shutdown().unwrap();
}
#[test]
fn notifications_remote_directory_and_extra_fields_never_admit() {
    let fixture = Fixture::new();
    let params = json!({"target":fixture.target(),"commandId":CommandId::new(),"expectedRevision":0,"name":"Workspace","directoryPath":fixture.root.path()});
    assert!(
        dispatch(
            Call {
                id: None,
                method: "axo.state.workspace.create".into(),
                params: Some(params.clone())
            },
            &fixture.owner,
            fixture.machine,
            true
        )
        .is_none()
    );
    assert_eq!(
        fixture.call("axo.state.workspace.create", params.clone(), false)["error"]["code"],
        -32601
    );
    let mut invalid = params;
    invalid["argv"] = json!(["ignored"]);
    assert_eq!(
        fixture.call("axo.state.workspace.create", invalid, true)["error"]["code"],
        -32602
    );
    let missing = json!({"target":fixture.target(),"commandId":CommandId::new(),"expectedRevision":0,"name":"Session"});
    assert_eq!(
        fixture.call("axo.state.session.create", missing, true)["error"]["code"],
        -32602
    );
    assert_eq!(fixture.owner.revision().unwrap(), 0);
}
#[test]
fn cursor_source_and_catalog_revision_are_fenced() {
    let fixture = Fixture::new();
    for index in 0..2 {
        let response=fixture.call("axo.state.workspace.create",json!({"target":fixture.target(),"commandId":CommandId::new(),"expectedRevision":index,"name":"Workspace","directoryPath":fixture.root.path()}),true);
        assert!(response.get("error").is_none());
    }
    let response = fixture.call(
        "axo.state.workspace.list",
        json!({"target":fixture.target(),"limit":1}),
        true,
    );
    let cursor = response["result"]["value"]["cursor"].clone();
    assert!(cursor.is_object());
    let mut invalid = cursor.clone();
    invalid["target"]["storeGeneration"] = json!(StoreGeneration::new());
    assert_eq!(
        fixture.call(
            "axo.state.workspace.list",
            json!({"target":fixture.target(),"limit":1,"cursor":invalid}),
            true
        )["error"]["code"],
        -32002
    );
    assert_eq!(
        fixture.call(
            "axo.state.workspace.list",
            json!({"target":fixture.target(),"cursor":null}),
            true
        )["error"]["code"],
        -32602
    );
    let changed=fixture.call("axo.state.workspace.create",json!({"target":fixture.target(),"commandId":CommandId::new(),"expectedRevision":2,"name":"Workspace","directoryPath":fixture.root.path()}),true);
    assert!(changed.get("error").is_none());
    assert_eq!(
        fixture.call(
            "axo.state.workspace.list",
            json!({"target":fixture.target(),"cursor":cursor}),
            true
        )["error"]["code"],
        -32002
    );
}
#[test]
fn frozen_service_admission_does_not_create_a_graph() {
    let fixture = Fixture::new();
    let target = fixture.target();
    fixture.owner.freeze_admission();
    assert_eq!(fixture.call("axo.state.session.create",json!({"target":target,"commandId":CommandId::new(),"expectedRevision":0,"workspaceId":null,"name":"Session"}),true)["error"]["code"],-32010);
    assert_eq!(fixture.owner.revision().unwrap(), 0);
}
