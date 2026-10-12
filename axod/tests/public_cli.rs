//! Actual installed-binary boundary: Rust axo -> public WebSocket -> axod serve.
use axod::client::{Client, ClientError};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn daemon_program() -> PathBuf {
    let path = std::env::var_os("AXO_LOCAL_DAEMON_BINARY")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_axod")));
    assert!(
        path.is_absolute() && path.is_file(),
        "Owned helper fixture requires an absolute executable"
    );
    path
}

struct Daemon {
    root: PathBuf,
    child: Child,
}
impl Daemon {
    fn start() -> Self {
        let root = std::env::temp_dir().join(format!("axo-rust-cli-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let config = root.join("profiles.json");
        let profiles = json!({"profiles":{
            "fixture":{"directory":root,"argv":["/bin/sh","-c","printf accepted > marker.txt"]},
            "terminal":{"directory":root,"argv":["/bin/sh","-c","stty -echo; printf ready; while IFS= read -r line; do printf '%s\\n' \"$line\"; stty size > geometry.txt; done"]},
            "flood":{"directory":root,"argv":["/bin/sh","-c","printf '%09000d' 0; printf ready > flood-ready.txt; sleep 30"]}
        }});
        fs::write(&config, serde_json::to_vec(&profiles).unwrap()).unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
        let child = Command::new(daemon_program())
            .arg("serve")
            .arg(&root)
            .arg("--profiles-config")
            .arg(config)
            .env("HOME", &root)
            .env("SHELL", "/bin/sh")
            .env_remove("ZDOTDIR")
            .env_remove("ENV")
            .env_remove("BASH_ENV")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut owned = Self { root, child };
        let deadline = Instant::now() + Duration::from_secs(5);
        while Client::connect(&owned.discovery()).is_err() {
            assert!(
                owned.child.try_wait().unwrap().is_none(),
                "Owned daemon startup failed"
            );
            assert!(Instant::now() < deadline, "Owned discovery deadline");
            thread::sleep(Duration::from_millis(25));
        }
        owned
    }
    fn discovery(&self) -> PathBuf {
        self.root.join("local-endpoint.json")
    }
    fn invoke(&self, method: &str, params: Value) -> std::process::Output {
        let mut child = Command::new(env!("CARGO_BIN_EXE_axo"))
            .arg("rpc")
            .arg(self.discovery())
            .arg(method)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(&params).unwrap())
            .unwrap();
        child.wait_with_output().unwrap()
    }
    fn call(&self, method: &str, params: Value) -> Value {
        let reply = self.invoke(method, params);
        assert!(reply.status.success(), "Owned CLI operation failed");
        serde_json::from_slice(&reply.stdout).unwrap()
    }
    fn target(&self) -> Value {
        let descriptor = Client::connect(&self.discovery()).unwrap().discovery;
        json!({"machineId":descriptor.machine_id,"hostGeneration":descriptor.host_generation})
    }
}
impl Drop for Daemon {
    fn drop(&mut self) {
        // Only this still-unreaped owned handle may be signaled; no process searching/adoption.
        if self.child.try_wait().ok().flatten().is_none() {
            unsafe {
                libc::kill(self.child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(5);
            while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(25));
            }
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
struct FrontendPty {
    manager: axod::runtime::Manager,
    root: PathBuf,
}
impl FrontendPty {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("axo-frontend-pty-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let manager = axod::runtime::Manager::new(axod::journal::Journal::open(&root).unwrap());
        Self { manager, root }
    }
}
impl Drop for FrontendPty {
    fn drop(&mut self) {
        self.manager.shutdown();
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn uuid_argument(id: impl serde::Serialize) -> String {
    let encoded = serde_json::to_string(&id).unwrap();
    encoded
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
        .expect("Typed UUID argument")
        .to_owned()
}
#[test]
fn actual_frontend_child_forwards_pty_input_resize_and_quits_without_stopping_work() {
    use axod::{model::*, runtime::Sink, terminal::Frame};
    use std::sync::mpsc;
    let daemon = Daemon::start();
    let discovery = Client::connect(&daemon.discovery()).unwrap().discovery;
    let started = daemon.call(
        "axo.runtime.startApproved",
        json!({
            "target": {"machineId":discovery.machine_id,"hostGeneration":discovery.host_generation,
                       "sessionId":SessionId::new(),"paneId":PaneId::new()},
            "commandId":CommandId::new(),"profileId":"terminal"
        }),
    );
    let runtime: RuntimeRef =
        serde_json::from_value(started["terminal"]["runtime"].clone()).unwrap();
    let frontend = FrontendPty::new();
    let relay = frontend
        .manager
        .start(
            CommandId::new(),
            TerminalTarget {
                session_id: SessionId::new(),
                pane_id: PaneId::new(),
            },
            &TerminalLaunch {
                directory: frontend.root.to_str().unwrap().into(),
                argv: vec![
                    env!("CARGO_BIN_EXE_axod").into(),
                    "terminal-attach".into(),
                    daemon.root.to_str().unwrap().into(),
                    uuid_argument(discovery.machine_id),
                    uuid_argument(runtime.host_generation),
                    uuid_argument(runtime.target.session_id),
                    uuid_argument(runtime.target.pane_id),
                    uuid_argument(runtime.runtime_generation),
                ],
            },
        )
        .unwrap();
    let owner = ClientId::new();
    let (sink, receiver) = Sink::bounded(32);
    let attached = frontend.manager.attach(relay.runtime, owner, sink).unwrap();
    let mut consumed = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !consumed.windows(5).any(|bytes| bytes == b"ready") {
        assert!(Instant::now() < deadline, "Owned frontend startup deadline");
        match receiver.recv_timeout(Duration::from_millis(50)) {
            Ok(Frame::Attached { backlog, .. }) => consumed.extend_from_slice(&backlog.data),
            Ok(Frame::Output { data, .. }) => consumed.extend_from_slice(&data),
            Ok(Frame::Exited { .. }) => panic!("Owned frontend exited before attachment"),
            Err(mpsc::RecvTimeoutError::Timeout) => (),
            Err(_) => panic!("Owned frontend channel closed"),
        }
        assert!(consumed.len() <= 8192);
    }
    frontend
        .manager
        .resize(attached.attachment, owner, 42, 91)
        .unwrap();
    frontend
        .manager
        .input(attached.attachment, owner, "hello λ\n".as_bytes())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !fs::read_to_string(daemon.root.join("geometry.txt"))
        .is_ok_and(|geometry| geometry.trim() == "42 91")
        || !consumed
            .windows(8)
            .any(|bytes| bytes == "hello λ".as_bytes())
    {
        assert!(
            Instant::now() < deadline,
            "Owned frontend input/resize deadline"
        );
        match receiver.recv_timeout(Duration::from_millis(50)) {
            Ok(Frame::Output { data, .. }) => consumed.extend_from_slice(&data),
            Ok(_) => panic!("Unexpected frontend lifecycle event"),
            Err(mpsc::RecvTimeoutError::Timeout) => (),
            Err(_) => panic!("Owned frontend channel closed"),
        }
        assert!(consumed.len() <= 8192);
    }
    frontend.manager.stop(relay.runtime).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let listed = daemon.call("axo.runtime.list", json!({"target":daemon.target()}));
        let terminals = listed["terminals"].as_array().unwrap();
        assert_eq!(
            terminals.len(),
            1,
            "Frontend attachment created duplicate managed work"
        );
        assert_eq!(
            terminals[0]["runtime"],
            serde_json::to_value(runtime).unwrap()
        );
        assert_eq!(terminals[0]["process"]["kind"], "running");
        if terminals[0]["attached"] == false {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Owned frontend lease cleanup deadline"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn frontend_refuses_truncated_screen_replay_without_stopping_the_runtime() {
    use axod::model::*;
    let daemon = Daemon::start();
    let discovery = Client::connect(&daemon.discovery()).unwrap().discovery;
    let started = daemon.call(
        "axo.runtime.startApproved",
        json!({
            "target":{"machineId":discovery.machine_id,"hostGeneration":discovery.host_generation,
                      "sessionId":SessionId::new(),"paneId":PaneId::new()},
            "commandId":CommandId::new(),"profileId":"flood"
        }),
    );
    let runtime: RuntimeRef =
        serde_json::from_value(started["terminal"]["runtime"].clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !daemon.root.join("flood-ready.txt").exists() {
        assert!(Instant::now() < deadline, "Owned flood fixture deadline");
        thread::sleep(Duration::from_millis(20));
    }
    let (observer, initial) =
        axod::terminal_client::TerminalClient::connect(&daemon.root, discovery.machine_id, runtime)
            .unwrap();
    assert!(
        initial.truncated,
        "Owned flood was not drained before the recovery test"
    );
    observer.detach().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while daemon.call("axo.runtime.list", json!({"target":daemon.target()}))["terminals"][0]["attached"]
        != false
    {
        assert!(
            Instant::now() < deadline,
            "Owned observer lease cleanup deadline"
        );
        thread::sleep(Duration::from_millis(20));
    }
    let frontend = FrontendPty::new();
    let relay = frontend
        .manager
        .start(
            CommandId::new(),
            TerminalTarget {
                session_id: SessionId::new(),
                pane_id: PaneId::new(),
            },
            &TerminalLaunch {
                directory: frontend.root.to_str().unwrap().into(),
                argv: vec![
                    env!("CARGO_BIN_EXE_axod").into(),
                    "terminal-attach".into(),
                    daemon.root.to_str().unwrap().into(),
                    uuid_argument(discovery.machine_id),
                    uuid_argument(runtime.host_generation),
                    uuid_argument(runtime.target.session_id),
                    uuid_argument(runtime.target.pane_id),
                    uuid_argument(runtime.runtime_generation),
                ],
            },
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !frontend.manager.list().iter().any(|terminal| {
        terminal.runtime == relay.runtime
            && matches!(terminal.process, ProcessState::Exited { wait_status } if wait_status != 0)
    }) {
        assert!(
            Instant::now() < deadline,
            "Owned frontend recovery refusal deadline"
        );
        thread::sleep(Duration::from_millis(20));
    }
    let listed = daemon.call("axo.runtime.list", json!({"target":daemon.target()}));
    assert_eq!(listed["terminals"].as_array().unwrap().len(), 1);
    assert_eq!(listed["terminals"][0]["process"]["kind"], "running");
    assert_eq!(listed["terminals"][0]["attached"], false);
}

#[test]
fn actual_cli_observes_host_and_reconciles_one_owned_native_pty_launch() {
    let daemon = Daemon::start();
    let target = daemon.target();
    let host = daemon.call("axo.host.get", json!({"target":target}));
    assert_eq!(host["cloud"]["kind"], "notConfigured");
    assert_eq!(host["daemonVersion"], axod::host::VERSION);
    assert_eq!(host["machineId"], target["machineId"]);
    assert_eq!(host["hostGeneration"], target["hostGeneration"]);
    assert!(!host["hostname"].as_str().unwrap().is_empty());
    assert!(!host["machineType"].as_str().unwrap().is_empty());
    let mut launch_target = target.clone();
    launch_target["sessionId"] = json!(uuid::Uuid::new_v4());
    launch_target["paneId"] = json!(uuid::Uuid::new_v4());
    let command = uuid::Uuid::new_v4();
    let params = json!({"target":launch_target,"commandId":command,"profileId":"fixture"});
    let first = daemon.invoke("axo.runtime.startApproved", params.clone());
    assert!(first.status.success(), "CLI approved launch failed");
    let first: Value = serde_json::from_slice(&first.stdout).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !daemon.root.join("marker.txt").exists() {
        assert!(Instant::now() < deadline, "Owned tool effect deadline");
        thread::sleep(Duration::from_millis(25));
    }
    let again = daemon.invoke("axo.runtime.startApproved", params);
    assert!(again.status.success(), "CLI reconciliation failed");
    let again: Value = serde_json::from_slice(&again.stdout).unwrap();
    let first_runtime: axod::model::RuntimeRef =
        serde_json::from_value(first["terminal"]["runtime"].clone()).expect("Typed runtime result");
    let again_runtime: axod::model::RuntimeRef =
        serde_json::from_value(again["terminal"]["runtime"].clone())
            .expect("Typed reconciliation result");
    assert!(
        first_runtime == again_runtime,
        "Reconciliation changed runtime identity"
    );
}
#[test]
fn actual_cli_preserves_stale_targets_and_never_dumps_request_bodies() {
    let daemon = Daemon::start();
    let mut target = daemon.target();
    target["hostGeneration"] = json!(uuid::Uuid::new_v4());
    let rejected = daemon.invoke("axo.runtime.startApproved", json!({"target":{"machineId":target["machineId"],"hostGeneration":target["hostGeneration"],"sessionId":uuid::Uuid::new_v4(),"paneId":uuid::Uuid::new_v4()},"commandId":uuid::Uuid::new_v4(),"profileId":"PAYLOAD_MUST_NOT_BE_DIAGNOSTICS"}));
    assert!(!rejected.status.success());
    assert_eq!(
        String::from_utf8(rejected.stderr).unwrap().trim(),
        "Axo RPC error -32002"
    );
    assert!(rejected.stdout.is_empty());
    assert!(!daemon.root.join("marker.txt").exists());
    let mut client = Client::connect(&daemon.discovery()).unwrap();
    assert_eq!(
        client.call("axo.runtime.list", json!({"target":target})),
        Err(ClientError::Rpc(-32002))
    );
    assert!(
        client
            .call("axo.runtime.list", json!({"target":daemon.target()}))
            .is_ok()
    );
}
