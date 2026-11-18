use super::*;
use axo_protocol::commands::EntryId;

const THREAD: &str = "01a1eea8-952a-7271-8b55-c2708a01c6ff";

fn command(n: u8) -> CommandId {
    CommandId::try_from(format!("6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a{n:02x}")).unwrap()
}

fn prompt(text: &str, command_id: Option<CommandId>) -> TurnRequest {
    TurnRequest {
        input: vec![json!({ "type": "text", "text": text, "text_elements": [] })],
        command_id,
    }
}

fn started(thread: &mut Thread, turn: &str) -> Observed {
    thread.observe(
        "turn/started",
        &json!({ "threadId": THREAD, "turn": { "id": turn, "status": "inProgress", "items": [] } }),
    )
}

fn completed(thread: &mut Thread, turn: &str) -> Observed {
    thread.observe(
        "turn/completed",
        &json!({ "threadId": THREAD, "turn": { "id": turn, "status": "completed", "items": [] } }),
    )
}

fn names(observed: &Observed) -> Vec<&'static str> {
    observed.events.iter().map(|event| event.name).collect()
}

#[test]
fn an_idle_thread_starts_a_turn_and_a_busy_one_refuses_a_plain_prompt() {
    let mut thread = Thread::new(THREAD.into(), None);
    assert!(!thread.working());
    let first = prompt("hi", Some(command(1)));
    assert_eq!(thread.plan_send(first.clone(), None), SendPlan::Start(first));
    assert!(thread.working(), "working from the moment axod asks");
    assert_eq!(
        thread.plan_send(prompt("again", None), None),
        SendPlan::Reject(RejectReason::Busy)
    );
}

#[test]
fn steering_and_interrupting_need_the_turn_to_be_named() {
    let mut thread = Thread::new(THREAD.into(), None);
    thread.plan_send(prompt("hi", None), None);
    assert_eq!(
        thread.plan_send(prompt("steer", None), Some(QueuedDelivery::Steer)),
        SendPlan::Reject(RejectReason::Busy)
    );
    thread.started("turn-1");
    let steer = prompt("steer", Some(command(2)));
    assert_eq!(
        thread.plan_send(steer.clone(), Some(QueuedDelivery::Steer)),
        SendPlan::Steer {
            turn_id: "turn-1".into(),
            request: steer
        }
    );
    assert_eq!(
        thread.plan_send(prompt("now", None), Some(QueuedDelivery::Interrupt)),
        SendPlan::Interrupt {
            turn_id: "turn-1".into()
        }
    );
}

#[test]
fn follow_ups_wait_in_order_and_each_starts_the_next_turn() {
    let mut thread = Thread::new(THREAD.into(), Some("turn-1".into()));
    let (a, b) = (prompt("a", Some(command(1))), prompt("b", Some(command(2))));
    assert_eq!(thread.plan_send(a.clone(), Some(QueuedDelivery::FollowUp)), SendPlan::Held);
    assert_eq!(thread.plan_send(b.clone(), Some(QueuedDelivery::FollowUp)), SendPlan::Held);
    let ended = completed(&mut thread, "turn-1");
    assert_eq!(names(&ended), ["agent.settled"]);
    assert_eq!(ended.next, Some(a));
    assert!(thread.working(), "the follow-up's turn is on its way");
    started(&mut thread, "turn-2");
    assert_eq!(completed(&mut thread, "turn-2").next, Some(b));
    started(&mut thread, "turn-3");
    assert_eq!(completed(&mut thread, "turn-3").next, None);
    assert!(!thread.working());
}

#[test]
fn an_interrupting_prompt_goes_before_the_follow_ups() {
    let mut thread = Thread::new(THREAD.into(), Some("turn-1".into()));
    thread.plan_send(prompt("later", None), Some(QueuedDelivery::FollowUp));
    let now = prompt("now", None);
    thread.plan_send(now.clone(), Some(QueuedDelivery::Interrupt));
    assert_eq!(completed(&mut thread, "turn-1").next, Some(now));
}

