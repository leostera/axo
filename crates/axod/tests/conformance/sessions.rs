//! Sessions and their agent: creating, prompting, the turn's events, the transcript, closing,
//! reopening, and surviving restarts and crashes of Pi and of axod.

#[path = "../support/mod.rs"]
mod support;

use serde_json::{Value, json};
use support::{Axod, Options, Pi, pane};

const INVALID_PARAMS: i64 = -32602;

fn session(axod: &Axod, id: &Value) -> Value {
    axod.sessions()
        .into_iter()
        .find(|listed| &listed["id"] == id)
        .unwrap_or_else(|| panic!("Session {id} is not open"))
}

fn pi_pid(session: &Value) -> i32 {
    pane(session, "pi")["processId"].as_i64().unwrap() as i32
}

fn transcript(session: &Value) -> String {
    let file = session["piSessionFile"]
        .as_str()
        .expect("a Pi Session has a transcript file");
    std::fs::read_to_string(file).unwrap_or_default()
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only asks whether the process exists.
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
}

#[test]
fn a_new_axod_opens_no_session_and_starts_each_where_it_is_asked() {
    let axod = Axod::start();
    assert!(axod.sessions().is_empty(), "nothing opens by itself");
    let project = axod.directory.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let project = std::fs::canonicalize(&project).unwrap();

    let first = axod.ok("axo.session.create", json!({ "folder": project }));
    assert_eq!(first["folder"], json!(project), "{first}");
    let roles: Vec<&str> = first["shells"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["role"].as_str().unwrap())
        .collect();
    assert_eq!(roles, ["pi", "terminal"], "Pi beside a terminal: {first}");
    let beside = axod.ok("axo.session.create", json!({ "like": first["id"] }));
    assert_eq!(beside["folder"], json!(project), "{beside}");
    let home = axod.ok("axo.session.create", json!({}));
    assert_eq!(
        home["folder"],
        json!(std::fs::canonicalize(axod.home()).unwrap()),
        "{home}"
    );
    for refused in [
        json!({ "folder": "relative/path" }),
        json!({ "folder": project.join("missing") }),
        json!({ "folder": project, "like": first["id"] }),
        json!({ "workspaceId": "gone" }),
    ] {
        assert_eq!(
            axod.err("axo.session.create", refused.clone()).code,
            INVALID_PARAMS,
            "{refused}"
        );
    }

    for session in [&first, &beside, &home] {
        let closed = axod.ok("axo.session.close", json!({ "sessionId": session["id"] }));
        assert_eq!(closed, json!({ "archivedSessionId": session["id"] }));
    }
    assert!(axod.sessions().is_empty(), "nothing replaces the last one");
}

#[test]
fn a_prompt_reaches_pi_and_its_turn_streams_back_and_is_recorded() {
    let axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    let mut events = axod.subscribe(json!({ "sessionId": id }));

    let accepted = axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "run the tests" }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");

    // Pi's own events come through unchanged, in order, ending with the turn's end. What Pi
    // says of itself once it has started (its state, commands and models, RFD0033) comes
    // whenever it is ready, so it is not part of the turn.
    let names: Vec<String> = {
        events.wait_for("the turn to end", |event| {
            (event["type"] == "pi.event" && event["name"] == "agent.end").then_some(())
        });
        events
            .seen
            .iter()
            .filter(|e| e["type"] == "pi.event")
            .map(|e| e["name"].as_str().unwrap().to_owned())
            .filter(|name| !matches!(name.as_str(), "pi.state" | "pi.commands" | "pi.models"))
            .collect()
    };
    assert_eq!(
        names.first().map(String::as_str),
        Some("message.end"),
        "{names:?}"
    );
    assert!(names.contains(&"agent.start".to_owned()), "{names:?}");
    let sequences: Vec<u64> = events
        .seen
        .iter()
        .filter(|e| e["type"] == "pi.event")
        .map(|e| e["sequence"].as_u64().unwrap())
        .collect();
    assert!(
        sequences.windows(2).all(|pair| pair[0] < pair[1]),
        "{sequences:?}"
    );

    assert!(
        axod.pi_log().contains("SENT:run the tests\n"),
        "{}",
        axod.pi_log()
    );
    let after = axod.wait_for("the Session to record its last message", || {
        let listed = session(&axod, &id);
        listed["lastMessageAt"].is_i64().then_some(listed)
    });
    let recorded = transcript(&after);
    assert!(
        recorded.contains("run the tests") && recorded.contains("Done: run the tests"),
        "{recorded}"
    );
    assert_eq!(
        after["piSessionId"], created["piSessionId"],
        "the same Pi conversation"
    );
}

