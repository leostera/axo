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

fn command_id(n: u64) -> axo_protocol::commands::CommandId {
    axo_protocol::commands::CommandId::try_from(format!("00000000-0000-4000-8000-{n:012x}"))
        .unwrap()
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

/// A prompt Pi refuses as busy reached no agent, so it does not count against its sender: an
/// agent retrying `turn` delivery while Pi works can still send once Pi can take it.
#[tokio::test(flavor = "multi_thread")]
async fn prompts_refused_as_busy_do_not_use_up_the_senders_limit() {
    let fixture = Fixture::with(Pi::Fake { turn_ms: 10_000 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let to_self = |text: &str, delivery| PromptSession {
        session_id: record.id,
        text: prompt_text(text),
        delivery,
        from_session_id: Some(record.id),
    };
    sessions::prompt(
        &fixture.core,
        to_self("start a long turn", PromptDelivery::FollowUp),
        None,
        Vec::new(),
    )
    .await
    .unwrap();
    fixture
        .until("the turn to start", || {
            fixture.pi_log().contains("SENT:[From Axo Session")
        })
        .await;
    for _ in 0..12 {
        assert!(matches!(
            sessions::prompt(
                &fixture.core,
                to_self("only if idle", PromptDelivery::Turn),
                None,
                Vec::new()
            )
            .await,
            Err(PromptError::Busy)
        ));
    }
    sessions::prompt(
        &fixture.core,
        to_self("after it", PromptDelivery::FollowUp),
        None,
        Vec::new(),
    )
    .await
    .expect("refused prompts did not count");
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

/// A normal Send from any client must not abort either the question or its approved run.
#[tokio::test(flavor = "multi_thread")]
async fn a_send_queues_behind_a_human_question_and_the_work_approved_by_yes() {
    use axo_protocol::elicitation::{Asker, ElicitationAction, ElicitationAnswer, Reply};
    let fixture = Fixture::with(Pi::Fake { turn_ms: 30_000 }).await;
    let record = fixture.new_session().await;
    fixture.wait_for_pi(record.id).await;
    let asking = {
        let core = std::sync::Arc::clone(&fixture.core);
        tokio::spawn(async move {
            core.ask_with(
                record.id,
                "Approve the current work?",
                Asker::Agent,
                None,
                Duration::from_secs(30),
            )
            .await
        })
    };
    fixture
        .until("the question to be published", || {
            !fixture.core.questions.pending().is_empty()
        })
        .await;
    let question = fixture.core.questions.pending().pop().unwrap();
    let send = |text: &str| PromptSession {
        session_id: record.id,
        text: prompt_text(text),
        delivery: PromptDelivery::Interrupt,
        from_session_id: None,
    };
    sessions::prompt(
        &fixture.core,
        send("while Yes is on its way"),
        None,
        Vec::new(),
    )
    .await
    .unwrap();
    fixture
        .until("the protected prompt to reach Pi", || {
            fixture
                .pi_log()
                .contains("DELIVERY:followUp:while Yes is on its way")
        })
        .await;
    assert!(
        !asking.is_finished(),
        "Send must not settle or cancel the question"
    );
    fixture
        .core
        .questions
        .resolve(
            fixture.core.as_ref(),
            &question.id,
            ElicitationAnswer::Accept,
            Reply::Bare,
        )
        .unwrap();
    assert_eq!(
        asking.await.unwrap().unwrap().outcome.action,
        ElicitationAction::Accept
    );
    sessions::prompt(
        &fixture.core,
        send("voice message after Yes"),
        None,
        Vec::new(),
    )
    .await
    .unwrap();
    fixture
        .until("the post-approval prompt to reach Pi", || {
            fixture
                .pi_log()
                .contains("DELIVERY:followUp:voice message after Yes")
        })
        .await;
    assert!(
        !fixture.pi_log().contains("DELIVERY:interrupt:"),
        "No ordinary Send interrupts this protected run"
    );
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
#[test]
fn a_pane_that_takes_no_input_holds_up_only_its_own_writers() {
    const NAME: &str = concat!(
        module_path!(),
        "::a_pane_that_takes_no_input_holds_up_only_its_own_writers"
    );
    run_bounded_input_scenario(NAME, blocked_input_scenario());
}

#[test]
fn stopping_axod_ends_a_blocked_input_writer() {
    const NAME: &str = concat!(
        module_path!(),
        "::stopping_axod_ends_a_blocked_input_writer"
    );
    run_bounded_input_scenario(NAME, async {
        let fixture = Fixture::new().await;
        let record = fixture.new_session().await;
        let terminal = pane(&record, PaneRole::Terminal);
        let stuck = {
            let core = std::sync::Arc::clone(&fixture.core);
            tokio::spawn(async move {
                ops::write_input(&core, record.id, terminal, 0, large_terminal_paste()).await
            })
        };
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            !stuck.is_finished(),
            "the pane must have input backpressure"
        );
        tokio::time::timeout(Duration::from_secs(10), sessions::stop(&fixture.core))
            .await
            .expect("daemon shutdown must finish retiring its panes");
        let ended = tokio::time::timeout(Duration::from_secs(2), stuck)
            .await
            .expect("daemon shutdown must end the blocked writer")
            .unwrap();
        assert!(ended.is_err());
    });
}

fn run_bounded_input_scenario(name: &str, scenario: impl std::future::Future<Output = ()>) {
    // libtest names omit the crate prefix from module_path!().
    let name = name.split_once("::").unwrap().1;
    if crate::test_support::in_bounded_test_process(name, Duration::from_secs(25)) {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap()
            .block_on(scenario);
    }
}

fn large_terminal_paste() -> TerminalBytes {
    TerminalBytes::from_base64(&axo_protocol::base64::encode(
        &[b"x".repeat(99), b"\n".to_vec()].concat().repeat(480),
    ))
    .unwrap()
}

async fn blocked_input_scenario() {
    let fixture = Fixture::new().await;
    let record = fixture.new_session().await;
    let terminal = pane(&record, PaneRole::Terminal);
    // A paste larger than a PTY holds for a program that doesn't read it.
    let paste = large_terminal_paste();
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
    tokio::time::timeout(Duration::from_secs(2), async {
        ops::rename(&fixture.core, other.id, "still answering".into()).await?;
        ops::write_input(
            &fixture.core,
            other.id,
            pane(&other, PaneRole::Terminal),
            0,
            TerminalBytes::from_base64(&axo_protocol::base64::encode(b"z")).unwrap(),
        )
        .await
    })
    .await
    .expect("another pane and its Session must remain responsive")
    .unwrap();

    let started = Instant::now();
    let refused = tokio::time::timeout(
        TERMINAL_INPUT_WRITE_TIMEOUT + Duration::from_secs(2),
        ops::write_input(
            &fixture.core,
            record.id,
            terminal,
            1,
            TerminalBytes::from_base64(&axo_protocol::base64::encode(b"y")).unwrap(),
        ),
    )
    .await
    .expect("the waiting writer must respect its turn deadline")
    .unwrap_err();
    assert_eq!(refused.kind(), io::ErrorKind::TimedOut, "{refused}");
    assert!(started.elapsed() >= TERMINAL_INPUT_WRITE_TIMEOUT);

    tokio::time::timeout(
        Duration::from_secs(2),
        sessions::close(&fixture.core, record.id),
    )
    .await
    .expect("closing must not wait for the blocked writer")
    .unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(10), stuck)
        .await
        .expect("the stuck write ended with its pane")
        .unwrap();
    assert!(ended.is_err());
    sessions::stop(&fixture.core).await;
}
