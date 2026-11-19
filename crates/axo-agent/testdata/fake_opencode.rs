//! A stand-in for `opencode` 2.0.20 in tests: `--version`, `serve --hostname 127.0.0.1` (a
//! small v2 HTTP API on a loopback port, with basic authentication and an event stream), and
//! the TUI (`--server URL --session ID`), which logs its arguments and waits for its PTY to
//! close. A prompt is answered with `echo: <text>`; the prompt `hang` runs until interrupted.
//!
//! Sessions persist across restarts in `fake-opencode-sessions.json` in its working directory,
//! as OpenCode keeps them in its database. While `fake-opencode-hold` exists there, `serve` waits
//! before it listens.
//!
//! It logs what it is asked to `$AXO_FAKE_OPENCODE_LOG`, or `fake-opencode.log` in its working
//! directory, one line per write.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

fn log(line: &str) {
    let path = std::env::var("AXO_FAKE_OPENCODE_LOG").unwrap_or_else(|_| "fake-opencode.log".into());
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = file.write_all(format!("{line}\n").as_bytes());
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("--version") => println!("2.0.20"),
        Some("serve") => serve(),
        _ => tui(&args),
    }
}

fn tui(args: &[String]) {
    log(&format!("tui {}", args.join(" ")));
    log(&format!("tui password={}", std::env::var("OPENCODE_PASSWORD").is_ok()));
    let mut sink = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut sink);
}

#[derive(Default)]
struct Session {
    title: String,
    directory: String,
    model: Value,
    /// `(role, text)`.
    messages: Vec<(String, String)>,
}

#[derive(Default)]
struct State {
    sessions: HashMap<String, Session>,
    active: Option<String>,
    subscribers: Vec<TcpStream>,
    next: u64,
}

type Shared = Arc<Mutex<State>>;

