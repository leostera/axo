//! Asking the person (RFD0029) on this Mac: who may ask, who may answer, what clients see.
//!
//! Only Axo.app answers locally (by code signature) and the test is not Axo.app, so answers are
//! the relay's to test (`//packages/axo-api-worker:relay_test`, `elicitations-e2e`).

#[path = "../support/mod.rs"]
mod support;

use std::thread;

use serde_json::{Value, json};
use support::Axod;

const INVALID_PARAMS: i64 = -32602;
const NOT_A_PERSON: i64 = -32012;
const NOT_A_TOOL: i64 = -32013;
const NOT_PENDING: i64 = -32011;

/// Asks on a connection of its own, which stays open (and the question pending) until axod
/// answers or the connection is dropped.
fn ask_in_background(
    axod: &Axod,
    params: Value,
) -> thread::JoinHandle<std::io::Result<Result<Value, support::RpcError>>> {
    let socket = axod.socket();
    thread::spawn(move || support::call(&socket, "axo.elicitation.request", params))
}

fn pending(axod: &Axod) -> Vec<Value> {
    axod.ok("axo.elicitation.list", json!({}))["elicitations"]
        .as_array()
        .unwrap()
        .clone()
}

#[test]
fn an_agents_question_is_shown_to_every_client_and_listed_until_answered() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let mut events = axod.subscribe(json!({ "includeTerminalOutput": false }));
    assert!(pending(&axod).is_empty());

    let _asking = ask_in_background(
        &axod,
        json!({ "sessionId": session, "message": "  Deploy to production?  " }),
    );
    let requested = events.wait_for_type("elicitation.requested");
    let question = &requested["elicitation"];
    assert_eq!(question["sessionId"], session);
    assert_eq!(question["message"], "Deploy to production?", "trimmed");
    assert_eq!(question["askedBy"], "agent");
    assert_eq!(question["kind"], "confirm");
    let ttl = question["expiresAt"].as_u64().unwrap() - question["createdAt"].as_u64().unwrap();
    assert_eq!(ttl, 5 * 60_000);

    let listed = pending(&axod);
    assert_eq!(listed.len(), 1, "{listed:#?}");
    assert_eq!(listed[0]["id"], question["id"]);
}

#[test]
fn only_axo_app_answers_on_this_mac() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let _asking = ask_in_background(&axod, json!({ "sessionId": session, "message": "Go?" }));
    let id = axod.wait_for("the question", || {
        pending(&axod).first().map(|q| q["id"].clone())
    });
    let refused = axod.err(
        "axo.elicitation.resolve",
        json!({ "elicitationId": id, "action": "accept" }),
    );
    assert_eq!(refused.code, NOT_A_PERSON, "{refused:?}");
    assert_eq!(
        pending(&axod).len(),
        1,
        "a refused answer leaves the question waiting"
    );

    // Nor may anyone answer `cancel`, which is axod's alone.
    let cancel = axod.err(
        "axo.elicitation.resolve",
        json!({ "elicitationId": id, "action": "cancel" }),
    );
    assert!(
        cancel.code == INVALID_PARAMS || cancel.code == NOT_A_PERSON,
        "{cancel:?}"
    );
    let unknown = axod.err(
        "axo.elicitation.resolve",
        json!({ "elicitationId": "nope", "action": "accept" }),
    );
    assert!(
        unknown.code == NOT_A_PERSON || unknown.code == NOT_PENDING,
        "{unknown:?}"
    );
}

#[test]
fn only_axods_own_tools_ask_as_a_tool() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let refused = axod.err(
        "axo.elicitation.request",
        json!({ "sessionId": session, "message": "Click Buy?", "askedBy": "computerUse" }),
    );
    assert_eq!(refused.code, NOT_A_TOOL, "{refused:?}");
    assert!(pending(&axod).is_empty());
}

