//! How long the Mac takes to answer, measured alone (its Bazel target is `exclusive`): numbers
//! taken while other tests share the machine say more about the machine than about axod.

#[path = "../support/mod.rs"]
mod support;

use std::time::{Duration, Instant};

use serde_json::{Value, json};
use support::hub::{CODE, FakeHub};
use support::{Axod, Options, Pi};

/// A Mac linked through `hub`, and the target the account names it by.
fn linked(hub: &FakeHub) -> (Axod, Value) {
    let axod = Axod::with(Options {
        pi: Pi::Fake,
        relay_url: Some(hub.url()),
        ..Options::default()
    });
    let link = axod.ok("axo.relay.link", json!({ "code": CODE }));
    assert_eq!(link["linked"], true, "{link}");
    let register = hub.wait_for_request("axo.host.register");
    let target = json!({
        "hostId": register["params"]["hostId"],
        "hostGeneration": register["params"]["hostGeneration"],
    });
    (axod, target)
}

/// Nothing in the relay loop polls (RFD0034, step 7): a request is read as it arrives and its
/// answer sent as soon as it is ready. A loop that checked the socket on a timer would add half
/// its period to every call; the median of many calls shows it under any load.
#[test]
fn the_account_s_calls_are_answered_without_waiting_for_a_poll() {
    let hub = FakeHub::start();
    let (_axod, target) = linked(&hub);
    let mut took: Vec<Duration> = (0..40)
        .map(|_| {
            let started = Instant::now();
            hub.ok("axo.remote.workspace.list", json!({ "target": target }));
            started.elapsed()
        })
        .collect();
    took.sort();
    let median = took[took.len() / 2];
    assert!(
        median < Duration::from_millis(5),
        "median {median:?} of {took:?}"
    );
}

/// A command for Pi goes out as it is sent, not on the bridge worker's next wake: the worker
/// sleeps on Pi's socket and its command queue together (RFD0034, step 7). A worker that read
/// with a timeout would hold every command for half its period on average (it was 200ms).
#[test]
fn a_command_reaches_pi_without_waiting_for_a_poll() {
    let hub = FakeHub::start();
    let (axod, target) = linked(&hub);
    let session = axod.wait_for_pi(&axod.sessions()[0])["id"].clone();
    // Pi says what it runs once it is bound, so the bridge is up.
    axod.wait_for("Pi's bridge to bind", || {
        let listed = axod.ok("axo.session.catalog", json!({}));
        listed["sessions"]
            .as_array()?
            .iter()
            .find(|s| s["id"] == session)
            .filter(|s| s["pi"].is_object())
            .map(|_| ())
    });
    let mut took: Vec<Duration> = (0..20)
        .map(|turn| {
            let level = ["low", "high"][turn % 2];
            let started = Instant::now();
            let saved = hub.ok(
                "axo.remote.session.model.set",
                json!({ "target": target, "sessionId": session, "thinkingLevel": level }),
            );
            assert_eq!(saved["saved"], true, "{saved}");
            started.elapsed()
        })
        .collect();
    took.sort();
    let median = took[took.len() / 2];
    assert!(
        median < Duration::from_millis(30),
        "median {median:?} of {took:?}"
    );
}
