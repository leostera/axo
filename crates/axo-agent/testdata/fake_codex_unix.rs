// A stand-in for `codex` 0.170.0 in tests: `--version`, `app-server --listen unix://PATH`
// (initialize, thread/start, thread/name/set, thread/resume and model/list, answered as the
// real server answers them, trimmed) and the TUI's `--remote unix://PATH resume THREAD`, which
// only says what it was asked to resume. Its thread's rollout is `fake-rollout.jsonl` in the
// working directory: each turn appends the prompt and an echo of it, then reports the turn as
// started and completed. Every request and the TUI's start are appended to
// `$AXO_FAKE_CODEX_LOG`, or `fake-codex.log` in the working directory (the Session's folder),
// one line each.

use std::io::Write;
use std::os::unix::net::UnixListener;

use serde_json::{Value, json};
use tungstenite::Message;

const THREAD: &str = "01a1eea8-952a-7271-8b55-c2708a01c6ff";

fn log(line: &str) {
    let path = std::env::var_os("AXO_FAKE_CODEX_LOG")
        .map_or_else(|| std::path::PathBuf::from("fake-codex.log"), std::path::PathBuf::from);
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    // One write: the server and the TUI append to the same file.
    file.write_all(format!("{line}\n").as_bytes()).unwrap();
}

fn append(path: &std::path::Path, line: &Value) {
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
    file.write_all(format!("{line}\n").as_bytes()).unwrap();
}

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let mut arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
    // Root config overrides come first, `-c key=value` each.
    while let ["-c", value, ..] = arguments.as_slice() {
        log(&format!("config {value}"));
        arguments.drain(..2);
    }
    match arguments.as_slice() {
        ["--version"] => println!("codex-cli 0.170.0"),
        ["app-server", "--listen", address] => serve(address.strip_prefix("unix://").unwrap()),
        ["--remote", address, "resume", thread] => {
            log(&format!("tui {address} {thread} cwd={}", std::env::current_dir().unwrap().display()));
            println!("resuming {thread}");
            loop {
                std::thread::park();
            }
        }
        other => {
            eprintln!("fake codex: unexpected arguments {other:?}");
            std::process::exit(2);
        }
    }
}

fn serve(path: &str) {
    let listener = UnixListener::bind(path).unwrap();
    log(&format!("listening {path}"));
    for stream in listener.incoming() {
        let stream = stream.unwrap();
        std::thread::spawn(move || {
            let Ok(mut socket) = tungstenite::accept(stream) else { return };
            while let Ok(message) = socket.read() {
                let Message::Text(text) = message else { continue };
                let request: Value = serde_json::from_str(&text).unwrap();
                let method = request["method"].as_str().unwrap_or_default().to_owned();
                log(&format!("request {method} {}", request["params"]));
                let Some(id) = request.get("id") else { continue };
                let rollout = std::env::current_dir().unwrap().join("fake-rollout.jsonl");
                let mut notifications = Vec::new();
                let result = match method.as_str() {
                    "thread/start" | "thread/resume" => {
                        if !rollout.exists() {
                            append(&rollout, &json!({ "timestamp": "2026-11-18T12:00:00.000Z", "type": "session_meta", "payload": {
                                "id": THREAD, "timestamp": "2026-11-18T12:00:00.000Z", "cwd": std::env::current_dir().unwrap(),
                                "originator": "codex_cli_rs", "cli_version": "0.170.0", "source": "cli", "model_provider": "openai"
                            } }));
                        }
                        json!({
                            "thread": { "id": request["params"]["threadId"].as_str().unwrap_or(THREAD), "status": { "type": "idle" }, "path": rollout },
                            "model": "gpt-5.1", "modelProvider": "openai", "reasoningEffort": "medium",
                        })
                    }
                    "model/list" => json!({ "data": [], "nextCursor": null }),
                    "turn/start" => {
                        let text = request["params"]["input"][0]["text"].as_str().unwrap_or_default().to_owned();
                        let message = |role: &str, kind: &str, text: &str| json!({ "timestamp": "2026-11-18T12:00:01.000Z", "type": "response_item", "payload": {
                            "type": "message", "role": role, "content": [{ "type": kind, "text": text }]
                        } });
                        append(&rollout, &message("user", "input_text", &text));
                        append(&rollout, &message("assistant", "output_text", &format!("echo: {text}")));
                        let thread = request["params"]["threadId"].clone();
                        let turn = json!({ "id": "turn-1", "status": "completed", "items": [] });
                        notifications.push(json!({ "method": "turn/started", "params": { "threadId": thread, "turn": { "id": "turn-1", "status": "inProgress", "items": [] } } }));
                        notifications.push(json!({ "method": "turn/completed", "params": { "threadId": thread, "turn": turn } }));
                        json!({ "turn": { "id": "turn-1", "status": "inProgress", "items": [] } })
                    }
                    _ => json!({}),
                };
                let answer = json!({ "id": id, "result": result }).to_string();
                if socket.send(Message::Text(answer.into())).is_err() {
                    return;
                }
                for notification in notifications {
                    if socket.send(Message::Text(notification.to_string().into())).is_err() {
                        return;
                    }
                }
            }
        });
    }
}