fn serve() {
    let password = std::env::var("OPENCODE_SERVER_PASSWORD").unwrap_or_default();
    if let Ok(config) = std::env::var("OPENCODE_CONFIG_CONTENT") {
        log(&format!("config {config}"));
    }
    log(&format!("serve cwd={}", std::env::current_dir().unwrap().display()));
    // OpenCode starts its MCP servers before it listens; a test holds it here with this file.
    while std::path::Path::new("fake-opencode-hold").exists() {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    println!("some startup noise");
    println!("server listening on http://127.0.0.1:{port}");
    let _ = std::io::stdout().flush();
    let expected = format!("Basic {}", base64(&format!("opencode:{password}")));
    let state: Shared = Arc::new(Mutex::new(State { sessions: load(), ..State::default() }));
    for stream in listener.incoming().flatten() {
        let state = Arc::clone(&state);
        let expected = expected.clone();
        std::thread::spawn(move || {
            let _ = handle(stream, &state, &expected);
        });
    }
}

fn handle(stream: TcpStream, state: &Shared, expected: &str) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut first = String::new();
    reader.read_line(&mut first)?;
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or_default().to_owned();
    let target = parts.next().unwrap_or_default().to_owned();
    let mut length = 0;
    let mut authorized = false;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            match name.to_ascii_lowercase().as_str() {
                "content-length" => length = value.trim().parse().unwrap_or(0),
                "authorization" => authorized = value.trim() == expected,
                _ => {}
            }
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let path = target.split('?').next().unwrap_or_default().to_owned();
    log(&format!("request {method} {path}"));
    let mut stream = stream;
    if !authorized {
        return respond(&mut stream, 401, &json!({ "error": "unauthorized" }));
    }
    let segments: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    match (method.as_str(), segments.as_slice()) {
        ("GET", ["api", "info"]) => respond(&mut stream, 200, &json!({ "version": "2.0.20" })),
        ("GET", ["api", "event"]) => {
            stream.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
            )?;
            stream.write_all(b": heartbeat\n\ndata: {\"id\":\"evt_0\",\"type\":\"server.connected\",\"data\":{}}\n\n")?;
            stream.flush()?;
            state.lock().unwrap().subscribers.push(stream);
            Ok(())
        }
        ("POST", ["api", "session"]) => {
            let mut state = state.lock().unwrap();
            let id = format!("ses_fake{:04}", state.sessions.len() + 1);
            let session = Session {
                title: body["title"].as_str().unwrap_or("untitled").to_owned(),
                directory: body["location"]["directory"].as_str().unwrap_or_default().to_owned(),
                model: json!({ "id": "mock-1", "providerID": "mock" }),
                messages: Vec::new(),
            };
            log(&format!("created {id} title={} directory={}", session.title, session.directory));
            let info = info(&id, &session);
            state.sessions.insert(id, session);
            save(&state);
            drop(state);
            respond(&mut stream, 200, &json!({ "data": info }))
        }
        ("GET", ["api", "session", "active"]) => {
            let state = state.lock().unwrap();
            let mut data = serde_json::Map::new();
            if let Some(id) = &state.active {
                data.insert(id.clone(), json!({ "type": "running" }));
            }
            drop(state);
            respond(&mut stream, 200, &json!({ "data": data }))
        }
        ("GET", ["api", "session", id]) => {
            let state = state.lock().unwrap();
            match state.sessions.get(*id) {
                Some(session) => {
                    let info = info(id, session);
                    drop(state);
                    respond(&mut stream, 200, &json!({ "data": info }))
                }
                None => {
                    drop(state);
                    respond(&mut stream, 404, &json!({ "error": "not found" }))
                }
            }
        }
        ("POST", ["api", "session", id, "prompt"]) => {
            let id = (*id).to_owned();
            let text = body["text"].as_str().unwrap_or_default().to_owned();
            log(&format!("prompt {id} delivery={} text={text}", body["delivery"].as_str().unwrap_or("none")));
            if !state.lock().unwrap().sessions.contains_key(&id) {
                return respond(&mut stream, 404, &json!({ "error": "not found" }));
            }
            respond(&mut stream, 200, &json!({ "data": { "id": "msg_1", "sessionID": id } }))?;
            run(state, &id, &text);
            Ok(())
        }
        ("POST", ["api", "session", id, "interrupt"]) => {
            let mut locked = state.lock().unwrap();
            let interrupted = locked.active.as_deref() == Some(*id);
            if interrupted {
                locked.active = None;
                publish(&mut locked, "session.execution.interrupted", id, json!({ "reason": "user" }));
            }
            drop(locked);
            log(&format!("interrupt {id} interrupted={interrupted}"));
            respond(&mut stream, 200, &json!({ "interrupted": interrupted }))
        }
        ("POST", ["api", "session", id, "model"]) => {
            let mut locked = state.lock().unwrap();
            if let Some(session) = locked.sessions.get_mut(*id) {
                session.model = body["model"].clone();
            }
            save(&locked);
            publish(&mut locked, "session.model.selected", id, json!({ "model": body["model"] }));
            drop(locked);
            log(&format!("model {id} {}", body["model"]));
            respond(&mut stream, 200, &json!({}))
        }
        ("GET", ["api", "model"]) => respond(
            &mut stream,
            200,
            &json!({ "location": { "directory": "/" }, "data": [
                { "id": "mock-1", "modelID": "mock-1", "providerID": "mock", "name": "Mock One" },
            ] }),
        ),
        ("GET", ["api", "experimental", "session", id, "export"]) => {
            let state = state.lock().unwrap();
            let Some(session) = state.sessions.get(*id) else {
                drop(state);
                return respond(&mut stream, 404, &json!({ "error": "not found" }));
            };
            let export = export(id, session);
            drop(state);
            respond(&mut stream, 200, &json!({ "data": export }))
        }
        _ => respond(&mut stream, 404, &json!({ "error": "no such route" })),
    }
}

