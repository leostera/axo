use super::*;

const ID: &str = "5d0c4c4e-1d2b-4c8e-9f60-0a1b2c3d4e5f";

fn hook(name: &str, fields: Value) -> Value {
    let mut hook = json!({
        "session_id": ID,
        "transcript_path": "/Users/x/.claude/projects/-tmp/5d0c.jsonl",
        "cwd": "/tmp",
        "hook_event_name": name,
    });
    for (key, value) in fields.as_object().unwrap() {
        hook[key] = value.clone();
    }
    hook
}

fn names(observed: &Observed) -> Vec<&'static str> {
    observed.events.iter().map(|event| event.name).collect()
}

#[test]
fn a_prompt_is_typed_when_idle_held_as_a_follow_up_and_refused_otherwise() {
    let mut session = Session::new(ID.into(), false);
    assert_eq!(session.plan_send("one".into(), None), SendPlan::Type("one".into()));
    assert!(session.working(), "working from the moment it is typed");
    assert_eq!(session.plan_send("two".into(), None), SendPlan::Reject(RejectReason::Busy));
    assert_eq!(
        session.plan_send("two".into(), Some(QueuedDelivery::Steer)),
        SendPlan::Reject(RejectReason::Unavailable)
    );
    assert_eq!(
        session.plan_send("two".into(), Some(QueuedDelivery::Interrupt)),
        SendPlan::Reject(RejectReason::Unavailable)
    );
    assert_eq!(session.plan_send("two".into(), Some(QueuedDelivery::FollowUp)), SendPlan::Held);
    let stopped = session.observe(&hook("Stop", json!({ "last_assistant_message": "done" })));
    assert_eq!(names(&stopped), ["message.start", "message.end", "agent.settled"]);
    assert_eq!(stopped.next.as_deref(), Some("two"));
    assert!(session.working(), "the held prompt is typed next");
}

#[test]
fn a_turn_reads_as_pi_reports_one() {
    let mut session = Session::new(ID.into(), false);
    let start = session.observe(&hook("SessionStart", json!({ "source": "startup", "model": "claude-opus-5" })));
    assert_eq!(names(&start), ["pi.state"]);
    assert_eq!(start.transcript, Some(PathBuf::from("/Users/x/.claude/projects/-tmp/5d0c.jsonl")));
    let submitted = session.observe(&hook("UserPromptSubmit", json!({ "prompt": "hi" })));
    assert_eq!(names(&submitted), ["agent.start", "message.start", "message.end"]);
    assert_eq!(submitted.events[2].data["message"]["content"][0]["text"], "hi");
    let asked = session.observe(&hook("PermissionRequest", json!({ "tool_name": "Bash" })));
    assert_eq!(names(&asked), ["ui.prompt.start"]);
    let pre = session.observe(&hook("PreToolUse", json!({ "tool_name": "Bash", "tool_use_id": "t1", "tool_input": { "command": "ls" } })));
    assert_eq!(pre.events[0].data["args"]["command"], "ls");
    let post = session.observe(&hook("PostToolUse", json!({ "tool_name": "Bash", "tool_use_id": "t1", "tool_response": { "stdout": "a" } })));
    assert_eq!(names(&post), ["ui.prompt.end", "tool.end"]);
    let failed = session.observe(&hook("PostToolUseFailure", json!({ "tool_name": "Bash", "tool_use_id": "t2", "error": "Exit code 1" })));
    assert_eq!(failed.events[0].data["isError"], true);
    assert_eq!(failed.events[0].data["result"]["content"][0]["text"], "Exit code 1");
    let stop = session.observe(&hook("Stop", json!({ "last_assistant_message": "Done." })));
    assert_eq!(names(&stop), ["message.start", "message.end", "agent.settled"]);
    assert!(!session.working());
}

#[test]
fn escape_settles_the_turn_since_claude_says_nothing_of_it() {
    let mut session = Session::new(ID.into(), false);
    assert_eq!(session.plan_stop().0, StopPlan::Idle);
    session.observe(&hook("UserPromptSubmit", json!({ "prompt": "long" })));
    session.observe(&hook("PermissionRequest", json!({})));
    let (plan, observed) = session.plan_stop();
    assert_eq!(plan, StopPlan::Escape);
    assert_eq!(names(&observed), ["ui.prompt.end", "agent.settled"]);
    assert!(!session.working());
    // A turn interrupted in the TUI is noticed when Claude says it has been idle.
    session.observe(&hook("UserPromptSubmit", json!({ "prompt": "again" })));
    let idle = session.observe(&hook("Notification", json!({ "notification_type": "idle_prompt" })));
    assert_eq!(names(&idle), ["agent.settled"]);
}

#[test]
fn other_conversations_and_subagents_change_nothing() {
    let mut session = Session::new(ID.into(), false);
    let mut other = hook("UserPromptSubmit", json!({ "prompt": "x" }));
    other["session_id"] = json!("someone-else");
    assert_eq!(session.observe(&other), Observed::default());
    let subagent = hook("Stop", json!({ "agent_id": "a1" }));
    assert_eq!(session.observe(&subagent), Observed::default());
    assert!(!session.working());
}

