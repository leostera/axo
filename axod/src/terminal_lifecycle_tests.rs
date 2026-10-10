//! Real PTY regressions at the manager boundary, independent of any transport envelope.
use crate::{
    journal::Journal,
    model::*,
    runtime::{Manager, Sink},
    terminal::{ErrorCode, Frame},
};
use serde_json::Value;
use std::os::unix::fs::DirBuilderExt;
use std::{
    fs,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
struct Fixture {
    manager: Manager,
    root: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("axod-pty-{}", uuid::Uuid::new_v4()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self {
            manager: Manager::new(Journal::open(&root).unwrap()),
            root,
        }
    }
    fn launch(&self, argv: Vec<String>) -> TerminalSnapshot {
        self.manager
            .start(
                CommandId::new(),
                TerminalTarget {
                    session_id: SessionId::new(),
                    pane_id: PaneId::new(),
                },
                &TerminalLaunch {
                    directory: self.root.to_str().unwrap().into(),
                    argv,
                },
            )
            .unwrap()
    }
    fn ticking(&self, name: &str, flood: bool) -> (TerminalSnapshot, PathBuf) {
        let state = self.root.join(name);
        let mut argv = vec![
            "/usr/bin/python3".into(),
            format!(
                "{}/tests/fixtures/terminal_child.py",
                env!("CARGO_MANIFEST_DIR")
            ),
            state.to_str().unwrap().into(),
        ];
        if flood {
            argv.push("--flood".into());
        }
        let terminal = self.launch(argv);
        eventually(|| read(&state).is_some_and(|value| value["ticks"].as_u64().unwrap_or(0) > 2));
        (terminal, state)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.manager.shutdown();
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn eventually(mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(6);
    while !ready() {
        assert!(Instant::now() < deadline, "Owned PTY fixture deadline");
        thread::sleep(Duration::from_millis(20));
    }
}
fn read(path: &PathBuf) -> Option<Value> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}
fn channel() -> (Sink, mpsc::Receiver<Frame>) {
    let (sender, receiver) = mpsc::sync_channel(32);
    (
        Sink {
            sender,
            disconnected: Arc::new(AtomicBool::new(false)),
        },
        receiver,
    )
}

#[test]
fn input_resize_disconnect_and_attachment_generations_are_fenced() {
    let f = Fixture::new();
    let (one, state) = f.ticking("one.json", false);
    let (_, sibling) = f.ticking("two.json", false);
    let (sink, receiver) = channel();
    let first = f.manager.attach(one.runtime, ClientId(1), sink).unwrap();
    assert!(matches!(receiver.recv().unwrap(), Frame::Attached { .. }));
    let (other, _) = channel();
    assert!(matches!(
        f.manager.attach(one.runtime, ClientId(2), other),
        Err(ErrorCode::AlreadyAttached)
    ));
    f.manager
        .input(first.attachment, ClientId(1), "hello λ\n".as_bytes())
        .unwrap();
    f.manager
        .resize(first.attachment, ClientId(1), 42, 91)
        .unwrap();
    eventually(|| {
        read(&state).is_some_and(|value| {
            value["received"]
                .as_array()
                .is_some_and(|items| items.len() == 1)
                && value["rows"] == 42
                && value["columns"] == 91
        })
    });
    assert_eq!(read(&sibling).unwrap()["received"], serde_json::json!([]));
    f.manager.disconnect(ClientId(1));
    let (next, _next_receiver) = channel();
    let replacement = f.manager.attach(one.runtime, ClientId(2), next).unwrap();
    assert_ne!(first.attachment, replacement.attachment);
    assert_eq!(
        f.manager.input(first.attachment, ClientId(2), b"wrong\n"),
        Err(ErrorCode::StaleAttachment)
    );
    let mut stale = one.runtime;
    stale.runtime_generation = RuntimeGeneration::new();
    assert_eq!(f.manager.stop(stale), Err(ErrorCode::StaleRuntime));
    let mut stale_host = one.runtime;
    stale_host.host_generation = HostGeneration::new();
    assert_eq!(f.manager.stop(stale_host), Err(ErrorCode::StaleHost));
}
#[test]
fn slow_output_is_bounded_and_reconnect_backlog_offsets_are_contiguous() {
    let f = Fixture::new();
    let (terminal, _) = f.ticking("flood.json", true);
    eventually(|| f.manager.list()[0].backlog_bytes == 8192);
    let (sink, receiver) = channel();
    let disconnected = sink.disconnected.clone();
    let attached = f
        .manager
        .attach(terminal.runtime, ClientId(1), sink)
        .unwrap();
    let backlog = match attached.initial {
        Frame::Attached { backlog, .. } => backlog,
        _ => panic!("Initial attachment"),
    };
    assert!(backlog.truncated);
    assert_eq!(backlog.data.len(), 8192);
    assert!(matches!(receiver.recv().unwrap(), Frame::Attached { .. }));
    match receiver.recv_timeout(Duration::from_secs(2)).unwrap() {
        Frame::Output { offset, .. } => assert_eq!(offset, backlog.next_offset),
        _ => panic!("Live output"),
    }
    eventually(|| disconnected.load(Ordering::SeqCst));
    assert!(!f.manager.list()[0].attached);
}
#[test]
fn final_output_precedes_exit_and_exited_attachment_can_detach() {
    let f = Fixture::new();
    let terminal = f.launch(vec![
        "/bin/sh".into(),
        "-c".into(),
        "read -r ignored; printf 'final-output\\n'; exit 7".into(),
    ]);
    let (sink, receiver) = channel();
    let attachment = f
        .manager
        .attach(terminal.runtime, ClientId(1), sink)
        .unwrap()
        .attachment;
    f.manager.input(attachment, ClientId(1), b"go\n").unwrap();
    let mut bytes = Vec::new();
    loop {
        match receiver.recv_timeout(Duration::from_secs(5)).unwrap() {
            Frame::Output { data, .. } => bytes.extend(data),
            Frame::Exited { wait_status, .. } => {
                assert!(libc::WIFEXITED(wait_status));
                assert_eq!(libc::WEXITSTATUS(wait_status), 7);
                break;
            }
            Frame::Attached { .. } => (),
        }
    }
    assert!(bytes.windows(12).any(|value| value == b"final-output"));
    f.manager.detach(attachment, ClientId(1)).unwrap();
}
#[test]
fn repeated_stop_escalates_once_and_preserves_sibling_progress() {
    let f = Fixture::new();
    let (_, state) = f.ticking("sibling.json", false);
    let ready = f.root.join("ready");
    let terminal = f.launch(vec![
        "/bin/sh".into(),
        "-c".into(),
        "trap '' TERM; : > \"$1\"; read -r value".into(),
        "axod-test".into(),
        ready.to_str().unwrap().into(),
    ]);
    eventually(|| ready.exists());
    for _ in 0..64 {
        f.manager.stop(terminal.runtime).unwrap();
    }
    eventually(|| {
        f.manager.list().iter().any(|value| {
            value.runtime == terminal.runtime
                && matches!(value.process, ProcessState::Exited { .. })
        })
    });
    let exited = f
        .manager
        .list()
        .into_iter()
        .find(|value| value.runtime == terminal.runtime)
        .unwrap();
    if let ProcessState::Exited { wait_status } = exited.process {
        assert!(libc::WIFSIGNALED(wait_status));
        assert_eq!(libc::WTERMSIG(wait_status), 9);
    }
    let ticks = read(&state).unwrap()["ticks"].as_u64().unwrap();
    eventually(|| read(&state).is_some_and(|value| value["ticks"].as_u64().unwrap() > ticks + 3));
}
#[test]
fn reaped_leader_with_descendant_pty_stays_recovery_required() {
    let f = Fixture::new();
    let state = f.root.join("descendant.json");
    let release = f.root.join("release");
    let done = f.root.join("done");
    struct Release(PathBuf, PathBuf);
    impl Drop for Release {
        fn drop(&mut self) {
            let _ = fs::write(&self.0, []);
            eventually(|| self.1.exists());
        }
    }
    let _release = Release(release.clone(), done.clone());
    let terminal = f.launch(vec![
        "/usr/bin/python3".into(),
        format!(
            "{}/tests/fixtures/terminal_descendant.py",
            env!("CARGO_MANIFEST_DIR")
        ),
        state.to_str().unwrap().into(),
        release.to_str().unwrap().into(),
        done.to_str().unwrap().into(),
    ]);
    eventually(|| {
        f.manager
            .list()
            .iter()
            .any(|value| matches!(value.process, ProcessState::RecoveryRequired {}))
    });
    let launch = TerminalLaunch {
        directory: f.root.to_str().unwrap().into(),
        argv: vec!["/bin/sh".into()],
    };
    assert!(matches!(
        f.manager
            .start(CommandId::new(), terminal.runtime.target, &launch),
        Err(ErrorCode::Conflict)
    ));
    assert_eq!(
        read(&f.root.join("runtime-state.json")).unwrap()["receipts"]
            .as_object()
            .unwrap()
            .len(),
        1
    );
}
