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
        fs::write(&config, serde_json::to_vec(&json!({"profiles":{"fixture":{"directory":root,"argv":["/bin/sh","-c","printf accepted > marker.txt"]}}})).unwrap()).unwrap();
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
