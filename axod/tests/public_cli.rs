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
        fs::write(&config, serde_json::to_vec(&json!({"profiles":{"fixture":{"directory":root,"argv":["/bin/sh","-c","printf accepted > marker.txt"]},"shell":{"directory":root,"argv":["/bin/sh","-c","trap '' TERM; test -t 0 && test -t 1 || exit 17; printf TTY >> shell-effects.txt; while :; do sleep 1; done"]}}})).unwrap()).unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_axod"))
            .arg("serve")
            .arg(&root)
            .arg("--profiles-config")
            .arg(config)
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
    fn restart(&mut self) {
        unsafe {
            libc::kill(self.child.id() as i32, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "Owned daemon stop deadline");
            thread::sleep(Duration::from_millis(25));
        }
        self.child = Command::new(env!("CARGO_BIN_EXE_axod"))
            .arg("serve")
            .arg(&self.root)
            .arg("--profiles-config")
            .arg(self.root.join("profiles.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        while Client::connect(&self.discovery()).is_err() {
            assert!(Instant::now() < deadline, "Owned daemon restart deadline");
            thread::sleep(Duration::from_millis(25));
        }
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
#[test]
fn actual_cli_creates_addressed_metadata_and_reconciles_one_real_pty_launch() {
    let daemon = Daemon::start();
    let target = daemon.target();
    let list = daemon.invoke("axo.workspace.list", json!({"target":target}));
    assert!(list.status.success(), "CLI read failed");
    let list: Value = serde_json::from_slice(&list.stdout).unwrap();
    assert_eq!(list["revision"], 0);
    let host = daemon.call("axo.host.get", json!({"target":target}));
    assert_eq!(host["cloud"]["kind"], "notConfigured");
    assert_eq!(host["daemonVersion"], axod::host::VERSION);
    assert_eq!(host["machineId"], target["machineId"]);
    assert_eq!(host["hostGeneration"], target["hostGeneration"]);
    assert!(!host["hostname"].as_str().unwrap().is_empty());
    assert!(!host["machineType"].as_str().unwrap().is_empty());
    let create = daemon.invoke("axo.workspace.create", json!({"target":target,"commandId":uuid::Uuid::new_v4(),"expectedRevision":0,"directoryId":"fixture","name":"Rust CLI"}));
    assert!(create.status.success(), "CLI metadata mutation failed");
    assert!(
        !daemon.root.join("marker.txt").exists(),
        "Metadata create executed a profile"
    );
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
    let receipt = daemon.invoke(
        "axo.command.get",
        json!({"target":target,"commandId":command}),
    );
    assert!(receipt.status.success(), "CLI receipt read failed");
    let receipt: Value = serde_json::from_slice(&receipt.stdout).unwrap();
    let receipt_runtime: axod::model::RuntimeRef =
        serde_json::from_value(receipt["receipt"]["runtime"].clone())
            .expect("Typed receipt result");
    assert!(
        receipt_runtime == first_runtime,
        "Receipt lost original runtime identity"
    );
}
#[test]
fn actual_cli_preserves_stale_targets_and_never_dumps_request_bodies() {
    let daemon = Daemon::start();
    let mut target = daemon.target();
    target["hostGeneration"] = json!(uuid::Uuid::new_v4());
    let rejected = daemon.invoke("axo.workspace.create", json!({"target":target,"commandId":uuid::Uuid::new_v4(),"expectedRevision":0,"directoryId":"fixture","name":"PAYLOAD_MUST_NOT_BE_DIAGNOSTICS"}));
    assert!(!rejected.status.success());
    assert_eq!(
        String::from_utf8(rejected.stderr).unwrap().trim(),
        "Axo RPC error -32002"
    );
    assert!(rejected.stdout.is_empty());
    assert!(!daemon.root.join("marker.txt").exists());
    let mut client = Client::connect(&daemon.discovery()).unwrap();
    assert_eq!(
        client.call("axo.workspace.list", json!({"target":target})),
        Err(ClientError::Rpc(-32002))
    );
    assert!(
        client
            .call("axo.workspace.list", json!({"target":daemon.target()}))
            .is_ok()
    );
}

#[test]
fn actual_cli_adds_independent_shell_ptys_and_remove_kills_only_the_captured_pane() {
    let mut daemon = Daemon::start();
    let destination = daemon.target();
    let workspace = daemon.call("axo.workspace.create", json!({"target":destination,"commandId":uuid::Uuid::new_v4(),"expectedRevision":0,"directoryId":"fixture","name":"Shell work"}));
    let workspace_id = workspace["workspace"]["workspaceId"].clone();
    let session = daemon.call("axo.session.create", json!({"target":{"machineId":destination["machineId"],"hostGeneration":destination["hostGeneration"],"workspaceId":workspace_id},"commandId":uuid::Uuid::new_v4(),"expectedRevision":1,"name":"Shell session"}));
    let mut target = json!({"machineId":destination["machineId"],"hostGeneration":destination["hostGeneration"],"workspaceId":workspace_id,"sessionId":session["session"]["sessionId"]});
    assert!(
        !daemon.root.join("shell-effects.txt").exists(),
        "Metadata creation launched a shell"
    );
    let command = uuid::Uuid::new_v4();
    let add = json!({"target":target,"commandId":command,"profileId":"shell"});
    let first = daemon.call("axo.session.pane.add", add.clone());
    let repeated = daemon.call("axo.session.pane.add", add.clone());
    assert_eq!(first["receipt"], repeated["receipt"]);
    let second = daemon.call(
        "axo.session.pane.add",
        json!({"target":target,"commandId":uuid::Uuid::new_v4(),"profileId":"shell"}),
    );
    assert!(first["pane"]["paneId"] != second["pane"]["paneId"]);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !fs::read(daemon.root.join("shell-effects.txt")).is_ok_and(|bytes| bytes == b"TTYTTY") {
        assert!(Instant::now() < deadline, "Owned shell TTY effect deadline");
        thread::sleep(Duration::from_millis(25));
    }
    let live = daemon.call("axo.session.get", json!({"target":target}));
    assert!(
        live["session"]["shellPanes"].as_array().unwrap().len() == 2
            && live["session"]["pi"]["chatId"].is_null()
    );
    let mut stale = first["pane"]["runtime"].clone();
    stale["runtime_generation"] = json!(uuid::Uuid::new_v4());
    let rejected = daemon.invoke("axo.session.pane.remove", json!({"target":target,"commandId":uuid::Uuid::new_v4(),"paneId":first["pane"]["paneId"],"runtime":stale}));
    assert!(!rejected.status.success(), "Wrong runtime removed a shell");
    let theft = daemon.invoke("axo.runtime.startApproved", json!({"target":{"machineId":target["machineId"],"hostGeneration":target["hostGeneration"],"sessionId":target["sessionId"],"paneId":first["pane"]["paneId"]},"commandId":uuid::Uuid::new_v4(),"profileId":"fixture"}));
    assert!(
        !theft.status.success(),
        "Generic launch replaced a managed shell pane"
    );
    let remove_command = uuid::Uuid::new_v4();
    let remove = json!({"target":target,"commandId":remove_command,"paneId":first["pane"]["paneId"],"runtime":first["pane"]["runtime"]});
    let removed = daemon.call("axo.session.pane.remove", remove.clone());
    assert!(
        removed["receipt"]["disposition"]["kind"] == "removed"
            && removed["pane"]["terminal"]["process"]["kind"] == "exited"
    );
    assert_eq!(
        daemon.call("axo.session.pane.remove", remove)["receipt"],
        removed["receipt"]
    );
    let current = daemon.call("axo.session.get", json!({"target":target}));
    let panes = current["session"]["shellPanes"].as_array().unwrap();
    assert!(
        panes.len() == 1
            && panes[0]["paneId"] == second["pane"]["paneId"]
            && panes[0]["terminal"]["process"]["kind"] == "running",
        "Removal stopped or retargeted the sibling"
    );
    assert_eq!(
        daemon.call("axo.session.pane.add", add)["receipt"],
        first["receipt"],
        "Reconciliation replayed a removed pane's launch"
    );
    daemon.restart();
    target["hostGeneration"] = daemon.target()["hostGeneration"].clone();
    let stopped = daemon.call("axo.session.get", json!({"target":target}));
    assert!(stopped["session"]["shellPanes"][0]["terminal"]["process"]["kind"] == "exited");
    assert!(
        fs::read(daemon.root.join("shell-effects.txt")).unwrap() == b"TTYTTY",
        "Restart replayed shells"
    );
    let historical = daemon.call("axo.session.pane.remove", json!({"target":target,"commandId":uuid::Uuid::new_v4(),"paneId":second["pane"]["paneId"],"runtime":second["pane"]["runtime"]}));
    assert!(historical["receipt"]["disposition"]["kind"] == "removed");
    assert!(
        daemon.call("axo.session.get", json!({"target":target}))["session"]["shellPanes"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        daemon.call(
            "axo.command.get",
            json!({"target":daemon.target(),"commandId":remove_command})
        )["receipt"]["kind"]
            == "pane"
    );
}
