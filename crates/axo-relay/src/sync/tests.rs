//! The uploader against a fake cloud: what wakes it, and what doesn't (RFD0037,
//! `specs/sessions/upload-wakes.ts`).

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axo_protocol::SessionId;
use serde_json::{Value, json};

use super::{
    Eviction, SessionMetadata, StoredSyncState, SyncCursor, SyncSession, SyncStore, SyncWaker,
    SyncWorker,
};
use crate::host::{HostFuture, HostIdentity};
use crate::outbound::{AttachedSocket, RelayChannel};

const SESSION: &str = "8f8f8f8f-0000-4000-8000-000000000001";
const HEADER: &str = r#"{"type":"session","version":3,"id":"s"}"#;
/// How soon a line written is appended: a turn, not a tick (the tick was 500ms).
const AT_ONCE: Duration = Duration::from_millis(150);

struct Host {
    transcript: PathBuf,
    catalog_reads: AtomicUsize,
    round: AtomicU64,
}

impl SyncStore for Host {
    fn catalog(&self) -> HostFuture<'_, io::Result<Vec<SyncSession>>> {
        self.catalog_reads.fetch_add(1, Ordering::SeqCst);
        Box::pin(std::future::ready(Ok(vec![SyncSession {
            session_id: SESSION.parse().unwrap(),
            pi_session_file: Some(self.transcript.clone()),
            metadata: SessionMetadata {
                name: None,
                emoji: None,
                folder_name: None,
                has_agent: true,
                created_at: None,
                last_message_at: None,
                archived: false,
                workspace_state: None,
                pi: None,
            },
            status: None,
            transcript_in_cloud: false,
        }])))
    }
    fn states(&self) -> HostFuture<'_, io::Result<Vec<StoredSyncState>>> {
        Box::pin(std::future::ready(Ok(Vec::new())))
    }
    fn store_cursor(&self, _: SessionId, _: SyncCursor) -> HostFuture<'_, io::Result<()>> {
        Box::pin(std::future::ready(Ok(())))
    }
    fn store_metadata(&self, _: SessionId, _: String, _: u64) -> HostFuture<'_, io::Result<()>> {
        Box::pin(std::future::ready(Ok(())))
    }
    fn evict_transcript(
        &self,
        _: SessionId,
        _: SyncCursor,
        _: u64,
    ) -> HostFuture<'_, io::Result<Eviction>> {
        Box::pin(std::future::ready(Ok(Eviction::Kept)))
    }
    fn next_round(&self) -> HostFuture<'_, io::Result<u64>> {
        Box::pin(std::future::ready(Ok(self
            .round
            .fetch_add(1, Ordering::SeqCst)
            + 1)))
    }
}

/// What the fake cloud was sent: handshakes, and the highest position each append reached.
#[derive(Default)]
struct Received {
    handshakes: usize,
    appended: u64,
}

/// axod's uploader, a fake cloud answering it on the relay channel, and one open Session.
struct World {
    host: Arc<Host>,
    waker: SyncWaker,
    received: Arc<Mutex<Received>>,
    stop: axo_ipc::Stop,
    worker: Option<SyncWorker>,
    runtime: Option<tokio::runtime::Runtime>,
}

impl World {
    fn start(transcript: PathBuf) -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        let host = Arc::new(Host {
            transcript,
            catalog_reads: AtomicUsize::new(0),
            round: AtomicU64::new(0),
        });
        let channel = RelayChannel::new();
        let received = Arc::new(Mutex::new(Received::default()));
        let AttachedSocket { mut outgoing, .. } = channel.attach();
        {
            let channel = Arc::clone(&channel);
            let received = Arc::clone(&received);
            runtime.spawn(async move {
                while let Some(message) = outgoing.recv().await {
                    let message: Value = serde_json::from_str(&message.text).unwrap();
                    if let Some(result) = answer(&message, &received) {
                        channel.resolve(&json!({ "id": message["id"], "result": result }));
                    }
                }
            });
        }
        let waker = SyncWaker::default();
        let stop = axo_ipc::Stop::default();
        let store: Arc<dyn SyncStore> = host.clone();
        let identity = HostIdentity {
            host_id: "36bc9f8c-8a79-4885-9ca8-a1a271ccdcfe".into(),
            host_generation: "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230".into(),
        };
        let worker = SyncWorker::start(
            store,
            identity,
            channel,
            waker.clone(),
            runtime.handle().clone(),
            stop.clone(),
        )
        .unwrap();
        Self {
            host,
            waker,
            received,
            stop,
            worker: Some(worker),
            runtime: Some(runtime),
        }
    }

    fn catalog_reads(&self) -> usize {
        self.host.catalog_reads.load(Ordering::SeqCst)
    }

    fn appended(&self) -> u64 {
        self.received.lock().unwrap().appended
    }

    fn until(&self, what: &str, within: Duration, done: impl Fn(&Self) -> bool) -> Duration {
        let started = Instant::now();
        while !done(self) {
            assert!(started.elapsed() < within, "{what} within {within:?}");
            std::thread::sleep(Duration::from_millis(2));
        }
        started.elapsed()
    }

    fn handshaken(&self) {
        self.until("the handshake", Duration::from_secs(5), |world| {
            world.received.lock().unwrap().handshakes > 0
        });
    }
}

