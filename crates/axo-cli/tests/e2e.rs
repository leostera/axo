//! Real CLI -> isolated real daemon -> fake Pi. Never uses the person's socket or service.
#[path = "../../axod/tests/support/mod.rs"]
mod support;
use serde_json::{Value, json};
use std::process::{Command, Output, Stdio};
use support::{Axod, runfile};
fn cli(daemon: &Axod, args: &[&str]) -> Output {
    Command::new(runfile("AXO_CLI_BINARY"))
        .arg("--socket")
        .arg(daemon.socket())
        .arg("--json")
        .args(args)
        .env_remove("AXO_SESSION_ID")
        .env_remove("AXO_SOCKET")
        .stdin(Stdio::null())
        .output()
        .unwrap()
}
fn ok(daemon: &Axod, args: &[&str]) -> Value {
    let result = cli(daemon, args);
    assert!(
        result.status.success(),
        "{args:?}: {}\n{}",
        String::from_utf8_lossy(&result.stderr),
        daemon.log()
    );
    serde_json::from_slice(&result.stdout).unwrap()
}
#[test]
fn sessions_and_settings_use_the_real_protocol_without_consuming_focus_or_hiding_errors() {
    let daemon = Axod::start();
    assert!(ok(&daemon, &["session", "list"]).is_array());
    let created = ok(&daemon, &["session", "create"]);
    let id = created["id"].as_str().unwrap();
    daemon.wait_for_pi(&created);
    ok(
        &daemon,
        &["session", "rename", "--sid", id, "--name", "CLI fixture"],
    );
    assert_eq!(
        ok(&daemon, &["session", "show", "--sid", id])["manualName"],
        "CLI fixture"
    );
    let prompt = ok(
        &daemon,
        &[
            "session",
            "prompt",
            "--sid",
            id,
            "--message",
            "literal ; $(not-a-shell-command)",
            "--delivery",
            "turn",
        ],
    );
    assert_eq!(prompt["accepted"], true);
    ok(&daemon, &["config", "set", "sessions.idleMinutes", "0"]);
    assert_eq!(
        ok(&daemon, &["config", "get", "sessions.idleMinutes"])["value"],
        "0"
    );
    assert!(ok(&daemon, &["shell", "list", "--sid", id]).is_array());
    assert_eq!(
        cli(&daemon, &["session", "close", "--sid", id])
            .status
            .code(),
        Some(2)
    );
    ok(&daemon, &["session", "close", "--sid", id, "--yes"]);
    assert_eq!(ok(&daemon, &["session", "show", "--sid", id])["id"], id);
    let unknown = cli(
        &daemon,
        &[
            "session",
            "show",
            "--sid",
            "11111111-2222-4333-8444-555555555555",
        ],
    );
    assert_eq!(unknown.status.code(), Some(4));
    assert!(unknown.stdout.is_empty());
    let refused = cli(
        &daemon,
        &[
            "rpc",
            "call",
            "axo.elicitation.resolve",
            "--params",
            "{}",
            "--yes",
        ],
    );
    assert_eq!(refused.status.code(), Some(4));
    assert!(String::from_utf8_lossy(&refused.stderr).contains("only the person answers"));
    let status = ok(&daemon, &["relay", "status"]);
    assert_eq!(status["linked"], false);
    assert!(status["accountId"].is_null());
    assert_eq!(
        ok(&daemon, &["relay", "unlink", "--yes"]),
        json!({"unlinked":true})
    );
}
#[test]
fn event_watch_stops_cleanly_when_its_output_pipe_closes() {
    use std::io::{BufRead, BufReader};
    use std::time::{Duration, Instant};
    let daemon = Axod::start();
    let mut child = Command::new(runfile("AXO_CLI_BINARY"))
        .arg("--socket")
        .arg(daemon.socket())
        .args(["session", "watch", "--timeout-ms", "10000"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut reader = BufReader::new(child.stdout.take().unwrap());
    let mut subscribed = String::new();
    reader.read_line(&mut subscribed).unwrap();
    assert!(serde_json::from_str::<Value>(&subscribed).unwrap()["subscriptionId"].is_string());
    drop(reader);
    daemon.new_session();
    let end = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        if Instant::now() >= end {
            let _ = child.kill();
            let _ = child.wait();
            panic!("closed pipe left a live watcher");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn install_is_idempotent_and_never_replaces_another_executable() {
    let directory = support::fresh_directory("cli-bin");
    let binary = runfile("AXO_CLI_BINARY");
    let dir = directory.to_str().unwrap();
    let invoke = || {
        Command::new(&binary)
            .args(["cli", "install", "--dir", dir])
            .output()
            .unwrap()
    };
    assert!(invoke().status.success());
    assert!(invoke().status.success());
    std::fs::remove_file(directory.join("axo")).unwrap();
    std::fs::write(directory.join("axo"), "another program").unwrap();
    assert_eq!(invoke().status.code(), Some(2));
    assert_eq!(
        std::fs::read_to_string(directory.join("axo")).unwrap(),
        "another program"
    );
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn invalid_input_and_unsupported_commands_fail_before_a_connection_or_restart() {
    let binary = runfile("AXO_CLI_BINARY");
    for args in [
        vec!["session", "prompt", "--sid", "bad", "--message", "x"],
        vec!["relay", "connect"],
        vec!["relay", "disconnect"],
        vec!["daemon", "restart", "--yes"],
    ] {
        let result = Command::new(&binary)
            .args(["--socket", "/tmp/axo-cli-nonexistent.sock"])
            .args(&args)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(
            result.status.code(),
            Some(2),
            "{args:?}: {}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
    let capabilities = Command::new(&binary).arg("capabilities").output().unwrap();
    assert!(capabilities.status.success());
    let value: Value = serde_json::from_slice(&capabilities.stdout).unwrap();
    assert!(value["commands"].as_array().unwrap().len() > 30);
    assert!(
        value["excluded"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v[0] == "axo.elicitation.resolve")
    );
}