#[test]
fn a_stop_ends_only_a_turn_the_client_saw() {
    let mut thread = Thread::new(THREAD.into(), None);
    let by_command = StopTarget::new(None, None, vec![command(1)]).unwrap();
    assert_eq!(thread.plan_stop(&by_command), StopPlan::Idle, "idle");
    thread.plan_send(prompt("hi", Some(command(1))), None);
    assert_eq!(thread.plan_stop(&by_command), StopPlan::Idle, "not named yet");
    started(&mut thread, "turn-1");
    let interrupt = StopPlan::Interrupt {
        turn_id: "turn-1".into(),
    };
    assert_eq!(thread.plan_stop(&by_command), interrupt);
    let other = StopTarget::new(None, None, vec![command(9)]).unwrap();
    assert_eq!(thread.plan_stop(&other), StopPlan::Idle);
    thread.observe(
        "item/started",
        &json!({ "threadId": THREAD, "turnId": "turn-1", "item": { "type": "agentMessage", "id": "item-7", "text": "" } }),
    );
    let entry = |id: &str| EntryId::try_from(id.to_owned()).unwrap();
    let by_item = StopTarget::new(None, Some(entry("item-7")), Vec::new()).unwrap();
    assert_eq!(thread.plan_stop(&by_item), interrupt);
    let by_turn = StopTarget::new(Some(entry("turn-1")), None, Vec::new()).unwrap();
    assert_eq!(thread.plan_stop(&by_turn), interrupt);
    completed(&mut thread, "turn-1");
    assert_eq!(thread.plan_stop(&by_turn), StopPlan::Idle, "it has ended");
}

#[test]
fn a_turn_the_person_started_in_the_tui_is_followed_and_its_prompt_can_be_stopped() {
    let mut thread = Thread::new(THREAD.into(), None);
    assert_eq!(names(&started(&mut thread, "turn-9")), ["agent.start"]);
    assert!(thread.working());
    let user = thread.observe(
        "item/started",
        &json!({ "threadId": THREAD, "turnId": "turn-9", "item": {
            "type": "userMessage", "id": "u", "clientId": command(4).as_str(),
            "content": [{ "type": "text", "text": "typed", "text_elements": [] }]
        } }),
    );
    assert_eq!(user.events[0].name, "message.start");
    assert_eq!(user.events[0].data["message"]["role"], "user");
    let stop = StopTarget::new(None, None, vec![command(4)]).unwrap();
    assert!(matches!(thread.plan_stop(&stop), StopPlan::Interrupt { .. }));
}

#[test]
fn waiting_on_the_person_is_one_prompt_start_and_one_end() {
    let mut thread = Thread::new(THREAD.into(), Some("turn-1".into()));
    let status = |flags: Value| json!({ "threadId": THREAD, "status": { "type": "active", "activeFlags": flags } });
    let approval = thread.observe("thread/status/changed", &status(json!(["waitingOnApproval"])));
    assert_eq!(names(&approval), ["ui.prompt.start"]);
    assert_eq!(approval.events[0].data["kind"], "approval");
    let both = thread.observe(
        "thread/status/changed",
        &status(json!(["waitingOnApproval", "waitingOnUserInput"])),
    );
    assert!(both.events.is_empty(), "still waiting");
    let resolved = thread.observe("thread/status/changed", &status(json!([])));
    assert_eq!(names(&resolved), ["ui.prompt.end"]);
    thread.observe("thread/status/changed", &status(json!(["waitingOnUserInput"])));
    // A turn that ends while waiting ends the wait too.
    assert_eq!(names(&completed(&mut thread, "turn-1")), ["ui.prompt.end", "agent.settled"]);
}

