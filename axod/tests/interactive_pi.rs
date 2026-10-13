//! Rust-owned actual ambient TUI/PTY conformance; no TS orchestration or visual terminal.
use axod::{
    ambient_pi::AmbientPi,
    journal::Journal,
    model::*,
    pi_control::{Control, State},
    runtime::Manager,
};
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
struct Fixture {
    root: PathBuf,
    manager: Manager,
    requests: Arc<AtomicUsize>,
    stage: Arc<AtomicUsize>,
    stopping: Arc<AtomicBool>,
    server: Option<thread::JoinHandle<()>>,
    ambient: AmbientPi,
    port: u16,
}
impl Fixture {
    fn new() -> Self {
        let ambient = AmbientPi::find(None).expect("Ambient Pi dependency unavailable");
        let root = std::env::temp_dir().join(format!("axo-rust-pi-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(AtomicUsize::new(0));
        let stopping = Arc::new(AtomicBool::new(false));
        let stage = Arc::new(AtomicUsize::new(0));
        let progress = stage.clone();
        let count = requests.clone();
        let stop = stopping.clone();
        let server = thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => model(stream, &count, &progress),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10))
                    }
                    Err(_) => break,
                }
            }
        });
        let manager = Manager::new(Journal::open(&root).unwrap());
        Self {
            root,
            manager,
            requests,
            stage,
            stopping,
            server: Some(server),
            ambient,
            port,
        }
    }
    fn launch(&self, name: &str) -> (TerminalSnapshot, Control, PathBuf) {
        let cwd = self.root.join(name);
        fs::create_dir(&cwd).unwrap();
        let sessions = cwd.join("sessions");
        fs::create_dir(&sessions).unwrap();
        let agent = cwd.join("agent");
        fs::create_dir(&agent).unwrap();
        fs::write(agent.join("settings.json"), br#"{"quietStartup":true,"compaction":{"enabled":false},"retry":{"enabled":false},"packages":[]}"#).unwrap();
        let config = cwd.join("provider.json");
        fs::write(
            &config,
            serde_json::to_vec(&json!({"baseUrl":format!("http://127.0.0.1:{}/v1",self.port)}))
                .unwrap(),
        )
        .unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
        let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .to_path_buf();
        let mut argv = vec!["/bin/sh".into(), "-c".into(), "export HOME=\"$1\" PI_CODING_AGENT_DIR=\"$2\" PI_AXO_INTERACTIVE_FIXTURE_CONFIG=\"$3\" PI_OFFLINE=1; shift 3; exec \"$@\"".into(), "owned-fixture".into(), self.root.to_str().unwrap().into(), agent.to_str().unwrap().into(), config.to_str().unwrap().into(), self.ambient.executable.to_str().unwrap().into()];
        argv.extend(
            [
                "--no-extensions",
                "--no-skills",
                "--no-themes",
                "--no-context-files",
                "--no-prompt-templates",
                "--no-approve",
                "--offline",
                "--extension",
            ]
            .map(str::to_owned),
        );
        argv.push(repo.join("pi-axo/index.ts").to_str().unwrap().into());
        argv.push("--extension".into());
        argv.push(
            repo.join("pi-axo/tests/fixtures/provider.ts")
                .to_str()
                .unwrap()
                .into(),
        );
        argv.extend(
            [
                "--axo-managed-control",
                "--provider",
                "axo-interactive-fixture",
                "--model",
                "fixture",
                "--tools",
                "bash,fixture_ask",
                "--session-dir",
            ]
            .map(str::to_owned),
        );
        argv.push(sessions.to_str().unwrap().into());
        let (terminal, socket) = self
            .manager
            .start_with_control(
                CommandId::new(),
                TerminalTarget {
                    session_id: SessionId::new(),
                    pane_id: PaneId::new(),
                },
                &TerminalLaunch {
                    directory: cwd.to_str().unwrap().into(),
                    argv,
                },
            )
            .unwrap();
        let ProcessState::Running { pid } = terminal.process else {
            panic!("Owned child not running");
        };
        let control = Control::admit(terminal.runtime, pid, &cwd, &sessions, socket)
            .expect("Actual TUI admission failed");
        (terminal, control, cwd)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.manager.shutdown();
        self.stopping.store(true, Ordering::SeqCst);
        if let Some(server) = self.server.take() {
            let _ = server.join();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn model(mut stream: TcpStream, requests: &AtomicUsize, stage: &AtomicUsize) {
    stage.store(1, Ordering::SeqCst);
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut bytes = Vec::new();
    let header_end;
    loop {
        if bytes.len() > 8192 {
            return;
        }
        let mut chunk = [0; 1024];
        let Ok(count) = stream.read(&mut chunk) else {
            return;
        };
        if count == 0 {
            return;
        }
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            header_end = index + 4;
            break;
        }
    }
    let Ok(header) = std::str::from_utf8(&bytes[..header_end]) else {
        return;
    };
    stage.store(2, Ordering::SeqCst);
    let Some(length) = header.lines().find_map(|line| {
        line.split_once(':')
            .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, value)| value.trim().parse::<usize>().ok())
    }) else {
        return;
    };
    stage.store(3, Ordering::SeqCst);
    if length > 1024 * 1024 {
        return;
    }
    while bytes.len() < header_end + length {
        let mut chunk = [0; 4096];
        let Ok(count) = stream.read(&mut chunk) else {
            return;
        };
        if count == 0 {
            return;
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
    let Ok(body) = serde_json::from_slice::<Value>(&bytes[header_end..header_end + length]) else {
        return;
    };
    let count = requests.fetch_add(1, Ordering::SeqCst) + 1;
    let tool_result = body["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .is_some_and(|message| message["role"] == "tool");
    let delta = if tool_result {
        json!({"content":"actual Rust fixture complete λ 界"})
    } else {
        json!({"tool_calls":[{"index":0,"id":"actual-bash","type":"function","function":{"name":"bash","arguments":"{\"command\":\"printf Pi-owned-tool > marker.txt\"}"}}]})
    };
    let frame = |delta: Value, finish: Value| {
        json!({"id":format!("fixture-{count}"),"object":"chat.completion.chunk","created":1,"model":"fixture","choices":[{"index":0,"delta":delta,"finish_reason":finish}]}).to_string()
    };
    let body = format!(
        "data: {}\n\ndata: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
        frame(json!({"role":"assistant"}), Value::Null),
        frame(delta, Value::Null),
        frame(
            json!({}),
            json!(if tool_result { "stop" } else { "tool_calls" })
        )
    );
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
}
fn settled(control: &Control) -> State {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = control.get().expect("Actual TUI read failed");
        if !state.busy && state.interaction_id.is_none() {
            return state;
        }
        assert!(Instant::now() < deadline, "Actual TUI settlement deadline");
        thread::sleep(Duration::from_millis(25));
    }
}
#[test]
fn rust_orchestrates_actual_tui_pty_public_extension_real_bash_and_pi_history() {
    let fixture = Fixture::new();
    let (terminal, control, cwd) = fixture.launch("first");
    let state = control.current().unwrap();
    assert!(
        state.mode == axod::pi_control::Mode::Tui
            && state.stdin_tty
            && state.stdout_tty
            && state.stderr_tty
    );
    let ProcessState::Running { pid } = terminal.process else {
        panic!("Owned child missing");
    };
    assert!(state.pid == pid, "Extension is not in the owned child");
    assert!(fixture.requests.load(Ordering::SeqCst) == 0);
    let _dispatched = control
        .execute(
            axod::model::CommandId::new(),
            &axod::pi_control::Action::Send {
                text: "Real Rust-owned test λ 界".into(),
            },
        )
        .unwrap(); // Typed dispatch only, not execution.
    let state = settled(&control);
    let history = control.history().unwrap();
    // Canonical documents are Pi-owned payloads, not dynamic control routing.
    let entries: Vec<Value> = history
        .entries
        .iter()
        .map(|entry| serde_json::from_str(entry.json()).unwrap())
        .collect();
    let provider_failed = entries
        .iter()
        .any(|entry| entry["message"]["stopReason"] == "error");
    assert!(
        fs::read(cwd.join("marker.txt")).is_ok_and(|bytes| bytes == b"Pi-owned-tool"),
        "Real bash effect missing: requests={}, provider_failed={provider_failed}, recovery={}, model_stage={}",
        fixture.requests.load(Ordering::SeqCst),
        state.recovery,
        fixture.stage.load(Ordering::SeqCst)
    );
    let records: Vec<Value> = fs::read_to_string(state.file.unwrap())
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(
        records[0]["id"] == json!(state.chat_id),
        "Canonical chat binding changed"
    );
    assert!(
        records[1..] == entries,
        "Pi canonical entries differ from public reads"
    );
    assert!(fixture.requests.load(Ordering::SeqCst) == 2);
}
