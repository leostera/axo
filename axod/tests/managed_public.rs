//! The acceptance path: actual axo -> public WebSocket -> axod serve -> ambient Pi TUI.
#[path = "support/model_fixture.rs"]
mod model_fixture;
#[path = "support/worker_fixture.rs"]
mod worker_fixture;
use axod::client::Client;
use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
struct Daemon {
    child: Child,
}
impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
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
    }
}
fn private_json(path: &std::path::Path, value: Value) {
    fs::write(path, serde_json::to_vec(&value).unwrap()).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn cli_output(discovery: &std::path::Path, method: &str, params: Value) -> std::process::Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_axo"))
        .arg("rpc")
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
    child.wait_with_output().unwrap()
}
fn cli_error(discovery: &std::path::Path, method: &str, params: Value, code: i32) {
    let output = cli_output(discovery, method, params);
    assert!(
        !output.status.success() && output.stdout.is_empty(),
        "Expected sanitized public CLI rejection"
    );
    assert_eq!(
        String::from_utf8(output.stderr).unwrap().trim(),
        format!("Axo RPC error {code}")
    );
}
fn cli(discovery: &std::path::Path, method: &str, params: Value) -> Value {
    let output = cli_output(discovery, method, params);
    assert!(
        output.status.success(),
        "Public CLI method {method} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}
#[test]
fn actual_cli_starts_managed_tui_sends_real_message_and_reads_canonical_tool_evidence() {
    let model = model_fixture::Fixture::new();
    let root = model.root();
    let cwd = root.join("work");
    let state = root.join("owner");
    let sessions = root.join("sessions");
    let agent = root.join("agent");
    for directory in [&cwd, &state, &sessions, &agent] {
        fs::create_dir(directory).unwrap();
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).unwrap();
    }
    private_json(
        &agent.join("settings.json"),
        json!({"quietStartup":true,"compaction":{"enabled":false},"retry":{"enabled":false},"packages":[]}),
    );
    let provider = root.join("provider.json");
    private_json(&provider, json!({"baseUrl":model.url()}));
    let profiles = root.join("profiles.json");
    private_json(
        &profiles,
        json!({"profiles":{"work":{"directory":cwd,"argv":["/bin/sh"]}}}),
    );
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap();
    let mut worker = worker_fixture::Worker::new(repo, root);
    let relay = worker.relay.clone();
    let pi = root.join("pi.json");
    private_json(
        &pi,
        json!({"extension":repo.join("pi-axo/index.ts"),"profiles":{"work":{"directory":cwd,"sessionDirectory":sessions,"arguments":["--no-extensions","--no-skills","--no-themes","--no-context-files","--no-prompt-templates","--no-approve","--offline","--extension",repo.join("pi-axo/tests/fixtures/provider.ts"),"--provider","axo-interactive-fixture","--model","fixture","--tools","bash,fixture_ask,axo_ask"]}}}),
    );
    let spawn = || {
        let child = Command::new(env!("CARGO_BIN_EXE_axod"))
            .arg("serve")
            .arg(&state)
            .arg("--profiles-config")
            .arg(&profiles)
            .arg("--pi-config")
            .arg(&pi)
            .arg("--relay-config")
            .arg(&relay)
            .env("HOME", root)
            .env("PI_CODING_AGENT_DIR", &agent)
            .env("PI_AXO_INTERACTIVE_FIXTURE_CONFIG", &provider)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        Daemon { child }
    };
    let mut daemon = spawn();
    let discovery = state.join("local-endpoint.json");
    let deadline = Instant::now() + Duration::from_secs(5);
    let descriptor = loop {
        if let Ok(client) = Client::connect(&discovery) {
            break client.discovery;
        }
        assert!(
            daemon.child.try_wait().unwrap().is_none(),
            "Owned daemon startup failed"
        );
        assert!(Instant::now() < deadline, "Owned discovery deadline");
        thread::sleep(Duration::from_millis(25));
    };
    let destination =
        json!({"machineId":descriptor.machine_id,"hostGeneration":descriptor.host_generation});
    let directories = cli(
        &discovery,
        "axo.workspace.directories",
        json!({"target":destination}),
    );
    assert_eq!(directories["directories"], json!([{"directoryId":"work","name":"work"}]));
    assert!(!directories.to_string().contains(cwd.to_str().unwrap()));
    let workspace = cli(
        &discovery,
        "axo.workspace.create",
        json!({"target":destination,"commandId":uuid::Uuid::new_v4(),"expectedRevision":0,"directoryId":"work","name":"Public Pi"}),
    );
    let mut parent = destination.clone();
    parent["workspaceId"] = workspace["workspace"]["workspaceId"].clone();
    let created = cli(
        &discovery,
        "axo.session.create",
        json!({"target":parent,"commandId":uuid::Uuid::new_v4(),"expectedRevision":1,"name":"First actual Pi"}),
    );
    parent["sessionId"] = created["session"]["sessionId"].clone();
    parent["paneId"] = created["session"]["pi"]["paneId"].clone();
    assert!(model.requests() == 0, "Metadata created work");
    let start_command = uuid::Uuid::new_v4();
    let start_params =
        json!({"target":parent,"commandId":start_command,"persistence":{"kind":"fresh"}});
    let started = cli(&discovery, "axo.session.start", start_params.clone());
    assert!(
        started["admission"] == "ready",
        "Actual Pi was not admitted"
    );
    assert!(model.requests() == 0, "Admission replayed a prompt");
    let chat = started["chat"].clone();
    assert!(chat.is_object(), "Missing actual chat target");
    let reconciled = cli(&discovery, "axo.session.start", start_params);
    assert!(
        reconciled["chat"] == chat,
        "Start reconciliation retargeted work"
    );
    let command = uuid::Uuid::new_v4();
    let message = json!({"target":chat,"commandId":command,"text":"Public RPC actual tool λ 界"});
    let dispatched = cli(&discovery, "axo.chat.sendMessage", message.clone());
    assert!(
        dispatched["receipt"]["disposition"]["kind"] == "dispatched",
        "Message was not dispatched"
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = cli(&discovery, "axo.chat.get", json!({"target":chat}));
        if snapshot["busy"] == false && model.requests() == 2 {
            break;
        }
        assert!(Instant::now() < deadline, "Public Pi settlement deadline");
        thread::sleep(Duration::from_millis(100));
    }
    assert!(
        fs::read(cwd.join("marker.txt")).is_ok_and(|bytes| bytes == b"Pi-owned-tool"),
        "Actual bash effect missing"
    );
    let history = cli(&discovery, "axo.chat.history", json!({"target":chat}));
    assert!(
        history["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["role"] == "toolResult" && entry["toolName"] == "bash"),
        "Canonical tool evidence missing"
    );
    let tool = history["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["role"] == "toolResult" && entry["toolName"] == "bash")
        .unwrap();
    let detail = cli(
        &discovery,
        "axo.chat.getToolOutput",
        json!({"target":chat,"entryId":tool["entryId"],"toolCallId":tool["toolCallId"],"offset":0,"limit":1}),
    );
    assert!(
        detail["text"].as_str().unwrap().len() <= 1 && detail["totalBytes"].as_u64().unwrap() > 0
    );
    let first_page = cli(
        &discovery,
        "axo.chat.history",
        json!({"target":chat,"limit":1}),
    );
    assert!(first_page["entries"].as_array().unwrap().len() == 1 && first_page["next"].is_object());
    let next_page = cli(
        &discovery,
        "axo.chat.history",
        json!({"target":chat,"limit":1,"cursor":first_page["next"]}),
    );
    assert!(next_page["entries"][0]["entryId"] != first_page["entries"][0]["entryId"]);
    let observed = cli(
        &discovery,
        "axo.session.get",
        json!({"target":{"machineId":descriptor.machine_id,"hostGeneration":descriptor.host_generation,"workspaceId":parent["workspaceId"],"sessionId":parent["sessionId"]}}),
    );
    assert!(
        observed["session"]["pi"]["chatId"] == chat["chatId"]
            && observed["session"]["pi"]["admission"] == "ready"
    );
    let repeated = cli(&discovery, "axo.chat.sendMessage", message);
    assert!(repeated["receipt"]["disposition"]["kind"] == "dispatched");
    assert!(model.requests() == 2, "Reconciliation replayed execution");
    let receipt = cli(
        &discovery,
        "axo.command.get",
        json!({"target":destination,"commandId":command}),
    );
    assert!(
        receipt["receipt"]["kind"] == "pi",
        "Durable Pi disposition missing"
    );
    let lease = uuid::Uuid::new_v4();
    let view = json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"leaseId":lease,"viewing":true,"ttlSeconds":1});
    cli(&discovery, "axo.chat.setViewing", view.clone());
    assert!(cli(&discovery, "axo.chat.get", json!({"target":chat}))["viewingCount"] == 1);
    thread::sleep(Duration::from_millis(1100));
    assert!(cli(&discovery, "axo.chat.get", json!({"target":chat}))["viewingCount"] == 0);
    cli(&discovery, "axo.chat.setViewing", view);
    assert!(
        cli(&discovery, "axo.chat.get", json!({"target":chat}))["viewingCount"] == 0,
        "Reconciliation renewed expired viewing"
    );
    cli(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"text":"ASK_OWNED_QUESTION"}),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let question = loop {
        let snapshot = cli(&discovery, "axo.chat.get", json!({"target":chat}));
        if snapshot["question"].is_object() {
            break snapshot["question"].clone();
        }
        assert!(Instant::now() < deadline, "Owned question deadline");
        thread::sleep(Duration::from_millis(50));
    };
    let blocked = cli(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"text":"must remain blocked"}),
    );
    assert!(blocked["receipt"]["disposition"]["kind"] == "rejected");
    let bad = cli(
        &discovery,
        "axo.chat.answerQuestion",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"interactionId":question["interactionId"],"questionId":question["id"],"optionId":uuid::Uuid::new_v4()}),
    );
    assert!(bad["receipt"]["disposition"]["kind"] == "rejected");
    let answer = json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"interactionId":question["interactionId"],"questionId":question["id"],"optionId":question["options"][1]["id"]});
    assert!(
        cli(&discovery, "axo.chat.answerQuestion", answer.clone())["receipt"]["disposition"]["kind"]
            == "dispatched"
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = cli(&discovery, "axo.chat.get", json!({"target":chat}));
        if snapshot["busy"] == false && model.requests() == 4 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Owned answer settlement deadline"
        );
        thread::sleep(Duration::from_millis(50));
    }
    cli(&discovery, "axo.chat.answerQuestion", answer);
    assert!(model.requests() == 4, "Answer reconciliation replayed work");
    let history = cli(&discovery, "axo.chat.history", json!({"target":chat}));
    assert!(
        history["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["toolName"] == "axo_ask" && entry["text"] == "User chose: Deny"),
        "Actual owned question result missing"
    );
    cli(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"text":"BLOCK_PUBLIC_STREAM"}),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let interaction = loop {
        let snapshot = cli(&discovery, "axo.chat.get", json!({"target":chat}));
        if snapshot["interactionId"].is_string() && model.requests() == 5 {
            break snapshot["interactionId"].clone();
        }
        assert!(
            Instant::now() < deadline,
            "Public stream interaction deadline"
        );
        thread::sleep(Duration::from_millis(50));
    };
    let steering = cli(
        &discovery,
        "axo.chat.sendSteeringMessage",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"interactionId":interaction,"text":"QUEUED_PUBLIC_STEER"}),
    );
    assert!(steering["receipt"]["disposition"]["kind"] == "dispatched");
    let cancelled = cli(
        &discovery,
        "axo.chat.cancelTurn",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"interactionId":interaction}),
    );
    assert!(cancelled["receipt"]["disposition"]["kind"] == "dispatched");
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if cli(&discovery, "axo.chat.get", json!({"target":chat}))["busy"] == false {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Public cancel settlement deadline"
        );
        thread::sleep(Duration::from_millis(50));
    }
    let late = cli(
        &discovery,
        "axo.chat.cancelTurn",
        json!({"target":chat,"commandId":uuid::Uuid::new_v4(),"interactionId":interaction}),
    );
    assert!(late["receipt"]["disposition"]["kind"] == "rejected");
    assert!(model.requests() == 5, "Cancelled steering executed");
    let old_runtime = started["receipt"]["runtime"].clone();
    drop(daemon);
    let mut daemon = spawn();
    let deadline = Instant::now() + Duration::from_secs(5);
    let reboot = loop {
        if let Ok(client) = Client::connect(&discovery) {
            break client.discovery;
        }
        assert!(
            daemon.child.try_wait().unwrap().is_none(),
            "Owned restart rejected state"
        );
        assert!(
            Instant::now() < deadline,
            "Owned restart discovery deadline"
        );
        thread::sleep(Duration::from_millis(25));
    };
    assert!(
        reboot.machine_id == descriptor.machine_id
            && reboot.host_generation != descriptor.host_generation
    );
    parent["hostGeneration"] = json!(reboot.host_generation);
    let mut stopped_target = chat.clone();
    stopped_target["hostGeneration"] = json!(reboot.host_generation);
    let stopped = cli(
        &discovery,
        "axo.chat.get",
        json!({"target":stopped_target,"readMode":"stopped"}),
    );
    assert!(stopped["admission"] == "stopped" && stopped["busy"] == false);
    let stopped_history = cli(
        &discovery,
        "axo.chat.history",
        json!({"target":stopped_target,"readMode":"stopped"}),
    );
    assert!(
        stopped_history["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["toolName"] == "axo_ask" && entry["text"] == "User chose: Deny")
    );
    assert!(model.requests() == 5, "Stopped reads launched work");
    let resumed = cli(
        &discovery,
        "axo.session.start",
        json!({"target":parent,"commandId":uuid::Uuid::new_v4(),"persistence":{"kind":"resume","chatId":chat["chatId"],"previousRuntime":old_runtime}}),
    );
    assert!(resumed["admission"] == "ready", "Exact resume not admitted");
    assert!(
        resumed["chat"]["chatId"] == chat["chatId"]
            && resumed["chat"]["runtimeGeneration"] != chat["runtimeGeneration"],
        "Resume replaced canonical identity or reused runtime"
    );
    assert!(model.requests() == 5, "Restart or resume replayed work");
    let shell_parent = json!({"machineId":reboot.machine_id,"hostGeneration":reboot.host_generation,"workspaceId":resumed["chat"]["workspaceId"],"sessionId":resumed["chat"]["sessionId"]});
    let shell = cli(
        &discovery,
        "axo.session.pane.add",
        json!({"target":shell_parent,"commandId":uuid::Uuid::new_v4(),"profileId":"work"}),
    );
    assert!(
        shell["pane"]["kind"] == "shell" && shell["pane"]["paneId"] != resumed["chat"]["paneId"]
    );
    let removed_shell = cli(
        &discovery,
        "axo.session.pane.remove",
        json!({"target":shell_parent,"commandId":uuid::Uuid::new_v4(),"paneId":shell["pane"]["paneId"],"runtime":shell["pane"]["runtime"]}),
    );
    assert!(removed_shell["receipt"]["disposition"]["kind"] == "removed");
    assert!(
        cli(
            &discovery,
            "axo.chat.get",
            json!({"target":resumed["chat"]})
        )["admission"]
            == "ready"
            && model.requests() == 5,
        "Shell removal stopped or replayed the sibling Pi"
    );
    let resumed_history = cli(
        &discovery,
        "axo.chat.history",
        json!({"target":resumed["chat"]}),
    );
    assert!(
        resumed_history["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["toolName"] == "axo_ask" && entry["text"] == "User chose: Deny"),
        "Exact resume lost canonical tree"
    );
    let mut stale_chat = resumed["chat"].clone();
    stale_chat["runtimeGeneration"] = json!(uuid::Uuid::new_v4());
    cli_error(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":stale_chat,"commandId":uuid::Uuid::new_v4(),"text":"must not retarget"}),
        -32002,
    );
    assert!(model.requests() == 5, "Stale source dispatched");
    let mut cloud = worker.connect(reboot.machine_id);
    let cloud_snapshot = cloud.call("axo.chat.get", json!({"target":resumed["chat"]}));
    assert!(cloud_snapshot["target"] == resumed["chat"] && cloud_snapshot["admission"] == "ready");
    let second = cli(
        &discovery,
        "axo.session.create",
        json!({"target":{"machineId":reboot.machine_id,"hostGeneration":reboot.host_generation,"workspaceId":parent["workspaceId"]},"commandId":uuid::Uuid::new_v4(),"expectedRevision":2,"name":"Cloud-owned Pi"}),
    );
    let second_target = json!({"machineId":reboot.machine_id,"hostGeneration":reboot.host_generation,"workspaceId":parent["workspaceId"],"sessionId":second["session"]["sessionId"],"paneId":second["session"]["pi"]["paneId"]});
    let cloud_start = cloud.call("axo.session.start", json!({"target":second_target,"commandId":uuid::Uuid::new_v4(),"persistence":{"kind":"fresh"}}));
    assert!(
        cloud_start["admission"] == "ready"
            && cloud_start["chat"]["chatId"] != resumed["chat"]["chatId"],
        "Cloud admission did not bind an independent actual Pi"
    );
    assert!(model.requests() == 5, "Cloud admission replayed work");
    let sent = cloud.call("axo.chat.sendMessage", json!({"target":cloud_start["chat"],"commandId":uuid::Uuid::new_v4(),"text":"CLOUD_ACTUAL_TOOL"}));
    assert!(sent["receipt"]["disposition"]["kind"] == "dispatched");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if cli(
            &discovery,
            "axo.chat.get",
            json!({"target":cloud_start["chat"]}),
        )["busy"]
            == false
            && model.requests() == 7
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Cloud Pi tool settlement deadline"
        );
        thread::sleep(Duration::from_millis(100));
    }
    assert!(
        fs::read(cwd.join("cloud-marker.txt")).is_ok_and(|bytes| bytes == b"Cloud-owned-tool"),
        "Actual cloud-routed bash effect missing"
    );
    let cloud_history = cloud.call("axo.chat.history", json!({"target":cloud_start["chat"]}));
    assert!(
        cloud_history["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["role"] == "toolResult" && entry["toolName"] == "bash")
    );
    drop(cloud);
    worker.stop();
    assert!(
        cli(
            &discovery,
            "axo.chat.get",
            json!({"target":cloud_start["chat"]})
        )["admission"]
            == "ready",
        "Cloud/client loss stopped accepted Pi"
    );
    // Public void send can be consumed by a genuine Pi input hook. Dispatch is not execution.
    let consumed = cli(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":resumed["chat"],"commandId":uuid::Uuid::new_v4(),"text":"FIXTURE_HANDLED_INPUT"}),
    );
    assert!(consumed["receipt"]["disposition"]["kind"] == "dispatched");
    let deadline = Instant::now() + Duration::from_secs(7);
    loop {
        if cli(
            &discovery,
            "axo.chat.get",
            json!({"target":resumed["chat"]}),
        )["recovery"]
            == true
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Consumed input uncertainty deadline"
        );
        thread::sleep(Duration::from_millis(100));
    }
    let rejected = cli(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":resumed["chat"],"commandId":uuid::Uuid::new_v4(),"text":"cannot replay ambiguous input"}),
    );
    assert!(
        rejected["receipt"]["disposition"]["kind"] == "rejected"
            && rejected["receipt"]["disposition"]["code"] == -32009
    );
    assert!(
        model.requests() == 7,
        "Consumed input was fabricated as execution or replayed"
    );
    let actual = cli(
        &discovery,
        "axo.chat.history",
        json!({"target":resumed["chat"]}),
    );
    assert!(
        !actual["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["text"] == "FIXTURE_HANDLED_INPUT"),
        "Fabricated canonical user entry"
    );
    // A failed prepared-intent commit must fence every mutation domain, not kill accepted Pi.
    let pi_state = state.join("pi-state.json");
    let saved_state = state.join("pi-state.saved");
    fs::rename(&pi_state, &saved_state).unwrap();
    fs::create_dir(&pi_state).unwrap();
    cli_error(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":resumed["chat"],"commandId":uuid::Uuid::new_v4(),"text":"must not dispatch before commit"}),
        -32004,
    );
    cli_error(
        &discovery,
        "axo.chat.sendMessage",
        json!({"target":resumed["chat"],"commandId":uuid::Uuid::new_v4(),"text":"fenced"}),
        -32008,
    );
    let destination =
        json!({"machineId":reboot.machine_id,"hostGeneration":reboot.host_generation});
    cli_error(
        &discovery,
        "axo.workspace.create",
        json!({"target":destination,"commandId":uuid::Uuid::new_v4(),"expectedRevision":3,"directoryId":"work","name":"Must stay fenced"}),
        -32008,
    );
    cli_error(
        &discovery,
        "axo.runtime.startApproved",
        json!({"target":{"machineId":reboot.machine_id,"hostGeneration":reboot.host_generation,"sessionId":uuid::Uuid::new_v4(),"paneId":uuid::Uuid::new_v4()},"commandId":uuid::Uuid::new_v4(),"profileId":"work"}),
        -32008,
    );
    cli_error(
        &discovery,
        "axo.session.pane.add",
        json!({"target":{"machineId":reboot.machine_id,"hostGeneration":reboot.host_generation,"workspaceId":resumed["chat"]["workspaceId"],"sessionId":resumed["chat"]["sessionId"]},"commandId":uuid::Uuid::new_v4(),"profileId":"work"}),
        -32008,
    );
    assert!(model.requests() == 7, "Storage failure dispatched work");
    let snapshot = cli(
        &discovery,
        "axo.chat.get",
        json!({"target":resumed["chat"]}),
    );
    assert!(
        snapshot["admission"] == "recoveryRequired",
        "Fencing was hidden as readiness"
    );
    let original = cli(
        &discovery,
        "axo.command.get",
        json!({"target":destination,"commandId":command}),
    );
    assert!(
        original["receipt"]["receipt"]["disposition"]["kind"] == "dispatched",
        "Fencing erased original disposition"
    );
    let running = cli(
        &discovery,
        "axo.runtime.list",
        json!({"target":destination}),
    );
    assert!(
        running["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .any(
                |terminal| terminal["runtime"] == resumed["receipt"]["runtime"]
                    && terminal["process"]["kind"] == "running"
            ),
        "Fencing stopped accepted Pi"
    );
    fs::remove_dir(&pi_state).unwrap();
    fs::rename(&saved_state, &pi_state).unwrap();
}
