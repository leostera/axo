use super::*;

const SESSION: &str = "ses_e73a7ea43ffepr6zTFga6PRFtL";

fn command(n: u8) -> CommandId {
    CommandId::try_from(format!("6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a{n:02x}")).unwrap()
}

fn event(kind: &str, data: Value) -> Value {
    let mut data = data;
    if data.get("sessionID").is_none() && !kind.starts_with("form.created") {
        data["sessionID"] = json!(SESSION);
    }
    json!({ "id": "evt_1", "type": kind, "created": 1, "data": data })
}

fn names(events: &[Emitted]) -> Vec<&'static str> {
    events.iter().map(|event| event.name).collect()
}

#[test]
fn an_idle_session_takes_a_prompt_and_a_working_one_needs_a_delivery() {
    let mut session = Session::new(SESSION.into(), false);
    assert_eq!(session.plan_send(None, None), SendPlan::Prompt { delivery: None });
    session.observe(&event("session.execution.started", json!({})));
    assert_eq!(session.plan_send(None, None), SendPlan::Reject(RejectReason::Busy));
    assert_eq!(
        session.plan_send(Some(QueuedDelivery::Steer), None),
        SendPlan::Prompt { delivery: Some("steer") }
    );
    assert_eq!(
        session.plan_send(Some(QueuedDelivery::FollowUp), None),
        SendPlan::Prompt { delivery: Some("queue") }
    );
    assert_eq!(
        session.plan_send(Some(QueuedDelivery::Interrupt), None),
        SendPlan::InterruptThenPrompt
    );
}

#[test]
fn a_stop_never_ends_newer_work_than_the_prompt_it_names() {
    let mut session = Session::new(SESSION.into(), false);
    let stop = |n| StopTarget::new(None, None, vec![command(n)]).unwrap();
    assert_eq!(session.plan_stop(&stop(1)), StopPlan::Idle);
    session.plan_send(None, Some(&command(1)));
    session.observe(&event("session.execution.started", json!({})));
    assert_eq!(session.plan_stop(&stop(1)), StopPlan::Interrupt);
    session.observe(&event("session.execution.succeeded", json!({})));
    // The person starts another in the TUI: prompt 1's execution is over.
    session.observe(&event("session.execution.started", json!({})));
    assert_eq!(session.plan_stop(&stop(1)), StopPlan::Idle);
    // A stop that names nothing axod sent is for what runs.
    assert_eq!(session.plan_stop(&stop(9)), StopPlan::Interrupt);
    session.plan_send(Some(QueuedDelivery::Steer), Some(&command(2)));
    assert_eq!(session.plan_stop(&stop(2)), StopPlan::Interrupt);
}

#[test]
fn an_execution_reads_as_pi_reports_a_turn() {
    let mut session = Session::new(SESSION.into(), false);
    let mut seen = Vec::new();
    for (kind, data) in [
        ("session.execution.started", json!({})),
        ("session.inbox.enqueued", json!({ "inboxID": "msg_1", "item": { "type": "user", "payload": { "text": "hi" }, "delivery": "queue" } })),
        ("session.text.started", json!({ "assistantMessageID": "msg_2", "ordinal": 0 })),
        ("session.text.delta", json!({ "assistantMessageID": "msg_2", "ordinal": 0, "delta": "Hel" })),
        ("session.text.delta", json!({ "assistantMessageID": "msg_2", "ordinal": 0, "delta": "lo" })),
        ("session.text.ended", json!({ "assistantMessageID": "msg_2", "ordinal": 0, "text": "Hello" })),
        ("session.tool.input.started", json!({ "assistantMessageID": "msg_2", "id": "call_1", "name": "read" })),
        ("session.tool.called", json!({ "assistantMessageID": "msg_2", "id": "call_1", "input": { "path": "README.md" }, "executed": true })),
        ("session.tool.failed", json!({ "assistantMessageID": "msg_2", "id": "call_1", "error": { "type": "x", "message": "no such file" }, "executed": true })),
        ("session.execution.succeeded", json!({})),
    ] {
        seen.extend(session.observe(&event(kind, data)));
    }
    assert_eq!(
        names(&seen),
        ["agent.start", "message.start", "message.end", "message.start", "message.update", "message.update", "message.end", "tool.start", "tool.end", "agent.settled"]
    );
    assert_eq!(seen[1].data["message"]["content"][0]["text"], "hi");
    assert_eq!(seen[5].data["message"]["content"][0]["text"], "Hello");
    assert_eq!(seen[7].data["toolName"], "read");
    assert_eq!(seen[8].data["isError"], true);
    assert_eq!(seen[8].data["result"]["content"][0]["text"], "no such file");
    assert!(!session.working());
}

