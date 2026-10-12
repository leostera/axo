//! Actual ambient Pi admission for local-folder and workspace-free home sessions.
#[path = "support/model_fixture.rs"]
mod model_fixture;
use axod::client::Client;
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct OwnedDaemon(Child);
impl Drop for OwnedDaemon {
    fn drop(&mut self) {
        if self.0.try_wait().unwrap().is_none() {
            unsafe {
                libc::kill(self.0.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(5);
            while self.0.try_wait().unwrap().is_none() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(20));
            }
            if self.0.try_wait().unwrap().is_none() {
                let _ = self.0.kill();
            }
            let _ = self.0.wait();
        }
    }
}
fn private_json(path: &Path, value: Value) {
    fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn rpc(discovery: &Path, method: &str, params: Value) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_axo"))
        .args(["rpc"])
        .arg(discovery)
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
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "Public {method} failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    serde_json::from_slice(&result.stdout).unwrap()
}
fn wait_until(mut test: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !test() {
        assert!(Instant::now() < deadline, "Owned fixture deadline");
        thread::sleep(Duration::from_millis(25));
    }
}
#[cfg(target_os = "macos")]
#[test]
fn production_helper_policy_materializes_fresh_home_graph_without_client_starts_or_pi_config() {
    let model = model_fixture::Fixture::new();
    let root = model.root();
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let contents = root.join("Contents");
    let helpers = contents.join("Helpers");
    let agent = root.join("agent");
    for directory in [&helpers, &agent] {
        fs::create_dir_all(directory).unwrap();
    }
    fs::set_permissions(&agent, fs::Permissions::from_mode(0o700)).unwrap();
    let helper = helpers.join("axod");
    fs::copy(env!("CARGO_BIN_EXE_axod"), &helper).unwrap();
    let adapter = contents.join("Resources/pi-axo/index.mjs");
    assert!(
        Command::new("node")
            .arg(repo.join("scripts/build-pi-adapter.mjs"))
            .arg(&adapter)
            .status()
            .unwrap()
            .success()
    );
    private_json(
        &agent.join("settings.json"),
        json!({
            "quietStartup":true,"compaction":{"enabled":false},"retry":{"enabled":false},"packages":[],
            "defaultProvider":"axo-interactive-fixture","defaultModel":"fixture","enableInstallTelemetry":false,
            "extensions":[repo.join("pi-axo/tests/fixtures/provider.ts"),"-builtin:mcp","-builtin:llama.cpp","-builtin:codemode","-builtin:tool-search"]
        }),
    );
    let provider = root.join("provider.json");
    private_json(&provider, json!({"baseUrl":model.url()}));
    // This owned HOME has its own startup file. Launchd's minimal PATH cannot find
    // ambient Pi or its Node shebang until serve-user captures the login-shell PATH.
    let path = std::env::var("PATH").unwrap().replace('\'', "'\\''");
    let startup = format!("export PATH='{path}'\n");
    for name in [".zprofile", ".bash_profile", ".profile"] {
        let file = root.join(name);
        fs::write(&file, &startup).unwrap();
        fs::set_permissions(file, fs::Permissions::from_mode(0o600)).unwrap();
    }
    let mut daemon = OwnedDaemon(
        Command::new(&helper)
            .arg("serve-user")
            .env("HOME", root)
            .env("PATH", "/usr/bin:/bin")
            .env("PI_CODING_AGENT_DIR", &agent)
            .env("PI_AXO_INTERACTIVE_FIXTURE_CONFIG", &provider)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
    );
    let discovery = root.join("Library/Application Support/Axo/Axod/local-endpoint.json");
    wait_until(|| {
        assert!(daemon.0.try_wait().unwrap().is_none());
        Client::connect(&discovery).is_ok()
    });
    let descriptor = Client::connect(&discovery).unwrap().discovery;
    let target =
        json!({"machineId":descriptor.machine_id,"hostGeneration":descriptor.host_generation});
    let bootstrap = rpc(&discovery, "axo.state.get", json!({"target":target}));
    assert_eq!(bootstrap["value"]["backendCompleteCreation"], true);
    let mut source = target;
    source["storeGeneration"] = bootstrap["storeGeneration"].clone();
    let command = uuid::Uuid::new_v4();
    let created = rpc(
        &discovery,
        "axo.state.session.create",
        json!({"target":source,"commandId":command,"expectedRevision":0,"workspaceId":null,"name":"Default home"}),
    );
    let original = created["value"]["operation"].clone();
    assert_eq!(original["kind"], "createStandalone");
    assert!(original["accepted"]["graph"]["session"]["workspaceId"].is_null());
    assert_eq!(
        original["accepted"]["graph"]["panes"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    wait_until(|| {
        assert!(daemon.0.try_wait().unwrap().is_none());
        let state = rpc(
            &discovery,
            "axo.state.operation.get",
            json!({"target":source,"commandId":command}),
        );
        assert_eq!(state["value"]["operation"], original);
        if state["value"]["session"]["readiness"] != "ready" {
            return false;
        }
        let panes = state["value"]["session"]["panes"].as_array().unwrap();
        assert_eq!(panes.len(), 2);
        assert!(
            panes
                .iter()
                .all(|pane| pane["availability"] == "live" && pane["terminal"].is_object())
        );
        true
    });
    let selected = root.join("central-selected");
    fs::create_dir(&selected).unwrap();
    fs::set_permissions(&selected, fs::Permissions::from_mode(0o700)).unwrap();
    let workspace_command = uuid::Uuid::new_v4();
    let workspace = rpc(
        &discovery,
        "axo.state.workspace.create",
        json!({"target":source,"commandId":workspace_command,"expectedRevision":1,"name":"Selected","directoryPath":selected}),
    );
    assert_eq!(workspace["value"]["operation"]["kind"], "createWorkspace");
    let captured = workspace["value"]["operation"].clone();
    wait_until(|| {
        let state = rpc(
            &discovery,
            "axo.state.operation.get",
            json!({"target":source,"commandId":workspace_command}),
        );
        assert_eq!(state["value"]["operation"], captured);
        state["value"]["session"]["readiness"] == "ready"
    });
    assert_eq!(
        model.requests(),
        0,
        "Metadata and admission must not replay or execute a prompt"
    );
    assert!(
        discovery
            .parent()
            .unwrap()
            .join("CentralSessions/session-state.sqlite3")
            .is_file()
    );
    assert!(
        !discovery
            .parent()
            .unwrap()
            .join("work-records.json")
            .exists()
    );
    assert!(
        !root
            .join("Library/Application Support/Axo/Axod/pi.json")
            .exists()
    );
}
