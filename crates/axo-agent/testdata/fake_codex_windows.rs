// Deterministic app-server fixture. No model calls, sign-in or shell commands.
// Its native rollout is written only inside the test-owned Session folder.
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};

thread_local! {
    static SOURCE: std::cell::RefCell<Option<std::path::PathBuf>> = const { std::cell::RefCell::new(None) };
}
fn native(kind: &str, payload: Value) {
    SOURCE.with_borrow(|source| {
        if let Some(path) = source {
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .unwrap();
            let timestamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis() as u64;
            writeln!(
                file,
                "{}",
                json!({"timestamp":timestamp,"type":kind,"payload":payload})
            )
            .unwrap();
        }
    });
}
fn source(thread: &str) -> std::path::PathBuf {
    let path = std::env::current_dir()
        .unwrap()
        .join(format!("{thread}.jsonl"));
    let fresh = !path.exists();
    SOURCE.with_borrow_mut(|source| *source = Some(path.clone()));
    if fresh {
        native(
            "session_meta",
            json!({"id":thread,"cwd":std::env::current_dir().unwrap()}),
        );
    }
    path
}
fn record(value: &Value) {
    let p = &value["params"];
    if value["method"] == "item/completed" {
        let item = &p["item"];
        let payload = match item["type"].as_str() {
            Some("userMessage") => {
                json!({"type":"message","role":"user","content":item["content"]})
            }
            Some("agentMessage") => {
                json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":item["text"]}]})
            }
            Some("reasoning") => {
                json!({"type":"reasoning","summary":item["summary"].as_array().unwrap().iter().map(|text| json!({"type":"summary_text","text":text})).collect::<Vec<_>>(),"encrypted_content":"OPAQUE_NOT_DISPLAYABLE"})
            }
            Some("commandExecution") => {
                native(
                    "response_item",
                    json!({"type":"function_call","name":"bash","call_id":item["id"],"arguments":json!({"command":item["command"]}).to_string()}),
                );
                json!({"type":"function_call_output","call_id":item["id"],"output":item["aggregatedOutput"]})
            }
            _ => return,
        };
        native("response_item", payload);
    }
}
fn send(value: Value) {
    record(&value);
    println!("{value}");
    io::stdout().flush().unwrap();
}
fn event(method: &str, params: Value) {
    send(json!({"method":method,"params":params}));
}
fn complete(thread: &str, turn: &str, status: &str, text: &str) {
    if !text.is_empty() {
        event(
            "item/agentMessage/delta",
            json!({"threadId":thread,"turnId":turn,"itemId":format!("{turn}-assistant"),"delta":text}),
        );
        event(
            "item/completed",
            json!({"threadId":thread,"turnId":turn,"item":{"type":"agentMessage","id":format!("{turn}-assistant"),"text":text}}),
        );
    }
    event(
        "turn/completed",
        json!({"threadId":thread,"turn":{"id":turn,"status":status,"error":null}}),
    );
}
fn main() {
    if std::env::args().any(|arg| arg == "--version") {
        println!("codex-cli 0.170.0");
        return;
    }
    let mut thread = format!("fixture-thread-{}", std::process::id());
    let mut count = 0;
    let mut active = String::new();
    let mut pending = String::new();
    for line in io::stdin().lock().lines() {
        let v: Value = serde_json::from_str(&line.unwrap()).unwrap();
        let id = v["id"].clone();
        let p = &v["params"];
        match v["method"].as_str() {
            Some("initialize") => send(
                json!({"id":id,"result":{"userAgent":"axo-fixture","platformFamily":"windows","platformOs":"windows"}}),
            ),
            Some("initialized") => {}
            Some("thread/start") => {
                send(json!({"id":id,"result":{"thread":{"id":thread,"path":source(&thread)}}}))
            }
            Some("thread/read") => {
                send(json!({"id":id,"result":{"thread":{"id":thread,"path":source(&thread)}}}))
            }
            Some("thread/resume") => {
                if std::path::Path::new("fixture-refuse-resume").is_file() {
                    send(
                        json!({"id":id,"error":{"code":-32602,"message":"Fixture resume refused"}}),
                    );
                    continue;
                }
                thread = p["threadId"].as_str().unwrap().into();
                send(json!({"id":id,"result":{"thread":{"id":thread,"path":source(&thread)}}}));
            }
            Some("model/list") => send(
                json!({"id":id,"result":{"data":[{"id":"fixture","model":"fixture","displayName":"Fixture model","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}],"defaultReasoningEffort":"low","inputModalities":["text","image"],"isDefault":true}],"nextCursor":null}}),
            ),
            Some("turn/steer") => {
                if p["expectedTurnId"] != active {
                    send(json!({"id":id,"error":{"code":-32602,"message":"Stale turn"}}));
                } else {
                    send(json!({"id":id,"result":{"turnId":active}}));
                    complete(
                        &thread,
                        &active,
                        "completed",
                        &format!("Steered: {}", p["input"][0]["text"].as_str().unwrap_or("")),
                    );
                }
            }
            Some("turn/start") => {
                count += 1;
                active = format!("turn-{}-{count}", std::process::id());
                let text = p["input"][0]["text"].as_str().unwrap_or_default();
                if text == "reject-start" {
                    send(
                        json!({"id":id,"error":{"code":-32602,"message":"Fixture start refused"}}),
                    );
                    continue;
                }
                event(
                    "turn/started",
                    json!({"threadId":thread,"turn":{"id":active,"status":"inProgress"}}),
                );
                event(
                    "item/completed",
                    json!({"threadId":thread,"turnId":active,"item":{"type":"userMessage","id":format!("{active}-user"),"content":[{"type":"text","text":text}]}}),
                );
                send(json!({"id":id,"result":{"turn":{"id":active,"status":"inProgress"}}}));
                match text {
                    "rich-transcript" => {
                        assert_eq!(
                            p["summary"], "auto",
                            "the host must request public reasoning summaries"
                        );
                        event(
                            "item/completed",
                            json!({"threadId":thread,"turnId":active,"item":{"type":"reasoning","id":format!("{active}-reasoning"),"summary":["Checking the owned fixture before editing."]}}),
                        );
                        event(
                            "item/completed",
                            json!({"threadId":thread,"turnId":active,"item":{"type":"commandExecution","id":format!("{active}-tool"),"command":"fixture --no-execution","aggregatedOutput":"RICH_TOOL_OUTPUT","status":"completed","exitCode":0}}),
                        );
                        complete(&thread, &active, "completed", "Rich transcript complete");
                    }
                    "stream-reconciliation" => {
                        let item = format!("{active}-assistant");
                        event(
                            "item/agentMessage/delta",
                            json!({"threadId":thread,"turnId":active,"itemId":item,"delta":"Stream fixture: partial"}),
                        );
                        std::thread::sleep(std::time::Duration::from_millis(1100));
                        event(
                            "item/agentMessage/delta",
                            json!({"threadId":thread,"turnId":active,"itemId":item,"delta":" and complete"}),
                        );
                        event(
                            "item/completed",
                            json!({"threadId":thread,"turnId":active,"item":{"type":"agentMessage","id":item,"text":"Stream fixture: partial and complete"}}),
                        );
                        event(
                            "item/agentMessage/delta",
                            json!({"threadId":thread,"turnId":active,"itemId":item,"delta":"LATE_FRAGMENT"}),
                        );
                        event(
                            "turn/completed",
                            json!({"threadId":thread,"turn":{"id":active,"status":"completed","error":null}}),
                        );
                    }
                    "wait" => {}
                    "crash" => std::process::exit(23),
                    "mcp-confirm" | "mcp-form" => {
                        pending = "mcp-permission-1".into();
                        let fields = if text == "mcp-form" {
                            json!({"secret":{"type":"string"}})
                        } else {
                            json!({})
                        };
                        send(
                            json!({"id":pending,"method":"mcpServer/elicitation/request","params":{
                            "threadId":thread,"turnId":active,"serverName":"node_repl","mode":"form",
                            "message":"Allow fixture access?","requestedSchema":{"type":"object","properties":fields},
                            "_meta":{"tool_params_display":{"tool":"owned fixture"}}}}),
                        );
                    }
                    "approval" => {
                        pending = "approval-1".into();
                        send(
                            json!({"id":pending,"method":"item/commandExecution/requestApproval","params":{"threadId":thread,"turnId":active,"itemId":"command-1","command":"fixture --no-execution","reason":"Test approval"}}),
                        );
                    }
                    "flood" => {
                        for i in 0..2300 {
                            event(
                                "item/agentMessage/delta",
                                json!({"threadId":thread,"turnId":active,"itemId":format!("{active}-assistant"),"delta":format!("{i} ")}),
                            );
                        }
                        complete(&thread, &active, "completed", "flood complete");
                    }
                    "inspect-controls" => complete(
                        &thread,
                        &active,
                        "completed",
                        &format!(
                            "Controls: {} / {} / {}",
                            p["model"], p["effort"], p["input"]
                        ),
                    ),
                    "inspect-policy" => complete(
                        &thread,
                        &active,
                        "completed",
                        &format!(
                            "Policy: {} / {}",
                            p["approvalPolicy"], p["sandboxPolicy"]["type"]
                        ),
                    ),
                    _ => complete(&thread, &active, "completed", &format!("Echo: {text}")),
                }
            }
            Some("turn/interrupt") => {
                send(json!({"id":id,"result":{}}));
                complete(&thread, &active, "interrupted", "");
            }
            Some(method) => send(
                json!({"id":id,"error":{"code":-32601,"message":format!("Unsupported fixture method: {method}")}}),
            ),
            None if id == pending => {
                let decision = v["result"]["decision"]
                    .as_str()
                    .or_else(|| v["result"]["action"].as_str())
                    .unwrap_or("cancel");
                event(
                    "serverRequest/resolved",
                    json!({"threadId":thread,"requestId":pending}),
                );
                complete(
                    &thread,
                    &active,
                    "completed",
                    &if pending == "mcp-permission-1" {
                        format!("MCP: {decision} / {}", v["result"]["content"])
                    } else {
                        format!("Approval: {decision}")
                    },
                );
                pending.clear();
            }
            None => {}
        }
    }
}