#[test]
fn approvals_and_questions_are_one_wait_each_and_end_with_the_execution() {
    let mut session = Session::new(SESSION.into(), true);
    let asked = session.observe(&event("permission.asked", json!({ "id": "per_1", "action": "bash", "resources": [] })));
    assert_eq!(names(&asked), ["ui.prompt.start"]);
    assert!(session.observe(&event("permission.asked", json!({ "id": "per_2", "action": "bash", "resources": [] }))).is_empty());
    assert!(session.observe(&event("permission.replied", json!({ "requestID": "per_1", "reply": "once" }))).is_empty());
    assert_eq!(names(&session.observe(&event("permission.replied", json!({ "requestID": "per_2", "reply": "once" })))), ["ui.prompt.end"]);
    let form = session.observe(&json!({ "type": "form.created", "data": { "form": { "id": "frm_1", "sessionID": SESSION } } }));
    assert_eq!(form[0].data["kind"], "question");
    assert_eq!(
        names(&session.observe(&event("session.execution.interrupted", json!({ "reason": "user" })))),
        ["ui.prompt.end", "agent.settled"]
    );
}

#[test]
fn another_sessions_events_change_nothing() {
    let mut session = Session::new(SESSION.into(), false);
    assert!(session.observe(&event("session.execution.started", json!({ "sessionID": "ses_other" }))).is_empty());
    assert!(session.observe(&json!({ "type": "form.created", "data": { "form": { "id": "f", "sessionID": "ses_other" } } })).is_empty());
    assert!(!session.working());
}

#[test]
fn renames_and_models_are_reported() {
    let mut session = Session::new(SESSION.into(), false);
    let renamed = session.observe(&event("session.renamed", json!({ "title": "probe" })));
    assert_eq!(renamed[0].data, json!({ "name": "probe" }));
    let model = session.observe(&event("session.model.selected", json!({ "model": { "id": "mock-1", "providerID": "mock" } })));
    assert_eq!(model[0].data["model"]["id"], "mock-1");
    assert_eq!(session.snapshot().len(), 2);
    let models = models_event(&json!({ "data": [{ "id": "mock-1", "modelID": "mock-1", "providerID": "mock", "name": "Mock" }] }));
    assert_eq!(models.data["models"][0], json!({ "provider": "mock", "id": "mock-1", "name": "Mock", "thinkingLevels": ["off"] }));
}

/// Generated event sequences, with other sessions' events mixed in: the session is working
/// exactly between an execution's start and its end, waits balance, and nothing panics.
#[test]
fn generated_event_sequences_keep_activity_and_waits_balanced() {
    let mut seed = 0x4f1b_bcdc_bc4f_3a91_u64;
    let mut next = move |bound: u64| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed % bound
    };
    let kinds = [
        "session.execution.started", "session.execution.succeeded", "session.execution.failed",
        "session.text.delta", "session.text.ended", "session.tool.called", "session.tool.success",
        "permission.asked", "permission.replied", "form.replied", "session.renamed", "bogus",
    ];
    for _ in 0..1_000 {
        let mut session = Session::new(SESSION.into(), false);
        let mut working = false;
        let mut waits: i64 = 0;
        for _ in 0..60 {
            let kind = kinds[next(kinds.len() as u64) as usize];
            let other = next(5) == 0;
            let id = format!("per_{}", next(3));
            let data = json!({
                "sessionID": if other { "ses_other" } else { SESSION },
                "id": id, "requestID": id, "delta": "x", "text": "t", "title": "n",
                "assistantMessageID": "m", "ordinal": 0,
            });
            let events = session.observe(&json!({ "type": kind, "data": data }));
            for event in &events {
                match event.name {
                    "agent.start" => working = true,
                    "agent.settled" => working = false,
                    "ui.prompt.start" => waits += 1,
                    "ui.prompt.end" => waits -= 1,
                    _ => {}
                }
            }
            assert!((0..=2).contains(&waits), "waits {waits}");
            assert_eq!(session.working(), working);
            if other {
                assert!(events.is_empty());
            }
        }
    }
}