/// Generated hook sequences: activity starts and settles in pairs, waits balance, and nothing
/// panics on whatever a hook carries.
#[test]
fn generated_hook_sequences_keep_activity_and_waits_balanced() {
    let mut seed = 0x9e37_79b9_7f4a_7c15_u64;
    let mut next = move |bound: u64| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed % bound
    };
    let kinds = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "Bogus",
    ];
    let notifications = ["elicitation_dialog", "elicitation_complete", "idle_prompt", "permission_prompt"];
    for _ in 0..1_000 {
        let mut session = Session::new(ID.into(), false);
        let (mut working, mut waits) = (false, 0_i64);
        for _ in 0..60 {
            let observed = match next(4) {
                0 => {
                    let (_, observed) = session.plan_stop();
                    observed
                }
                1 => {
                    let delivery = [None, Some(QueuedDelivery::FollowUp)][next(2) as usize];
                    if let SendPlan::Type(_) = session.plan_send("p".into(), delivery) {
                        session.observe(&hook("UserPromptSubmit", json!({ "prompt": "p" })))
                    } else {
                        Observed::default()
                    }
                }
                _ => {
                    let kind = kinds[next(kinds.len() as u64) as usize];
                    let note = notifications[next(notifications.len() as u64) as usize];
                    session.observe(&hook(kind, json!({ "notification_type": note, "prompt": 3, "tool_response": [1] })))
                }
            };
            for event in &observed.events {
                match event.name {
                    "agent.start" => working = true,
                    "agent.settled" => working = false,
                    "ui.prompt.start" => waits += 1,
                    "ui.prompt.end" => waits -= 1,
                    _ => {}
                }
            }
            assert!((0..=2).contains(&waits), "waits {waits}");
            if !session.working() {
                assert!(!working, "a settled session reported no end");
            }
        }
    }
}

#[test]
fn in_a_folder_claude_does_not_trust_prompts_wait_for_the_person_and_go_once_it_does() {
    let mut session = Session::new(ID.into(), true);
    let waiting: Vec<&str> = session.snapshot().iter().map(|event| event.name).collect();
    assert_eq!(waiting, ["activity.snapshot", "ui.prompt.start"]);
    assert_eq!(session.snapshot()[1].data["kind"], "trust");
    // Typed now, a prompt would answer Claude's question, whose choice is "No, exit".
    assert_eq!(session.plan_send("one".into(), None), SendPlan::Held);
    assert_eq!(session.plan_send("two".into(), Some(QueuedDelivery::FollowUp)), SendPlan::Held);
    assert_eq!(
        session.plan_send("now".into(), Some(QueuedDelivery::Steer)),
        SendPlan::Reject(RejectReason::Unavailable)
    );
    assert!(!session.working());
    let trusted = session.trusted();
    assert_eq!(names(&trusted), ["ui.prompt.end"]);
    assert_eq!(trusted.next.as_deref(), Some("one"));
    assert!(session.working(), "the first held prompt is typed");
    assert_eq!(session.trusted(), Observed::default(), "trusted once");
    let stopped = session.observe(&hook("Stop", json!({ "last_assistant_message": "done" })));
    assert_eq!(stopped.next.as_deref(), Some("two"), "the rest follow turn by turn");
}

#[test]
fn a_hook_while_untrusted_means_the_person_trusted_the_folder_in_the_terminal() {
    let mut session = Session::new(ID.into(), true);
    assert_eq!(session.plan_send("held".into(), None), SendPlan::Held);
    let started = session.observe(&hook("SessionStart", json!({ "source": "startup" })));
    assert_eq!(names(&started)[0], "ui.prompt.end");
    assert_eq!(started.next.as_deref(), Some("held"), "Claude is idle: the held prompt goes");
    assert!(!session.untrusted());

    // The person typed a prompt of their own: the held one waits for its turn.
    let mut session = Session::new(ID.into(), true);
    assert_eq!(session.plan_send("held".into(), None), SendPlan::Held);
    let submitted = session.observe(&hook("UserPromptSubmit", json!({ "prompt": "mine" })));
    assert_eq!(names(&submitted)[..2], ["ui.prompt.end", "agent.start"]);
    assert_eq!(submitted.next, None);
    let stopped = session.observe(&hook("Stop", json!({ "last_assistant_message": "ok" })));
    assert_eq!(stopped.next.as_deref(), Some("held"));
}

#[test]
fn the_trust_question_is_recognised_only_while_it_is_on_the_screen() {
    let asking = "Accessing workspace:\n\n /tmp/x\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm";
    assert!(asks_for_trust(asking, 40));
    assert!(asks_for_trust("Do you trust the files in this folder?", 40));
    assert!(!asks_for_trust("❯ \n  ? for shortcuts", 40));
    let scrolled = format!("{asking}\n{}", "line\n".repeat(50));
    assert!(!asks_for_trust(&scrolled, 40), "what scrolled away is no longer asked");
}
