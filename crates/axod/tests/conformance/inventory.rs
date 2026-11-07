//! Every method axod offers has a conformance test that calls it over the socket.
//!
//! The conformance tests (`tests/conformance/*.rs`) drive a real axod only through its wire, so
//! they hold across rewrites of its insides. This test reads their sources and fails when an
//! advertised method appears in none of them. A method that has no test yet is listed in
//! `NOT_YET_COVERED`, which may only shrink: listing a method that has a test fails too.

use std::collections::BTreeSet;

use axo_protocol::rpc::method;

/// Methods no conformance test calls yet. Remove a method once a test calls it.
const NOT_YET_COVERED: &[&str] = &[];

/// Every black-box test of axod: the conformance suite and the older `tests/rpc.rs`.
fn sources() -> String {
    let marker = std::path::PathBuf::from(
        std::env::var("CONFORMANCE_SOURCES").expect("CONFORMANCE_SOURCES"),
    );
    let runfiles = std::env::var_os("TEST_SRCDIR")
        .map(std::path::PathBuf::from)
        .expect("TEST_SRCDIR");
    let conformance = [runfiles.join(&marker), runfiles.join("_main").join(&marker)]
        .into_iter()
        .find(|candidate| candidate.exists())
        .expect("the conformance sources are in the runfiles")
        .parent()
        .unwrap()
        .to_path_buf();
    let mut text = String::new();
    for directory in [
        conformance.clone(),
        conformance.parent().unwrap().to_path_buf(),
    ] {
        for entry in std::fs::read_dir(&directory).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().is_some_and(|extension| extension == "rs")
                && !path.ends_with("inventory.rs")
            {
                text.push_str(&std::fs::read_to_string(&path).unwrap());
            }
        }
    }
    assert!(
        text.contains("fn a_prompt_reaches_pi"),
        "found the conformance tests in {}",
        conformance.display()
    );
    text
}

/// Whether `sources` call `name`, as the first argument of one of the harness's calls
/// (`ok`, `err`, `call`) or of `rpc.rs`'s (`rpc`, `rpc_with_params`). A name that is merely
/// mentioned, say in an assertion about negotiation, does not count.
fn calls(sources: &str, name: &str) -> bool {
    let compact: String = sources.split_whitespace().collect::<Vec<_>>().join(" ");
    let quoted = format!("\"{name}\"");
    compact.match_indices(&quoted).any(|(at, _)| {
        let before = compact[..at].trim_end();
        let before = before.strip_suffix(',').map_or(before, |rest| {
            // `rpc(&socket, "name"`: skip the socket argument.
            rest.rsplit_once('(').map_or(rest, |(head, _)| head)
        });
        ["ok(", "err(", "call(", "rpc(", "rpc_with_params("]
            .iter()
            .any(|call| before.ends_with(call))
            || ["rpc", "rpc_with_params"]
                .iter()
                .any(|call| before.ends_with(call))
    })
}

#[test]
fn calls_count_only_as_calls() {
    assert!(calls(r#"axod.ok("axo.a", json!({}))"#, "axo.a"));
    assert!(calls("axod.err(\n    \"axo.a\",\n json!({}))", "axo.a"));
    assert!(calls(r#"rpc(&socket, "axo.a")"#, "axo.a"));
    assert!(calls("rpc_with_params(\n &socket,\n \"axo.a\",", "axo.a"));
    assert!(!calls(r#"assert!(methods.contains(&"axo.a"))"#, "axo.a"));
    assert!(!calls(r#"let expected = ["axo.a", "axo.b"];"#, "axo.b"));
}

#[test]
fn every_method_axod_offers_has_a_conformance_test() {
    let sources = sources();
    let offered: BTreeSet<&str> = method::ADVERTISED
        .iter()
        .copied()
        .chain([method::PROTOCOL_NEGOTIATE])
        .collect();
    let called = |name: &str| calls(&sources, name);
    let missing: Vec<&str> = offered
        .iter()
        .copied()
        .filter(|name| !called(name) && !NOT_YET_COVERED.contains(name))
        .collect();
    let stale: Vec<&str> = NOT_YET_COVERED
        .iter()
        .copied()
        .filter(|name| called(name))
        .collect();
    assert!(
        missing.is_empty(),
        "no conformance test calls: {missing:#?}"
    );
    assert!(
        stale.is_empty(),
        "these have tests now; take them off NOT_YET_COVERED: {stale:#?}"
    );
}
