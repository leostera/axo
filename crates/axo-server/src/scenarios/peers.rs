//! The account's other Macs (RFD0024): their Sessions listed here, and panes on them.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

use axo_protocol::rpc::{self, PeerSessionView};
use axo_protocol::{PaneRole, SessionStatus};
use axo_relay::peers::{ClientRecord, Mirror, PeerCommandError, PeerLive, Place};
use serde_json::json;

use crate::peers::Peers;
use crate::test_support::Fixture;

const STUDIO: &str = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7";
const SESSION: &str = "8f8f8f8f-0000-4000-8000-000000000001";
const ARCHIVED: &str = "8f8f8f8f-0000-4000-8000-000000000002";
const HEADER: &str =
    r#"{"type":"session","version":3,"id":"8f8f8f8f-0000-4000-8000-000000000001","cwd":"/tmp"}"#;

/// A Mac that follows a Studio with one Session, one archived Session, and a listing of one of
/// its own Sessions (which the cloud should not send, and which is never shown).
async fn following() -> (Fixture, Arc<PeerLive>) {
    let fixture = Fixture::new().await;
    let index = fixture.directory.join("peers.json");
    let session = |id: &str, host: &str, archived: bool| {
        json!({
            "hostId": host, "sessionId": id, "epoch": 1, "head": 2, "status": "working",
            "metadata": {
                "name": "Fix the bug", "emoji": "🐛", "folderName": "axo",
                "hasAgent": true, "createdAt": 10, "lastMessageAt": 20, "archived": archived,
            },
        })
    };
    let listing = json!({
        "hosts": [{ "hostId": STUDIO, "hostGeneration": "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230", "label": "Mac Studio", "online": true }],
        "sessions": [
            session(SESSION, STUDIO, false),
            session(ARCHIVED, STUDIO, true),
            session("8f8f8f8f-0000-4000-8000-000000000003", &fixture.core.host_id, false),
        ],
    });
    fs::write(&index, serde_json::to_vec(&listing).unwrap()).unwrap();
    let live = PeerLive::new();
    Peers::attach(&fixture.core, Arc::clone(&live), index);
    (fixture, live)
}

fn place() -> Place {
    Place::of(STUDIO, SESSION).unwrap()
}