/// One execution: the prompt goes in, `echo: <text>` comes out; `hang` waits for an interrupt.
fn run(state: &Shared, id: &str, text: &str) {
    let mut locked = state.lock().unwrap();
    locked.active = Some(id.to_owned());
    publish(&mut locked, "session.execution.started", id, json!({}));
    publish(
        &mut locked,
        "session.inbox.enqueued",
        id,
        json!({ "inboxID": "msg_1", "item": { "type": "user", "payload": { "text": text }, "delivery": "queue" } }),
    );
    if let Some(session) = locked.sessions.get_mut(id) {
        session.messages.push(("user".into(), text.to_owned()));
    }
    if text == "hang" {
        save(&locked);
        return;
    }
    let answer = format!("echo: {text}");
    let part = json!({ "assistantMessageID": "msg_2", "ordinal": 0 });
    publish(&mut locked, "session.text.started", id, part.clone());
    for delta in ["echo: ", text] {
        let mut data = part.clone();
        data["delta"] = json!(delta);
        publish(&mut locked, "session.text.delta", id, data);
    }
    let mut ended = part;
    ended["text"] = json!(answer);
    publish(&mut locked, "session.text.ended", id, ended);
    if let Some(session) = locked.sessions.get_mut(id) {
        session.messages.push(("assistant".into(), answer));
    }
    locked.active = None;
    save(&locked);
    publish(&mut locked, "session.execution.succeeded", id, json!({}));
}

const SESSIONS_FILE: &str = "fake-opencode-sessions.json";

fn load() -> HashMap<String, Session> {
    let Ok(text) = std::fs::read_to_string(SESSIONS_FILE) else { return HashMap::new() };
    let saved: HashMap<String, Value> = serde_json::from_str(&text).unwrap_or_default();
    saved
        .into_iter()
        .map(|(id, session)| {
            let messages = session["messages"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|pair| (pair[0].as_str().unwrap_or_default().to_owned(), pair[1].as_str().unwrap_or_default().to_owned()))
                .collect();
            (
                id,
                Session {
                    title: session["title"].as_str().unwrap_or_default().to_owned(),
                    directory: session["directory"].as_str().unwrap_or_default().to_owned(),
                    model: session["model"].clone(),
                    messages,
                },
            )
        })
        .collect()
}

fn save(state: &State) {
    let saved: serde_json::Map<String, Value> = state
        .sessions
        .iter()
        .map(|(id, session)| {
            (
                id.clone(),
                json!({ "title": session.title, "directory": session.directory, "model": session.model, "messages": session.messages }),
            )
        })
        .collect();
    let _ = std::fs::write(SESSIONS_FILE, Value::Object(saved).to_string());
}

fn publish(state: &mut State, kind: &str, session: &str, mut data: Value) {
    data["sessionID"] = json!(session);
    state.next += 1;
    let frame = format!(
        "data: {}\n\n",
        json!({ "id": format!("evt_{}", state.next), "type": kind, "created": 1, "data": data })
    );
    state
        .subscribers
        .retain_mut(|subscriber| subscriber.write_all(frame.as_bytes()).and_then(|()| subscriber.flush()).is_ok());
}

fn info(id: &str, session: &Session) -> Value {
    json!({
        "id": id,
        "projectID": "fake",
        "title": session.title,
        "model": session.model,
        "location": { "directory": session.directory },
        "time": { "created": 1793355945734_u64, "updated": 1793355947924_u64 },
    })
}

/// As `opencode session export` writes a session (the shape of `testdata/atxf/export-2.0.20.json`).
fn export(id: &str, session: &Session) -> Value {
    let messages: Vec<Value> = session
        .messages
        .iter()
        .enumerate()
        .map(|(index, (role, text))| {
            let created = 1793355946000_u64 + index as u64 * 100;
            if role == "user" {
                json!({ "id": format!("msg_u{index}"), "time": { "created": created }, "text": text, "files": [], "type": "user" })
            } else {
                json!({
                    "id": format!("msg_a{index}"),
                    "time": { "created": created, "streamed": created + 10, "completed": created + 20 },
                    "type": "assistant",
                    "agent": "build",
                    "model": session.model,
                    "content": [{ "type": "text", "text": text }],
                    "finish": "stop",
                    "rawFinish": "stop",
                    "cost": 0,
                    "tokens": { "input": 1, "output": 1, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
                })
            }
        })
        .collect();
    json!({ "info": info(id, session), "messages": messages })
}

fn respond(stream: &mut TcpStream, status: u16, body: &Value) -> std::io::Result<()> {
    let body = body.to_string();
    let reason = match status {
        200 => "OK",
        401 => "Unauthorized",
        _ => "Not Found",
    };
    write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    stream.flush()
}

fn base64(text: &str) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = text.as_bytes();
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0_u32, |n, (i, byte)| n | u32::from(*byte) << (16 - 8 * i));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}