#[test]
fn replies_stream_as_they_are_written_and_end_whole() {
    let mut thread = Thread::new(THREAD.into(), Some("turn-1".into()));
    let delta = |text: &str| json!({ "threadId": THREAD, "turnId": "turn-1", "itemId": "m", "delta": text });
    thread.observe("item/agentMessage/delta", &delta("Hel"));
    let update = thread.observe("item/agentMessage/delta", &delta("lo"));
    assert_eq!(update.events[0].name, "message.update");
    assert_eq!(update.events[0].data["message"]["content"][0]["text"], "Hello");
    let end = thread.observe(
        "item/completed",
        &json!({ "threadId": THREAD, "turnId": "turn-1", "item": { "type": "agentMessage", "id": "m", "text": "Hello." } }),
    );
    assert_eq!(end.events[0].name, "message.end");
    assert_eq!(
        end.events[0].data["message"],
        json!({ "role": "assistant", "content": [{ "type": "text", "text": "Hello." }] })
    );
}

#[test]
fn tools_are_reported_as_pi_reports_them() {
    let mut thread = Thread::new(THREAD.into(), Some("turn-1".into()));
    let item = |status: &str| json!({
        "type": "commandExecution", "id": "c1", "command": "ls", "cwd": "/w",
        "status": status, "aggregatedOutput": "a\nb", "exitCode": 1
    });
    let start = thread.observe("item/started", &json!({ "threadId": THREAD, "item": item("inProgress") }));
    assert_eq!(start.events[0].name, "tool.start");
    assert_eq!(start.events[0].data["toolName"], "bash");
    assert_eq!(start.events[0].data["args"]["command"], "ls");
    let end = thread.observe("item/completed", &json!({ "threadId": THREAD, "item": item("completed") }));
    assert_eq!(end.events[0].name, "tool.end");
    assert_eq!(end.events[0].data["isError"], true);
    assert_eq!(end.events[0].data["result"]["content"][0]["text"], "a\nb");
    let reasoning = thread.observe(
        "item/completed",
        &json!({ "threadId": THREAD, "item": { "type": "reasoning", "id": "r", "summary": [], "content": [] } }),
    );
    assert!(reasoning.events.is_empty());
}

#[test]
fn another_threads_notifications_change_nothing() {
    let mut thread = Thread::new(THREAD.into(), None);
    let other = thread.observe(
        "turn/started",
        &json!({ "threadId": "someone-else", "turn": { "id": "x" } }),
    );
    assert_eq!(other, Observed::default());
    assert!(!thread.working());
}

#[test]
fn the_model_and_effort_are_announced_as_pi_state() {
    let mut thread = Thread::new(THREAD.into(), None);
    assert_eq!(thread.snapshot().len(), 1, "no model known yet");
    thread.set_running_model("openai", "gpt-5.1", Some("medium"));
    let snapshot = thread.snapshot();
    assert_eq!(snapshot[1].name, "pi.state");
    assert_eq!(snapshot[1].data["thinkingLevel"], "medium");
    let changed = thread.choose(Some("gpt-5.1-mini"), Some("high"));
    assert_eq!(changed[0].data["model"]["id"], "gpt-5.1-mini");
    assert_eq!(changed[0].data["thinkingLevel"], "high");
    assert_eq!(
        thread.choice(),
        &ModelChoice {
            model: Some("gpt-5.1-mini".into()),
            effort: Some("high".into())
        }
    );
    assert_eq!(reasoning_effort("off"), Some("none"));
    assert_eq!(reasoning_effort("max"), None);
}

