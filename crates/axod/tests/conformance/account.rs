//! What axod offers that needs the person's account, on a Mac that has none: the relay, the
//! account's apps, other Macs, assets, sharing. Each answers plainly that it cannot, and
//! nothing waits or hangs. The Worker's relay tests (`//packages/axo-api-worker:relay_test`)
//! drive the same methods on a linked Mac.
//!
//! Also the methods only Axo.app or axod's own tools may call, refused to anyone else.

#[path = "../support/mod.rs"]
mod support;

use std::thread;
use std::time::{Duration, Instant};

use serde_json::json;
use support::{Axod, Options};

const NOT_CONNECTED: i64 = -32024;
const INVALID_PARAMS: i64 = -32602;

#[test]
fn an_unlinked_mac_says_so_and_connecting_finds_no_account() {
    let axod = Axod::start();
    let status = axod.ok("axo.relay.status", json!({}));
    assert_eq!(status["state"], "disconnected", "{status}");
    assert_eq!(
        status["lastError"], "This Mac is not linked to an Axo account.",
        "{status}"
    );
    assert!(status["connectedSinceUnixMillis"].is_null(), "{status}");
    // Asking to connect is taken, and finds no account to connect to.
    let connect = axod.ok("axo.relay.connect", json!({}));
    assert_eq!(connect["requested"], true, "{connect}");
    thread::sleep(Duration::from_millis(300));
    assert_eq!(
        axod.ok("axo.relay.status", json!({}))["state"],
        "disconnected"
    );
}

#[test]
fn linking_with_a_relay_that_is_not_there_fails_and_leaves_the_mac_unlinked() {
    // A loopback port nothing listens on: linking must fail, quickly, and change nothing.
    let axod = Axod::with(Options {
        relay_url: Some(support::NO_RELAY.into()),
        ..Options::default()
    });
    let started = Instant::now();
    let refused = axod.err("axo.relay.link", json!({ "code": "ABCD-EFGH" }));
    assert!(refused.code < 0, "{refused:?}");
    assert!(
        started.elapsed() < Duration::from_secs(20),
        "took {:?}",
        started.elapsed()
    );
    let status = axod.ok("axo.relay.status", json!({}));
    assert_ne!(status["state"], "connected", "{status}");

    let malformed = axod.err("axo.relay.link", json!({}));
    assert_eq!(malformed.code, INVALID_PARAMS, "{malformed:?}");
}

#[test]
fn the_accounts_apps_are_not_connected_without_an_account() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let quickly = |started: Instant| {
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "waited {:?}",
            started.elapsed()
        )
    };
    let started = Instant::now();
    let refused = [
        axod.err("axo.apps.list", json!({ "sessionId": session })),
        axod.err(
            "axo.apps.search",
            json!({ "sessionId": session, "code": "return 1" }),
        ),
        axod.err(
            "axo.apps.run",
            json!({ "sessionId": session, "code": "return 1" }),
        ),
        axod.err("axo.apps.log", json!({ "sessionId": session })),
        axod.err(
            "axo.apps.add",
            json!({ "sessionId": session, "url": "https://example.com/mcp" }),
        ),
        axod.err(
            "axo.apps.remove",
            json!({ "sessionId": session, "name": "example" }),
        ),
    ];
    quickly(started);
    for error in refused {
        assert_eq!(error.code, NOT_CONNECTED, "{error:?}");
    }
}

#[test]
fn an_unlinked_sessions_brief_leaves_the_account_out() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let started = Instant::now();
    let brief = axod.ok("axo.session.brief", json!({ "sessionId": session }))["brief"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "waited {:?}",
        started.elapsed()
    );
    assert!(brief.starts_with("You run inside Axo"), "{brief}");
    assert!(brief.contains("`session_prompt`"), "{brief}");
    assert!(brief.contains("`elicitation_request`"), "{brief}");
    assert!(!brief.contains("apps_run"), "{brief}");
    assert!(!brief.contains("account, if this Mac is linked"), "{brief}");

    let malformed = axod.err("axo.session.brief", json!({}));
    assert_eq!(malformed.code, INVALID_PARAMS, "{malformed:?}");
}

#[test]
fn other_macs_are_none_without_an_account() {
    let axod = Axod::start();
    let peers = axod.ok("axo.peer.sessions.list", json!({}));
    assert!(peers.to_string().len() < 200, "no other Macs: {peers}");
    let host = "00000000-0000-4000-8000-000000000001";
    let session = "00000000-0000-4000-8000-000000000002";
    let open = axod.err(
        "axo.peer.session.open",
        json!({ "hostId": host, "sessionId": session }),
    );
    assert!(open.code < 0, "{open:?}");
    // Watching answers an empty view of a Mac that is not there, as it would of one offline.
    let watch = axod.ok(
        "axo.peer.session.watch",
        json!({ "hostId": host, "sessionId": session }),
    );
    assert_eq!(watch["connected"], false, "{watch}");
    assert_eq!(watch["hostOnline"], false, "{watch}");
    assert_eq!(watch["records"], json!([]), "{watch}");
    let command = axod.err(
        "axo.peer.command",
        json!({ "hostId": host, "method": "axo.session.prompt", "params": { "sessionId": session, "text": "hi" } }),
    );
    assert!(command.code < 0, "{command:?}");
    // Closing what is not open is not an error: there is nothing to close.
    let closed = axod.ok(
        "axo.peer.session.close",
        json!({ "hostId": host, "sessionId": session }),
    );
    assert_eq!(closed["closed"], false, "{closed}");
}

#[test]
fn only_axods_own_tools_fetch_assets_or_ask_for_input() {
    let axod = Axod::start();
    let session = axod.new_session()["id"].clone();
    let fetch = axod.err("axo.assets.fetch", json!({ "attachments": [] }));
    assert!(fetch.message.contains("only axod"), "{fetch:?}");
    let input = axod.err(
        "axo.computer.input",
        json!({ "sessionId": session, "args": {} }),
    );
    assert!(input.code < 0 && input.code != INVALID_PARAMS, "{input:?}");
    let redactions = axod.err("axo.computer.redactions", json!({}));
    assert_eq!(redactions.code, input.code, "{redactions:?}");
}
