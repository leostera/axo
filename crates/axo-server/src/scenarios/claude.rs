//! Claude Code Sessions (RFD0072) against the fake claude
//! (`crates/axo-agent/testdata/fake_claude.rs`): a Session that runs Claude Code starts its
//! TUI with Axo's brief, MCP server and hooks, takes prompts typed into it, keeps its
//! transcript, and resumes its conversation after axod restarts.

use std::fs;

use axo_protocol::SessionRecord;
use axo_protocol::agent::AgentKind;
use axo_protocol::rpc::{CreateSession, PromptDelivery, PromptText, SessionLocation};

use crate::sessions;
use crate::test_support::Fixture;

fn command_id(n: u64) -> axo_protocol::commands::CommandId {
    axo_protocol::commands::CommandId::try_from(format!("00000000-0000-4000-8000-{n:012x}"))
        .unwrap()
}

/// What the fake claude was asked, in the Session's folder.
fn claude_log(fixture: &Fixture) -> String {
    fs::read_to_string(fixture.directory.join("fake-claude.log")).unwrap_or_default()
}

async fn claude_session(fixture: &Fixture) -> SessionRecord {
    sessions::create(
        &fixture.core,
        CreateSession {
            location: SessionLocation::InFolder(fixture.directory.clone()),
            name: None,
            agent: AgentKind::ClaudeCode,
        },
    )
    .await
    .unwrap()
}

async fn prompt(fixture: &Fixture, record: &SessionRecord, text: &str, n: u64) {
    sessions::prompt_from_client(
        &fixture.core,
        record.id,
        PromptText::parse(text.to_owned()).unwrap(),
        command_id(n),
        Vec::new(),
        PromptDelivery::FollowUp,
    )
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_claude_session_types_prompts_into_its_tui_and_keeps_a_transcript() {
    let fixture = Fixture::new().await;
    let record = claude_session(&fixture).await;
    assert_eq!(record.agent, AgentKind::ClaudeCode);
    fixture.wait_for_pi(record.id).await;
    fixture
        .until("the TUI's first hook", || claude_log(&fixture).contains("hook SessionStart"))
        .await;
    let log = claude_log(&fixture);
    // The conversation is named after the Session; Axo's brief and MCP server come along.
    assert!(log.contains(&format!("tui new {}", record.id)), "{log}");
    assert!(log.contains("brief You run inside Axo"), "{log}");
    assert!(log.contains(&format!("\"AXO_SESSION_ID\":\"{}\"", record.id)), "{log}");

    prompt(&fixture, &record, "hello claude", 1).await;
    fixture
        .until("the prompt typed into the TUI", || claude_log(&fixture).contains("prompt hello claude"))
        .await;
    let transcript = record.pi_session_file.clone().expect("every Session has a transcript");
    fixture
        .until("the answer in the transcript", || {
            fs::read_to_string(&transcript).is_ok_and(|text| text.contains("echo: hello claude"))
        })
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn after_a_restart_a_claude_session_resumes_its_conversation() {
    let mut fixture = Fixture::new().await;
    let record = claude_session(&fixture).await;
    fixture.wait_for_pi(record.id).await;
    fixture
        .until("the TUI's first hook", || claude_log(&fixture).contains("hook SessionStart"))
        .await;
    prompt(&fixture, &record, "first", 1).await;
    fixture
        .until("the first turn", || claude_log(&fixture).contains("hook Stop"))
        .await;
    fixture.restart().await;
    prompt(&fixture, &record, "again", 2).await;
    fixture
        .until("the prompt in the resumed conversation", || {
            claude_log(&fixture).contains("prompt again")
        })
        .await;
    assert!(claude_log(&fixture).contains(&format!("tui resume {}", record.id)));
}
