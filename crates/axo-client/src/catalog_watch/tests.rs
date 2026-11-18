use super::*;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::broadcast,
    task::{JoinHandle, JoinSet},
};

struct Fixture {
    directory: PathBuf,
    path: PathBuf,
    catalog: Arc<Mutex<Value>>,
    events: broadcast::Sender<Value>,
    reads: Arc<AtomicUsize>,
    active: Arc<AtomicUsize>,
    opened: Arc<AtomicUsize>,
    methods: Arc<Mutex<Vec<String>>>,
    task: JoinHandle<()>,
}
impl Fixture {
    fn new() -> Self {
        // A Unix socket path is at most 104 bytes on macOS, and Bazel's temp_dir() is longer:
        // keep sockets under /tmp, as the other crates' tests do.
        let directory = std::path::PathBuf::from("/tmp").join(format!(
            "axo-w-{}",
            &axo_protocol::new_uuid_v4().unwrap()[..12]
        ));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("rpc.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let catalog = Arc::new(Mutex::new(json!({"sessions":[],"archived":[]})));
        let (events, _) = broadcast::channel(32);
        let reads = Arc::new(AtomicUsize::new(0));
        let active = Arc::new(AtomicUsize::new(0));
        let opened = Arc::new(AtomicUsize::new(0));
        let methods = Arc::new(Mutex::new(Vec::new()));
        let task = tokio::spawn({
            let (catalog, events, reads, active, opened, methods) = (
                catalog.clone(),
                events.clone(),
                reads.clone(),
                active.clone(),
                opened.clone(),
                methods.clone(),
            );
            async move {
                let mut tasks = JoinSet::new();
                loop {
                    tokio::select! {
                        accepted = listener.accept() => {
                            let (socket, _) = accepted.unwrap();
                            let (catalog, events, reads, active, opened, methods) =
                                (catalog.clone(), events.clone(), reads.clone(), active.clone(), opened.clone(), methods.clone());
                            tasks.spawn(async move {
                                serve(socket, catalog, events, reads, active, opened, methods).await;
                            });
                        }
                        result = tasks.join_next(), if !tasks.is_empty() => { result.unwrap().unwrap(); }
                    }
                }
            }
        });
        Self {
            directory,
            path,
            catalog,
            events,
            reads,
            active,
            opened,
            methods,
            task,
        }
    }
    fn set(&self, name: &str) {
        *self.catalog.lock().unwrap() = json!({"sessions":[session(name)],"archived":[]});
    }
    fn emit(&self, events: Value) {
        self.events
            .send(json!({"jsonrpc":"2.0","method":"axo.session.events","params":{"events":events}}))
            .unwrap();
    }
    fn start(&self) -> (CatalogWatch, JoinHandle<()>) {
        let (watch, watcher) = CatalogWatch::channel();
        let path = self.path.clone();
        (watch, tokio::spawn(async move { watcher.run(&path).await }))
    }
    fn assert_read_only(&self) {
        assert!(self.methods.lock().unwrap().iter().all(|method| matches!(
            method.as_str(),
            rpc::method::PROTOCOL_NEGOTIATE
                | rpc::method::SESSION_CATALOG
                | rpc::method::DAEMON_HEALTH
                | "axo.session.events.stream"
        )));
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
struct Active(Arc<AtomicUsize>);
impl Drop for Active {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}
async fn send(socket: &mut BufReader<UnixStream>, value: Value) {
    let mut line = serde_json::to_vec(&value).unwrap();
    line.push(b'\n');
    let _ = socket.get_mut().write_all(&line).await;
}
async fn serve(
    socket: UnixStream,
    catalog: Arc<Mutex<Value>>,
    events: broadcast::Sender<Value>,
    reads: Arc<AtomicUsize>,
    active: Arc<AtomicUsize>,
    opened: Arc<AtomicUsize>,
    methods: Arc<Mutex<Vec<String>>>,
) {
    let mut socket = BufReader::new(socket);
    loop {
        let mut line = String::new();
        if socket.read_line(&mut line).await.unwrap_or(0) == 0 {
            return;
        }
        let request: Value = serde_json::from_str(&line).unwrap();
        let method = request["method"].as_str().unwrap();
        methods.lock().unwrap().push(method.into());
        let result = match method {
            rpc::method::PROTOCOL_NEGOTIATE => {
                json!({"protocolVersion":rpc::PROTOCOL_VERSION,"methods":rpc::method::ADVERTISED})
            }
            rpc::method::SESSION_CATALOG => {
                assert_eq!(
                    active.load(Ordering::SeqCst),
                    1,
                    "subscribe before listing; only one stream"
                );
                reads.fetch_add(1, Ordering::SeqCst);
                catalog.lock().unwrap().clone()
            }
            rpc::method::DAEMON_HEALTH => {
                let ready = catalog
                    .lock()
                    .unwrap()
                    .get("_ready")
                    .and_then(Value::as_bool)
                    .unwrap_or(true);
                json!({"version":"fixture","buildNumber":1,"status":"running","ready":ready})
            }
            "axo.session.events.stream" => {
                assert_eq!(request["params"]["includeTerminalOutput"], false);
                let mut receiver = events.subscribe();
                active.fetch_add(1, Ordering::SeqCst);
                opened.fetch_add(1, Ordering::SeqCst);
                let _active = Active(active.clone());
                let acknowledgement = catalog
                    .lock()
                    .unwrap()
                    .get("_subscriptionAck")
                    .cloned()
                    .unwrap_or_else(|| json!({"subscriptionId":"fixture"}));
                send(
                    &mut socket,
                    json!({"jsonrpc":"2.0","id":request["id"],"result":acknowledgement}),
                )
                .await;
                let mut ignored = [0];
                loop {
                    tokio::select! {
                        event = receiver.recv() => {
                            let event = event.unwrap();
                            if event == json!("close") { return }
                            send(&mut socket, event).await;
                        }
                        _ = socket.read(&mut ignored) => return,
                    }
                }
            }
            other => panic!("watcher sent a forbidden method: {other}"),
        };
        send(
            &mut socket,
            json!({"jsonrpc":"2.0","id":request["id"],"result":result}),
        )
        .await;
    }
}
fn session(name: &str) -> Value {
    json!({"id":axo_protocol::SessionId::from_u128(1),"name":name,"status":"ready","folder":"/tmp/fixture",
        "shells":[{"id":1,"role":"terminal","processId":1,"initialPwd":"/tmp/fixture","ptyDevice":"/dev/pts/1",
        "attachSocketPath":"/tmp/fixture/attach.sock","available":true}],"layout":{"kind":"pane","shellId":1}})
}
async fn live(
    watch: &mut CatalogWatch,
    check: impl Fn(&CatalogSnapshot) -> bool,
) -> Arc<CatalogState> {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            let state = watch.changed().await.unwrap();
            if matches!(state.as_ref(), CatalogState::Live(snapshot) if check(snapshot)) {
                return state;
            }
        }
    })
    .await
    .expect("a fresh authoritative catalog")
}
async fn stopped(watch: CatalogWatch, task: JoinHandle<()>) {
    drop(watch);
    tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .expect("cancellation is prompt")
        .unwrap();
}

