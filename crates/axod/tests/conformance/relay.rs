//! A Mac linked to an account, seen from the account: axod against a fake of Axo's cloud
//! (`support/hub.rs`). Linking, the daemon socket and its credential, what the account may ask
//! of the Mac (`axo.remote.*`, commands, prompts), what the Mac forwards to the account
//! (a Session's apps calls) and what it tells it (questions). These hold the relay's behaviour
//! still while it moves into the server core (RFD0034 step 6).
//!
//! The Worker's relay tests (`//packages/axo-api-worker:relay_test`) drive the same paths through
//! the real Worker; these are the Mac's half alone, fast and exact.

#[path = "../support/mod.rs"]
mod support;

use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::hub::{ACCOUNT_ID, Answer, CODE, FakeHub};
use support::{Axod, Options, Pi};

const STALE_HOST: i64 = -32002;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;

/// An axod linked to `hub`, connected, and the target the account names it by.
fn linked(hub: &FakeHub, pi: Pi) -> (Axod, Value) {
    linked_with(
        hub,
        Options {
            pi,
            ..Options::default()
        },
    )
}

/// [`linked`], with axod started as `options` say.
fn linked_with(hub: &FakeHub, options: Options) -> (Axod, Value) {
    let axod = Axod::with(Options {
        relay_url: Some(hub.url()),
        ..options
    });
    let link = axod.ok("axo.relay.link", json!({ "code": CODE }));
    assert_eq!(link["linked"], true, "{link}");
    // A connection that never comes is axod's to explain: its log goes with the failure.
    let register = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        hub.wait_until_connected();
        hub.wait_for_request("axo.host.register")
    }))
    .unwrap_or_else(|_| {
        panic!(
            "axod did not connect and register; axod log:\n{}",
            axod.log()
        )
    });
    let target = json!({
        "hostId": register["params"]["hostId"],
        "hostGeneration": register["params"]["hostGeneration"],
    });
    (axod, target)
}

fn wait_for_status(axod: &Axod, state: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let status = axod.ok("axo.relay.status", json!({}));
        if status["state"] == state {
            return status;
        }
        assert!(
            Instant::now() < deadline,
            "relay never became {state}: {status}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_linked_mac_connects_with_its_credential_and_registers() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub, Pi::Fake);

    let redeemed = hub.redeemed();
    assert_eq!(redeemed.len(), 1);
    let redemption = &redeemed[0];
    assert_eq!(redemption["code"], CODE);
    assert_eq!(redemption["hostId"], target["hostId"]);
    assert!(
        redemption["credential"]
            .as_str()
            .is_some_and(|c| c.len() >= 40),
        "{redemption}"
    );

    // The daemon socket is the account's route for this host, with the credential it redeemed.
    let daemon = hub
        .sockets()
        .into_iter()
        .find(|socket| socket.path.ends_with("/daemon"))
        .expect("a daemon socket");
    assert_eq!(
        daemon.path,
        format!(
            "/api/v1/accounts/{ACCOUNT_ID}/hosts/{}/daemon",
            target["hostId"].as_str().unwrap()
        )
    );
    assert_eq!(
        daemon.authorization.as_deref(),
        Some(format!("Bearer {}", redemption["credential"].as_str().unwrap()).as_str())
    );
    assert_eq!(
        daemon.credential_id.as_deref(),
        redemption["credentialId"].as_str()
    );

    // It negotiates the protocol before it registers.
    let negotiate = hub.wait_for_request("axo.protocol.negotiate");
    assert!(
        negotiate["params"]["protocolVersion"].is_u64(),
        "{negotiate}"
    );
    let register = &hub.received("axo.host.register")[0];
    assert_eq!(
        (negotiate["id"].clone(), register["id"].clone()),
        (json!("axod-1"), json!("axod-2")),
        "negotiate, then register"
    );
    let status = wait_for_status(&axod, "connected");
    assert!(status["connectedSinceUnixMillis"].is_number(), "{status}");
}

#[test]
fn a_dropped_socket_comes_back_and_registers_again() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub, Pi::Fake);
    hub.drop_socket();
    let again = hub.wait_for_request("axo.host.register");
    assert_eq!(again["params"]["hostId"], target["hostId"]);
    wait_for_status(&axod, "connected");
}

