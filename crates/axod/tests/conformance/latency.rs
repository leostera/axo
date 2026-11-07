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