#[tokio::test]
async fn events_and_manual_refresh_keep_one_idle_subscription_and_never_apply_old_snapshots() {
    let fixture = Fixture::new();
    fixture.set("first");
    let (mut watch, task) = fixture.start();
    live(&mut watch, |s| s.epoch == 1).await;
    fixture.set("newer authoritative name");
    fixture.emit(json!([{"type":"session.snapshot","session":session("old queued name")} ]));
    live(&mut watch, |s| {
        s.catalog.sessions()[0].name == "newer authoritative name"
    })
    .await;
    for _ in 0..3 {
        watch.refresh().unwrap();
        live(&mut watch, |s| s.epoch == 1).await;
    }
    assert_eq!(
        fixture.opened.load(Ordering::SeqCst),
        1,
        "refresh must not cancel EventStream::next"
    );
    let reads = fixture.reads.load(Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        fixture.reads.load(Ordering::SeqCst),
        reads,
        "idle catalog is not polled"
    );
    fixture.assert_read_only();
    stopped(watch, task).await;
}

#[tokio::test]
async fn eof_lag_and_malformed_events_replace_the_epoch_even_with_identical_pane_ids() {
    let fixture = Fixture::new();
    fixture.set("same IDs");
    let (mut watch, task) = fixture.start();
    live(&mut watch, |s| s.epoch == 1).await;
    for (index, event) in [
        json!("close"),
        json!({"jsonrpc":"2.0","method":"axo.session.events","params":{"events":[{"type":"subscription.lagged"}]}}),
        json!({"jsonrpc":"2.0","method":"axo.session.events","params":{"events":"invalid"}}),
    ].into_iter().enumerate() {
        fixture.events.send(event).unwrap();
        live(&mut watch, |s| s.epoch == index as u64 + 2).await;
        assert_eq!(fixture.active.load(Ordering::SeqCst), 1);
    }
    fixture.assert_read_only();
    stopped(watch, task).await;
}

