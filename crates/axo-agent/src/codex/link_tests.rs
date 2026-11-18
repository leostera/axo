//! The link against a fake app-server speaking Codex 0.170.0's frames, as recorded from the
//! real one (initialize, thread/start, thread/name/set, model/list) and as its protocol types
//! describe turns.

use super::*;
use axo_protocol::commands::{CommandId, StopTarget};
use tokio::sync::mpsc;

use crate::runtime::QueuedDelivery;
use tokio::net::UnixListener;
use tokio_tungstenite::WebSocketStream;

const THREAD: &str = "01a1eea8-952a-7271-8b55-c2708a01c6ff";
const COMMAND: &str = "6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b";

/// The server's side of one connection.
struct Server(WebSocketStream<UnixStream>);

impl Server {
    async fn accept(listener: &UnixListener) -> Self {
        let (stream, _) = listener.accept().await.unwrap();
        Self(tokio_tungstenite::accept_async(stream).await.unwrap())
    }

    async fn read(&mut self) -> Value {
        loop {
            match self.0.next().await.unwrap().unwrap() {
                Message::Text(text) => return serde_json::from_str(&text).unwrap(),
                _ => continue,
            }
        }
    }

    /// Reads the next request, checks its method, and returns it.
    async fn expect(&mut self, method: &str) -> Value {
        let request = self.read().await;
        assert_eq!(request["method"], method, "{request}");
        request
    }

    async fn send(&mut self, value: Value) {
        self.0.send(Message::Text(value.to_string().into())).await.unwrap();
    }

    async fn answer(&mut self, request: &Value, result: Value) {
        self.send(json!({ "id": request["id"], "result": result })).await;
    }

    async fn notify(&mut self, method: &str, params: Value) {
        self.send(json!({ "method": method, "params": params, "emittedAtMs": 1 })).await;
    }

    async fn initialize(&mut self) {
        let initialize = self.expect("initialize").await;
        assert_eq!(initialize["params"]["clientInfo"]["name"], "axod");
        self.answer(&initialize, json!({ "userAgent": "axod/0.170.0", "codexHome": "/h", "platformFamily": "unix", "platformOs": "macos" })).await;
        self.notify("remoteControl/status/changed", json!({ "status": "disabled" })).await;
        self.expect("initialized").await;
    }

    /// What the real server answers when a client rejoins an idle thread (trimmed), then the
    /// model list the link asks for.
    async fn start_thread(&mut self) {
        self.initialize().await;
        let resume = self.expect("thread/resume").await;
        assert_eq!(resume["params"]["threadId"], THREAD);
        assert_eq!(resume["params"]["developerInstructions"], "<axo>brief</axo>");
        self.answer(&resume, json!({
            "thread": { "id": THREAD, "status": { "type": "idle" }, "turns": [] },
            "model": "gpt-5.1", "modelProvider": "openai", "reasoningEffort": "medium",
        })).await;
        self.notify("thread/name/updated", json!({ "threadId": THREAD, "threadName": "Session 1" })).await;
        let models = self.expect("model/list").await;
        self.answer(&models, json!({ "data": [
            { "id": "gpt-5.1", "displayName": "GPT-5.1", "hidden": false,
              "supportedReasoningEfforts": [{ "reasoningEffort": "low" }, { "reasoningEffort": "high" }] },
            { "id": "secret", "displayName": "Hidden", "hidden": true, "supportedReasoningEfforts": [] },
        ], "nextCursor": null })).await;
    }
}

struct Harness {
    directory: PathBuf,
    listener: UnixListener,
    commands: LinkCommands,
    heard: mpsc::UnboundedReceiver<AgentEvent>,
    link: tokio::task::JoinHandle<()>,
}

