//! OpenCode Sessions (RFD0072) against the fake opencode
//! (`crates/axo-agent/testdata/fake_opencode.rs`): a Session that runs OpenCode starts its
//! server, a session and the TUI, takes prompts, keeps its transcript, and rejoins its session
//! after axod restarts.

use std::fs;

use axo_protocol::SessionRecord;
use axo_protocol::agent::AgentKind;
use axo_protocol::rpc::{CreateSession, PromptDelivery, PromptText, SessionLocation};

use crate::sessions;
use crate::test_support::Fixture;

const SESSION: &str = "ses_fake0001";

fn command_id(n: u64) -> axo_protocol::commands::CommandId {
    axo_protocol::commands::CommandId::try_from(format!("00000000-0000-4000-8000-{n:012x}"))
        .unwrap()
}

/// What the fake opencode was asked, in the Session's folder.
fn opencode_log(fixture: &Fixture) -> String {
    fs::read_to_string(fixture.directory.join("fake-opencode.log")).unwrap_or_default()
}

fn count(log: &str, prefix: &str) -> usize {
    log.lines().filter(|line| line.starts_with(prefix)).count()
}

async fn opencode_session(fixture: &Fixture) -> SessionRecord {
    sessions::create(
        &fixture.core,
        CreateSession {
            location: SessionLocation::InFolder(fixture.directory.clone()),
            name: None,
            agent: AgentKind::OpenCode,
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
async fn an_opencode_session_runs_the_tui_on_its_own_session_and_keeps_a_transcript() {
    let fixture = Fixture::new().await;
    let record = opencode_session(&fixture).await;
    assert_eq!(record.agent, AgentKind::OpenCode);
    fixture.wait_for_pi(record.id).await;
    let log = opencode_log(&fixture);
    assert_eq!(count(&log, "created "), 1, "{log}");
    // Axo's MCP server, configured for this Session; its instructions carry the brief.
    let config = log
        .lines()
        .find_map(|line| line.strip_prefix("config "))
        .expect(&log);
    let config: serde_json::Value = serde_json::from_str(config).unwrap();
    assert_eq!(
        config["mcp"]["axo"]["environment"]["AXO_SESSION_ID"],
        record.id.to_string()
    );
    assert_eq!(config["mcp"]["axo"]["command"][1], "mcp");
    fixture
        .until("the TUI on the session", || {
            opencode_log(&fixture).lines().any(|line| {
                line.starts_with("tui --server http://127.0.0.1:")
                    && line.ends_with(&format!("--session {SESSION}"))
            })
        })
        .await;
    assert!(opencode_log(&fixture).contains("tui password=true"));

    prompt(&fixture, &record, "hello opencode", 1).await;
    fixture
        .until("the prompt to reach the server", || {
            opencode_log(&fixture).contains(&format!(
                "prompt {SESSION} delivery=none text=hello opencode"
            ))
        })
        .await;
    // OpenCode's export becomes the Session's transcript, as Pi lines the cloud syncs.
    let transcript = record
        .pi_session_file
        .clone()
        .expect("every Session has a transcript");
    fixture
        .until("the answer in the transcript", || {
            fs::read_to_string(&transcript).is_ok_and(|text| text.contains("echo: hello opencode"))
        })
        .await;
    let text = fs::read_to_string(&transcript).unwrap();
    let header: serde_json::Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(header["id"], record.id.to_string());
}

#[tokio::test(flavor = "multi_thread")]
async fn after_a_restart_an_opencode_session_rejoins_its_session_instead_of_creating_another() {
    let mut fixture = Fixture::new().await;
    let record = opencode_session(&fixture).await;
    fixture.wait_for_pi(record.id).await;
    let tuis = |fixture: &Fixture| count(&opencode_log(fixture), "tui --server");
    fixture.until("the first TUI", || tuis(&fixture) == 1).await;
    fixture.restart().await;
    prompt(&fixture, &record, "again", 2).await;
    fixture
        .until("the prompt to reach the same session", || {
            opencode_log(&fixture).contains(&format!("prompt {SESSION} delivery=none text=again"))
        })
        .await;
    fixture
        .until("the second TUI", || tuis(&fixture) == 2)
        .await;
    let log = opencode_log(&fixture);
    assert_eq!(
        count(&log, "created "),
        1,
        "one session for the Session's life:\n{log}"
    );
    assert_eq!(count(&log, "serve "), 2, "{log}");
}
