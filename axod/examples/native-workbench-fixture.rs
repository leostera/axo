//! Rust owns disposable daemon/Pi fixtures. The Swift child uses production native
//! coordinator/view/terminal code, with compile-only service/history isolation.
#[path = "../tests/support/model_fixture.rs"]
mod model_fixture;
use axod::{ambient_pi::AmbientPi, client::Client};
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
        process::ExitStatusExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
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
struct NativeChild(Child);
impl Drop for NativeChild {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}
fn native(check: &Path, state: &Path, helper: &Path, home: &Path, mode: &str) -> NativeChild {
    NativeChild(
        Command::new(check)
            .arg(state)
            .arg(helper)
            .arg(home)
            .arg(mode)
            .spawn()
            .unwrap(),
    )
}
fn finish_native(child: &mut NativeChild, seconds: u64) -> ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(status) = child.0.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "Owned native workbench deadline");
        thread::sleep(Duration::from_millis(20));
    }
}
fn runtime_identities(discovery: &Path) -> Value {
    let mut client = Client::connect(discovery).unwrap();
    let target = json!({"machineId":client.discovery.machine_id,"hostGeneration":client.discovery.host_generation});
    let result = client
        .call("axo.runtime.list", json!({"target":target}))
        .unwrap();
    let terminals = result["terminals"].as_array().unwrap();
    assert_eq!(terminals.len(), 2);
    assert!(terminals.iter().all(|item| item["runtime"].is_object()));
    json!(
        terminals
            .iter()
            .map(|item| item["runtime"].clone())
            .collect::<Vec<_>>()
    )
}
fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    assert!(
        (3..=5).contains(&args.len()),
        "Usage: native-workbench-fixture native-check helper [repetitions] [all|chat|drafts]"
    );
    let repetitions = args.get(3).map_or(1, |value| {
        let value = value.to_str().expect("ASCII repetition count");
        assert!(!value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()));
        let count: usize = value.parse().expect("Bounded repetition count");
        assert!((1..=20).contains(&count), "Repetitions must be 1–20");
        count
    });
    let only = match args.get(4) {
        None => None,
        Some(value) => match value.to_str() {
            Some("all") => None,
            Some("chat") => Some("chat"),
            Some("drafts") => Some("drafts"),
            _ => panic!("Owned campaign mode must be all, chat or drafts"),
        },
    };
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
        for mode in [
            "delayed",
            "unavailable",
            "automatic",
            "pending",
            "panes",
            "chat",
            "storage",
            "drafts",
        ] {
            if only.is_some_and(|only| mode != only) {
                continue;
            }
            let model = matches!(mode, "chat" | "drafts").then(model_fixture::Fixture::new);
            let provider = model.as_ref().map(|model| {
                let path = model.root().join("provider.json");
                private_file(&path, &json!({"baseUrl":model.url()}));
                path
            });
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
            if mode == "storage" {
                let drafts = state.join("chat-drafts");
                fs::DirBuilder::new().mode(0o700).create(&drafts).unwrap();
                let file = drafts.join("drafts.bin");
                fs::write(&file, b"opaque-owned-draft").unwrap();
                fs::set_permissions(file, fs::Permissions::from_mode(0o600)).unwrap();
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
            } else if matches!(mode, "chat" | "drafts") {
                json!([
                    "--no-approve",
                    "--offline",
                    "--no-skills",
                    "--no-themes",
                    "--no-context-files",
                    "--no-prompt-templates",
                    "--extension",
                    repo.join("pi-axo/tests/fixtures/native-start-delay.ts"),
                    "--extension",
                    repo.join("pi-axo/tests/fixtures/provider.ts"),
                    "--extension",
                    repo.join("pi-axo/tests/fixtures/native-chat-events.ts"),
                    "--model",
                    "axo-interactive-fixture/fixture",
                    "--tools",
                    "bash,fixture_ask,axo_ask,axo_set_title"
                ])
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
            let mut command = Command::new(&helper);
            if let Some(provider) = &provider {
                command.env("PI_AXO_INTERACTIVE_FIXTURE_CONFIG", provider);
            }
            let child = command
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
            let first_phase = if mode == "drafts" { "draft-exit" } else { mode };
            let mut first = native(&check, &state, &helper, &home, first_phase);
            let status = finish_native(&mut first, if mode == "chat" { 80 } else { 45 });
            if !status.success()
                && let Some(model) = &model
            {
                eprintln!(
                    "Owned native model failure diagnostic: requestCount={}",
                    model.requests()
                );
            }
            assert!(status.success(), "Owned native workbench check failed");
            if mode == "drafts" {
                let originals = runtime_identities(&discovery);
                let mut crashing = native(&check, &state, &helper, &home, "draft-crash");
                let ready = home.join("native-draft-crash-ready");
                let deadline = Instant::now() + Duration::from_secs(20);
                while !ready.exists() {
                    assert!(
                        crashing.0.try_wait().unwrap().is_none(),
                        "Owned draft crash client exited before checkpoint"
                    );
                    assert!(
                        Instant::now() < deadline,
                        "Owned draft crash checkpoint deadline"
                    );
                    thread::sleep(Duration::from_millis(20));
                }
                assert_eq!(fs::read(ready).unwrap(), b"ready");
                assert!(
                    crashing.0.try_wait().unwrap().is_none(),
                    "Owned crash client no longer running"
                );
                // Exactly this still-unreaped owned client, not daemon/Pi/PIDs
                // obtained from an inventory. Accepted work is left running.
                let heartbeat = home.join("native-draft-heartbeat");
                let before_crash = fs::metadata(&heartbeat).unwrap().len();
                assert!(before_crash > 0 && before_crash <= 800);
                crashing.0.kill().unwrap();
                let killed = crashing.0.wait().unwrap();
                assert_eq!(killed.signal(), Some(libc::SIGKILL));
                let after_crash = fs::metadata(&heartbeat).unwrap().len();
                assert!(after_crash >= before_crash && after_crash < 800);
                let progress_deadline = Instant::now() + Duration::from_secs(3);
                while fs::metadata(&heartbeat).unwrap().len() <= after_crash {
                    assert!(
                        Instant::now() < progress_deadline,
                        "Accepted shell work did not progress after owned client crash"
                    );
                    thread::sleep(Duration::from_millis(20));
                }
                assert_eq!(runtime_identities(&discovery), originals);
                let mut recovery = native(&check, &state, &helper, &home, "draft-recover");
                assert!(
                    finish_native(&mut recovery, 30).success(),
                    "Owned draft recovery client failed"
                );
                assert_eq!(runtime_identities(&discovery), originals);
                println!(
                    "PASS: Rust-owned separate native client exit/crash/recovery keeps exact daemon PTYs and progressing accepted shell work, never replaces a pending ticket or calls the model; not Finder/IME/power-loss acceptance"
                );
            }
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
                "panes" => 4,
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
            if let Some(model) = &model {
                assert_eq!(
                    model.requests(),
                    if mode == "chat" { 8 } else { 0 },
                    "Owned native model request count; no replay or duplicate execution"
                );
                if mode == "chat" {
                    assert_eq!(fs::read(home.join("marker.txt")).unwrap(), b"Pi-owned-tool");
                    assert_eq!(
                        fs::read(home.join("native-steer-marker.txt")).unwrap(),
                        b"Native-steered"
                    );
                }
            }
            println!(
                "PASS: owned native workflow ({mode}); exact catalog/runtime counts, non-destructive disposal, no duplicate work"
            );
            drop(owned);
        }
    }
}
