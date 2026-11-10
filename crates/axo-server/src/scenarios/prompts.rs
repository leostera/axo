//! Prompts reaching Pi, and input reaching panes.

use std::io;
use std::time::{Duration, Instant};

use axo_ipc::cancel::{self, Cancellation};
use axo_protocol::rpc::{PromptDelivery, PromptSession, PromptText, TerminalBytes};
use axo_protocol::{PaneRole, SessionId};

use crate::ops::{self, TERMINAL_INPUT_WRITE_TIMEOUT};
use crate::session::prompts::PromptError;
use crate::sessions;
use crate::test_support::{Fixture, Pi, pane};

fn prompt_text(text: &str) -> PromptText {
    PromptText::parse(text.to_owned()).unwrap()
}

fn command_id(n: u64) -> axo_relay::CommandId {
    axo_relay::CommandId::try_from(format!("00000000-0000-4000-8000-{n:012x}")).unwrap()
}

/// A person's prompt to a Pi that is still starting waits for it, but stops as soon as its request
/// is cancelled (the client went), instead of at its time limit.
#[tokio::test(flavor = "multi_thread")]
async fn a_prompt_waiting_for_pi_to_start_stops_when_its_request_is_cancelled() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let cancellation = Cancellation::default();
    let cancelling = cancellation.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(200)).await;
        cancelling.cancel();
    });
    let started = Instant::now();
    let refused = cancel::scope(
        cancellation,
        sessions::prompt_from_client(
            &fixture.core,
            record.id,
            prompt_text("hello"),
            command_id(1),
            Vec::new(),
            PromptDelivery::FollowUp,
        ),
    )
    .await
    .unwrap_err();
    assert_eq!(refused.kind(), io::ErrorKind::Interrupted, "{refused}");
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(200) && waited < Duration::from_secs(1),
        "{waited:?}"
    );
}

/// An agent's prompt names the Session that sent it, and an agent prompting itself is held to
/// its own limit however long the chain.
#[tokio::test(flavor = "multi_thread")]
async fn an_agents_prompt_names_its_sender_and_prompting_itself_is_limited() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let to_self = |text: &str| PromptSession {
        session_id: record.id,
        text: prompt_text(text),
        delivery: PromptDelivery::FollowUp,
        from_session_id: Some(record.id),
    };
    for _ in 0..10 {
        let accepted = sessions::prompt(&fixture.core, to_self("again"), None, Vec::new())
            .await
            .unwrap();
        assert!(!accepted.queued);
    }
    assert!(matches!(
        sessions::prompt(&fixture.core, to_self("again"), None, Vec::new()).await,
        Err(PromptError::RateLimited)
    ));
    let named = format!("SENT:[From Axo Session {} {:?}]", record.id, record.name);
    fixture
        .until("the prompts to reach Pi", || {
            fixture.pi_log().matches(&named).count() == 10
        })
        .await;
}

/// A prompt from a Session that is not open is refused, and so is one to a Session with no Pi.
#[tokio::test(flavor = "multi_thread")]
async fn a_prompt_names_open_sessions_only() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let unknown = SessionId::from_u128(987_654);
    let from_unknown = PromptSession {
        session_id: record.id,
        text: prompt_text("hi"),
        delivery: PromptDelivery::FollowUp,
        from_session_id: Some(unknown),
    };
    assert!(matches!(
        sessions::prompt(&fixture.core, from_unknown, None, Vec::new()).await,
        Err(PromptError::Invalid(_))
    ));
    let to_unknown = PromptSession {
        session_id: unknown,
        text: prompt_text("hi"),
        delivery: PromptDelivery::FollowUp,
        from_session_id: None,
    };
    assert!(matches!(
        sessions::prompt(&fixture.core, to_unknown, None, Vec::new()).await,
        Err(PromptError::NoPi)
    ));
}

/// A key a person presses away from the Mac reaches Pi as that key.
#[tokio::test(flavor = "multi_thread")]
async fn a_remote_key_press_reaches_pi_as_that_key() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 0 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    ops::press_key(&fixture.core, record.id, axo_relay::PiKey::Escape)
        .await
        .unwrap();
    ops::press_key(&fixture.core, record.id, axo_relay::PiKey::Enter)
        .await
        .unwrap();
    fixture
        .until("the keys to reach Pi", || {
            let typed: String = fixture
                .pi_log()
                .lines()
                .filter_map(|line| line.strip_prefix("TYPED:"))
                .collect();
            typed == "\\u{1b}\\r"
        })
        .await;
}

/// A pane whose program never reads holds up only its own writers: the rest of axod answers, more
/// input for it gives up, and closing it ends the stuck write.
#[tokio::test(flavor = "multi_thread")]
async fn a_pane_that_takes_no_input_holds_up_only_its_own_writers() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let terminal = pane(&record, PaneRole::Terminal);
    // A paste larger than a PTY holds for a program that doesn't read it.
    let paste = TerminalBytes::from_base64(&axo_protocol::base64::encode(
        &[b"x".repeat(99), b"\n".to_vec()].concat().repeat(480),
    ))
    .unwrap();
    let stuck = {
        let core = std::sync::Arc::clone(&fixture.core);
        tokio::spawn(async move { ops::write_input(&core, record.id, terminal, 0, paste).await })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !stuck.is_finished(),
        "the paste is stuck, as a person's would be"
    );

    let other = fixture.new_session().await;
    ops::rename(&fixture.core, other.id, "still answering".into())
        .await
        .unwrap();

    let started = Instant::now();
    let refused = ops::write_input(
        &fixture.core,
        record.id,
        terminal,
        1,
        TerminalBytes::from_base64(&axo_protocol::base64::encode(b"y")).unwrap(),
    )
    .await
    .unwrap_err();
    assert_eq!(refused.kind(), io::ErrorKind::TimedOut, "{refused}");
    assert!(started.elapsed() >= TERMINAL_INPUT_WRITE_TIMEOUT);

    sessions::close(&fixture.core, record.id).await.unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(10), stuck)
        .await
        .expect("the stuck write ended with its pane")
        .unwrap();
    assert!(ended.is_err());
}