/// A socket that registered was online: when it drops, however often, the next one comes in
/// about a second, not after a backoff that grew across healthy connections.
#[test]
fn a_registered_socket_that_drops_again_and_again_still_comes_back_at_once() {
    let hub = FakeHub::start();
    let (_axod, _target) = linked(&hub, Pi::Fake);
    hub.wait_until_connected();
    for drop in 0..5 {
        let dropped = std::time::Instant::now();
        hub.drop_socket();
        hub.wait_until_connected();
        let back = dropped.elapsed();
        assert!(
            back < std::time::Duration::from_millis(1_900),
            "drop {drop} took {back:?} to come back"
        );
    }
}

#[test]
fn the_account_creates_renames_and_closes_sessions_on_the_mac() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub, Pi::Fake);

    let created = hub.ok("axo.remote.session.create", json!({ "target": target }));
    let session = created["session"]["sessionId"].clone();
    assert!(session.is_string(), "{created}");
    let home = std::fs::canonicalize(axod.home()).unwrap();
    assert_eq!(
        created["session"]["folderName"],
        json!(home.file_name().unwrap().to_string_lossy()),
        "the account sees the folder's name, not its path: {created}"
    );
    assert!(!created.to_string().contains(&*home.to_string_lossy()));
    let beside = hub.ok(
        "axo.remote.session.create",
        json!({ "target": target, "like": session }),
    );
    let beside_id = beside["session"]["sessionId"].clone();
    let folder_of = |id: &Value| {
        axod.sessions()
            .into_iter()
            .find(|listed| listed["id"] == *id)
            .unwrap()["folder"]
            .clone()
    };
    assert_eq!(folder_of(&beside_id), folder_of(&session));
    assert!(
        axod.sessions().iter().any(|listed| listed["id"] == session),
        "the Mac lists the Session the account created"
    );

    hub.ok(
        "axo.remote.session.rename",
        json!({ "target": target, "sessionId": session, "name": "From the phone" }),
    );
    let renamed = axod
        .sessions()
        .into_iter()
        .find(|listed| listed["id"] == session)
        .unwrap();
    assert_eq!(renamed["manualName"], "From the phone");

    hub.ok(
        "axo.remote.session.close",
        json!({ "target": target, "sessionId": session }),
    );
    assert!(!axod.sessions().iter().any(|listed| listed["id"] == session));
}

#[test]
fn the_account_is_refused_for_another_mac_and_for_what_it_cannot_ask() {
    let hub = FakeHub::start();
    let (_axod, target) = linked(&hub, Pi::Fake);

    let stale = json!({ "hostId": target["hostId"], "hostGeneration": "an-older-generation" });
    let refused = hub
        .call("axo.remote.session.create", json!({ "target": stale }))
        .unwrap_err();
    assert_eq!(refused["code"], STALE_HOST, "{refused}");

    let malformed = hub
        .call(
            "axo.remote.session.create",
            json!({ "target": target, "extra": 1 }),
        )
        .unwrap_err();
    assert_eq!(malformed["code"], INVALID_PARAMS, "{malformed}");

    let unknown = hub
        .call(
            "axo.remote.session.delete-everything",
            json!({ "target": target }),
        )
        .unwrap_err();
    assert_eq!(unknown["code"], METHOD_NOT_FOUND, "{unknown}");
}

