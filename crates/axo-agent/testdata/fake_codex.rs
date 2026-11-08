//! Deterministic app-server fixture. No model calls, sign-in, shell commands or external IO.
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};

fn send(value: Value) {
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
            Some("thread/start") => send(json!({"id":id,"result":{"thread":{"id":thread}}})),
            Some("thread/resume") => {
                thread = p["threadId"].as_str().unwrap().into();
                send(json!({"id":id,"result":{"thread":{"id":thread}}}));
            }
            Some("turn/start") => {
                count += 1;
                active = format!("turn-{}-{count}", std::process::id());
                let text = p["input"][0]["text"].as_str().unwrap_or_default();
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
                    "wait" => {}
                    "crash" => std::process::exit(23),
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
                let decision = v["result"]["decision"].as_str().unwrap_or("cancel");
                event(
                    "serverRequest/resolved",
                    json!({"threadId":thread,"requestId":pending}),
                );
                complete(
                    &thread,
                    &active,
                    "completed",
                    &format!("Approval: {decision}"),
                );
                pending.clear();
            }
            None => {}
        }
    }
}
