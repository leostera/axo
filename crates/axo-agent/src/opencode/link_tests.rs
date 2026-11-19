use super::*;
use std::io::BufRead;

use axo_protocol::commands::{CommandId, StopTarget};
use tokio::sync::mpsc;

use crate::channel::command_channel;
use crate::runtime::QueuedDelivery;

/// The fake server, started without a guard, and where it listens.
fn serve(directory: &std::path::Path) -> (ServerProcess, ServerAddress) {
    let fake = std::fs::canonicalize(std::env::var_os("AXO_TEST_FAKE_OPENCODE").expect("set by Bazel")).unwrap();
    let mut child = std::process::Command::new(fake)
        .args(["serve", "--hostname", "127.0.0.1"])
        .current_dir(directory)
        .env("OPENCODE_SERVER_PASSWORD", "pw")
        .env("AXO_FAKE_OPENCODE_LOG", directory.join("opencode.log"))
        .stdout(std::process::Stdio::piped())
        .process_group(0)
        .spawn()
        .unwrap();
    let mut lines = std::io::BufReader::new(child.stdout.take().unwrap()).lines();
    let address = loop {
        let line = lines.next().unwrap().unwrap();
        if let Some(address) = ServerAddress::from_listening_line(&line, "pw".into()) {
            break address;
        }
    };
    std::thread::spawn(move || lines.for_each(drop));
    (ServerProcess::new(child, crate::channel::nothing_while_running), address)
}

use std::os::unix::process::CommandExt;

struct Followed {
    commands: crate::channel::LinkCommands,
    events: mpsc::UnboundedReceiver<AgentEvent>,
    link: tokio::task::JoinHandle<()>,
    conversation: PathBuf,
}

async fn follow(directory: &std::path::Path) -> Followed {
    let (server, address) = serve(directory);
    let session_id = create_session(&address, directory, "Session 1").await.unwrap();
    let conversation = directory.join("conversation.json");
    let config = LinkConfig {
        address,
        session_id,
        directory: directory.to_owned(),
        conversation: conversation.clone(),
        log_context: "test".into(),
    };
    let (commands, requests) = command_channel();
    let (sender, events) = mpsc::unbounded_channel();
    let link = tokio::spawn(run(config, requests, Some(server), move |event| sender.send(event).is_ok()));
    Followed { commands, events, link, conversation }
}

/// Events until one named `name`, which is included.
async fn until(events: &mut mpsc::UnboundedReceiver<AgentEvent>, name: &str) -> Vec<(String, Value)> {
    let mut seen = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let event = tokio::time::timeout_at(deadline, events.recv())
            .await
            .unwrap_or_else(|_| panic!("no {name} after {seen:?}"))
            .expect("the link ended");
        if let AgentEvent::Event { name: got, data, .. } = event {
            let done = got == name;
            seen.push((got, data));
            if done {
                return seen;
            }
        }
    }
}

fn command(n: u8) -> CommandId {
    CommandId::try_from(format!("6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a{n:02x}")).unwrap()
}

const TIMEOUT: Duration = Duration::from_secs(10);

#[tokio::test]
async fn a_prompt_runs_and_its_conversation_is_kept_for_the_transcript() {
    let directory = crate::test_directory();
    let mut followed = follow(&directory).await;
    match followed.events.recv().await.unwrap() {
        AgentEvent::Bound { agent_session_id } => assert_eq!(agent_session_id, "ses_fake0001"),
        other => panic!("{other:?}"),
    }
    let first = until(&mut followed.events, "pi.models").await;
    let names: Vec<&str> = first.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(names, ["activity.snapshot", "pi.state", "pi.models"]);
    assert_eq!(first[1].1["model"]["id"], "mock-1");
    let answer = followed
        .commands
        .send_message("hello opencode", None, Some(&command(1)), &[], TIMEOUT)
        .await
        .unwrap();
    assert_eq!(answer, CommandResult::Accepted);
    let turn = until(&mut followed.events, "agent.settled").await;
    let names: Vec<&str> = turn.iter().map(|(name, _)| name.as_str()).collect();
    assert_eq!(
        names,
        ["agent.start", "message.start", "message.end", "message.start", "message.update", "message.update", "message.end", "agent.settled"]
    );
    assert_eq!(turn[6].1["message"]["content"][0]["text"], "echo: hello opencode");
    let export = std::fs::read_to_string(&followed.conversation).unwrap();
    let header = crate::transcript::PiHeader {
        session_id: "s".into(),
        timestamp: crate::transcript::rfc3339_utc(0),
        cwd: "/".into(),
    };
    let lines = crate::transcript::pi_lines(crate::AgentKind::OpenCode, &export, &header).unwrap();
    assert!(lines.contains("echo: hello opencode"), "{lines}");
    assert!(lines.contains("hello opencode"), "{lines}");
    followed.commands.shutdown(TIMEOUT).await.unwrap();
    followed.link.await.unwrap();
    std::fs::remove_dir_all(&directory).unwrap();
}

