//! Bounded full-Ghostty fixture with Rust-owned daemon/process/state lifetimes.
//! The Swift test owns only an offscreen window and transport frontend surface.
use axod::{client::Client, model::RuntimeRef};
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct Fixture {
    root: PathBuf,
    daemon: Child,
    cli: PathBuf,
}
impl Fixture {
    fn start(helper: &Path, cli: PathBuf) -> Self {
        let root =
            std::env::temp_dir().join(format!("axo-native-surface-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let config = root.join("profiles.json");
        fs::write(&config, serde_json::to_vec(&json!({"profiles":{"terminal":{"directory":root,"argv":["/bin/sh","-c","stty -echo; printf surface-ready; while IFS= read -r line; do printf '%s\\n' \"$line\"; stty size > geometry.txt; done"]}}})).unwrap()).unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
        let daemon = Command::new(helper)
            .arg("serve")
            .arg(&root)
            .arg("--profiles-config")
            .arg(config)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut fixture = Self { root, daemon, cli };
        let deadline = Instant::now() + Duration::from_secs(5);
        while Client::connect(&fixture.discovery()).is_err() {
            assert!(
                fixture.daemon.try_wait().unwrap().is_none(),
                "Owned daemon failed"
            );
            assert!(Instant::now() < deadline, "Owned discovery deadline");
            thread::sleep(Duration::from_millis(10));
        }
        fixture
    }
    fn discovery(&self) -> PathBuf {
        self.root.join("local-endpoint.json")
    }
    fn call(&self, method: &str, params: Value) -> Value {
        let mut child = Command::new(&self.cli)
            .arg("rpc")
            .arg(self.discovery())
            .arg(method)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(&params).unwrap())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success(), "Owned public CLI call failed");
        serde_json::from_slice(&output.stdout).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if self.daemon.try_wait().ok().flatten().is_none() {
            // The still-owned unreaped Child, never an observed historical PID.
            unsafe {
                libc::kill(self.daemon.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(5);
            while self.daemon.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            let _ = self.daemon.kill();
            let _ = self.daemon.wait();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn uuid_argument(id: impl serde::Serialize) -> String {
    serde_json::to_value(id)
        .unwrap()
        .as_str()
        .expect("Typed UUID")
        .to_owned()
}
fn main() {
    let arguments: Vec<_> = std::env::args_os().collect();
    assert_eq!(
        arguments.len(),
        4,
        "Expected native-check, helper and CLI paths"
    );
    let helper = PathBuf::from(&arguments[2]);
    let fixture = Fixture::start(&helper, PathBuf::from(&arguments[3]));
    let discovery = Client::connect(&fixture.discovery()).unwrap().discovery;
    let target =
        json!({"machineId":discovery.machine_id,"hostGeneration":discovery.host_generation});
    let command = uuid::Uuid::new_v4();
    let started = fixture.call("axo.runtime.startApproved", json!({"target":{"machineId":discovery.machine_id,"hostGeneration":discovery.host_generation,"sessionId":uuid::Uuid::new_v4(),"paneId":uuid::Uuid::new_v4()},"commandId":command,"profileId":"terminal"}));
    let runtime: RuntimeRef =
        serde_json::from_value(started["terminal"]["runtime"].clone()).unwrap();
    let mut native = Command::new(&arguments[1])
        .arg(&helper)
        .arg(&fixture.root)
        .arg(uuid_argument(discovery.machine_id))
        .arg(uuid_argument(runtime.host_generation))
        .arg(uuid_argument(runtime.target.session_id))
        .arg(uuid_argument(runtime.target.pane_id))
        .arg(uuid_argument(runtime.runtime_generation))
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(25);
    let status = loop {
        if let Some(status) = native.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = native.kill();
            let _ = native.wait();
            panic!("Native fixture deadline");
        }
        thread::sleep(Duration::from_millis(10));
    };
    assert!(status.success(), "Owned native surface fixture failed");
    let receipt = fixture.call(
        "axo.command.get",
        json!({"target":target,"commandId":command}),
    );
    let captured: RuntimeRef =
        serde_json::from_value(receipt["receipt"]["runtime"].clone()).unwrap();
    assert!(
        runtime == captured,
        "Frontend disposal changed accepted runtime"
    );
    let current = fixture.call("axo.runtime.list", json!({"target":target}));
    let terminals = current["terminals"].as_array().unwrap();
    assert_eq!(
        terminals.len(),
        1,
        "Presentation created extra managed runtimes"
    );
    let still_owned: RuntimeRef = serde_json::from_value(terminals[0]["runtime"].clone()).unwrap();
    assert!(
        runtime == still_owned,
        "Presentation retargeted accepted work"
    );
    assert_eq!(terminals[0]["process"]["kind"], "running");
    assert_eq!(terminals[0]["attached"], false);
    println!(
        "PASS: full native Ghostty/daemon PTY fixture; exact accepted runtime survives frontend disposal (component evidence, not workbench acceptance)"
    );
}