#[test]
fn a_prompt_while_working_follows_up_by_default_and_is_refused_as_a_turn() {
    let axod = Axod::with(Options {
        env: vec![("AXO_FAKE_PI_TURN_MS".into(), "1500".into())],
        ..Options::default()
    });
    let id = axod.new_session()["id"].clone();
    let mut events = axod.subscribe(json!({ "sessionId": id }));
    axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "first" }),
    );
    events.wait_for("the turn to start", |e| {
        (e["name"] == "agent.start").then_some(())
    });

    let refused = axod.err(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "now", "delivery": "turn" }),
    );
    assert!(
        refused.message.contains("busy") || refused.code < 0,
        "{refused:?}"
    );
    axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "second" }),
    );

    // Both turns run, the follow-up after the first.
    let mut ended = 0;
    events.wait_for("both turns to end", |e| {
        if e["name"] == "agent.end" {
            ended += 1;
        }
        (ended == 2).then_some(())
    });
    let log = axod.pi_log();
    let first = log.find("SENT:first").unwrap();
    let second = log.find("SENT:second").unwrap();
    assert!(first < second, "{log}");
    assert!(
        log.contains("BUSY:now"),
        "Pi itself refuses a turn while working: {log}"
    );
}

#[test]
fn prompts_are_checked_before_they_reach_pi() {
    let axod = Axod::start();
    let id = axod.new_session()["id"].clone();
    let empty = axod.err("axo.session.prompt", json!({ "sessionId": id, "text": "" }));
    assert_eq!(empty.code, INVALID_PARAMS, "{empty:?}");
    let long = axod.err(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "x".repeat(16_001) }),
    );
    assert_eq!(long.code, INVALID_PARAMS, "{long:?}");
    let nobody = axod.err(
        "axo.session.prompt",
        json!({ "sessionId": "00000000-0000-4000-8000-000000000000", "text": "hi" }),
    );
    assert!(nobody.code < 0, "{nobody:?}");
    assert!(!axod.pi_log().contains("SENT:"), "{}", axod.pi_log());
}

#[test]
fn a_prompt_sent_while_pi_starts_waits_for_it() {
    let axod = Axod::with(Options {
        env: vec![("AXO_FAKE_PI_STARTUP_MS".into(), "1500".into())],
        ..Options::default()
    });
    let id = axod.ok("axo.session.create", json!({}))["id"].clone();
    let accepted = axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "early" }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
    axod.wait_for("the early prompt to reach Pi", || {
        axod.pi_log().contains("SENT:early").then_some(())
    });
}

#[test]
fn renaming_sets_the_persons_name_beside_pis() {
    let axod = Axod::start();
    let id = axod.new_session()["id"].clone();
    let pis = session(&axod, &id)["name"].clone();
    let renamed = axod.ok(
        "axo.session.rename",
        json!({ "sessionId": id, "name": "Release" }),
    );
    assert_eq!(renamed["manualName"], "Release");
    // `name` stays Pi's title; clients show `manualName` over it.
    assert_eq!(session(&axod, &id)["name"], pis);
    assert_eq!(session(&axod, &id)["manualName"], "Release");
    for bad in ["", " padded ", "x".repeat(81).as_str(), "line\nbreak"] {
        let refused = axod.err(
            "axo.session.rename",
            json!({ "sessionId": id, "name": bad }),
        );
        assert_eq!(refused.code, INVALID_PARAMS, "{bad:?}: {refused:?}");
    }
    assert_eq!(session(&axod, &id)["manualName"], "Release");
}

