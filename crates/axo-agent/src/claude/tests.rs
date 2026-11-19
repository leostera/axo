//! Launch and link together, against the fake Claude Code (`testdata/fake_claude.rs`).

use std::path::{Path, PathBuf};
use std::time::Duration;

use axo_protocol::commands::{CommandId, StopTarget};
use axo_pty::process::WindowSize;
use tokio::sync::mpsc;

use super::*;
use crate::axo_mcp::AxoMcp;
use crate::runtime::{AgentEvent, CommandResult, QueuedDelivery, RejectReason};

const TIMEOUT: Duration = Duration::from_secs(10);

fn request(directory: &Path, conversation: &str) -> ClaudeLaunch {
    let work = directory.join("work");
    std::fs::create_dir_all(&work).unwrap();
    let session = axo_protocol::new_uuid_v4().unwrap();
    ClaudeLaunch {
        executable: std::fs::canonicalize(std::env::var_os("AXO_TEST_FAKE_CLAUDE").expect("set by Bazel")).unwrap(),
        paths: ClaudePaths::new(directory, &session),
        initial_pwd: work,
        session_uuid: session,
        pane_id: "pane-1".into(),
        home: directory.to_owned(),
        config_dir: directory.join(".claude"),
        environment: vec![("AXO_FAKE_CLAUDE_LOG", directory.join("claude.log"))],
        conversation: conversation.into(),
        brief: Some("You run inside Axo.\nmore".into()),
        mcp: Some(AxoMcp {
            axod: PathBuf::from("/opt/axo/axod"),
            socket: directory.join("axod.sock"),
            session_id: "s".into(),
        }),
        previous: None,
        size: WindowSize::DEFAULT,
    }
}

fn log(directory: &Path) -> String {
    std::fs::read_to_string(directory.join("claude.log")).unwrap_or_default()
}

