//! Rust owns disposable daemon/Pi fixtures. The Swift child uses production native
//! coordinator/view/terminal code, with compile-only service/history isolation.
use axod::{ambient_pi::AmbientPi, client::Client};
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct Owned {
    root: PathBuf,
    child: Child,
}
impl Drop for Owned {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            // Only the still-unreaped child of this fixture, never discovered PIDs.
            unsafe {
                libc::kill(self.child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(5);
            while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(20));
            }
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn private_file(path: &Path, value: &Value) {
    fs::write(path, serde_json::to_vec(value).unwrap()).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    assert!(
        (3..=4).contains(&args.len()),
        "Usage: native-workbench-fixture native-check helper [repetitions]"
    );
    let repetitions = args.get(3).map_or(1, |value| {
        let value = value.to_str().expect("ASCII repetition count");
        assert!(!value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()));
        let count: usize = value.parse().expect("Bounded repetition count");
        assert!((1..=20).contains(&count), "Repetitions must be 1–20");
        count
    });
    let check = PathBuf::from(&args[1]);
    let helper = PathBuf::from(&args[2]);
    assert!(check.is_absolute() && check.is_file() && helper.is_absolute() && helper.is_file());
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let packaged_adapter = helper
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("Resources/pi-axo/index.mjs");
    let adapter = if packaged_adapter.is_file() {
        packaged_adapter
    } else {
        repo.join("pi-axo/index.ts")
    };
    let ambient =
        AmbientPi::find(None).expect("Actual ambient Pi required; no repository fallback");
    for repetition in 1..=repetitions {
        println!("Owned native campaign repetition={repetition}/{repetitions}");
        for mode in ["delayed", "unavailable", "automatic", "pending"] {
            let temporary =
                std::env::temp_dir().join(format!("axo-native-workbench-{}", uuid::Uuid::new_v4()));
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&temporary)
                .unwrap();
            let root = fs::canonicalize(temporary).unwrap();
            let state = root.join("state");
            let home = root.join("home");
            let sessions = root.join("sessions");
            let agent = root.join("agent");
            for path in [&state, &home, &sessions, &agent] {
                fs::DirBuilder::new().mode(0o700).create(path).unwrap();
            }
            // A synthetic login-shell output marker lets the native check observe
            // the actual presentation stream before its one intentional input.
            let login = home.join(".profile");
            fs::write(&login, b"printf 'axo-native-shell-prompt\\n'\n").unwrap();
            fs::set_permissions(&login, fs::Permissions::from_mode(0o600)).unwrap();
            private_file(&root.join("profiles.json"), &json!({"profiles":{}}));
            let executable = if mode == "unavailable" {
                root.join("missing-pi")
            } else {
                ambient.executable.clone()
            };
            let arguments = if mode == "unavailable" {
                json!(["--no-approve"])
            } else {
                json!([
                    "--no-approve",
                    "--extension",
                    repo.join("pi-axo/tests/fixtures/native-start-delay.ts"),
                    "--model",
                    "axo-native-fixture/fixture"
                ])
            };
            private_file(
                &root.join("pi.json"),
                &json!({"extension":adapter,"profiles":{},"local":{
                    "sessionDirectory":sessions,"executable":executable,"arguments":arguments
                }}),
            );
            let diagnostic = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(root.join("daemon.stderr"))
                .unwrap();
            let child = Command::new(&helper)
                .arg("serve")
                .arg(&state)
                .arg("--profiles-config")
                .arg(root.join("profiles.json"))
                .arg("--pi-config")
                .arg(root.join("pi.json"))
                .env("HOME", &home)
                .env("SHELL", "/bin/sh")
                .env("PI_CODING_AGENT_DIR", &agent)
                .env_remove("ZDOTDIR")
                .env_remove("ENV")
                .env_remove("BASH_ENV")
                .stdout(Stdio::null())
                .stderr(Stdio::from(diagnostic))
                .spawn()
                .unwrap();
            let mut owned = Owned { root, child };
            let discovery = state.join("local-endpoint.json");
            let deadline = Instant::now() + Duration::from_secs(6);
            while Client::connect(&discovery).is_err() {
                assert!(
                    owned.child.try_wait().unwrap().is_none(),
                    "Owned daemon startup failed"
                );
                assert!(Instant::now() < deadline, "Owned daemon discovery deadline");
                thread::sleep(Duration::from_millis(20));
            }
            let mut native = Command::new(&check)
                .arg(&state)
                .arg(&helper)
                .arg(&home)
                .arg(mode)
                .spawn()
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(45);
            let status = loop {
                if let Some(status) = native.try_wait().unwrap() {
                    break status;
                }
                if Instant::now() >= deadline {
                    let _ = native.kill();
                    let _ = native.wait();
                    panic!("Owned native workbench deadline");
                }
                thread::sleep(Duration::from_millis(20));
            };
            assert!(status.success(), "Owned native workbench check failed");
            let mut client = Client::connect(&discovery).unwrap();
            let target = json!({"machineId":client.discovery.machine_id,"hostGeneration":client.discovery.host_generation});
            let catalog = client
                .call("axo.session.list", json!({"target":target}))
                .unwrap();
            assert_eq!(
                catalog["sessions"].as_array().unwrap().len(),
                if mode == "pending" { 0 } else { 1 },
                "Native restore/reconnect/later-launch created duplicate work"
            );
            let runtimes = client
                .call("axo.runtime.list", json!({"target":target}))
                .unwrap();
            let terminals = runtimes["terminals"].as_array().unwrap();
            let expected = match mode {
                "pending" => 0,
                "unavailable" => 1,
                _ => 2,
            };
            assert_eq!(terminals.len(), expected);
            assert!(
                terminals
                    .iter()
                    .all(|terminal| terminal["process"]["kind"] == "running"),
                "Presentation disposal stopped managed work"
            );
            if mode == "pending" {
                assert!(!home.join("native-shell-ready").exists());
            } else {
                assert_eq!(
                    fs::read(home.join("native-shell-ready")).unwrap(),
                    b"native-shell-ready"
                );
            }
            println!(
                "PASS: owned native workflow ({mode}); exact catalog/runtime counts, non-destructive disposal, no duplicate work"
            );
            drop(owned);
        }
    }
}