#[test]
fn questions_are_checked_before_anyone_sees_them() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    for message in ["", "   ", "x".repeat(5_000).as_str()] {
        let refused = axod.err(
            "axo.elicitation.request",
            json!({ "sessionId": session, "message": message }),
        );
        assert_eq!(refused.code, INVALID_PARAMS, "{message:.20}: {refused:?}");
    }
    let nobody = axod.err(
        "axo.elicitation.request",
        json!({ "sessionId": "00000000-0000-4000-8000-000000000000", "message": "Go?" }),
    );
    assert_eq!(nobody.code, INVALID_PARAMS, "{nobody:?}");
    assert!(pending(&axod).is_empty());
}

#[test]
fn an_agent_can_wait_on_several_questions_at_once() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let _askers: Vec<_> = (0..3)
        .map(|n| {
            ask_in_background(
                &axod,
                json!({ "sessionId": session, "message": format!("Question {n}?") }),
            )
        })
        .collect();
    axod.wait_for("three questions", || {
        (pending(&axod).len() == 3).then_some(())
    });
    // Axod still answers everything else while they wait.
    assert_eq!(axod.ok("axo.daemon.health", json!({}))["status"], "running");
}

#[test]
fn an_asker_that_goes_away_withdraws_its_question() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let mut events = axod.subscribe(json!({ "includeTerminalOutput": false }));
    {
        let mut stream = std::os::unix::net::UnixStream::connect(axod.socket()).unwrap();
        use std::io::Write;
        writeln!(
            stream,
            "{}",
            json!({ "jsonrpc": "2.0", "id": 1, "method": "axo.elicitation.request", "params": { "sessionId": session, "message": "Go?" } })
        )
        .unwrap();
        events.wait_for_type("elicitation.requested");
        // The asker hangs up.
    }
    let resolved = events.wait_for_type("elicitation.resolved");
    assert_eq!(resolved["action"], "cancel");
    assert!(pending(&axod).is_empty());
}

/// Count only the daemon's threads, not the test's clients or its fake Pi child. macOS's ps
/// reports one row per thread; Linux exposes the same information as /proc/<pid>/task.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn daemon_threads(axod: &Axod) -> usize {
    #[cfg(target_os = "macos")]
    {
        let output = std::process::Command::new("/bin/ps")
            .args(["-M", &axod.pid().to_string()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let rows = std::str::from_utf8(&output.stdout).unwrap().lines().count();
        assert!(rows > 1, "ps must report the daemon's threads");
        rows - 1
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_dir(format!("/proc/{}/task", axod.pid()))
            .unwrap()
            .count()
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[test]
fn thirty_two_pending_questions_do_not_allocate_a_thread_each() {
    use std::io::Write;
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    assert!(pending(&axod).is_empty());
    // Warm the permission probe before taking the baseline. Allow two incidental OS/runtime
    // threads, but not one thread per question (the old implementation added 32).
    axod.ok("axo.daemon.health", json!({}));
    let baseline = daemon_threads(&axod);
    let mut askers = Vec::new();
    let mut peak = baseline;
    for count in 1..=32 {
        let mut socket = UnixStream::connect(axod.socket()).unwrap();
        writeln!(
            socket,
            "{}",
            json!({
                "jsonrpc": "2.0", "id": count, "method": "axo.elicitation.request",
                "params": { "sessionId": session, "message": format!("Question {count}?") }
            })
        )
        .unwrap();
        askers.push(socket);
        axod.wait_for("every question to be waiting", || {
            (pending(&axod).len() == count).then_some(())
        });
        peak = peak.max(daemon_threads(&axod));
    }
    // They stay pending while other RPCs continue to work, rather than being dropped early.
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(pending(&axod).len(), 32);
    peak = peak.max(daemon_threads(&axod));
    assert!(
        peak <= baseline + 2,
        "32 waiting questions grew daemon threads from {baseline} to {peak}: {}",
        axod.log()
    );
    drop(askers);
    axod.wait_for("all disconnected askers' questions to be withdrawn", || {
        pending(&axod).is_empty().then_some(())
    });
}
