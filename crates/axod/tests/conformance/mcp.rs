//! `axod mcp`, the MCP server Pi runs for its Session: every tool it offers, called the way an
//! agent calls it.

#[path = "../support/mod.rs"]
mod support;

use serde_json::{Value, json};
use support::{Axod, Mcp};

/// This file, to check that every offered tool is called in it.
const THIS_FILE: &str = include_str!("mcp.rs");

fn first_session(axod: &Axod) -> (Value, String) {
    let session = axod.wait_for_pi(&axod.sessions()[0]);
    let id = session["id"].as_str().unwrap().to_owned();
    (session, id)
}

#[test]
fn every_tool_axod_mcp_offers_is_called_here() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let tools = mcp.tools();
    assert!(tools.len() >= 17, "{tools:?}");
    // Calls as rustfmt may lay them out: `ok(\n    "name"` reads as `ok("name"`.
    let compact = THIS_FILE
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("( ", "(");
    let uncalled: Vec<&String> = tools
        .iter()
        .filter(|name| {
            let quoted = format!("\"{name}\"");
            !["ok(", "err(", "tool(", "send_tool("]
                .iter()
                .any(|call| compact.contains(&format!("{call}{quoted}")))
        })
        .collect();
    assert!(uncalled.is_empty(), "no test here calls: {uncalled:?}");
}

#[test]
fn an_unknown_session_is_refused_at_startup() {
    let axod = Axod::start();
    let refused = std::process::Command::new(support::axod_binary())
        .arg("mcp")
        .env("AXO_SOCKET", axod.socket())
        .env("AXO_SESSION_ID", "00000000-0000-4000-8000-000000000000")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(!refused.status.success());
}

#[test]
fn an_agent_finds_itself_and_the_sessions_and_workspaces_around_it() {
    let axod = Axod::start();
    let (session, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let me = mcp.ok("whoami", json!({}));
    assert_eq!(me["sessionId"], session["id"]);
    assert_eq!(me["workspaceId"], session["workspaceId"]);
    assert_eq!(
        me["session"]["piSessionFile"], session["piSessionFile"],
        "{me}"
    );

    let catalog = mcp.ok("session_catalog", json!({}));
    assert!(
        catalog["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["id"] == session["id"]),
        "{catalog}"
    );
    let workspaces = mcp.ok("workspace_list", json!({}));
    assert_eq!(
        workspaces["workspaces"].as_array().unwrap().len(),
        1,
        "{workspaces}"
    );
    assert_eq!(mcp.close().code(), Some(0));
}

#[test]
fn an_agent_starts_names_and_prompts_another_session() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let other = mcp.ok("workspace_session_create", json!({ "workspaceId": "self" }));
    let other_id = other["id"].clone();
    assert_ne!(other_id, json!(id));
    mcp.ok(
        "session_rename",
        json!({ "sessionId": other_id, "name": "Helper" }),
    );
    axod.wait_for_pi(&other);
    let prompted = mcp.ok(
        "session_prompt",
        json!({ "sessionId": other_id, "text": "help me" }),
    );
    assert_eq!(prompted["accepted"], true, "{prompted}");
    // An agent's prompt reaches Pi saying which Session sent it.
    axod.wait_for("the prompt to reach the other Pi", || {
        let log = axod.pi_log();
        (log.contains(&format!("SENT:[From Axo Session {id}")) && log.contains("help me"))
            .then_some(())
    });
    let listed = axod
        .sessions()
        .into_iter()
        .find(|s| s["id"] == other_id)
        .unwrap();
    assert_eq!(listed["manualName"], "Helper");

    let empty = mcp.err("session_prompt", json!({ "sessionId": "self", "text": "" }));
    assert!(!empty.is_empty());
}

#[test]
fn an_agent_opens_types_into_reads_and_closes_a_terminal() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let created = mcp.ok("shell_create", json!({ "sessionId": "self" }));
    assert_eq!(created["role"], "terminal", "{created}");
    let shell = created["id"].clone();
    mcp.ok(
        "terminal_write",
        json!({ "sessionId": "self", "shellId": shell, "text": "echo conf-$((40+2))\r" }),
    );
    axod.wait_for("the shell's output", || {
        let screen = mcp.ok(
            "terminal_screen",
            json!({ "sessionId": "self", "shellId": shell, "lines": 50 }),
        );
        screen["text"]
            .as_str()
            .unwrap()
            .contains("conf-42")
            .then_some(())
    });
    mcp.ok(
        "shell_close",
        json!({ "sessionId": "self", "shellId": shell }),
    );
    let session = axod
        .sessions()
        .into_iter()
        .find(|s| s["id"] == json!(id))
        .unwrap();
    assert!(
        session["shells"]
            .as_array()
            .unwrap()
            .iter()
            .all(|p| p["id"] != shell),
        "{session}"
    );
    let gone = mcp.err(
        "terminal_screen",
        json!({ "sessionId": "self", "shellId": shell }),
    );
    assert!(!gone.is_empty());
}

#[test]
fn without_an_account_the_connections_tools_say_so() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    for message in [
        mcp.err("connections_list", json!({})),
        mcp.err("connections_search", json!({ "query": "linear issues" })),
        mcp.err("connections_execute", json!({ "code": "async () => 1" })),
        mcp.err(
            "connections_add",
            json!({ "name": "linear", "url": "https://mcp.linear.app/mcp" }),
        ),
        mcp.err("connections_remove", json!({ "name": "linear" })),
        mcp.err("connections_log", json!({})),
    ] {
        assert!(
            message.to_lowercase().contains("account") || message.contains("link"),
            "{message}"
        );
    }
}

