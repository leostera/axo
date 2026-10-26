//! Conformance with the published v1 contract in `schemas/axo.leostera.dev/v1`.
//!
//! Fixtures whose shape the schema pins exactly must round-trip through these types unchanged.
//! For records the schema describes loosely (most session fields are optional there, while
//! Axod always sends them), what these types produce is checked against the schema instead:
//! every required key is present and nothing outside `properties` appears.

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::rpc::{ConfigValue, NextEvents, ProtocolNegotiated, TerminalInput, TerminalResize};
use crate::{
    Availability, Event, Layout, PaneRole, RelayStatus, SessionId, SessionRecord, SessionStatus,
    ShellId, ShellRecord,
};

macro_rules! fixture {
    ($name:literal) => {
        include_str!(concat!(
            "../../../schemas/axo.leostera.dev/v1/fixtures/",
            $name
        ))
    };
}

const COMMON_SCHEMA: &str = include_str!("../../../schemas/axo.leostera.dev/v1/common.schema.json");

fn round_trips<T: DeserializeOwned + Serialize>(value: &Value) {
    let typed: T = serde_json::from_value(value.clone())
        .unwrap_or_else(|error| panic!("{value} does not parse: {error}"));
    assert_eq!(&serde_json::to_value(typed).unwrap(), value);
}

fn json(source: &str) -> Value {
    serde_json::from_str(source).unwrap()
}

#[test]
fn exactly_specified_fixtures_round_trip() {
    round_trips::<Event>(&json(fixture!("terminal-output.event.json"))["params"]["event"]);
    round_trips::<NextEvents>(&json(fixture!("events-next.call.json"))["params"]);
    round_trips::<TerminalInput>(&json(fixture!("terminal-input.local.call.json"))["params"]);
    round_trips::<TerminalResize>(&json(fixture!("terminal-resize.local.call.json"))["params"]);
    round_trips::<crate::Viewport>(
        &json(fixture!("client-viewport-set.local.call.json"))["params"],
    );
    round_trips::<ProtocolNegotiated>(&json(fixture!("negotiate.result.json")));
    round_trips::<ConfigValue>(&json(fixture!("config.value.shell.json")));
    round_trips::<ConfigValue>(&json(fixture!("config.value.agent.json")));
    round_trips::<RelayStatus>(&json(fixture!("remote-access-status.result.json")));
}

/// Checks `value`'s keys against the schema definition `name` in `common.schema.json`.
fn conforms_to(name: &str, value: &Value) {
    let schema = json(COMMON_SCHEMA);
    let definition = &schema["$defs"][name];
    let object = value.as_object().unwrap();
    let allowed = definition["properties"].as_object().unwrap();
    for key in object.keys() {
        assert!(allowed.contains_key(key), "{name} does not allow `{key}`");
    }
    for required in definition["required"].as_array().unwrap() {
        let required = required.as_str().unwrap();
        assert!(
            object.contains_key(required),
            "{name} requires `{required}`"
        );
    }
}

fn shell(id: i64, role: PaneRole, availability: Availability) -> ShellRecord {
    ShellRecord {
        id: ShellId::new(id).unwrap(),
        pane_id: (role == PaneRole::Pi).then(|| "2896bac4-a44b-44b2-9869-f4facf3adf33".to_owned()),
        role,
        process_id: 4321,
        initial_pwd: "/tmp".into(),
        pty_device: "/dev/ttys001".to_owned(),
        attach_socket_path: "/tmp/axo/attach.sock".into(),
        availability,
    }
}

#[test]
fn produced_session_records_conform_to_the_schema() {
    let session = SessionRecord {
        id: SessionId::new(9).unwrap(),
        session_uuid: "a0b7d77a-5551-4cbc-8dfc-75b2d466dece".to_owned(),
        pi_session_file: Some("/tmp/session.jsonl".into()),
        pi_session_id: Some("pi-session".to_owned()),
        workspace_id: Some("7f1918d3-8b6d-4af4-a57e-7e6ae28e89e2".to_owned()),
        workspace_name: Some("Axo".to_owned()),
        name: "Session 1".to_owned(),
        manual_name: None,
        emoji: Some("🦀".to_owned()),
        last_message_at: None,
        status: SessionStatus::Ready,
        initial_pwd: "/tmp".into(),
        shells: vec![
            shell(
                12,
                PaneRole::Pi,
                Availability::Unavailable {
                    reason: "gone".to_owned(),
                },
            ),
            shell(13, PaneRole::Terminal, Availability::Available),
        ],
        layout: Some(Layout::single(ShellId::new(13).unwrap())),
    };
    let value = serde_json::to_value(&session).unwrap();
    conforms_to("LocalSession", &value);
    for shell in value["shells"].as_array().unwrap() {
        conforms_to("LocalShell", shell);
    }
}

#[test]
fn session_fixtures_parse_as_shells() {
    // The session fixtures omit fields Axod always sends, so only their shells are complete.
    for source in [fixture!("session-list.result.json")] {
        for session in json(source)["sessions"].as_array().unwrap() {
            for shell in session["shells"].as_array().unwrap() {
                let mut shell = shell.clone();
                shell["role"] = Value::from("terminal");
                serde_json::from_value::<ShellRecord>(shell).unwrap();
            }
        }
    }
}