#[tokio::test]
async fn a_conflated_outage_still_delivers_a_new_epoch() {
    let fixture = Fixture::new();
    let (mut watch, task) = fixture.start();
    live(&mut watch, |s| s.epoch == 1).await;
    fixture.events.send(json!("close")).unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        // Inspect without consuming: simulate GTK being busy through the whole outage.
        while !matches!(watch.updates.borrow().as_ref(), CatalogState::Live(s) if s.epoch == 2) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let update = watch.take_update().unwrap().unwrap();
    assert!(matches!(update.as_ref(), CatalogState::Live(s) if s.epoch == 2));
    assert!(watch.take_update().unwrap().is_none());
    stopped(watch, task).await;
}

#[tokio::test]
async fn invalid_catalogs_are_never_live_and_latest_state_delivery_is_bounded() {
    let fixture = Fixture::new();
    fixture.set("invalid");
    fixture.catalog.lock().unwrap()["sessions"][0]["shells"][0]["attachSocketPath"] =
        json!("relative.sock");
    let (mut watch, task) = fixture.start();
    let state = tokio::time::timeout(Duration::from_secs(2), watch.changed())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(state.as_ref(), CatalogState::Reconnecting { .. }));
    fixture.set("recovered");
    watch.refresh().unwrap();
    live(&mut watch, |s| s.catalog.sessions()[0].name == "recovered").await;
    // Deliberately do not consume intermediate UI deliveries.
    for i in 0..10 {
        fixture.set(&format!("version {i}"));
        watch.refresh().unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    live(&mut watch, |s| s.catalog.sessions()[0].name == "version 9").await;
    assert!(
        watch.take_update().unwrap().is_none(),
        "no queued snapshot backlog"
    );
    stopped(watch, task).await;
}

#[tokio::test]
async fn cancellation_interrupts_bootstrap_and_reconnect_backoff() {
    let fixture = Fixture::new();
    let hanging = fixture.directory.join("hanging.sock");
    let listener = UnixListener::bind(&hanging).unwrap();
    let (seen, request_seen) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut socket = BufReader::new(socket);
        let mut line = String::new();
        socket.read_line(&mut line).await.unwrap();
        seen.send(()).unwrap();
        // Never answer negotiation. Dropping the watch must cancel it, not wait five seconds.
        assert_eq!(socket.read(&mut [0]).await.unwrap(), 0);
    });
    let (watch, worker) = CatalogWatch::channel();
    let task = tokio::spawn(async move { worker.run(&hanging).await });
    tokio::time::timeout(Duration::from_secs(1), request_seen)
        .await
        .unwrap()
        .unwrap();
    stopped(watch, task).await;
    tokio::time::timeout(Duration::from_secs(1), server)
        .await
        .unwrap()
        .unwrap();
    let missing = fixture.directory.join("missing.sock");
    let (mut watch, worker) = CatalogWatch::channel();
    let task = tokio::spawn(async move { worker.run(&missing).await });
    watch.changed().await.unwrap();
    stopped(watch, task).await;
}

#[tokio::test]
async fn readiness_is_authoritative_and_subscription_acknowledgements_are_validated() {
    for acknowledgement in [
        Value::Null,
        json!({}),
        json!({"subscriptionId":""}),
        json!({"subscriptionId":1}),
    ] {
        let fixture = Fixture::new();
        fixture.catalog.lock().unwrap()["_subscriptionAck"] = acknowledgement;
        let (mut watch, task) = fixture.start();
        let state = tokio::time::timeout(Duration::from_secs(1), watch.changed())
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(state.as_ref(), CatalogState::Reconnecting { .. }));
        assert_eq!(fixture.reads.load(Ordering::SeqCst), 0);
        stopped(watch, task).await;
    }
    let fixture = Fixture::new();
    fixture.catalog.lock().unwrap()["_ready"] = json!(false);
    let (mut watch, task) = fixture.start();
    live(&mut watch, |s| !s.health.ready).await;
    fixture.catalog.lock().unwrap()["_ready"] = json!(true);
    fixture.emit(json!([{"type":"daemon.ready"}]));
    live(&mut watch, |s| s.epoch == 1 && s.health.ready).await;
    stopped(watch, task).await;
}

#[tokio::test]
async fn initially_absent_daemon_recovers_without_manual_refresh() {
    let fixture = Fixture::new();
    fixture.set("appeared later");
    let parked = fixture.directory.join("parked.sock");
    std::fs::rename(&fixture.path, &parked).unwrap();
    let (mut watch, task) = fixture.start();
    let state = tokio::time::timeout(Duration::from_secs(1), watch.changed())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(state.as_ref(), CatalogState::Reconnecting { .. }));
    std::fs::rename(parked, &fixture.path).unwrap();
    live(&mut watch, |s| {
        s.epoch > 1 && s.catalog.sessions()[0].name == "appeared later"
    })
    .await;
    fixture.assert_read_only();
    stopped(watch, task).await;
}