#[test]
fn a_prompt_from_the_account_reaches_pi() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub, Pi::Fake);
    let listed = axod.new_session().clone();
    axod.wait_for_pi(&listed);
    let session = listed["id"].clone();

    let accepted = hub.ok(
        "axo.remote.session.prompt",
        json!({ "target": target, "sessionId": session, "text": "run the tests" }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !axod.pi_log().contains("SENT:run the tests") {
        assert!(
            Instant::now() < deadline,
            "Pi never got it:\n{}",
            axod.pi_log()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// How often `needle` is in the fake Pi's log.
fn logged(axod: &Axod, needle: &str) -> usize {
    axod.pi_log().matches(needle).count()
}

fn the_session(axod: &Axod, session: &Value) -> Value {
    axod.sessions()
        .into_iter()
        .find(|listed| listed["id"] == *session)
        .unwrap()
}

#[test]
fn a_prompt_from_the_account_says_when_a_working_pi_takes_it() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub, Pi::Fake);
    let session = axod.new_session()["id"].clone();

    hub.ok(
        "axo.remote.session.prompt",
        json!({ "target": target, "sessionId": session, "text": "after this", "commandId": "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b" }),
    );
    hub.ok(
        "axo.remote.session.prompt",
        json!({ "target": target, "sessionId": session, "text": "look here", "delivery": "steer", "commandId": "0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d" }),
    );
    hub.ok(
        "axo.remote.session.prompt",
        json!({ "target": target, "sessionId": session, "text": "stop, this instead", "delivery": "interrupt", "commandId": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d" }),
    );
    let log = axod.pi_log();
    assert!(
        log.contains("DELIVERY:interrupt:stop, this instead"),
        "{log}"
    );
    assert!(
        log.contains("DELIVERY:followUp:after this"),
        "a follow-up unless it says otherwise:\n{log}"
    );
    assert!(log.contains("DELIVERY:steer:look here"), "{log}");

    let refused = hub
        .call(
            "axo.remote.session.prompt",
            json!({ "target": target, "sessionId": session, "text": "x", "delivery": "now" }),
        )
        .unwrap_err();
    assert_eq!(refused["code"], INVALID_PARAMS, "{refused}");
}

#[test]
fn a_prompt_to_a_starting_pi_is_answered_once_pi_has_it_in_its_log() {
    let hub = FakeHub::start();
    let (axod, target) = linked_with(
        &hub,
        Options {
            env: vec![("AXO_FAKE_PI_STARTUP_MS".into(), "1500".into())],
            ..Options::default()
        },
    );
    let session = axod.ok("axo.session.create", json!({}))["id"].clone();
    let accepted = hub.ok(
        "axo.remote.session.prompt",
        json!({ "target": target, "sessionId": session, "text": "early", "commandId": "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b" }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
    // Accepted means Pi has it: nothing waits in axod's memory for the client to trust.
    assert_eq!(logged(&axod, "SENT:early"), 1, "{}", axod.pi_log());
}

#[test]
fn a_pi_too_slow_to_start_is_answered_as_starting_and_the_retry_is_taken_once() {
    let hub = FakeHub::start();
    let (axod, target) = linked_with(
        &hub,
        Options {
            env: vec![("AXO_FAKE_PI_STARTUP_MS".into(), "6000".into())],
            ..Options::default()
        },
    );
    let listed = axod.ok("axo.session.create", json!({}));
    let prompt = json!({ "target": target, "sessionId": listed["id"], "text": "patient", "commandId": "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b" });
    let starting = hub
        .call("axo.remote.session.prompt", prompt.clone())
        .unwrap_err();
    assert_eq!(starting["code"], -32008, "{starting}");
    assert_eq!(
        logged(&axod, "SENT:patient"),
        0,
        "refused, so nothing is kept for later"
    );

    axod.wait_for_pi(&listed);
    hub.ok("axo.remote.session.prompt", prompt.clone());
    hub.ok("axo.remote.session.prompt", prompt);
    assert_eq!(logged(&axod, "SENT:patient"), 1, "{}", axod.pi_log());
}

#[test]
fn the_account_sees_the_model_pi_runs_and_switches_it() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub, Pi::Fake);
    let session = axod.new_session()["id"].clone();
    let pi = axod.wait_for("Pi to say what it runs", || {
        let pi = the_session(&axod, &session)["pi"].clone();
        pi.is_object().then_some(pi)
    });
    assert_eq!(
        pi,
        json!({ "model": { "provider": "fake", "id": "fake-1", "name": "Fake One" }, "thinkingLevel": "medium" })
    );

    let commands = hub.ok(
        "axo.remote.session.commands",
        json!({ "target": target, "sessionId": session }),
    );
    assert_eq!(
        commands["commands"],
        json!([
            { "name": "review", "description": "Review the change", "source": "prompt" },
            { "name": "axo-share", "description": "Share this conversation", "source": "extension" },
        ])
    );
    let models = hub.ok(
        "axo.remote.session.models",
        json!({ "target": target, "sessionId": session }),
    );
    let names: Vec<&str> = models["models"]
        .as_array()
        .unwrap()
        .iter()
        .map(|model| model["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Fake One", "Fake Two"]);
    assert_eq!(
        models["models"][1]["thinkingLevels"],
        json!(["off", "low", "medium", "high"])
    );

    let saved = hub.ok(
        "axo.remote.session.model.set",
        json!({ "target": target, "sessionId": session, "model": { "provider": "fake", "id": "fake-2" }, "thinkingLevel": "high" }),
    );
    assert_eq!(saved["saved"], true, "{saved}");
    axod.wait_for("the switch to reach the Session's snapshot", || {
        (the_session(&axod, &session)["pi"]
            == json!({ "model": { "provider": "fake", "id": "fake-2", "name": "Fake Two" }, "thinkingLevel": "high" }))
        .then_some(())
    });

    let unknown = hub
        .call(
            "axo.remote.session.model.set",
            json!({ "target": target, "sessionId": session, "model": { "provider": "fake", "id": "fake-9" } }),
        )
        .unwrap_err();
    assert_eq!(unknown["code"], INVALID_PARAMS, "{unknown}");
    for nothing in [
        json!({ "target": target, "sessionId": session }),
        json!({ "target": target, "sessionId": session, "thinkingLevel": "extreme" }),
    ] {
        let refused = hub
            .call("axo.remote.session.model.set", nothing)
            .unwrap_err();
        assert_eq!(refused["code"], INVALID_PARAMS, "{refused}");
    }
}

#[test]
fn the_account_restarts_a_working_pi_on_the_same_conversation() {
    let hub = FakeHub::start();
    let (axod, target) = linked_with(
        &hub,
        Options {
            env: vec![("AXO_FAKE_PI_TURN_MS".into(), "60000".into())],
            ..Options::default()
        },
    );
    let before = axod.new_session();
    let session = before["id"].clone();
    hub.ok(
        "axo.remote.session.prompt",
        json!({ "target": target, "sessionId": session, "text": "a long job" }),
    );
    axod.wait_for("Pi to be working", || {
        (the_session(&axod, &session)["status"] == "working").then_some(())
    });

    let restarted = hub.ok(
        "axo.remote.session.restart",
        json!({ "target": target, "sessionId": session }),
    );
    assert_eq!(restarted["restarted"], true, "{restarted}");
    axod.wait_for("a second Pi to start and be ready", || {
        let listed = the_session(&axod, &session);
        (logged(&axod, "STARTED:") == 2 && listed["status"] == "ready").then_some(())
    });
    assert_eq!(
        the_session(&axod, &session)["piSessionFile"],
        before["piSessionFile"],
        "the same conversation"
    );

    let missing = hub
        .call(
            "axo.remote.session.restart",
            json!({ "target": target, "sessionId": "00000000-0000-4000-8000-000000000000" }),
        )
        .unwrap_err();
    assert_eq!(missing["code"], -32004, "{missing}");
}

#[test]
fn the_account_runs_a_command_on_the_mac_and_hears_how_it_ended() {
    let hub = FakeHub::start();
    let (_axod, _target) = linked(&hub, Pi::Fake);
    let result = hub.ok(
        "axo.apps.bash",
        json!({
            "accountId": ACCOUNT_ID,
            "callId": "00000000-0000-4000-8000-000000000001",
            "command": "echo from-the-account; exit 3",
        }),
    );
    assert_eq!(result["stdout"], "from-the-account\n", "{result}");
    assert_eq!(result["exitCode"], 3, "{result}");
    assert_eq!(result["timedOut"], false, "{result}");

    // A command for any other account is refused, and nothing runs.
    let refused = hub
        .call(
            "axo.apps.bash",
            json!({
                "accountId": "00000000-0000-4000-8000-0000000000ff",
                "callId": "00000000-0000-4000-8000-000000000002",
                "command": "echo should-not-run",
            }),
        )
        .unwrap_err();
    assert!(
        refused["code"].as_i64().is_some_and(|code| code < 0),
        "{refused}"
    );
}

#[test]
fn a_sessions_apps_calls_go_to_the_account_and_its_answer_comes_back() {
    let hub = FakeHub::start();
    let (axod, _target) = linked(&hub, Pi::Fake);
    let session = axod.new_session()["id"].clone();

    hub.respond(
        "axo.apps.list",
        Answer::Result(json!({ "apps": [{ "kind": "thirdParty", "name": "linear" }] })),
    );
    let listed = axod.ok("axo.apps.list", json!({ "sessionId": session }));
    assert_eq!(listed["apps"][0]["name"], "linear", "{listed}");
    // The account learns which Session asked.
    let forwarded = hub.wait_for_request("axo.apps.list");
    assert_eq!(forwarded["params"]["sessionId"], session, "{forwarded}");

    // A refusal keeps its code and words.
    hub.respond(
        "axo.apps.run",
        Answer::Error(-32602, "the script is not a function".into()),
    );
    let refused = axod.err(
        "axo.apps.run",
        json!({ "sessionId": session, "code": "not a function" }),
    );
    assert_eq!(refused.code, -32602, "{refused:?}");
    assert_eq!(refused.message, "the script is not a function");
}

#[test]
fn a_question_is_told_to_the_account_and_withdrawn_there_when_its_asker_leaves() {
    let hub = FakeHub::start();
    let (axod, _target) = linked(&hub, Pi::Fake);
    let session = axod.new_session()["id"].clone();
    {
        let mut stream = std::os::unix::net::UnixStream::connect(axod.socket()).unwrap();
        use std::io::Write;
        writeln!(
            stream,
            "{}",
            json!({ "jsonrpc": "2.0", "id": 1, "method": "axo.elicitation.request", "params": { "sessionId": session, "message": "Deploy?" } })
        )
        .unwrap();
        let requested = hub.wait_for("the question", |message| {
            message["method"] == "axo.elicitation.requested"
        });
        assert_eq!(requested["params"]["message"], "Deploy?", "{requested}");
        assert_eq!(requested["params"]["sessionId"], session, "{requested}");
        // The asker hangs up.
    }
    let resolved = hub.wait_for("the question withdrawn", |message| {
        message["method"] == "axo.elicitation.resolved"
    });
    assert_eq!(resolved["params"]["action"], "cancel", "{resolved}");
}

#[test]
fn the_account_drives_a_sessions_panes_keys_and_layout() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub, Pi::Fake);
    let created = hub.ok("axo.remote.session.create", json!({ "target": target }));
    let session = created["session"]["sessionId"].clone();
    let listed = axod
        .sessions()
        .into_iter()
        .find(|listed| listed["id"] == session)
        .expect("the Mac lists it");
    axod.wait_for_pi(&listed);
    let pi = listed["shells"]
        .as_array()
        .unwrap()
        .iter()
        .find(|shell| shell["role"] == "pi")
        .unwrap()["id"]
        .clone();

    // A terminal beside Pi: typed into (base64, from sequence 0), resized, laid out, and closed.
    let shell = hub.ok(
        "axo.remote.shell.create",
        json!({ "target": target, "sessionId": session }),
    );
    assert_eq!(shell["sessionId"], session, "{shell}");
    let terminal = shell["shellId"].clone();
    let typed = hub.ok(
        "axo.remote.terminal.input",
        json!({ "target": target, "sessionId": session, "shellId": terminal, "sequence": 0, "data": "ZWNobyBoaQ0=" }),
    );
    assert_eq!(
        (typed["accepted"].clone(), typed["sequence"].clone()),
        (json!(true), json!(0))
    );
    let resized = hub.ok(
        "axo.remote.terminal.resize",
        json!({ "target": target, "sessionId": session, "shellId": terminal, "rows": 30, "columns": 100 }),
    );
    assert_eq!(
        (resized["rows"].clone(), resized["columns"].clone()),
        (json!(30), json!(100))
    );
    // A layout names every pane of the Session, once.
    let shells: Vec<Value> = axod
        .sessions()
        .into_iter()
        .find(|listed| listed["id"] == session)
        .unwrap()["shells"]
        .as_array()
        .unwrap()
        .iter()
        .map(|shell| shell["id"].clone())
        .collect();
    assert!(
        shells.contains(&pi) && shells.contains(&terminal),
        "{shells:?}"
    );
    let split_ids = [
        "7d0e6a52-3f1c-4b8e-9a2d-6c4f1e8b9a10",
        "02a4c161-8143-4c9a-bbf2-1a625e8b8342",
        "5b3f8e21-9c7d-4a1e-b2f0-3d6e8a9c1b47",
    ];
    let mut layout = json!({ "kind": "pane", "shellId": shells.last().unwrap() });
    for (index, shell) in shells.iter().rev().skip(1).enumerate() {
        layout = json!({
            "kind": "split",
            "id": split_ids[index],
            "direction": "right",
            "ratio": 0.5,
            "first": { "kind": "pane", "shellId": shell },
            "second": layout,
        });
    }
    let saved = hub.ok(
        "axo.remote.session.layout.set",
        json!({ "target": target, "sessionId": session, "layout": layout }),
    );
    assert_eq!(saved["saved"], true, "{saved}");
    let closed = hub.ok(
        "axo.remote.shell.close",
        json!({ "target": target, "sessionId": session, "shellId": terminal }),
    );
    assert_eq!(closed["closed"], true, "{closed}");

    // Pi's keys, and stopping a turn that is not running.
    let key = hub.ok(
        "axo.remote.session.key",
        json!({ "target": target, "sessionId": session, "key": "escape" }),
    );
    assert_eq!(key["accepted"], true, "{key}");
    let stop = hub.call(
        "axo.remote.session.stop",
        json!({ "target": target, "sessionId": session, "turnId": "no-such-turn" }),
    );
    match stop {
        Ok(stopped) => assert_eq!(stopped["stopped"], false, "{stopped}"),
        Err(error) => assert!(error["code"].as_i64().is_some_and(|c| c < 0), "{error}"),
    }
    // A stop may name only what the client saw of the run; it must name something.
    let seen = hub.call(
        "axo.remote.session.stop",
        json!({ "target": target, "sessionId": session, "seen": "no-such-entry", "commandIds": ["6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b"] }),
    );
    match seen {
        Ok(stopped) => assert_eq!(stopped["stopped"], false, "{stopped}"),
        Err(error) => assert!(
            error["code"]
                .as_i64()
                .is_some_and(|c| c < 0 && c != INVALID_PARAMS),
            "{error}"
        ),
    }
    let nothing = hub
        .call(
            "axo.remote.session.stop",
            json!({ "target": target, "sessionId": session }),
        )
        .unwrap_err();
    assert_eq!(nothing["code"], INVALID_PARAMS, "{nothing}");
    let unknown_key = hub
        .call(
            "axo.remote.session.key",
            json!({ "target": target, "sessionId": session, "key": "delete" }),
        )
        .unwrap_err();
    assert_eq!(unknown_key["code"], INVALID_PARAMS, "{unknown_key}");
}

/// The actual lease interval, with a real daemon and socket: a cloud call stays pending across
/// a heartbeat, then completes on the same connection. No test-only shorter heartbeat masks it.
#[test]
fn a_slow_relayed_handler_does_not_delay_heartbeats() {
    let hub = FakeHub::start();
    let (axod, _) = linked(&hub, Pi::Fake);
    let gate = axod.directory.join("release-command");
    let started = axod.directory.join("command-started");
    assert!(
        std::process::Command::new("/usr/bin/mkfifo")
            .arg(&gate)
            .status()
            .unwrap()
            .success()
    );
    let call = hub.begin_call("axo.apps.bash", json!({
        "accountId": ACCOUNT_ID,
        "callId": "00000000-0000-4000-8000-000000000042",
        "command": format!("touch '{}'; read -r answer < '{}'; printf '%s' \"$answer\"", started.display(), gate.display()),
        "timeoutMs": 120000,
    }));
    let deadline = Instant::now() + Duration::from_secs(10);
    while !started.exists() {
        assert!(
            Instant::now() < deadline,
            "the relayed handler never started: {}",
            axod.log()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    hub.wait_for_with_timeout(
        "a heartbeat while the command waits",
        Duration::from_secs(75),
        |message| message["method"] == "axo.host.heartbeat",
    );
    assert!(
        hub.received_reply(&call).is_none(),
        "the handler must still be waiting"
    );
    std::fs::write(&gate, b"finished\n").unwrap();
    let reply = hub.wait_for("the slow handler's answer after its heartbeat", |message| {
        message["id"] == call && message.get("method").is_none()
    });
    assert!(reply.get("error").is_none(), "{reply}");
    assert_eq!(reply["result"]["stdout"], "finished");
    assert_eq!(reply["result"]["timedOut"], false);
    assert_eq!(
        hub.received("axo.host.register").len(),
        1,
        "a heartbeat must not require reconnecting"
    );
}