fn record(cursor: u64) -> ClientRecord {
    serde_json::from_value(
        json!({ "cursor": cursor, "line": format!(r#"{{"type":"message","id":"m{cursor}"}}"#) }),
    )
    .unwrap()
}

async fn watch(
    fixture: &Fixture,
    epoch: Option<u64>,
    cursor: u64,
    version: u64,
) -> PeerSessionView {
    let core = Arc::clone(&fixture.core);
    core.peers
        .watch(
            &core,
            rpc::WatchPeerSession {
                host_id: STUDIO.to_owned(),
                session_id: SESSION.parse().unwrap(),
                epoch,
                cursor,
                version,
                timeout_ms: Some(10),
                window: None,
            },
        )
        .await
        .unwrap()
}

fn cursors(view: &PeerSessionView) -> Vec<u64> {
    view.records.iter().map(|record| record.cursor).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn other_macs_sessions_are_listed_but_never_as_this_macs() {
    let (fixture, _live) = following().await;
    let list = fixture.core.peers.list(&fixture.core).unwrap();
    assert_eq!(list.hosts.len(), 1);
    assert_eq!(list.hosts[0].label, "Mac Studio");
    assert_eq!(
        list.sessions
            .iter()
            .map(|peer| peer.session.id.to_string())
            .collect::<Vec<_>>(),
        vec![SESSION],
        "archived Sessions and this Mac's own are left out"
    );
    let session = &list.sessions[0];
    assert_eq!(session.host_id, STUDIO);
    assert_eq!(
        (session.session.name.as_str(), session.session.status),
        ("Fix the bug", SessionStatus::Working)
    );
    assert!(
        session.session.shells.is_empty(),
        "no pane until one is opened"
    );
    assert!(fixture.core.catalog.records().is_empty());
    assert!(!list.connected);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pane_reads_on_from_its_cursor_and_starts_over_after_a_cut() {
    let (fixture, _live) = following().await;
    let mut mirror = Mirror::new(fixture.directory.join("sessions"));
    mirror
        .start(&place(), 1, HEADER, &[record(1), record(2)])
        .unwrap();

    let first = watch(&fixture, None, 0, 0).await;
    assert!(first.reset, "a first look draws from nothing");
    assert_eq!((first.epoch, first.cursor), (Some(1), 2));
    assert_eq!(cursors(&first), vec![1, 2]);
    assert_eq!(
        (first.host_label.as_str(), first.status),
        ("Mac Studio", Some(SessionStatus::Working))
    );

    mirror.append(&place(), 1, &[record(3)]).unwrap();
    let next = watch(&fixture, Some(1), 2, first.version).await;
    assert!(!next.reset);
    assert_eq!(cursors(&next), vec![3]);

    // The Studio cut its log back: the pane drops what it drew and draws the copy again.
    mirror.reset(&place(), 2, 1).unwrap();
    let cut = watch(&fixture, Some(1), 3, next.version).await;
    assert!(cut.reset);
    assert_eq!((cut.epoch, cut.cursor), (Some(2), 1));
    assert_eq!(cursors(&cut), vec![1]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_remote_pane_is_pi_with_no_session_file_in_remote_mode() {
    let (mut fixture, _live) = following().await;
    fixture.listen();
    // The stored agent command is the fixture's stand-in: it records how it was started.
    let recorded = fixture.directory.join("launched");
    let agent = fixture.directory.join("silent-shell");
    fs::write(
        &agent,
        format!(
            "#!/bin/sh\necho \"$@\" \"$AXO_REMOTE_HOST_ID\" \"$AXO_REMOTE_SESSION_ID\" \"$AXO_REMOTE_HOST_LABEL\" \"${{AXO_SESSION_ID:-none}}\" > {}\nexec /bin/sleep 60\n",
            recorded.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&agent, fs::Permissions::from_mode(0o700)).unwrap();

    let opened = Peers::open(&fixture.core, STUDIO, SESSION.parse().unwrap()).unwrap();
    let shell = opened.session.shells[0].clone();
    assert_eq!(shell.role, PaneRole::Pi);
    let again = Peers::open(&fixture.core, STUDIO, SESSION.parse().unwrap()).unwrap();
    assert_eq!(again.session.shells[0].id, shell.id, "one pane per Session");

    fixture
        .until("the pane to start Pi", || {
            fs::read_to_string(&recorded).is_ok_and(|text| !text.is_empty())
        })
        .await;
    let launched = fs::read_to_string(&recorded).unwrap();
    assert!(
        launched.starts_with(
            "--no-session --no-extensions --no-mcp --no-skills --no-prompt-templates --extension "
        ),
        "{launched}"
    );
    assert!(
        launched
            .trim_end()
            .ends_with(&format!("{STUDIO} {SESSION} Mac Studio none")),
        "{launched}"
    );

    let socket = fixture.core.attach_socket_path.clone();
    let attached =
        tokio::task::spawn_blocking(move || axo_pty::attach::connect(&socket, shell.id.get()))
            .await
            .unwrap();
    assert!(attached.is_ok(), "the Mac app attaches as to any pane");
    let listed = fixture.core.peers.list(&fixture.core).unwrap();
    assert_eq!(listed.sessions[0].session.shells.len(), 1);
    assert!(
        fixture.core.catalog.records().is_empty(),
        "not one of this Mac's"
    );

    assert!(Peers::close(&fixture.core, SESSION.parse().unwrap()));
    let listed = fixture.core.peers.list(&fixture.core).unwrap();
    assert!(listed.sessions[0].session.shells.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn commands_go_out_only_while_following_and_only_prompts_stops_and_keys() {
    let (fixture, live) = following().await;
    let command = |method: &str| rpc::PeerCommand {
        host_id: STUDIO.to_owned(),
        method: method.to_owned(),
        params: serde_json::Map::new(),
    };
    let send = |request: rpc::PeerCommand| {
        let core = Arc::clone(&fixture.core);
        async move { core.peers.command(request).await }
    };
    assert_eq!(
        send(command("axo.remote.session.prompt")).await,
        Err(PeerCommandError::offline())
    );
    assert_eq!(
        send(command("axo.remote.session.close"))
            .await
            .unwrap_err()
            .code,
        -32602
    );
    assert!(!live.is_connected());
}