#[test]
fn attachments_become_lines_and_local_images() {
    use axo_protocol::asset::{AssetHash, AssetName, AssetType};
    let attachment = |name: &str, mime: &str, size: u64| FetchedAttachment {
        path: std::path::PathBuf::from(format!("/tmp/{name}")),
        asset: AssetHash::from_digest([0xab; 32]),
        name: AssetName::parse(name.to_owned()).unwrap(),
        mime_type: AssetType::parse(mime).unwrap(),
        size,
    };
    let input = user_input(
        "look",
        &[
            attachment("a.png", "image/png", 2048),
            attachment("b.pdf", "application/pdf", 3 * 1024 * 1024),
        ],
    );
    let text = input[0]["text"].as_str().unwrap();
    assert!(text.starts_with("look\n\n[Attached image: a.png at /tmp/a.png axo-asset:sha256:abab"));
    assert!(text.contains("[Attached file: b.pdf (application/pdf, 3.0 MB) at /tmp/b.pdf"));
    assert_eq!(input[1], json!({ "type": "localImage", "path": "/tmp/a.png" }));
    assert_eq!(input.len(), 2);
}

/// A model of the rules, checked against the state machine over many generated runs: at most
/// one turn at a time, held prompts start in order with an interrupting one first, and every
/// accepted prompt starts exactly once.
#[test]
fn generated_runs_keep_one_turn_at_a_time_and_start_every_accepted_prompt_once() {
    let mut seed = 0x853c_49e6_748f_ea9b_u64;
    let mut next = move |bound: u64| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed % bound
    };
    for run in 0..2_000 {
        let mut thread = Thread::new(THREAD.into(), None);
        let mut serial = 0_u32;
        let mut accepted: Vec<String> = Vec::new();
        let mut started_texts: Vec<String> = Vec::new();
        // The turn the server is running, and whether axod has asked for one it hasn't named.
        let mut running: Option<String> = None;
        let mut asked = false;
        let mut turns = 0_u32;
        for _ in 0..40 {
            match next(6) {
                0..=2 => {
                    serial += 1;
                    let text = format!("p{serial}");
                    let delivery = match next(4) {
                        0 => None,
                        1 => Some(QueuedDelivery::Steer),
                        2 => Some(QueuedDelivery::FollowUp),
                        _ => Some(QueuedDelivery::Interrupt),
                    };
                    match thread.plan_send(prompt(&text, None), delivery) {
                        SendPlan::Start(request) => {
                            assert!(running.is_none() && !asked, "run {run}: a second turn");
                            asked = true;
                            started_texts.push(request.input[0]["text"].as_str().unwrap().into());
                            accepted.push(text);
                        }
                        SendPlan::Steer { turn_id, .. } => {
                            assert_eq!(Some(&turn_id), running.as_ref(), "run {run}");
                            // Steered into the running turn: it does not start one.
                        }
                        SendPlan::Held | SendPlan::Interrupt { .. } => accepted.push(text),
                        SendPlan::Reject(reason) => assert_eq!(reason, RejectReason::Busy),
                    }
                }
                3 if asked && running.is_none() => {
                    turns += 1;
                    let id = format!("turn-{turns}");
                    thread.started(&id);
                    started(&mut thread, &id);
                    running = Some(id);
                    asked = false;
                }
                4 if running.is_some() => {
                    let id = running.take().unwrap();
                    if let Some(request) = completed(&mut thread, &id).next {
                        assert!(!asked);
                        asked = true;
                        started_texts.push(request.input[0]["text"].as_str().unwrap().into());
                    }
                }
                _ => {}
            }
            assert_eq!(thread.working(), running.is_some() || asked, "run {run}");
        }
        // Let every held prompt run.
        loop {
            if asked {
                turns += 1;
                let id = format!("turn-{turns}");
                started(&mut thread, &id);
                running = Some(id);
                asked = false;
            }
            let Some(id) = running.take() else { break };
            if let Some(request) = completed(&mut thread, &id).next {
                asked = true;
                started_texts.push(request.input[0]["text"].as_str().unwrap().into());
            }
        }
        let mut sorted_started = started_texts.clone();
        sorted_started.sort();
        let mut sorted_accepted = accepted.clone();
        sorted_accepted.sort();
        assert_eq!(sorted_started, sorted_accepted, "run {run}: each accepted prompt starts once");
    }
}