#[test]
fn a_closed_session_keeps_its_transcript_and_reopens_with_it() {
    let axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    let mut events = axod.subscribe(json!({ "sessionId": id }));
    axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "remember this" }),
    );
    events.wait_for("the turn to end", |e| {
        (e["name"] == "agent.end").then_some(())
    });
    drop(events);

    let pid = pi_pid(&session(&axod, &id));
    axod.ok("axo.session.close", json!({ "sessionId": id }));
    assert!(axod.sessions().iter().all(|s| s["id"] != id));
    axod.wait_for("the closed Session's Pi to exit", || {
        (!alive(pid)).then_some(())
    });
    let catalog = axod.ok("axo.session.catalog", json!({}));
    let archived = catalog["archived"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == id)
        .cloned()
        .expect("archived");
    assert!(archived["archivedAt"].is_i64(), "{archived}");

    // Reopening takes the most recently closed Session.
    let reopened = axod.ok("axo.session.reopen", json!({}));
    assert_eq!(reopened["id"], id);
    axod.wait_for_pi(&reopened);
    let listed = session(&axod, &id);
    assert_eq!(listed["piSessionFile"], created["piSessionFile"]);
    assert!(transcript(&listed).contains("remember this"));
}

fn wait_for_unavailable_pi(axod: &Axod, id: &Value) -> Value {
    axod.wait_for("the Pi pane to become unavailable", || {
        let listed = session(axod, id);
        let pi = pane(&listed, "pi");
        (pi["available"] == false && pi["availabilityReason"].is_string()).then(|| listed.clone())
    })
}

#[test]
fn a_pi_that_dies_leaves_its_pane_unavailable_until_it_is_restarted() {
    let axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    let shell = pane(&created, "pi")["id"].clone();
    let mut events = axod.subscribe(json!({ "sessionId": id }));
    axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "first life" }),
    );
    events.wait_for("the turn to end", |e| {
        (e["name"] == "agent.end").then_some(())
    });
    drop(events);

    let before = pi_pid(&created);
    // SAFETY: kills only the fake Pi this test's axod launched.
    unsafe { libc::kill(before, libc::SIGKILL) };
    wait_for_unavailable_pi(&axod, &id);
    let terminal = pane(&session(&axod, &id), "terminal").clone();
    assert_eq!(
        terminal["available"], true,
        "the terminal beside it lives on"
    );

    axod.ok(
        "axo.session.pi.restart.auto.v1",
        json!({ "sessionId": id, "shellId": shell }),
    );
    axod.wait_for_pi(&created);
    let after = session(&axod, &id);
    assert_ne!(pi_pid(&after), before);
    assert_eq!(
        after["piSessionFile"], created["piSessionFile"],
        "the same conversation"
    );
    assert!(transcript(&after).contains("first life"));
}

#[test]
fn a_forced_restart_also_recovers_a_dead_pi() {
    let axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    let shell = pane(&created, "pi")["id"].clone();
    // SAFETY: kills only the fake Pi this test's axod launched.
    unsafe { libc::kill(pi_pid(&created), libc::SIGKILL) };
    wait_for_unavailable_pi(&axod, &id);
    axod.ok(
        "axo.session.pi.restart.force.v2",
        json!({ "sessionId": id, "shellId": shell }),
    );
    axod.wait_for_pi(&created);
    axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "back" }),
    );
    axod.wait_for("the new Pi to take the prompt", || {
        axod.pi_log().contains("SENT:back").then_some(())
    });
}

#[test]
fn restarting_a_pi_that_is_running_is_refused_and_leaves_it_alone() {
    let axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    let shell = pane(&created, "pi")["id"].clone();
    let pid = pi_pid(&created);
    let auto = axod.err(
        "axo.session.pi.restart.auto.v1",
        json!({ "sessionId": id, "shellId": shell }),
    );
    assert!(auto.message.contains("safe opportunity"), "{auto:?}");
    let forced = axod.err(
        "axo.session.pi.restart.force.v2",
        json!({ "sessionId": id, "shellId": shell }),
    );
    assert!(forced.message.contains("no longer available"), "{forced:?}");
    let terminal = pane(&created, "terminal")["id"].clone();
    let not_pi = axod.err(
        "axo.session.pi.restart.force.v2",
        json!({ "sessionId": id, "shellId": terminal }),
    );
    assert!(not_pi.code < 0, "{not_pi:?}");
    assert!(alive(pid));
    assert_eq!(pi_pid(&session(&axod, &id)), pid);
}

#[test]
fn a_prompt_to_a_dead_pi_is_refused_not_lost() {
    let axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    // SAFETY: kills only the fake Pi this test's axod launched.
    unsafe { libc::kill(pi_pid(&created), libc::SIGKILL) };
    wait_for_unavailable_pi(&axod, &id);
    match axod.call(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "anyone?" }),
    ) {
        Err(error) => assert!(error.code < 0, "{error:?}"),
        Ok(accepted) => {
            // If axod takes it, it must start a Pi to deliver it.
            assert_eq!(accepted["accepted"], true, "{accepted}");
            axod.wait_for("the prompt to reach a new Pi", || {
                axod.pi_log().contains("SENT:anyone?").then_some(())
            });
        }
    }
}

