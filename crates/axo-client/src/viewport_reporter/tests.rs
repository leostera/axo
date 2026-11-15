use super::*;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize},
    },
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixListener,
    sync::Notify,
    task::{JoinHandle, JoinSet},
};

struct Fixture {
    directory: PathBuf,
    path: PathBuf,
    calls: Arc<Mutex<Vec<Viewport>>>,
    offered: Arc<AtomicBool>,
    mode: Arc<AtomicUsize>, // 0 acknowledge, 1 lose acknowledgement, 2 hold it
    negotiations: Arc<AtomicUsize>,
    release: Arc<Notify>,
    task: JoinHandle<()>,
}
impl Fixture {
    fn new() -> Self {
        let directory = std::env::temp_dir().join(format!(
            "axo-viewport-{}",
            axo_protocol::new_uuid_v4().unwrap()
        ));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("rpc.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let calls = Arc::new(Mutex::new(Vec::new()));
        let offered = Arc::new(AtomicBool::new(true));
        let mode = Arc::new(AtomicUsize::new(0));
        let negotiations = Arc::new(AtomicUsize::new(0));
        let release = Arc::new(Notify::new());
        let task = tokio::spawn({
            let (calls, offered, mode, negotiations, release) = (
                calls.clone(),
                offered.clone(),
                mode.clone(),
                negotiations.clone(),
                release.clone(),
            );
            async move {
                let mut tasks = JoinSet::new();
                loop {
                    tokio::select! {
                        accepted = listener.accept() => {
                            let (socket, _) = accepted.unwrap();
                            let (calls, offered, mode, negotiations, release) =
                                (calls.clone(), offered.clone(), mode.clone(), negotiations.clone(), release.clone());
                            tasks.spawn(async move {
                                let mut socket = BufReader::new(socket);
                                loop {
                                    let mut line = String::new();
                                    if socket.read_line(&mut line).await.unwrap_or(0) == 0 { return }
                                    let request: Value = serde_json::from_str(&line).unwrap();
                                    let value = match request["method"].as_str().unwrap() {
                                        rpc::method::PROTOCOL_NEGOTIATE => {
                                            negotiations.fetch_add(1, Ordering::SeqCst);
                                            let methods: Vec<_> = if offered.load(Ordering::SeqCst) { vec![rpc::method::CLIENT_VIEWPORT_SET_V2] } else { vec![] };
                                            json!({"protocolVersion":rpc::PROTOCOL_VERSION,"methods":methods})
                                        }
                                        rpc::method::CLIENT_VIEWPORT_SET_V2 => {
                                            let viewport: Viewport = serde_json::from_value(request["params"].clone()).unwrap();
                                            assert!(viewport.is_native());
                                            calls.lock().unwrap().push(viewport);
                                            match mode.load(Ordering::SeqCst) {
                                                1 => return,
                                                2 => release.notified().await,
                                                _ => {},
                                            }
                                            json!({"accepted":true})
                                        }
                                        other => panic!("unexpected viewport method: {other}"),
                                    };
                                    let mut reply = serde_json::to_vec(&json!({"jsonrpc":"2.0","id":request["id"],"result":value})).unwrap();
                                    reply.push(b'\n');
                                    if socket.get_mut().write_all(&reply).await.is_err() { return }
                                }
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
            calls,
            offered,
            mode,
            negotiations,
            release,
            task,
        }
    }
    fn start(&self) -> (ViewportReporter, JoinHandle<()>) {
        let (reporter, worker) = ViewportReporter::channel();
        let path = self.path.clone();
        (
            reporter,
            tokio::spawn(async move { worker.run(&path).await }),
        )
    }
    async fn calls(&self, count: usize) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while self.calls.lock().unwrap().len() != count {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("expected serial viewport sends");
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
fn viewport(width: f64) -> Viewport {
    Viewport::from_native_metrics(
        axo_protocol::Size {
            width,
            height: 600.0,
        },
        1.5,
        axo_protocol::PixelSize {
            width: 12,
            height: 24,
        },
        axo_protocol::Padding {
            top: 20,
            bottom: 20,
            left: 4,
            right: 4,
        },
        1.0,
        axo_protocol::ViewportOrigin::default(),
    )
    .unwrap()
}
async fn status(reporter: &mut ViewportReporter, check: impl Fn(&ViewportStatus) -> bool) {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if check(&reporter.changed().await.unwrap()) {
                return;
            }
        }
    })
    .await
    .expect("viewport status");
}
async fn stop(reporter: ViewportReporter, task: JoinHandle<()>) {
    drop(reporter);
    tokio::time::timeout(Duration::from_secs(1), task)
        .await
        .expect("reporter cancellation")
        .unwrap();
}

#[tokio::test]
async fn viewport_bursts_coalesce_and_unchanged_geometry_is_resent_only_on_new_epoch() {
    let fixture = Fixture::new();
    let (mut reporter, task) = fixture.start();
    for width in [100.0, 200.0, 300.0, 300.0] {
        reporter.report(1, viewport(width)).unwrap();
    }
    status(&mut reporter, |s| s.phase == ViewportPhase::Published).await;
    assert_eq!(*fixture.calls.lock().unwrap(), [viewport(300.0)]);
    reporter.report(1, viewport(300.0)).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(fixture.calls.lock().unwrap().len(), 1);
    reporter.report(2, viewport(300.0)).unwrap();
    status(&mut reporter, |s| {
        s.epoch == 2 && s.phase == ViewportPhase::Published
    })
    .await;
    assert_eq!(fixture.calls.lock().unwrap().len(), 2);
    stop(reporter, task).await;
}

#[tokio::test]
async fn lost_acknowledgements_fence_geometry_changes_until_explicit_retry_or_reconnect() {
    let fixture = Fixture::new();
    fixture.mode.store(1, Ordering::SeqCst);
    let (mut reporter, task) = fixture.start();
    reporter.report(1, viewport(100.0)).unwrap();
    status(&mut reporter, |s| {
        matches!(s.phase, ViewportPhase::Uncertain { .. })
    })
    .await;
    reporter.report(1, viewport(200.0)).unwrap();
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert_eq!(
        fixture.calls.lock().unwrap().len(),
        1,
        "no blind retry on size change"
    );
    fixture.mode.store(0, Ordering::SeqCst);
    reporter.retry().unwrap();
    status(&mut reporter, |s| s.phase == ViewportPhase::Published).await;
    assert_eq!(
        *fixture.calls.lock().unwrap(),
        [viewport(100.0), viewport(200.0)]
    );
    fixture.mode.store(1, Ordering::SeqCst);
    reporter.report(1, viewport(300.0)).unwrap();
    status(&mut reporter, |s| {
        matches!(s.phase, ViewportPhase::Uncertain { .. })
    })
    .await;
    fixture.mode.store(0, Ordering::SeqCst);
    reporter.report(2, viewport(400.0)).unwrap();
    status(&mut reporter, |s| {
        s.epoch == 2 && s.phase == ViewportPhase::Published
    })
    .await;
    assert_eq!(fixture.calls.lock().unwrap().last(), Some(&viewport(400.0)));
    stop(reporter, task).await;
}

#[tokio::test]
async fn in_flight_updates_finish_before_only_the_latest_pending_value_is_sent() {
    let fixture = Fixture::new();
    fixture.mode.store(2, Ordering::SeqCst);
    let (mut reporter, task) = fixture.start();
    reporter.report(1, viewport(100.0)).unwrap();
    fixture.calls(1).await;
    reporter.report(1, viewport(200.0)).unwrap();
    reporter.report(1, viewport(300.0)).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(fixture.calls.lock().unwrap().len(), 1);
    fixture.mode.store(0, Ordering::SeqCst);
    fixture.release.notify_one();
    fixture.calls(2).await;
    status(&mut reporter, |s| s.phase == ViewportPhase::Published).await;
    assert_eq!(
        *fixture.calls.lock().unwrap(),
        [viewport(100.0), viewport(300.0)]
    );
    stop(reporter, task).await;
}

#[tokio::test]
async fn unsupported_native_viewports_do_not_fall_back_to_guessed_legacy_metrics() {
    let fixture = Fixture::new();
    fixture.offered.store(false, Ordering::SeqCst);
    let (mut reporter, task) = fixture.start();
    reporter.report(1, viewport(100.0)).unwrap();
    status(&mut reporter, |s| s.phase == ViewportPhase::Unsupported).await;
    reporter.report(1, viewport(200.0)).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(fixture.negotiations.load(Ordering::SeqCst), 1);
    assert!(fixture.calls.lock().unwrap().is_empty());
    fixture.offered.store(true, Ordering::SeqCst);
    reporter.report(2, viewport(200.0)).unwrap();
    status(&mut reporter, |s| s.phase == ViewportPhase::Published).await;
    stop(reporter, task).await;
}

#[tokio::test]
async fn suspension_and_disposal_do_not_dispatch_pending_geometry() {
    let fixture = Fixture::new();
    let (reporter, task) = fixture.start();
    assert!(reporter.report(0, viewport(100.0)).is_err());
    assert!(
        reporter
            .report(1, viewport(100.0).legacy_projection())
            .is_err()
    );
    reporter.report(1, viewport(100.0)).unwrap();
    reporter.suspend();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(fixture.calls.lock().unwrap().is_empty());
    stop(reporter, task).await;
    let (reporter, task) = fixture.start();
    fixture.mode.store(2, Ordering::SeqCst);
    reporter.report(1, viewport(200.0)).unwrap();
    fixture.calls(1).await;
    stop(reporter, task).await;
    assert_eq!(fixture.calls.lock().unwrap().len(), 1);
}
