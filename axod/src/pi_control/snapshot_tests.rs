//! Pure receive-order tests: no Pi launcher, file writer or process signals.
use super::*;
use serde_json::{Value, json};
fn state() -> State {
    serde_json::from_value(json!({"chatId":uuid::Uuid::new_v4(),"title":"Ready","file":"/private/session.jsonl","leafId":null,"cwd":"/workspace","mode":"tui","stdinTTY":true,"stdoutTTY":true,"stderrTTY":true,"rows":30,"columns":100,"pid":123,"busy":false,"interactionId":null,"uiWaits":0,"question":null,"tools":[],"pending":false,"recovery":false,"model":null})).unwrap()
}
fn shared() -> Shared {
    let ready = state();
    Shared {
        state: Mutex::new(Observations {
            ready: Some(ready.clone()),
            current: Some(ready),
            gap: false,
            calls: BTreeMap::new(),
        }),
        changed: Condvar::new(),
    }
}
fn pending(shared: &Shared) -> (RequestId, mpsc::Receiver<Result<Response, ControlError>>) {
    let id = RequestId::new();
    let (sender, receiver) = mpsc::sync_channel(1);
    shared.state.lock().unwrap().calls.insert(
        id,
        Pending {
            expected: wire::Expected::Snapshot,
            sender,
        },
    );
    (id, receiver)
}
fn snapshot(shared: &Shared, id: RequestId, state: State) -> bool {
    route(
        Record::Reply(wire::Reply {
            id: Some(id),
            response: Response::Snapshot(Box::new(state)),
        }),
        shared,
    )
}
#[test]
fn correlated_snapshot_updates_cache_without_overwriting_later_status() {
    let shared = shared();
    let (id, receiver) = pending(&shared);
    let mut refreshed = shared.state.lock().unwrap().ready.clone().unwrap();
    refreshed.title = Some("Refreshed".into());
    assert!(snapshot(&shared, id, refreshed.clone()));
    assert_eq!(
        shared
            .state
            .lock()
            .unwrap()
            .current
            .as_ref()
            .unwrap()
            .title
            .as_deref(),
        Some("Refreshed")
    );
    let mut later = refreshed;
    later.title = Some("Later status".into());
    assert!(route(Record::Status(Box::new(later)), &shared));
    assert!(matches!(
        receiver.recv().unwrap(),
        Ok(Response::Snapshot(_))
    ));
    assert_eq!(
        shared
            .state
            .lock()
            .unwrap()
            .current
            .as_ref()
            .unwrap()
            .title
            .as_deref(),
        Some("Later status")
    );
}
#[test]
fn foreign_snapshot_identity_never_becomes_cached_observation() {
    for key in ["chatId", "file", "cwd", "pid"] {
        let shared = shared();
        let (id, receiver) = pending(&shared);
        let mut foreign =
            serde_json::to_value(shared.state.lock().unwrap().ready.as_ref().unwrap()).unwrap();
        foreign[key] = match key {
            "chatId" => json!(uuid::Uuid::new_v4()),
            "pid" => json!(124),
            _ => Value::String("/different".into()),
        };
        assert!(!snapshot(
            &shared,
            id,
            serde_json::from_value(foreign).unwrap()
        ));
        assert!(matches!(receiver.recv().unwrap(), Err(ControlError::Stale)));
        assert_eq!(
            shared
                .state
                .lock()
                .unwrap()
                .current
                .as_ref()
                .unwrap()
                .title
                .as_deref(),
            Some("Ready")
        );
        // The receive loop terminates on false and fences every pending caller.
        fence(&shared);
        assert!(shared.state.lock().unwrap().gap);
    }
}
#[test]
fn closed_channel_fence_cannot_be_reset_by_snapshot_reply() {
    let shared = shared();
    let (id, receiver) = pending(&shared);
    let ready = shared.state.lock().unwrap().ready.clone().unwrap();
    fence(&shared);
    assert!(matches!(
        receiver.recv().unwrap(),
        Err(ControlError::OutcomeUnknown)
    ));
    assert!(!snapshot(&shared, id, ready));
    assert!(shared.state.lock().unwrap().gap);
}