async fn until_log(directory: &Path, needle: &str) {
    let deadline = tokio::time::Instant::now() + TIMEOUT;
    while !log(directory).contains(needle) {
        assert!(tokio::time::Instant::now() < deadline, "no {needle:?} in:\n{}", log(directory));
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Events until one named `name`, included, and any conversation reported meanwhile.
async fn until(events: &mut mpsc::UnboundedReceiver<AgentEvent>, name: &str) -> (Vec<(String, serde_json::Value)>, Option<PathBuf>) {
    let (mut seen, mut file) = (Vec::new(), None);
    loop {
        let event = tokio::time::timeout(TIMEOUT, events.recv())
            .await
            .unwrap_or_else(|_| panic!("no {name} after {seen:?}"))
            .expect("the link ended");
        match event {
            AgentEvent::Event { name: got, data, .. } => {
                let done = got == name;
                seen.push((got, data));
                if done {
                    return (seen, file);
                }
            }
            AgentEvent::Conversation { file: named } => file = Some(named),
            _ => {}
        }
    }
}

fn command(n: u8) -> CommandId {
    CommandId::try_from(format!("6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a{n:02x}")).unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn prompts_are_typed_hooks_are_reported_and_the_conversation_resumes() {
    let directory = crate::test_directory();
    let conversation = axo_protocol::new_uuid_v4().unwrap();
    let launch_request = request(&directory, &conversation);
    let paths = launch_request.paths.clone();
    let process = tokio::task::spawn_blocking({
        let launch_request = launch_request.clone();
        move || launch(&launch_request)
    })
    .await
    .unwrap()
    .unwrap();
    assert!(paths.is_running().unwrap(), "the TUI holds the lock");
    let ClaudeProcess { pty, writer_lock, hooks, .. } = process;
    let (commands, requests) = command_channel();
    let (sender, mut events) = mpsc::unbounded_channel();
    let config = LinkConfig {
        conversation: conversation.clone(),
        terminal: pty.master.try_clone().unwrap(),
        log_context: "test".into(),
    };
    let link = tokio::spawn(run(config, requests, hooks, move |event| sender.send(event).is_ok()));
    match events.recv().await.unwrap() {
        AgentEvent::Bound { agent_session_id } => assert_eq!(agent_session_id, conversation),
        other => panic!("{other:?}"),
    }
    let (start, transcript) = until(&mut events, "pi.state").await;
    assert_eq!(start.last().unwrap().1["model"]["id"], "claude-opus-5");
    let transcript = transcript.expect("SessionStart names the transcript");
    let first = log(&directory);
    assert!(first.contains(&format!("tui new {conversation}")), "{first}");
    assert!(first.contains("brief You run inside Axo."), "{first}");
    assert!(first.contains("\"AXO_SESSION_ID\":\"s\""), "{first}");

    let send = |text: &'static str, delivery, n| {
        let commands = commands.clone();
        async move { commands.send_message(text, delivery, Some(&command(n)), &[], TIMEOUT).await.unwrap() }
    };
    assert_eq!(send("hello claude", None, 1).await, CommandResult::Accepted);

    let (turn, _) = until(&mut events, "agent.settled").await;
    let names: Vec<&str> = turn.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(names, ["agent.start", "message.start", "message.end", "message.start", "message.end", "agent.settled"]);
    assert_eq!(turn[4].1["message"]["content"][0]["text"], "echo: hello claude");
    // Claude writes its reply to the file after its Stop hook, so after the turn settles.
    let deadline = std::time::Instant::now() + TIMEOUT;
    let native = loop {
        let native = std::fs::read_to_string(&transcript).unwrap_or_default();
        if native.contains("echo: hello claude") {
            break native;
        }
        assert!(std::time::Instant::now() < deadline, "the reply never reached the file");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let header = crate::transcript::PiHeader {
        session_id: "s".into(),
        timestamp: crate::transcript::rfc3339_utc(0),
        cwd: "/".into(),
    };
    let lines = crate::transcript::pi_lines(crate::AgentKind::ClaudeCode, &native, &header).unwrap();
    assert!(lines.contains("echo: hello claude"), "{lines}");

    // A long turn: no steering, a follow-up waits, a stop is Escape and lets the follow-up go.
    assert_eq!(send("hang", None, 2).await, CommandResult::Accepted);
    until(&mut events, "agent.start").await;
    assert_eq!(send("now", Some(QueuedDelivery::Steer), 3).await, CommandResult::Rejected(RejectReason::Unavailable));
    assert_eq!(send("now", None, 3).await, CommandResult::Rejected(RejectReason::Busy));
    assert_eq!(send("after", Some(QueuedDelivery::FollowUp), 4).await, CommandResult::Accepted);
    let stop = StopTarget::new(None, None, vec![command(2)]).unwrap();
    assert_eq!(commands.stop_turn(stop.clone(), TIMEOUT).await.unwrap(), CommandResult::Accepted);
    until_log(&directory, "escape").await;
    until_log(&directory, "prompt after").await;
    until(&mut events, "agent.settled").await;
    until(&mut events, "agent.settled").await;
    assert_eq!(commands.stop_turn(stop, TIMEOUT).await.unwrap(), CommandResult::Rejected(RejectReason::Idle));
    assert_eq!(
        commands.set_model(Some(("anthropic", "claude-opus-5")), None, TIMEOUT).await.unwrap(),
        CommandResult::Rejected(RejectReason::Unavailable)
    );
    assert_eq!(commands.shutdown(TIMEOUT).await.unwrap(), CommandResult::Accepted);
    link.await.unwrap();
    until_log(&directory, "exit").await;
    drop((pty, writer_lock));

    // The conversation Claude wrote is resumed by the next launch.
    assert!(transcript_exists(&directory.join(".claude"), &conversation));
    let again = tokio::task::spawn_blocking(move || launch(&launch_request)).await.unwrap().unwrap();
    until_log(&directory, &format!("tui resume {conversation}")).await;
    axo_pty::process::signal(&again.pty.child, libc::SIGKILL);
    drop(again);
    std::fs::remove_dir_all(&directory).unwrap();
}