fn start(instructions: Option<&str>) -> Harness {
    let directory = crate::test_directory();
    let socket = directory.join("codex.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let (commands, requests) = command_channel();
    let (events, heard) = mpsc::unbounded_channel();
    let config = LinkConfig {
        socket,
        thread_id: THREAD.into(),
        instructions: instructions.map(str::to_owned),
        log_context: "test".into(),
    };
    let link = tokio::spawn(run(config, requests, None, move |event| events.send(event).is_ok()));
    Harness {
        directory,
        listener,
        commands,
        heard,
        link,
    }
}

/// The next event, skipping nothing: the name and data of an `Event`, or the event itself.
async fn next_event(heard: &mut mpsc::UnboundedReceiver<AgentEvent>) -> (String, Value) {
    match tokio::time::timeout(Duration::from_secs(5), heard.recv()).await.unwrap().unwrap() {
        AgentEvent::Event { name, data, .. } => (name, data),
        other => (format!("{other:?}"), Value::Null),
    }
}

async fn until_event(heard: &mut mpsc::UnboundedReceiver<AgentEvent>, wanted: &str) -> Value {
    loop {
        let (name, data) = next_event(heard).await;
        if name == wanted {
            return data;
        }
    }
}

#[tokio::test]
async fn the_link_rejoins_the_thread_binds_and_reports_its_state_and_models() {
    let mut harness = start(Some("<axo>brief</axo>"));
    let mut server = Server::accept(&harness.listener).await;
    server.start_thread().await;
    assert_eq!(
        harness.heard.recv().await.unwrap(),
        AgentEvent::Bound {
            agent_session_id: THREAD.into()
        }
    );
    assert_eq!(next_event(&mut harness.heard).await, ("activity.snapshot".into(), json!({ "working": false })));
    let (name, state) = next_event(&mut harness.heard).await;
    assert_eq!(name, "pi.state");
    assert_eq!(state["model"]["id"], "gpt-5.1");
    assert_eq!(state["thinkingLevel"], "medium");
    assert_eq!(until_event(&mut harness.heard, "session.info").await, json!({ "name": "Session 1" }));
    let models = until_event(&mut harness.heard, "pi.models").await;
    assert_eq!(
        models["models"],
        json!([{ "provider": "codex", "id": "gpt-5.1", "name": "GPT-5.1", "thinkingLevels": ["low", "high"] }])
    );
    harness.link.abort();
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn a_prompt_starts_a_turn_whose_reply_streams_and_a_follow_up_waits_for_it() {
    let mut harness = start(Some("<axo>brief</axo>"));
    let mut server = Server::accept(&harness.listener).await;
    server.start_thread().await;
    until_event(&mut harness.heard, "pi.models").await;

    let command = CommandId::try_from(COMMAND.to_owned()).unwrap();
    let sending = tokio::spawn({
        let commands = harness.commands.clone();
        let command = command.clone();
        async move {
            commands
                .send_message("hello", None, Some(&command), &[], Duration::from_secs(5))
                .await
        }
    });
    let turn = server.expect("turn/start").await;
    assert_eq!(turn["params"]["threadId"], THREAD);
    assert_eq!(turn["params"]["clientUserMessageId"], COMMAND);
    assert_eq!(turn["params"]["input"][0]["text"], "hello");
    assert_eq!(turn["params"]["effort"], "medium");
    server.answer(&turn, json!({ "turn": { "id": "turn-1", "status": "inProgress", "items": [] } })).await;
    assert_eq!(sending.await.unwrap().unwrap(), CommandResult::Accepted);

    // While it works: a plain prompt is refused, a follow-up waits.
    let busy = harness.commands.send_message("again", None, None, &[], Duration::from_secs(5)).await;
    assert_eq!(busy.unwrap(), CommandResult::Rejected(RejectReason::Busy));
    let held = harness
        .commands
        .send_message("later", Some(QueuedDelivery::FollowUp), None, &[], Duration::from_secs(5))
        .await;
    assert_eq!(held.unwrap(), CommandResult::Accepted);

    server.notify("turn/started", json!({ "threadId": THREAD, "turn": { "id": "turn-1", "status": "inProgress", "items": [] } })).await;
    assert_eq!(until_event(&mut harness.heard, "agent.start").await, json!({}));
    server.notify("item/agentMessage/delta", json!({ "threadId": THREAD, "turnId": "turn-1", "itemId": "m1", "delta": "Hi" })).await;
    let update = until_event(&mut harness.heard, "message.update").await;
    assert_eq!(update["message"]["content"][0]["text"], "Hi");
    server.notify("item/completed", json!({ "threadId": THREAD, "turnId": "turn-1", "item": { "type": "agentMessage", "id": "m1", "text": "Hi!" } })).await;
    let end = until_event(&mut harness.heard, "message.end").await;
    assert_eq!(end["message"]["role"], "assistant");
    server.notify("turn/completed", json!({ "threadId": THREAD, "turn": { "id": "turn-1", "status": "completed", "items": [] } })).await;
    until_event(&mut harness.heard, "agent.settled").await;

    // The follow-up starts the next turn on its own.
    let next = server.expect("turn/start").await;
    assert_eq!(next["params"]["input"][0]["text"], "later");
    harness.link.abort();
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn a_stop_interrupts_the_turn_the_client_saw_and_a_steer_names_it() {
    let mut harness = start(Some("<axo>brief</axo>"));
    let mut server = Server::accept(&harness.listener).await;
    server.start_thread().await;
    until_event(&mut harness.heard, "pi.models").await;
    // The person starts a turn in the TUI.
    server.notify("turn/started", json!({ "threadId": THREAD, "turn": { "id": "turn-7", "status": "inProgress", "items": [] } })).await;
    server.notify("item/started", json!({ "threadId": THREAD, "turnId": "turn-7", "item": {
        "type": "userMessage", "id": "u7", "clientId": COMMAND, "content": [{ "type": "text", "text": "typed", "text_elements": [] }]
    } })).await;
    until_event(&mut harness.heard, "message.start").await;

    let steering = tokio::spawn({
        let commands = harness.commands.clone();
        async move {
            commands
                .send_message("also", Some(QueuedDelivery::Steer), None, &[], Duration::from_secs(5))
                .await
        }
    });
    let steer = server.expect("turn/steer").await;
    assert_eq!(steer["params"]["expectedTurnId"], "turn-7");
    server.send(json!({ "id": steer["id"], "error": { "code": -32600, "message": "turn mismatch" } })).await;
    assert_eq!(steering.await.unwrap().unwrap(), CommandResult::Rejected(RejectReason::Stale));

    let unseen = StopTarget::new(None, None, vec![CommandId::try_from("6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a00".to_owned()).unwrap()]).unwrap();
    assert_eq!(
        harness.commands.stop_turn(unseen, Duration::from_secs(5)).await.unwrap(),
        CommandResult::Rejected(RejectReason::Idle)
    );
    let seen = StopTarget::new(None, None, vec![CommandId::try_from(COMMAND.to_owned()).unwrap()]).unwrap();
    let stopping = tokio::spawn({
        let commands = harness.commands.clone();
        async move { commands.stop_turn(seen, Duration::from_secs(5)).await }
    });
    let interrupt = server.expect("turn/interrupt").await;
    assert_eq!(interrupt["params"], json!({ "threadId": THREAD, "turnId": "turn-7" }));
    server.answer(&interrupt, json!({})).await;
    assert_eq!(stopping.await.unwrap().unwrap(), CommandResult::Accepted);
    harness.link.abort();
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn approvals_are_left_to_the_tui_and_shown_as_waiting_on_the_person() {
    let mut harness = start(Some("<axo>brief</axo>"));
    let mut server = Server::accept(&harness.listener).await;
    server.start_thread().await;
    until_event(&mut harness.heard, "pi.models").await;
    server.send(json!({ "id": 0, "method": "item/commandExecution/requestApproval", "params": { "threadId": THREAD, "itemId": "c" } })).await;
    server.notify("thread/status/changed", json!({ "threadId": THREAD, "status": { "type": "active", "activeFlags": ["waitingOnApproval"] } })).await;
    assert_eq!(until_event(&mut harness.heard, "ui.prompt.start").await["kind"], "approval");
    server.notify("serverRequest/resolved", json!({ "threadId": THREAD, "requestId": 0 })).await;
    server.notify("thread/status/changed", json!({ "threadId": THREAD, "status": { "type": "active", "activeFlags": [] } })).await;
    until_event(&mut harness.heard, "ui.prompt.end").await;
    // The link never answered the approval: the next thing it writes is its own request.
    let asking = tokio::spawn({
        let commands = harness.commands.clone();
        async move { commands.send_message("x", Some(QueuedDelivery::FollowUp), None, &[], Duration::from_secs(5)).await }
    });
    // Idle per the link (no turn started), so the prompt starts one.
    let next = server.expect("turn/start").await;
    assert!(next.get("result").is_none());
    server.answer(&next, json!({ "turn": { "id": "t" } })).await;
    asking.await.unwrap().unwrap();
    harness.link.abort();
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn a_dropped_connection_rejoins_the_same_thread() {
    let mut harness = start(Some("<axo>brief</axo>"));
    let mut server = Server::accept(&harness.listener).await;
    server.start_thread().await;
    until_event(&mut harness.heard, "pi.models").await;
    drop(server);
    loop {
        if let (name, _) = next_event(&mut harness.heard).await
            && name == "Disconnected"
        {
            break;
        }
    }
    let mut again = Server::accept(&harness.listener).await;
    again.initialize().await;
    let resume = again.expect("thread/resume").await;
    assert_eq!(resume["params"]["threadId"], THREAD);
    assert_eq!(resume["params"]["developerInstructions"], "<axo>brief</axo>");
    again.answer(&resume, json!({ "thread": { "id": THREAD, "status": { "type": "active", "activeFlags": [] } }, "model": "gpt-5.1", "modelProvider": "openai" })).await;
    assert_eq!(
        harness.heard.recv().await.unwrap(),
        AgentEvent::Bound {
            agent_session_id: THREAD.into()
        }
    );
    assert_eq!(next_event(&mut harness.heard).await.1, json!({ "working": true }));
    harness.link.abort();
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn an_existing_thread_that_cannot_be_resumed_ends_the_link() {
    let mut harness = start(None);
    let mut server = Server::accept(&harness.listener).await;
    server.initialize().await;
    let resume = server.expect("thread/resume").await;
    assert!(resume["params"].get("developerInstructions").is_none());
    server.send(json!({ "id": resume["id"], "error": { "code": -32600, "message": "no rollout found" } })).await;
    tokio::time::timeout(Duration::from_secs(5), &mut harness.link)
        .await
        .expect("the link ends")
        .unwrap();
    assert!(harness.heard.try_recv().is_err(), "it never bound");
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn a_server_that_breaks_the_protocol_is_not_followed() {
    let mut harness = start(Some("<axo>brief</axo>"));
    let mut server = Server::accept(&harness.listener).await;
    server.start_thread().await;
    until_event(&mut harness.heard, "pi.models").await;
    server.0.send(Message::Text("{\"neither\":1}".into())).await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), &mut harness.link)
        .await
        .expect("the link ends")
        .unwrap();
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn continuation_is_refused_and_shutdown_ends_the_link() {
    let mut harness = start(Some("<axo>brief</axo>"));
    let mut server = Server::accept(&harness.listener).await;
    server.start_thread().await;
    until_event(&mut harness.heard, "pi.models").await;
    assert_eq!(
        harness.commands.resume_turn(Duration::from_secs(5)).await.unwrap(),
        CommandResult::Rejected(RejectReason::Unavailable)
    );
    assert_eq!(
        harness.commands.set_model(None, Some("max"), Duration::from_secs(5)).await.unwrap(),
        CommandResult::Rejected(RejectReason::Invalid)
    );
    assert_eq!(
        harness.commands.set_model(Some(("codex", "gpt-5.1-mini")), Some("high"), Duration::from_secs(5)).await.unwrap(),
        CommandResult::Accepted
    );
    let state = until_event(&mut harness.heard, "pi.state").await;
    assert_eq!(state["model"]["id"], "gpt-5.1-mini");
    assert_eq!(state["thinkingLevel"], "high");
    assert_eq!(
        harness.commands.shutdown(Duration::from_secs(5)).await.unwrap(),
        CommandResult::Accepted
    );
    tokio::time::timeout(Duration::from_secs(5), &mut harness.link)
        .await
        .expect("the link ends")
        .unwrap();
    std::fs::remove_dir_all(harness.directory).unwrap();
}

#[tokio::test]
async fn a_new_session_gets_a_thread_that_is_written_before_the_tui_resumes_it() {
    let directory = crate::test_directory();
    let socket = directory.join("codex.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let creating = tokio::spawn({
        let socket = socket.clone();
        async move {
            create_thread(&socket, Path::new("/work"), "Session 1", Some("<axo>brief</axo>"), "test").await
        }
    });
    let mut server = Server::accept(&listener).await;
    server.initialize().await;
    let start = server.expect("thread/start").await;
    assert_eq!(start["params"]["cwd"], "/work");
    assert_eq!(start["params"]["developerInstructions"], "<axo>brief</axo>");
    server.notify("thread/started", json!({ "thread": { "id": THREAD } })).await;
    server.answer(&start, json!({ "thread": { "id": THREAD, "status": { "type": "idle" } }, "model": "gpt-5.1", "modelProvider": "openai" })).await;
    let name = server.expect("thread/name/set").await;
    assert_eq!(name["params"], json!({ "threadId": THREAD, "name": "Session 1" }));
    server.answer(&name, json!({})).await;
    assert_eq!(creating.await.unwrap().unwrap(), THREAD);
    std::fs::remove_dir_all(directory).unwrap();
}

#[tokio::test]
async fn a_thread_that_cannot_be_started_is_an_error() {
    let directory = crate::test_directory();
    let socket = directory.join("codex.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let creating = tokio::spawn({
        let socket = socket.clone();
        async move { create_thread(&socket, Path::new("/work"), "S", None, "test").await }
    });
    let mut server = Server::accept(&listener).await;
    server.initialize().await;
    let start = server.expect("thread/start").await;
    assert!(start["params"].get("developerInstructions").is_none());
    server.send(json!({ "id": start["id"], "error": { "code": -32603, "message": "no auth" } })).await;
    assert!(creating.await.unwrap().is_err());
    std::fs::remove_dir_all(directory).unwrap();
}
