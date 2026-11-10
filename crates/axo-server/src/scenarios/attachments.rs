//! Attaching to panes over the attach socket, as the app does.

use std::io::Read;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axo_protocol::{PaneRole, SessionId, ShellId};
use axo_pty::TerminalOutput;
use axo_pty::attach::{self, Attachment};

use crate::sessions;
use crate::test_support::{Fixture, pane};

async fn attach(fixture: &Fixture, shell: ShellId) -> Attachment {
    let socket = fixture.core.attach_socket_path.clone();
    tokio::task::spawn_blocking(move || attach::connect(&socket, shell.get()))
        .await
        .unwrap()
        .unwrap()
}

async fn output(fixture: &Fixture, id: SessionId, shell: ShellId) -> Arc<TerminalOutput> {
    sessions::handle(&fixture.core, id)
        .unwrap()
        .with(move |session| session.output(shell))
        .await
        .unwrap()
        .unwrap()
}

async fn attachments(fixture: &Fixture, id: SessionId, shell: ShellId) -> usize {
    sessions::handle(&fixture.core, id)
        .unwrap()
        .with(move |session| session.attachments(shell))
        .await
        .unwrap()
        .unwrap()
}

/// A client that hangs up while its shell is quiet ends its attachment at once: the task sees the
/// hang-up, rather than waiting for output or a timer.
#[tokio::test(flavor = "multi_thread")]
async fn a_client_that_hangs_up_on_a_quiet_shell_ends_its_attachment_at_once() {
    let mut fixture = Fixture::new().await;
    fixture.listen();
    let record = fixture.new_session().await;
    let terminal = pane(&record, PaneRole::Terminal);
    let attachment = attach(&fixture, terminal).await;
    assert_eq!(attachments(&fixture, record.id, terminal).await, 1);

    let hung_up = Instant::now();
    drop(attachment);
    while attachments(&fixture, record.id, terminal).await > 0 {
        assert!(
            hung_up.elapsed() < Duration::from_secs(1),
            "the attachment outlived its client"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// After a relaunch the app attaches to a Pi that set its modes long ago and has since written
/// far more output than any byte history keeps. The replay still restores them.
#[tokio::test(flavor = "multi_thread")]
async fn a_late_attachment_restores_a_long_running_full_screen_program() {
    let mut fixture = Fixture::new().await;
    fixture.listen();
    let record = fixture.new_session().await;
    let pi = pane(&record, PaneRole::Pi);
    let output = output(&fixture, record.id, pi).await;
    output.record(b"\x1b[?1049h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[2J");
    let frame = b"\x1b[H\x1b[2Kworking...\r\n".repeat(1024);
    for _ in 0..(2 * axo_pty::output::MAX_TERMINAL_REPLAY_BYTES / frame.len()) {
        output.record(&frame);
    }
    output.record(b"\x1b[H\x1b[2KLATE ATTACH FRAME");

    let mut attachment = attach(&fixture, pi).await;
    let length = attachment.replay_bytes;
    assert!(
        length > 0 && length < 1024 * 1024,
        "a replay of {length} bytes"
    );
    let replay = tokio::task::spawn_blocking(move || {
        let mut replay = vec![0_u8; length as usize];
        attachment.control.read_exact(&mut replay).unwrap();
        String::from_utf8_lossy(&replay).into_owned()
    })
    .await
    .unwrap();
    for mode in [
        "\x1b[?1049h",
        "\x1b[?1000h",
        "\x1b[?1003h",
        "\x1b[?1006h",
        "\x1b[?2004h",
    ] {
        assert!(replay.contains(mode), "the replay restores {mode:?}");
    }
    assert!(replay.contains("LATE ATTACH FRAME"));
}

/// A client that never reads is let go once its backlog overflows, and the shell's output never
/// waits for it.
#[tokio::test(flavor = "multi_thread")]
async fn a_stalled_client_is_released_without_blocking_the_shell() {
    let mut fixture = Fixture::new().await;
    fixture.listen();
    let record = fixture.new_session().await;
    let terminal = pane(&record, PaneRole::Terminal);
    let output = output(&fixture, record.id, terminal).await;
    let _never_read = attach(&fixture, terminal).await;
    let chunk = vec![b'x'; 64 * 1024];
    let deadline = Instant::now() + Duration::from_secs(10);
    while output.subscriber_count() > 0 {
        assert!(Instant::now() < deadline, "the stalled client was kept");
        output.record(&chunk);
        tokio::task::yield_now().await;
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while attachments(&fixture, record.id, terminal).await > 0 {
        assert!(Instant::now() < deadline, "the pane still counts it");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A shell that is not open is refused as such, so the client stops retrying.
#[tokio::test(flavor = "multi_thread")]
async fn attaching_to_a_pane_that_is_gone_is_refused() {
    let mut fixture = Fixture::new().await;
    fixture.listen();
    let socket = fixture.core.attach_socket_path.clone();
    let refused = tokio::task::spawn_blocking(move || attach::open(&socket, 987_654))
        .await
        .unwrap()
        .unwrap_err();
    assert_eq!(refused.kind(), std::io::ErrorKind::NotFound, "{refused}");
}

/// Stopping axod ends its attachments, even to a pane with nothing to say, so the app sees the
/// end at once rather than holding a stream nobody writes.
#[tokio::test(flavor = "multi_thread")]
async fn stopping_axod_ends_an_idle_attachment() {
    let mut fixture = Fixture::new().await;
    fixture.listen();
    let record = fixture.new_session().await;
    let mut attachment = attach(&fixture, pane(&record, PaneRole::Terminal)).await;
    crate::sessions::stop(&fixture.core).await;
    let ended = tokio::task::spawn_blocking(move || {
        let mut rest = Vec::new();
        attachment.control.read_to_end(&mut rest).map(|_| ())
    })
    .await
    .unwrap();
    assert!(
        ended.is_ok(),
        "the stream ended rather than timing out: {ended:?}"
    );
}