#[tokio::test]
async fn busy_steer_stop_and_model_commands_reach_the_server() {
    let directory = crate::test_directory();
    let mut followed = follow(&directory).await;
    until(&mut followed.events, "pi.models").await;
    let send = |text: &'static str, delivery, n| {
        let commands = followed.commands.clone();
        async move { commands.send_message(text, delivery, Some(&command(n)), &[], TIMEOUT).await.unwrap() }
    };
    assert_eq!(send("hang", None, 1).await, CommandResult::Accepted);
    until(&mut followed.events, "agent.start").await;
    assert_eq!(send("again", None, 2).await, CommandResult::Rejected(RejectReason::Busy));
    let stale = StopTarget::new(None, None, vec![command(9)]).unwrap();
    // A stop that names nothing axod sent ends what runs (the person's turn, say).
    assert_eq!(followed.commands.stop_turn(stale, TIMEOUT).await.unwrap(), CommandResult::Accepted);
    until(&mut followed.events, "agent.settled").await;
    let old = StopTarget::new(None, None, vec![command(1)]).unwrap();
    assert_eq!(
        followed.commands.stop_turn(old, TIMEOUT).await.unwrap(),
        CommandResult::Rejected(RejectReason::Idle)
    );
    assert_eq!(
        followed.commands.set_model(Some(("mock", "mock-2")), Some("high"), TIMEOUT).await.unwrap(),
        CommandResult::Rejected(RejectReason::Invalid)
    );
    assert_eq!(
        followed.commands.set_model(Some(("mock", "mock-2")), None, TIMEOUT).await.unwrap(),
        CommandResult::Accepted
    );
    let state = until(&mut followed.events, "pi.state").await;
    assert_eq!(state.last().unwrap().1["model"]["id"], "mock-2");
    assert_eq!(
        followed.commands.resume_turn(TIMEOUT).await.unwrap(),
        CommandResult::Rejected(RejectReason::Unavailable)
    );
    assert_eq!(send("next", Some(QueuedDelivery::FollowUp), 3).await, CommandResult::Accepted);
    until(&mut followed.events, "agent.settled").await;
    let log = std::fs::read_to_string(directory.join("opencode.log")).unwrap();
    assert!(log.contains("prompt ses_fake0001 delivery=none text=hang"), "{log}");
    assert!(log.contains("interrupt ses_fake0001 interrupted=true"), "{log}");
    assert!(log.contains("model ses_fake0001 {\"id\":\"mock-2\",\"providerID\":\"mock\"}"), "{log}");
    assert!(!log.contains("text=again"), "a busy answer sends nothing: {log}");
    drop(followed.commands);
    followed.link.await.unwrap();
    std::fs::remove_dir_all(&directory).unwrap();
}

#[tokio::test]
async fn a_session_the_server_does_not_have_ends_the_link_unbound() {
    let directory = crate::test_directory();
    let (server, address) = serve(&directory);
    let config = LinkConfig {
        address,
        session_id: "ses_missing".into(),
        directory: directory.clone(),
        conversation: directory.join("conversation.json"),
        log_context: "test".into(),
    };
    let (_commands, requests) = command_channel();
    let (sender, mut events) = mpsc::unbounded_channel();
    tokio::time::timeout(TIMEOUT, run(config, requests, Some(server), move |event| sender.send(event).is_ok()))
        .await
        .expect("the link gives up");
    while let Ok(event) = events.try_recv() {
        assert!(!matches!(event, AgentEvent::Bound { .. }), "{event:?}");
    }
    std::fs::remove_dir_all(&directory).unwrap();
}
