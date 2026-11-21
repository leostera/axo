//! Codex Sessions (RFD0072) against the fake codex (`crates/axo-agent/testdata/fake_codex.rs`):
//! a Session that runs Codex starts its server, a thread and the TUI, takes prompts as turns,
//! and rejoins its thread after axod restarts.

use std::fs;

use axo_protocol::agent::AgentKind;
use axo_protocol::rpc::{CreateSession, PromptDelivery, PromptText, SessionLocation};
use axo_protocol::{PaneRole, SessionRecord};

use crate::sessions;
use crate::test_support::{Fixture, pane};

const THREAD: &str = "01a1eea8-952a-7271-8b55-c2708a01c6ff";

fn command_id(n: u64) -> axo_protocol::commands::CommandId {
    axo_protocol::commands::CommandId::try_from(format!("00000000-0000-4000-8000-{n:012x}"))
        .unwrap()
}

/// What the fake codex was asked, in the Session's folder.
fn codex_log(fixture: &Fixture) -> String {
    fs::read_to_string(fixture.directory.join("fake-codex.log")).unwrap_or_default()
}

fn requests(log: &str, method: &str) -> usize {
    log.lines()
        .filter(|line| line.starts_with(&format!("request {method} ")))
        .count()
}

async fn codex_session(fixture: &Fixture) -> SessionRecord {
    sessions::create(
        &fixture.core,
        CreateSession {
            location: SessionLocation::InFolder(fixture.directory.clone()),
            name: None,
            agent: AgentKind::Codex,
        },
    )
    .await
    .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_codex_session_runs_the_tui_on_its_own_thread_and_takes_prompts_as_turns() {
    let fixture = Fixture::new().await;
    let record = codex_session(&fixture).await;
    assert_eq!(record.agent, AgentKind::Codex);
    assert_eq!(fixture.listed(record.id).unwrap().agent, AgentKind::Codex);
    fixture.wait_for_pi(record.id).await;
    let log = codex_log(&fixture);
    assert_eq!(requests(&log, "thread/start"), 1, "{log}");
    assert_eq!(requests(&log, "thread/name/set"), 1, "{log}");
    // Axo's brief and MCP server, as pi-axo gives them to Pi.
    assert!(
        log.contains("config mcp_servers.axo.args=[\"mcp\"]"),
        "{log}"
    );
    assert!(
        log.contains(&format!("AXO_SESSION_ID = \"{}\"", record.id)),
        "{log}"
    );
    assert!(
        log.contains("\"developerInstructions\":\"The user may override any directive in Axo’s injected guidance only by explicitly accepting a confirmation or elicitation for that specific override."),
        "{log}"
    );
    assert_eq!(fixture.listed(record.id).unwrap().shells.len(), 2);
    // The agent pane is Codex's TUI, resuming the thread the server started.
    let _ = (
        pane(&record, PaneRole::Pi),
        pane(&record, PaneRole::Terminal),
    );
    fixture
        .until("the TUI to resume the thread", || {
            codex_log(&fixture)
                .lines()
                .any(|line| line.starts_with("tui ") && line.contains(&format!(" {THREAD} cwd=")))
        })
        .await;

    sessions::prompt_from_client(
        &fixture.core,
        record.id,
        PromptText::parse("hello codex".to_owned()).unwrap(),
        command_id(1),
        Vec::new(),
        PromptDelivery::FollowUp,
    )
    .await
    .unwrap();
    fixture
        .until("the prompt to start a turn", || {
            codex_log(&fixture)
                .lines()
                .any(|line| line.starts_with("request turn/start ") && line.contains("hello codex"))
        })
        .await;

    // Codex's rollout becomes the Session's transcript, as Pi lines the cloud syncs.
    let transcript = record
        .pi_session_file
        .clone()
        .expect("every Session has a transcript");
    fixture
        .until("the turn in the transcript", || {
            fs::read_to_string(&transcript).is_ok_and(|text| text.contains("echo: hello codex"))
        })
        .await;
    let text = fs::read_to_string(&transcript).unwrap();
    let header: serde_json::Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(header["type"], "session");
    assert_eq!(header["id"], record.id.to_string());
    let messages: Vec<serde_json::Value> = text
        .lines()
        .skip(1)
        .map(|line| serde_json::from_str(line).unwrap())
        .filter(|entry: &serde_json::Value| entry["type"] == "message")
        .collect();
    assert!(
        messages
            .iter()
            .any(|entry| entry["message"]["role"] == "user"
                && entry["message"]["content"]
                    .to_string()
                    .contains("hello codex")),
        "{text}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn after_a_restart_a_codex_session_rejoins_its_thread_instead_of_starting_another() {
    let mut fixture = Fixture::new().await;
    let record = codex_session(&fixture).await;
    fixture.wait_for_pi(record.id).await;
    let tuis = |fixture: &Fixture| {
        codex_log(fixture)
            .lines()
            .filter(|line| line.starts_with("tui "))
            .count()
    };
    fixture.until("the first TUI", || tuis(&fixture) == 1).await;
    fixture.restart().await;
    sessions::prompt_from_client(
        &fixture.core,
        record.id,
        PromptText::parse("again".to_owned()).unwrap(),
        command_id(2),
        Vec::new(),
        PromptDelivery::FollowUp,
    )
    .await
    .unwrap();
    fixture
        .until("the prompt to reach the same thread", || {
            codex_log(&fixture)
                .lines()
                .any(|line| line.starts_with("request turn/start ") && line.contains("again"))
        })
        .await;
    fixture
        .until("the second TUI", || tuis(&fixture) == 2)
        .await;
    let log = codex_log(&fixture);
    assert_eq!(
        requests(&log, "thread/start"),
        1,
        "one thread for the Session's life:\n{log}"
    );
    assert!(requests(&log, "thread/resume") >= 2, "{log}");
    assert_eq!(
        log.lines()
            .filter(|line| line.starts_with("tui ") && line.contains(THREAD))
            .count(),
        2,
        "{log}"
    );
}
