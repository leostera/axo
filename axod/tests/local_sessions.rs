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
fn admit_and_execute(
    discovery: &Path,
    destination: &Value,
    session: &Value,
    directory: &Path,
) -> Value {
    let mut target = destination.clone();
    target["workspaceId"] = session["workspaceId"].clone();
    target["sessionId"] = session["sessionId"].clone();
    target["paneId"] = session["pi"]["paneId"].clone();
    let params =
        json!({"target":target,"commandId":uuid::Uuid::new_v4(),"persistence":{"kind":"fresh"}});
    let start = rpc(discovery, "axo.session.start", params.clone());
    assert_eq!(start["admission"], "ready");
    let chat = start["chat"].clone();
    assert_eq!(chat["workspaceId"], session["workspaceId"]);
    assert_eq!(
        rpc(discovery, "axo.session.start", params)["chat"],
        chat,
        "Reconciliation started another writer"
    );
    let send = rpc(
        discovery,
        "axo.chat.sendMessage",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"text":"TITLE_AND_ACTUAL_TOOL in captured directory"}),
    );
    assert_eq!(send["receipt"]["disposition"]["kind"], "dispatched");
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let state = rpc(discovery, "axo.chat.get", json!({"target":chat}));
        if directory.join("marker.txt").exists() && state["busy"] == false {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Owned fixture did not settle: marker={}, busy={}, recovery={}, uiWaits={}",
            directory.join("marker.txt").exists(),
            state["busy"],
            state["recovery"],
            state["uiWaits"]
        );
        thread::sleep(Duration::from_millis(40));
    }
    assert_eq!(
        fs::read_to_string(directory.join("marker.txt")).unwrap(),
        "Pi-owned-tool"
    );
    let mut named = destination.clone();
    named["workspaceId"] = session["workspaceId"].clone();
    named["sessionId"] = session["sessionId"].clone();
    assert_eq!(
        rpc(discovery, "axo.session.get", json!({"target":named}))["session"]["pi"]["title"],
        "Axo Workbench"
    );
    let history = rpc(discovery, "axo.chat.history", json!({"target":chat}));
    assert!(
        history.to_string().contains("toolResult"),
        "Actual tool evidence missing from Pi history"
    );
    chat
}
#[test]
fn actual_cli_starts_home_and_selected_folder_sessions_without_profiles() {
    let model = model_fixture::Fixture::new();
    let root = model.root();
    let state = root.join("state");
    let sessions = root.join("sessions");
    let agent = root.join("agent");
    let selected = root.join("selected-folder");
    for directory in [&state, &sessions, &agent, &selected] {
        fs::create_dir(directory).unwrap();
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let selected = fs::canonicalize(selected).unwrap();
    private_json(
        &agent.join("settings.json"),
        json!({"quietStartup":true,"compaction":{"enabled":false},"retry":{"enabled":false},"packages":[]}),
    );
    let provider = root.join("provider.json");
    private_json(&provider, json!({"baseUrl":model.url()}));
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let adapter = root.join("adapter.mjs");
    assert!(
        Command::new("node")
            .arg(repo.join("scripts/build-pi-adapter.mjs"))
            .arg(&adapter)
            .status()
            .unwrap()
            .success()
    );
    let policy = root.join("pi.json");
    private_json(
        &policy,
        json!({"extension":adapter,"profiles":{},"local":{"sessionDirectory":sessions,"arguments":[
            "--no-extensions","--no-skills","--no-themes","--no-context-files","--no-prompt-templates","--no-approve","--offline",
            "--extension",repo.join("pi-axo/tests/fixtures/provider.ts"),"--provider","axo-interactive-fixture","--model","fixture","--tools","bash,axo_ask,axo_set_title"
        ]}}),
    );
    let mut daemon = OwnedDaemon(
        Command::new(env!("CARGO_BIN_EXE_axod"))
            .arg("serve")
            .arg(&state)
            .arg("--pi-config")
            .arg(&policy)
            .env("HOME", root)
            .env("PI_CODING_AGENT_DIR", &agent)
            .env("PI_AXO_INTERACTIVE_FIXTURE_CONFIG", &provider)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
    );
    let discovery = state.join("local-endpoint.json");
    wait_until(|| {
        assert!(daemon.0.try_wait().unwrap().is_none());
        Client::connect(&discovery).is_ok()
    });
    let descriptor = Client::connect(&discovery).unwrap().discovery;
    let target =
        json!({"machineId":descriptor.machine_id,"hostGeneration":descriptor.host_generation});
    let home = rpc(
        &discovery,
        "axo.session.create",
        json!({"target":target,"commandId":uuid::Uuid::new_v4(),"expectedRevision":0,"name":"Home"}),
    );
    assert!(home["session"]["workspaceId"].is_null());
    assert_eq!(
        rpc(&discovery, "axo.workspace.list", json!({"target":target}))["workspaces"],
        json!([])
    );
    assert_eq!(model.requests(), 0, "Metadata creation executed work");
    admit_and_execute(&discovery, &target, &home["session"], root);
    let workspace = rpc(
        &discovery,
        "axo.workspace.createLocal",
        json!({"target":target,"commandId":uuid::Uuid::new_v4(),"expectedRevision":1,"directoryPath":selected,"name":"Selected","initialSessionName":"Project"}),
    );
    assert_eq!(
        workspace["revision"], 2,
        "Workspace and first session must commit together"
    );
    assert_eq!(
        workspace["session"]["workspaceId"],
        workspace["workspace"]["workspaceId"]
    );
    admit_and_execute(&discovery, &target, &workspace["session"], &selected);
    assert_eq!(
        rpc(&discovery, "axo.session.list", json!({"target":target}))["sessions"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let version =
        rpc(&discovery, "axo.host.get", json!({"target":target}))["daemonVersion"].clone();
    let handoff = rpc(
        &discovery,
        "axo.host.prepareUpgrade",
        json!({"target":target,"plan":{
            "handoffId":uuid::Uuid::new_v4(),"expectedVersion":version,"replacementVersion":"0.1.0 (next)",
            "replacementBuildNumber":9_007_199_254_740_991_u64
        }}),
    );
    assert_eq!(
        handoff["disposition"], "deferredActiveWork",
        "Upgrade retired an owned Pi"
    );
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