#[test]
fn sessions_and_conversations_survive_restarting_axod() {
    let mut axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    axod.ok(
        "axo.session.rename",
        json!({ "sessionId": id, "name": "Survivor" }),
    );
    let mut events = axod.subscribe(json!({ "sessionId": id }));
    axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "before restart" }),
    );
    events.wait_for("the turn to end", |e| {
        (e["name"] == "agent.end").then_some(())
    });
    drop(events);

    axod.restart();
    let restored = session(&axod, &id);
    assert_eq!(restored["manualName"], "Survivor");
    assert_eq!(restored["piSessionFile"], created["piSessionFile"]);
    axod.wait_for_pi(&restored);
    assert!(transcript(&session(&axod, &id)).contains("before restart"));
    axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "after restart" }),
    );
    axod.wait_for("the prompt after the restart", || {
        axod.pi_log().contains("SENT:after restart").then_some(())
    });
}

#[test]
fn pis_end_with_axod_even_when_it_crashes() {
    let mut axod = Axod::start();
    let created = axod.new_session();
    let id = created["id"].clone();
    let old_pi = pi_pid(&created);
    axod.crash();
    // Nothing ran on axod's way out; Pi hears its lifeline end and exits by itself.
    axod.wait_for("the crashed axod's Pi to exit", || {
        (!alive(old_pi)).then_some(())
    });
    axod.restart();
    let restored = session(&axod, &id);
    assert_eq!(restored["piSessionFile"], created["piSessionFile"]);
    let restored = axod.wait_for_pi(&restored);
    assert_ne!(pi_pid(&restored), old_pi);
}

#[test]
fn a_pi_left_running_by_an_earlier_axod_is_replaced_at_boot() {
    // A Pi that ignores hangups and its lifeline outlives axod and keeps the transcript.
    let mut axod = Axod::with(Options {
        env: vec![("AXO_FAKE_PI_STUBBORN".into(), "1".into())],
        ..Options::default()
    });
    let created = axod.new_session();
    let id = created["id"].clone();
    let old_pi = pi_pid(&created);
    axod.crash();
    std::thread::sleep(std::time::Duration::from_millis(300));
    assert!(alive(old_pi));
    axod.restart();
    let restored = axod.wait_for_pi(&session(&axod, &id));
    assert_eq!(restored["piSessionFile"], created["piSessionFile"]);
    assert_ne!(pi_pid(&restored), old_pi);
    axod.wait_for("the old Pi to be killed", || (!alive(old_pi)).then_some(()));
    assert!(
        axod.log().contains("event=pi.previous_killed"),
        "{}",
        axod.log()
    );
}

#[test]
fn a_frozen_pi_is_still_stopped_when_axod_stops() {
    let mut axod = Axod::start();
    let created = axod.new_session();
    let old_pi = pi_pid(&created);
    // SAFETY: signals the fake Pi this test's axod started.
    assert_eq!(unsafe { libc::kill(old_pi, libc::SIGSTOP) }, 0);
    // Stopping is not exiting: the Session keeps its Pi.
    std::thread::sleep(std::time::Duration::from_millis(300));
    assert_eq!(pi_pid(&session(&axod, &created["id"])), old_pi);
    axod.stop();
    assert!(
        !alive(old_pi),
        "axod stops every Pi it started, frozen or not"
    );
}

#[test]
fn a_sleeping_pi_leaves_the_session_usable() {
    // A Pi that never binds its bridge (an old Pi, or one stuck starting): axod still serves.
    let axod = Axod::with(Options {
        pi: Pi::Sleeping,
        ..Options::default()
    });
    let health = axod.wait_for("axod to be ready", || {
        let health = axod.ok("axo.daemon.health", json!({}));
        (health["ready"] == true).then_some(health)
    });
    assert_eq!(health["status"], "running");
    let id = axod.ok("axo.session.create", json!({}))["id"].clone();
    let accepted = axod.ok(
        "axo.session.prompt",
        json!({ "sessionId": id, "text": "queued" }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
}
