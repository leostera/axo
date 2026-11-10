//! Creating, closing and restoring Sessions, their panes and their processes.

use std::fs;
use std::path::Path;
use std::time::Duration;

use axo_protocol::rpc::CreateSession;
use axo_protocol::{Layout, LayoutDirection, LayoutNode};
use axo_protocol::{PaneRole, ShellId, Viewport, new_uuid_v4};

use crate::sessions;
use crate::test_support::{Fixture, Pi, alive, pane, pid};

fn viewport(width: f64) -> Viewport {
    serde_json::from_value(serde_json::json!({
        "terminalArea": { "width": width, "height": 600.0 },
        "backingScale": 2.0,
        "cell": { "width": 16, "height": 34 },
        "padding": { "top": 10, "bottom": 10, "left": 2, "right": 2 },
        "dividerThickness": 1.0
    }))
    .unwrap()
}

async fn pty_size(fixture: &Fixture, id: axo_protocol::SessionId, shell: ShellId) -> (u16, u16) {
    sessions::handle(&fixture.core, id)
        .unwrap()
        .with(move |session| session.pty_size(shell))
        .await
        .unwrap()
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_session_is_listed_with_its_pi_and_stored_identity() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    assert_eq!(record.shells.len(), 2);
    assert!(fixture.core.catalog.contains(record.id));
    let pid = pid(&record, PaneRole::Pi);
    assert!(alive(pid), "{record:?}");
    let id = record.id;
    let stored = fixture
        .core
        .store
        .call(move |database| axo_store::load_pi_process(database, id))
        .await
        .unwrap()
        .expect("Pi's identity is stored when it starts");
    assert!(stored.starts_with(&format!("{pid}:")), "{stored}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_session_starts_in_a_folder_beside_another_or_at_home_and_nothing_replaces_it() {
    let fixture = Fixture::new().await;
    let core = &fixture.core;
    let project = fixture.directory.join("project");
    fs::create_dir_all(&project).unwrap();
    assert!(
        core.catalog.records().is_empty(),
        "nothing is opened for you"
    );

    let first = sessions::create(core, CreateSession::InFolder(project.clone()))
        .await
        .unwrap();
    assert_eq!(first.folder, project);
    assert!(
        first
            .shells
            .iter()
            .all(|shell| shell.initial_pwd == project)
    );
    assert_eq!(
        first.pi_session_file.as_deref().and_then(Path::parent),
        Some(core.pi_directories.transcripts.as_path()),
        "a transcript is under its Mac's folder, by the Session's id"
    );
    let beside = sessions::create(core, CreateSession::Like(first.id))
        .await
        .unwrap();
    assert_eq!(beside.folder, project);
    assert_eq!(beside.name, "Session 2", "numbered within its folder");
    let home = sessions::create(core, CreateSession::default())
        .await
        .unwrap();
    assert_eq!(home.folder, core.home);

    // A relative folder, or a folder and a Session at once, cannot be asked for at all
    // (`CreateSession`'s parsing); a folder that is not there is refused here.
    for refused in [CreateSession::InFolder(fixture.directory.join("missing"))] {
        assert!(sessions::create(core, refused).await.is_err());
    }

    for session in [&first, &beside, &home] {
        sessions::close(core, session.id).await.unwrap();
    }
    assert!(
        core.catalog.records().is_empty(),
        "closing the last Session leaves none"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_manual_name_is_kept_apart_from_pis() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let renamed = crate::ops::rename(&fixture.core, record.id, "Sidebar label".into())
        .await
        .unwrap();
    assert_eq!(renamed.name, record.name, "Pi's name stays Pi's");
    assert_eq!(renamed.manual_name.as_deref(), Some("Sidebar label"));
    assert!(
        crate::ops::rename(&fixture.core, record.id, String::new())
            .await
            .is_err(),
        "a name has 1 to 80 characters"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_imported_transcript_is_copied_without_touching_the_source_and_through_symlinks() {
    let fixture = Fixture::new().await;
    let directory = &fixture.directory;
    let source = directory.join("source.jsonl");
    let destination = directory.join("owned-copy.jsonl");
    fs::write(
        &source,
        b"{\"type\":\"session\",\"version\":3,\"id\":\"source-id\",\"cwd\":\"/work\"}\n{\"type\":\"message\",\"id\":\"entry\"}\n",
    )
    .unwrap();
    sessions::copy_pi_transcript(&source, &destination, Path::new("/target")).unwrap();
    assert!(source.is_file());
    let copied = fs::read_to_string(&destination).unwrap();
    let mut lines = copied.lines();
    let header: serde_json::Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    assert_eq!(header["id"], "source-id");
    assert_eq!(header["cwd"], "/target", "the copy works in its new folder");
    assert_eq!(
        lines.next().unwrap(),
        "{\"type\":\"message\",\"id\":\"entry\"}"
    );

    let link = directory.join("linked.jsonl");
    std::os::unix::fs::symlink(&source, &link).unwrap();
    let linked_copy = directory.join("linked-copy.jsonl");
    sessions::copy_pi_transcript(&link, &linked_copy, Path::new("/target")).unwrap();
    assert!(
        !fs::symlink_metadata(&linked_copy)
            .unwrap()
            .file_type()
            .is_symlink()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_a_session_stops_its_processes_and_forgets_it() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let extra = crate::ops::create_shell(&fixture.core, record.id)
        .await
        .unwrap();
    let mut pids: Vec<i32> = record.shells.iter().map(|s| s.process_id as i32).collect();
    pids.push(extra.process_id as i32);
    assert_eq!(pids.len(), 3);
    sessions::close(&fixture.core, record.id).await.unwrap();
    assert!(!fixture.core.catalog.contains(record.id));
    assert!(!fixture.core.registry.contains(record.id));
    fixture
        .until("its processes to stop", || {
            pids.iter().all(|pid| !alive(*pid))
        })
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_terminal_whose_program_exits_leaves_the_session_at_once() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let terminal = pane(&record, PaneRole::Terminal);
    // SAFETY: kills the stand-in shell this test's core started.
    assert_eq!(
        unsafe { libc::kill(pid(&record, PaneRole::Terminal), libc::SIGKILL) },
        0
    );
    fixture
        .until("the terminal to leave its Session", || {
            fixture
                .listed(record.id)
                .is_some_and(|listed| listed.shells.iter().all(|shell| shell.id != terminal))
        })
        .await;
    assert!(
        fixture.listed(record.id).is_some(),
        "the Session stays open"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pi_that_exits_leaves_its_pane_unavailable_and_its_identity_cleared() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    // SAFETY: kills the stand-in Pi this test's core started.
    assert_eq!(
        unsafe { libc::kill(pid(&record, PaneRole::Pi), libc::SIGKILL) },
        0
    );
    fixture
        .until("the Pi pane to be unavailable", || {
            fixture
                .listed(record.id)
                .is_some_and(|listed| pid(&listed, PaneRole::Pi) == 0)
        })
        .await;
    let id = record.id;
    let stored = fixture
        .core
        .store
        .call(move |database| axo_store::load_pi_process(database, id))
        .await
        .unwrap();
    assert_eq!(stored, None);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stopped_pi_is_not_an_exited_one() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let pi = pid(&record, PaneRole::Pi);
    // SAFETY: signals the stand-in Pi this test's core started.
    assert_eq!(unsafe { libc::kill(pi, libc::SIGSTOP) }, 0);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(pid(&fixture.listed(record.id).unwrap(), PaneRole::Pi), pi);
    // SAFETY: as above.
    assert_eq!(unsafe { libc::kill(pi, libc::SIGCONT) }, 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pane_runs_on_a_real_pty_whose_master_axod_alone_keeps() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let terminal = pane(&record, PaneRole::Terminal);
    let (close_on_exec, device) = sessions::handle(&fixture.core, record.id)
        .unwrap()
        .with(move |session| session.pty(terminal))
        .await
        .unwrap()
        .unwrap();
    assert!(device.starts_with("/dev/"), "{device}");
    assert!(close_on_exec, "no child inherits another pane's PTY");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_latest_viewport_sizes_unattached_panes_and_new_ones() {
    let fixture = Fixture::new().await;
    let core = &fixture.core;
    let record = fixture.new_session().await;
    let id = record.id;
    let first = pane(&record, PaneRole::Pi);
    crate::ops::close_shell(core, id, pane(&record, PaneRole::Terminal))
        .await
        .unwrap();
    assert_eq!(pty_size(&fixture, id, first).await, (24, 80));

    sessions::set_viewport(core, viewport(1000.0))
        .await
        .unwrap();
    assert_eq!(pty_size(&fixture, id, first).await, (34, 124));

    // A new pane starts at the whole area until the client's layout places it.
    let second = crate::ops::create_shell(core, id).await.unwrap().id;
    assert_eq!(pty_size(&fixture, id, second).await, (34, 124));
    let split = LayoutNode::Split {
        id: new_uuid_v4().unwrap(),
        direction: LayoutDirection::Right,
        ratio: 0.5,
        first: Box::new(LayoutNode::Pane { shell_id: first }),
        second: Box::new(LayoutNode::Pane { shell_id: second }),
    };
    crate::ops::set_layout(core, id, Layout::try_from(split).unwrap())
        .await
        .unwrap();
    assert_eq!(pty_size(&fixture, id, first).await, (34, 61));
    assert_eq!(pty_size(&fixture, id, second).await, (34, 61));

    let stored = core
        .store
        .call(|database| axo_store::load_viewport(database))
        .await
        .unwrap();
    assert_eq!(stored, Some(viewport(1000.0)), "kept for the next axod");
}

#[tokio::test(flavor = "multi_thread")]
async fn sessions_and_their_panes_survive_a_restart_and_the_host_keeps_its_identity() {
    let mut fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let (host, generation) = (
        fixture.core.host_id.clone(),
        fixture.core.host_generation.clone(),
    );
    let pids: Vec<i32> = record.shells.iter().map(|s| s.process_id as i32).collect();
    fixture.restart().await;
    assert!(
        pids.iter().all(|pid| !alive(*pid)),
        "stopping axod stops its panes"
    );
    let restored = fixture.listed(record.id).expect("restored");
    assert_eq!(restored.pi_session_file, record.pi_session_file);
    assert_eq!(
        restored.shells.iter().map(|s| s.role).collect::<Vec<_>>(),
        record.shells.iter().map(|s| s.role).collect::<Vec<_>>()
    );
    assert_eq!(fixture.core.host_id, host, "the Mac is the same Mac");
    assert_ne!(fixture.core.host_generation, generation, "but a new run");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_terminal_whose_folder_is_gone_is_closed_instead_of_failing_restore() {
    let mut fixture = Fixture::new().await;
    let folder = fixture.directory.join("gone");
    fs::create_dir_all(&folder).unwrap();
    let record = sessions::create(&fixture.core, CreateSession::InFolder(folder.clone()))
        .await
        .unwrap();
    let other = fixture.new_session().await;
    let terminal = pane(&record, PaneRole::Terminal);
    crate::sessions::stop(&fixture.core).await;
    fs::remove_dir_all(&folder).unwrap();
    fixture.restart().await;

    let restored = fixture
        .listed(record.id)
        .expect("the Session is still open");
    assert!(restored.shells.iter().all(|shell| shell.id != terminal));
    assert!(
        fixture.listed(other.id).is_some(),
        "the others are restored"
    );
    let state: String = fixture
        .core
        .store
        .call(move |database| {
            database
                .query_row(
                    "SELECT state FROM shells WHERE id = ?1",
                    rusqlite::params![terminal.get()],
                    |row| row.get(0),
                )
                .map_err(std::io::Error::other)
        })
        .await
        .unwrap();
    assert_eq!(state, "archived");
}

#[tokio::test(flavor = "multi_thread")]
async fn axod_is_ready_once_the_pis_it_started_are_up() {
    let mut fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    fixture.restart().await;
    // The Session was active just now, so its Pi starts with axod; axod is ready once it binds.
    fixture
        .until("axod to be ready", || {
            fixture
                .core
                .ready
                .load(std::sync::atomic::Ordering::Acquire)
        })
        .await;
    let listed = fixture.listed(record.id).unwrap();
    assert!(listed.pi_session_id.is_some(), "{listed:?}");
}

/// A Pi mid-turn when axod stops is told so once the next axod restores it, and only that once.
#[tokio::test(flavor = "multi_thread")]
async fn a_pi_working_when_axod_stops_is_told_once_the_next_axod_restores_it() {
    let mut fixture = Fixture::with(Pi::Fake { turn_ms: 30_000 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    sessions::prompt(
        &fixture.core,
        axo_protocol::rpc::PromptSession {
            session_id: record.id,
            text: axo_protocol::rpc::PromptText::parse("a long job".into()).unwrap(),
            delivery: axo_protocol::rpc::PromptDelivery::FollowUp,
            from_session_id: None,
        },
        None,
        Vec::new(),
    )
    .await
    .unwrap();
    fixture
        .until("Pi to be working", || {
            fixture.core.catalog.view().sessions[&record.id].working
        })
        .await;
    fixture.set_turn_ms(0);
    fixture.restart().await;
    let notice = "SENT:(the session was stopped when Axo restarted, you may continue)";
    fixture
        .until("the restored Pi to be told", || {
            fixture.pi_log().contains(notice)
        })
        .await;
    let taken = fixture
        .core
        .store
        .call(|database| axo_store::take_daemon_stop(database))
        .await
        .unwrap();
    assert_eq!(taken, None, "the record is acted on once");

    // This axod stopped with nothing working, so the one after it tells no one.
    fixture.wait_for_pi(record.id).await;
    fixture
        .until("the notice's turn to end", || {
            !fixture.core.catalog.view().sessions[&record.id].working
        })
        .await;
    fixture.restart().await;
    fixture.wait_for_pi(record.id).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(fixture.pi_log().matches(notice).count(), 1);
}

/// A layout the store cannot read is no reason to lose the Session: it is restored with its panes
/// and no layout, which clients lay out themselves.
#[tokio::test(flavor = "multi_thread")]
async fn a_session_whose_stored_layout_is_damaged_is_restored_without_it() {
    let mut fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    crate::sessions::stop(&fixture.core).await;
    let id = record.id;
    fixture
        .core
        .store
        .call(move |database| {
            database
                .execute(
                    "UPDATE sessions SET layout_json = '{not a layout' WHERE id = ?1",
                    rusqlite::params![id.to_string()],
                )
                .map_err(std::io::Error::other)
        })
        .await
        .unwrap();
    fixture.restart().await;
    let restored = fixture.listed(record.id).expect("restored");
    assert_eq!(restored.shells.len(), 2);
    assert_eq!(restored.layout, None, "a damaged layout is ignored");
}