impl Drop for World {
    fn drop(&mut self) {
        self.stop.stop();
        self.waker.wake();
        if let Some(mut worker) = self.worker.take() {
            worker.join();
        }
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_timeout(Duration::from_secs(1));
        }
    }
}

fn answer(message: &Value, received: &Mutex<Received>) -> Option<Value> {
    let params = &message["params"];
    let mut received = received.lock().unwrap();
    match message["method"].as_str()? {
        "axo.host.sync" => {
            received.handshakes += 1;
            Some(json!({
                "round": params["round"],
                "applied": true,
                "sessions": [{ "sessionId": SESSION, "state": "unknown" }],
            }))
        }
        "axo.host.session.append" => {
            let count = params["from"].as_u64()? + params["records"].as_array()?.len() as u64 - 1;
            received.appended = received.appended.max(count);
            Some(json!({ "outcome": "committed", "epoch": 1, "count": count, "chain": null }))
        }
        _ => message.get("id").map(|_| json!({})),
    }
}

fn transcript_path(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "axo-upload-{name}-{}-{:?}",
        std::process::id(),
        Instant::now()
    ));
    std::fs::create_dir_all(&directory).unwrap();
    directory.join("transcript.jsonl")
}

/// Appends record `position`; the first also writes the header, creating the file.
fn write_record(path: &Path, position: u64) {
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    let parent = match position {
        1 => "null".to_owned(),
        _ => format!("\"r{}\"", position - 1),
    };
    let header = if position == 1 {
        format!("{HEADER}\n")
    } else {
        String::new()
    };
    write!(
        file,
        "{header}{{\"id\":\"r{position}\",\"parentId\":{parent}}}\n"
    )
    .unwrap();
}

#[test]
fn an_idle_uploader_reads_nothing_until_something_changes() {
    let path = transcript_path("idle");
    write_record(&path, 1);
    let world = World::start(path);
    world.until("the first record", Duration::from_secs(5), |world| {
        world.appended() == 1
    });
    std::thread::sleep(Duration::from_millis(100));
    let reads = world.catalog_reads();
    std::thread::sleep(Duration::from_millis(1200));
    assert_eq!(world.catalog_reads(), reads, "no turn without a cause");
}

#[test]
fn a_line_written_to_an_open_transcript_is_appended_at_once() {
    let path = transcript_path("write");
    write_record(&path, 1);
    let world = World::start(path.clone());
    world.until("the first record", Duration::from_secs(5), |world| {
        world.appended() == 1
    });
    // No Pi event: only the kernel says the file changed.
    for position in 2..=6 {
        std::thread::sleep(Duration::from_millis(50));
        write_record(&path, position);
        let took = world.until("the record", Duration::from_secs(2), |world| {
            world.appended() == position
        });
        assert!(took < AT_ONCE, "record {position} took {took:?}");
    }
}

#[test]
fn the_first_line_of_a_transcript_that_did_not_exist_is_appended_at_once() {
    let path = transcript_path("create");
    let world = World::start(path.clone());
    world.handshaken();
    std::thread::sleep(Duration::from_millis(100));
    write_record(&path, 1);
    let took = world.until("the first record", Duration::from_secs(2), |world| {
        world.appended() == 1
    });
    assert!(took < AT_ONCE, "the first record took {took:?}");
    // From then on the file itself is watched.
    write_record(&path, 2);
    let took = world.until("the second record", Duration::from_secs(2), |world| {
        world.appended() == 2
    });
    assert!(took < AT_ONCE, "the second record took {took:?}");
}

#[test]
fn a_rewritten_transcript_is_watched_again() {
    let path = transcript_path("rewrite");
    write_record(&path, 1);
    let world = World::start(path.clone());
    world.until("the first record", Duration::from_secs(5), |world| {
        world.appended() == 1
    });
    // Replaced by a rename, as an editor or a compaction would: a new file at the same path.
    let replacement = path.with_extension("new");
    std::fs::copy(&path, &replacement).unwrap();
    std::fs::rename(&replacement, &path).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    write_record(&path, 2);
    let took = world.until(
        "the record in the new file",
        Duration::from_secs(2),
        |world| world.appended() == 2,
    );
    assert!(took < AT_ONCE, "the record took {took:?}");
}

#[test]
fn a_session_event_rereads_the_catalog() {
    let path = transcript_path("event");
    write_record(&path, 1);
    let world = World::start(path);
    world.until("the first record", Duration::from_secs(5), |world| {
        world.appended() == 1
    });
    std::thread::sleep(Duration::from_millis(100));
    let reads = world.catalog_reads();
    world.waker.wake();
    world.until("the catalog read again", AT_ONCE, |world| {
        world.catalog_reads() > reads
    });
}
