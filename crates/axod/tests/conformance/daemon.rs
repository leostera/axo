//! The daemon itself: negotiation, health, settings, the JSON-RPC envelope, and events.

#[path = "../support/mod.rs"]
mod support;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Value, json};
use support::Axod;

const INVALID_PARAMS: i64 = -32602;
const METHOD_NOT_FOUND: i64 = -32601;

/// Sends raw bytes on a fresh connection and reads one response line.
fn raw(axod: &Axod, line: &str) -> Value {
    let mut stream = UnixStream::connect(axod.socket()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stream.write_all(line.as_bytes()).unwrap();
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response).unwrap();
    serde_json::from_str(&response).unwrap_or_else(|error| panic!("{error}: {response:?}"))
}

#[test]
fn negotiation_offers_every_method_and_only_version_2() {
    let axod = Axod::start();
    let negotiated = axod.ok("axo.protocol.negotiate", json!({ "protocolVersion": 2 }));
    assert_eq!(negotiated["protocolVersion"], 2);
    let methods: Vec<&str> = negotiated["methods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m.as_str().unwrap())
        .collect();
    assert!(methods.contains(&"axo.session.create"), "{methods:?}");
    assert!(methods.contains(&"axo.elicitation.request"), "{methods:?}");
    assert!(
        !methods.contains(&"axo.protocol.negotiate"),
        "negotiation is not itself offered"
    );

    let refused = axod.err("axo.protocol.negotiate", json!({ "protocolVersion": 1 }));
    assert_eq!(refused.code, INVALID_PARAMS, "{refused:?}");
    assert!(
        refused.message.contains("unsupported protocol version"),
        "{refused:?}"
    );
}

#[test]
fn health_says_running_and_ready_with_this_build() {
    let axod = Axod::start();
    let health = axod.wait_for("axod to be ready", || {
        let health = axod.ok("axo.daemon.health", json!({}));
        (health["ready"] == true).then_some(health)
    });
    assert_eq!(health["status"], "running");
    assert!(
        health["version"]
            .as_str()
            .is_some_and(|version| !version.is_empty()),
        "{health}"
    );
    assert!(health["buildNumber"].as_u64().is_some(), "{health}");
}

#[test]
fn settings_are_read_changed_and_kept_across_a_restart() {
    let mut axod = Axod::start();
    let agent = axod.ok("axo.config.get", json!({ "key": "agent.command" }));
    assert_eq!(agent["key"], "agent.command");
    assert!(agent["value"].is_string(), "{agent}");

    let saved = axod.ok(
        "axo.config.set",
        json!({ "key": "shell.command", "value": "/bin/sh -l" }),
    );
    assert_eq!(
        saved,
        json!({ "key": "shell.command", "value": "/bin/sh -l" })
    );
    assert_eq!(
        axod.ok("axo.config.get", json!({ "key": "shell.command" }))["value"],
        "/bin/sh -l"
    );

    axod.restart();
    assert_eq!(
        axod.ok("axo.config.get", json!({ "key": "shell.command" }))["value"],
        "/bin/sh -l"
    );

    let unknown = axod.err("axo.config.get", json!({ "key": "no.such.key" }));
    assert_eq!(unknown.code, INVALID_PARAMS, "{unknown:?}");
    // A command line that does not parse is refused, and the setting keeps its value.
    let broken = axod.err(
        "axo.config.set",
        json!({ "key": "shell.command", "value": "" }),
    );
    assert!(broken.code < 0, "{broken:?}");
    assert_eq!(
        axod.ok("axo.config.get", json!({ "key": "shell.command" }))["value"],
        "/bin/sh -l"
    );
}

/// When idle Pis sleep (RFD0045): 30 minutes and 20 awake unless changed, in whole numbers.
#[test]
fn idle_pi_limits_have_defaults_and_take_whole_numbers() {
    let mut axod = Axod::start();
    for (key, default) in [("sessions.idleMinutes", "30"), ("sessions.idleLimit", "20")] {
        assert_eq!(
            axod.ok("axo.config.get", json!({ "key": key }))["value"],
            default
        );
        let refused = axod.err("axo.config.set", json!({ "key": key, "value": "-1" }));
        assert!(refused.code < 0, "{refused:?}");
        axod.ok("axo.config.set", json!({ "key": key, "value": "5" }));
    }
    axod.restart();
    for key in ["sessions.idleMinutes", "sessions.idleLimit"] {
        assert_eq!(
            axod.ok("axo.config.get", json!({ "key": key }))["value"],
            "5"
        );
    }
}

#[test]
fn the_envelope_rejects_what_is_not_a_call_it_knows() {
    let axod = Axod::start();

    let unknown = axod.err("axo.no.such.method", json!({}));
    assert_eq!(unknown.code, METHOD_NOT_FOUND, "{unknown:?}");

    // Parameters are strict: an unknown field is refused, not ignored.
    let extra = axod.err("axo.daemon.health", json!({ "surprise": true }));
    assert_eq!(extra.code, INVALID_PARAMS, "{extra:?}");

    let not_json = raw(&axod, "this is not json\n");
    assert_eq!(not_json["error"]["code"], -32700, "{not_json}");

    let no_method = raw(&axod, "{\"jsonrpc\":\"2.0\",\"id\":7}\n");
    assert!(no_method["error"]["code"].as_i64().is_some(), "{no_method}");

    // The id comes back as sent, whatever its type.
    let named = raw(
        &axod,
        "{\"jsonrpc\":\"2.0\",\"id\":\"call-1\",\"method\":\"axo.daemon.health\",\"params\":{}}\n",
    );
    assert_eq!(named["id"], "call-1", "{named}");
    assert!(named["result"]["status"].is_string(), "{named}");

    // After all of that, axod still answers.
    assert_eq!(axod.ok("axo.daemon.health", json!({}))["status"], "running");
}

#[test]
fn one_connection_carries_many_calls_in_order() {
    let axod = Axod::start();
    let mut stream = UnixStream::connect(axod.socket()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    for id in 1..=5 {
        writeln!(
            stream,
            "{}",
            json!({ "jsonrpc": "2.0", "id": id, "method": "axo.daemon.health", "params": {} })
        )
        .unwrap();
    }
    let mut reader = BufReader::new(stream);
    let mut ids = Vec::new();
    for _ in 1..=5 {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        ids.push(response["id"].as_i64().unwrap());
    }
    ids.sort();
    assert_eq!(ids, vec![1, 2, 3, 4, 5]);
}

#[test]
fn events_are_pushed_on_their_own_connection_until_it_closes() {
    let axod = Axod::start();
    // More streams than axod keeps subscriptions for: closing each one ends its subscription.
    for _ in 0..70 {
        drop(axod.subscribe(json!({ "includeTerminalOutput": false })));
    }
    let mut events = axod.subscribe(json!({ "includeTerminalOutput": false }));
    let session = axod.ok("axo.session.create", json!({}));
    let id = session["id"].as_str().unwrap().to_owned();
    events.wait_for("the new Session's event, pushed", |event| {
        event.to_string().contains(&id).then_some(())
    });
    // A stream for a Session that is not open is refused.
    let mut stream = UnixStream::connect(axod.socket()).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    writeln!(
        stream,
        "{}",
        json!({ "jsonrpc": "2.0", "id": 1, "method": "axo.session.events.stream",
                "params": { "sessionId": "00000000-0000-4000-8000-000000000000" } })
    )
    .unwrap();
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).unwrap();
    let answer: Value = serde_json::from_str(&answer).unwrap();
    assert!(answer.get("error").is_some(), "{answer}");
}

#[test]
fn events_are_not_polled_for() {
    let axod = Axod::start();
    for method in [
        "axo.session.subscribe",
        "axo.session.events.next",
        "axo.session.unsubscribe",
    ] {
        let gone = axod.err(method, json!({}));
        assert_eq!(gone.code, METHOD_NOT_FOUND, "{method}: {gone:?}");
    }
}

#[test]
fn a_subscription_to_one_session_sees_only_that_session() {
    let axod = Axod::start();
    let first = axod.ok("axo.session.create", json!({}));
    let mut events =
        axod.subscribe(json!({ "sessionId": first["id"], "includeTerminalOutput": false }));
    let second = axod.ok("axo.session.create", json!({}));
    axod.ok(
        "axo.session.rename",
        json!({ "sessionId": first["id"], "name": "First" }),
    );
    events.wait_for("the rename", |event| {
        event.to_string().contains("First").then_some(())
    });
    let second_id = second["id"].as_str().unwrap();
    assert!(
        events
            .seen
            .iter()
            .all(|event| !event.to_string().contains(second_id)),
        "saw another Session's events: {:#?}",
        events.seen
    );
}

#[test]
fn sigterm_stops_axod_and_its_panes() {
    let mut axod = Axod::start();
    let session = axod.new_session();
    let pids: Vec<i32> = session["shells"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["processId"].as_i64().unwrap() as i32)
        .collect();
    axod.stop();
    assert!(!axod.running());
    for pid in pids.into_iter().filter(|pid| *pid > 0) {
        axod.wait_for("the pane's process to end", || {
            // SAFETY: probing with signal 0 only asks whether the process exists.
            (unsafe { libc::kill(pid, 0) } != 0).then_some(())
        });
    }
}

/// launchd stops axod with SIGTERM, a terminal with SIGINT: either stops it on its own, cleanly
/// and at once, without the SIGKILL that `stop` falls back to.
#[test]
fn a_signal_stops_axod_cleanly() {
    for signal in [libc::SIGTERM, libc::SIGINT] {
        let mut axod = Axod::start();
        axod.ok("axo.session.list", json!({}));
        // SAFETY: signals only the axod this test started.
        unsafe { libc::kill(axod.pid() as libc::pid_t, signal) };
        let deadline = std::time::Instant::now() + Duration::from_secs(4);
        while axod.running() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            !axod.running(),
            "signal {signal} did not stop axod:\n{}",
            axod.log()
        );
        let log = axod.log();
        assert!(log.contains("event=daemon.server_stopped"), "{log}");
    }
}