#[test]
fn an_agents_question_reaches_the_person_and_tool_calls_run_while_it_waits() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let _asking = mcp.send_tool("elicitation_request", json!({ "message": "Ship it?" }));
    let question = axod.wait_for("the question", || {
        axod.ok("axo.elicitation.list", json!({}))["elicitations"]
            .as_array()
            .unwrap()
            .first()
            .cloned()
    });
    assert_eq!(question["askedBy"], "agent");
    assert_eq!(question["sessionId"], json!(id));
    // While it waits, the agent's other calls still run.
    assert_eq!(mcp.ok("whoami", json!({}))["sessionId"], json!(id));
}

#[test]
fn computer_use_lists_its_tools_and_refuses_what_it_does_not_know() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let listed = mcp.tool(
        "computer_tools",
        json!({ "names": ["get_window_state", "request_input"] }),
    );
    assert_ne!(listed["isError"], true, "{listed}");
    let text = listed.to_string();
    assert!(
        text.contains("get_window_state") && text.contains("request_input"),
        "{text:.400}"
    );

    let unknown = mcp.err("computer", json!({ "tool": "format_disk" }));
    assert!(unknown.contains("not a computer tool"), "{unknown}");
    let extra = mcp.err("computer", json!({ "tool": "list_apps", "approved": true }));
    assert!(extra.contains("Nothing you pass can approve"), "{extra}");
    let confirm = mcp.err("computer", json!({ "tool": "list_apps", "confirm": "yes" }));
    assert!(
        confirm.contains("confirm must be true or false"),
        "{confirm}"
    );
}

#[test]
fn computer_use_asks_the_person_as_axo_when_the_agent_asks_it_to_confirm() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let _asking = mcp.send_tool("computer", json!({ "tool": "list_apps", "confirm": true }));
    let question = axod.wait_for("the gate's question", || {
        axod.ok("axo.elicitation.list", json!({}))["elicitations"]
            .as_array()
            .unwrap()
            .first()
            .cloned()
    });
    // Asked by the tool itself, which only axod's own `axod mcp` may do.
    assert_eq!(question["askedBy"], "computerUse", "{question}");
}

/// `request_input` reads the window before it asks, so a test without a real form sees its
/// refusals; `//packages/axo-api-worker:input-live` fills a real one.
#[test]
fn request_input_refuses_what_it_cannot_fill_without_asking() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut mcp = Mcp::start(&axod, &id);
    let shape = mcp.err(
        "computer",
        json!({ "tool": "request_input", "args": { "pid": 1 } }),
    );
    assert!(shape.contains("request_input takes"), "{shape}");
    let none = mcp.err(
        "computer",
        json!({ "tool": "request_input", "args": { "pid": 1, "window_id": 1, "fields": [] } }),
    );
    assert!(none.contains("1 to 8 fields"), "{none}");
    let nine = vec![json!({ "kind": "text" }); 9];
    let many = mcp.err(
        "computer",
        json!({ "tool": "request_input", "args": { "pid": 1, "window_id": 1, "fields": nine } }),
    );
    assert!(many.contains("1 to 8 fields"), "{many}");
    let no_window = mcp.err(
        "computer",
        json!({ "tool": "request_input", "args": { "pid": 999_999, "window_id": 1, "fields": [{ "kind": "password" }] } }),
    );
    assert!(!no_window.is_empty());
    assert!(
        axod.ok("axo.elicitation.list", json!({}))["elicitations"]
            .as_array()
            .unwrap()
            .is_empty(),
        "nobody was asked"
    );
}

fn waiting_questions(axod: &Axod) -> Vec<Value> {
    axod.ok("axo.elicitation.list", json!({}))["elicitations"]
        .as_array()
        .unwrap()
        .clone()
}

/// RFD0034: when Pi leaves, `axod mcp` gives up its calls, and axod withdraws their questions
/// from every device, at once rather than five minutes on.
#[test]
fn an_agent_that_leaves_withdraws_its_questions() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut events = axod.subscribe(json!({ "includeTerminalOutput": false }));
    let mut mcp = Mcp::start(&axod, &id);
    mcp.send_tool("elicitation_request", json!({ "message": "Still there?" }));
    let asked = events.wait_for_type("elicitation.requested");
    let started = std::time::Instant::now();
    assert!(mcp.close().success());
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "axod mcp lingered {:?}",
        started.elapsed()
    );
    let resolved = events.wait_for_type("elicitation.resolved");
    assert_eq!(resolved["id"], asked["elicitation"]["id"]);
    assert_eq!(resolved["action"], "cancel");
    assert!(waiting_questions(&axod).is_empty());
}

/// RFD0034: an MCP client that cancels a call withdraws its question; the agent goes on.
#[test]
fn cancelling_a_call_withdraws_its_question() {
    let axod = Axod::start();
    let (_, id) = first_session(&axod);
    let mut events = axod.subscribe(json!({ "includeTerminalOutput": false }));
    let mut mcp = Mcp::start(&axod, &id);
    let call = mcp.send_tool("elicitation_request", json!({ "message": "Deploy?" }));
    events.wait_for_type("elicitation.requested");
    mcp.notify(
        "notifications/cancelled",
        json!({ "requestId": call, "reason": "the user stopped it" }),
    );
    let resolved = events.wait_for_type("elicitation.resolved");
    assert_eq!(resolved["action"], "cancel");
    assert!(waiting_questions(&axod).is_empty());
    assert_eq!(
        mcp.ok("whoami", json!({}))["sessionId"],
        json!(id),
        "the agent goes on"
    );
}
