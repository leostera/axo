//! A stand-in for Pi in axod's black-box tests. It does what axod needs from Pi, over the same
//! wires, and nothing more:
//!
//! - It keeps the transcript writer lock axod hands it (an inherited descriptor) by staying alive.
//! - After `AXO_FAKE_PI_STARTUP_MS` (default 100) it binds axod's bridge socket
//!   (`AXO_PI_BRIDGE_SOCKET`), checks `AXO_PI_BRIDGE_TOKEN`, and says who it is.
//! - It answers commands as Pi does: `send` starts a turn (or is queued, or is `busy`), `stop`
//!   ends the turn whose user record it names (or is `idle`), `shutdown` exits, and
//!   `shutdownIfIdle` exits only when idle. A `commandId` runs at most once.
//! - Right after saying who it is, it publishes what it runs (RFD0033): `pi.state` (the model
//!   "Fake One" at `medium`), `pi.commands` and `pi.models` ("Fake One", "Fake Two"). `setModel`
//!   switches between those two, or answers `invalid`, and publishes `pi.state` again.
//! - A turn records the user's message and a reply in its session file (`AXO_PI_SESSION_FILE`)
//!   before saying so over the bridge, and streams the reply as it grows. It lasts
//!   `AXO_FAKE_PI_TURN_MS` (default 0).
//! - Everything it is typed (its PTY, raw) and sent is appended to `AXO_FAKE_PI_LOG`, if set, as
//!   `TYPED:`, `SENT:`, `DELIVERY:`, `STOPPED:`, `ATTACHED:`, `MODEL:` and `STARTED:` lines, so
//!   tests can read what reached Pi.
//!
//! `AXO_FAKE_PI_FAIL=start` makes it exit at once with status 3, as a Pi that cannot start.

use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

#[derive(Default)]
struct Pi {
    /// The bridge connection that authenticated last; events go to it.
    bridge: Option<UnixStream>,
    sequence: u64,
    /// The running turn: the id of its user record.
    turn: Option<String>,
    queued: Vec<String>,
    commands: HashSet<String>,
    last_entry: Option<String>,
    entries: u64,
    model: Option<&'static str>,
    thinking_level: Option<String>,
}

/// The models this Pi has: (id, name).
const MODELS: [(&str, &str); 2] = [("fake-1", "Fake One"), ("fake-2", "Fake Two")];

impl Pi {
    fn state(&self) -> Value {
        let id = self.model.unwrap_or(MODELS[0].0);
        let name = MODELS.iter().find(|(known, _)| *known == id).map_or(id, |(_, name)| name);
        json!({
            "model": { "provider": "fake", "id": id, "name": name },
            "thinkingLevel": self.thinking_level.as_deref().unwrap_or("medium"),
        })
    }
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn log(line: &str) {
    if let Some(path) = env("AXO_FAKE_PI_LOG") {
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = file.write_all(line.as_bytes());
        }
    }
}

fn now() -> String {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = elapsed.as_secs();
    let (days, rest) = (seconds / 86_400, seconds % 86_400);
    let (year, month, day) = civil(days as i64);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rest / 3600,
        rest % 3600 / 60,
        rest % 60,
        elapsed.subsec_millis()
    )
}

/// Days since 1970-01-01 to a calendar date (Howard Hinnant's algorithm).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(month <= 2), month, day)
}

impl Pi {
    fn publish(&mut self, stream: &str, name: &str, data: Value) {
        self.sequence += 1;
        let record = json!({ "type": "event", "streamId": stream, "sequence": self.sequence, "name": name, "data": data });
        if let Some(bridge) = self.bridge.as_mut() {
            let _ = writeln!(bridge, "{record}");
        }
    }

    /// Appends an entry to the session file, starting it with Pi's header; returns its id.
    fn record(&mut self, session: &str, entry: Value) -> String {
        self.entries += 1;
        let id = format!("{:08x}", self.entries);
        let Some(file) = env("AXO_PI_SESSION_FILE").map(PathBuf::from) else {
            return id;
        };
        if !file.exists() {
            if let Some(parent) = file.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let header = json!({ "type": "session", "version": 3, "id": session, "timestamp": now(), "cwd": working_directory() });
            let _ = fs::write(&file, format!("{header}\n"));
        }
        let mut entry = entry;
        entry["id"] = json!(id);
        entry["parentId"] = json!(self.last_entry);
        entry["timestamp"] = json!(now());
        if let Ok(mut out) = OpenOptions::new().append(true).open(&file) {
            let _ = writeln!(out, "{entry}");
        }
        self.last_entry = Some(id.clone());
        id
    }
}

/// Where Pi says it runs: `PWD` as its parent set it, like Node's `process.cwd()` would not
/// resolve `/tmp` to `/private/tmp`.
fn working_directory() -> String {
    env("PWD").unwrap_or_else(|| {
        std::env::current_dir()
            .unwrap_or_default()
            .display()
            .to_string()
    })
}

fn text(words: &str) -> Value {
    json!({ "role": "assistant", "content": [{ "type": "text", "text": words }] })
}

/// One turn: the user's message, a reply that grows, and its end.
fn run_turn(pi: &Arc<Mutex<Pi>>, session: &str, stream: &str, prompt: String) {
    let user =
        json!({ "role": "user", "content": [{ "type": "text", "text": prompt }], "timestamp": 0 });
    let turn = {
        let mut pi = pi.lock().unwrap();
        let turn = pi.record(session, json!({ "type": "message", "message": user }));
        pi.turn = Some(turn.clone());
        pi.publish(stream, "message.end", json!({ "message": user }));
        pi.publish(stream, "agent.start", json!({}));
        pi.publish(
            stream,
            "message.update",
            json!({ "message": text("Working") }),
        );
        turn
    };
    let lasts = env("AXO_FAKE_PI_TURN_MS")
        .and_then(|ms| ms.parse().ok())
        .unwrap_or(0u64);
    let deadline = std::time::Instant::now() + Duration::from_millis(lasts);
    while std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
        if pi.lock().unwrap().turn.as_deref() != Some(turn.as_str()) {
            return; // Stopped.
        }
    }
    let next = {
        let mut pi = pi.lock().unwrap();
        if pi.turn.as_deref() != Some(turn.as_str()) {
            return;
        }
        let reply = format!("Done: {prompt}");
        pi.record(
            session,
            json!({ "type": "message", "message": text(&reply) }),
        );
        pi.publish(stream, "message.end", json!({ "message": text(&reply) }));
        pi.publish(stream, "agent.end", json!({}));
        pi.turn = None;
        (!pi.queued.is_empty()).then(|| pi.queued.remove(0))
    };
    if let Some(prompt) = next {
        run_turn(pi, session, stream, prompt);
    }
}

fn answer(stream: &mut UnixStream, request: &Value, result: Value) {
    let _ = writeln!(
        stream,
        "{}",
        json!({ "type": "commandResult", "requestId": request["requestId"], "result": result })
    );
}

fn serve(pi: Arc<Mutex<Pi>>, mut stream: UnixStream, session: String, events: String) {
    let token = env("AXO_PI_BRIDGE_TOKEN").unwrap_or_default();
    let reader = BufReader::new(stream.try_clone().expect("bridge socket"));
    let mut authenticated = false;
    for line in reader.lines() {
        let Ok(line) = line else { return };
        let Ok(record) = serde_json::from_str::<Value>(&line) else {
            let _ = writeln!(
                stream,
                "{}",
                json!({ "type": "protocolError", "message": "not JSON" })
            );
            continue;
        };
        if record["type"] == "authenticate" {
            if record["token"] != json!(token) {
                let _ = writeln!(
                    stream,
                    "{}",
                    json!({ "type": "protocolError", "message": "wrong token" })
                );
                return;
            }
            authenticated = true;
            pi.lock().unwrap().bridge = stream.try_clone().ok();
            let identity = json!({
                "axoSessionId": env("AXO_SESSION_ID"),
                "axoPaneId": env("AXO_PANE_ID"),
                "piSessionId": session,
                "sessionFile": env("AXO_PI_SESSION_FILE"),
                "cwd": working_directory(),
                "processId": std::process::id(),
            });
            let _ = writeln!(
                stream,
                "{}",
                json!({ "type": "authenticated", "protocolVersion": 1 })
            );
            let _ = writeln!(
                stream,
                "{}",
                json!({ "type": "hello", "protocolVersion": 1, "identity": identity })
            );
            let mut state = pi.lock().unwrap();
            let current = state.state();
            state.publish(&events, "pi.state", current);
            state.publish(
                &events,
                "pi.commands",
                json!({ "commands": [
                    { "name": "review", "description": "Review the change", "source": "prompt" },
                    { "name": "axo-share", "description": "Share this conversation", "source": "extension" },
                ] }),
            );
            let models: Vec<Value> = MODELS
                .iter()
                .map(|(id, name)| json!({ "provider": "fake", "id": id, "name": name, "thinkingLevels": ["off", "low", "medium", "high"] }))
                .collect();
            state.publish(&events, "pi.models", json!({ "models": models }));
            continue;
        }
        if !authenticated || record["type"] != "command" {
            continue;
        }
        let action = &record["action"];
        match action["kind"].as_str().unwrap_or_default() {
            "send" => {
                let prompt = action["text"].as_str().unwrap_or_default().to_owned();
                if let Some(id) = action["commandId"].as_str() {
                    if !pi.lock().unwrap().commands.insert(id.to_owned()) {
                        answer(&mut stream, &record, json!({ "accepted": true }));
                        continue;
                    }
                }
                let working = pi.lock().unwrap().turn.is_some();
                let held = action["delivery"].is_string() || action["commandId"].is_string();
                if working && !held {
                    log(&format!("BUSY:{prompt}\n"));
                    answer(
                        &mut stream,
                        &record,
                        json!({ "accepted": false, "reason": "busy" }),
                    );
                    continue;
                }
                log(&format!("SENT:{prompt}\n"));
                if let Some(delivery) = action["delivery"].as_str() {
                    log(&format!("DELIVERY:{delivery}:{prompt}\n"));
                }
                if let Some(attachments) = action.get("attachments") {
                    log(&format!("ATTACHED:{attachments}\n"));
                }
                if working {
                    pi.lock().unwrap().queued.push(prompt);
                    answer(&mut stream, &record, json!({ "accepted": true }));
                    continue;
                }
                answer(&mut stream, &record, json!({ "accepted": true }));
                let (pi, session, events) = (Arc::clone(&pi), session.clone(), events.clone());
                thread::spawn(move || run_turn(&pi, &session, &events, prompt));
            }
            "stop" => {
                let turn = action["turnId"].as_str().unwrap_or_default();
                let mut state = pi.lock().unwrap();
                if state.turn.as_deref() == Some(turn) {
                    state.turn = None;
                    state.queued.clear();
                    state.publish(&events, "agent.end", json!({}));
                    drop(state);
                    log(&format!("STOPPED:{turn}\n"));
                    answer(&mut stream, &record, json!({ "accepted": true }));
                } else {
                    drop(state);
                    answer(
                        &mut stream,
                        &record,
                        json!({ "accepted": false, "reason": "idle" }),
                    );
                }
            }
            "setModel" => {
                let mut state = pi.lock().unwrap();
                let model = match action["model"]["id"].as_str() {
                    None => state.model,
                    Some(id) => match MODELS.iter().find(|(known, _)| *known == id) {
                        Some((known, _)) => Some(*known),
                        None => {
                            drop(state);
                            answer(&mut stream, &record, json!({ "accepted": false, "reason": "invalid" }));
                            continue;
                        }
                    },
                };
                state.model = model;
                if let Some(level) = action["thinkingLevel"].as_str() {
                    state.thinking_level = Some(level.to_owned());
                }
                let current = state.state();
                log(&format!("MODEL:{current}\n"));
                answer(&mut stream, &record, json!({ "accepted": true }));
                state.publish(&events, "pi.state", current);
            }
            "shutdown" => {
                answer(&mut stream, &record, json!({ "accepted": true }));
                std::process::exit(0);
            }
            "shutdownIfIdle" => {
                if pi.lock().unwrap().turn.is_some() {
                    answer(
                        &mut stream,
                        &record,
                        json!({ "accepted": false, "reason": "busy" }),
                    );
                } else {
                    answer(&mut stream, &record, json!({ "accepted": true }));
                    std::process::exit(0);
                }
            }
            _ => answer(
                &mut stream,
                &record,
                json!({ "accepted": false, "reason": "invalid" }),
            ),
        }
    }
}

/// Pi's terminal UI reads its keys raw: Enter as "\r", Escape on its own.
fn raw_stdin() {
    // SAFETY: tcgetattr/tcsetattr on stdin with a zeroed, then filled, termios.
    unsafe {
        let mut mode: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(0, &mut mode) == 0 {
            libc::cfmakeraw(&mut mode);
            libc::tcsetattr(0, libc::TCSANOW, &mode);
        }
    }
}

/// A version-4-shaped UUID, unique to this process and `salt`: Pi's ids are UUIDs, and axod
/// checks.
fn uuid(salt: u128) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let hex = format!(
        "{:032x}",
        nanos ^ (u128::from(std::process::id()) << 64) ^ (salt << 100)
    );
    format!(
        "{}-{}-4{}-8{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[13..16],
        &hex[17..20],
        &hex[20..32]
    )
}

fn main() {
    if env("AXO_FAKE_PI_FAIL").as_deref() == Some("start") {
        eprintln!("fake Pi: failing to start, as asked");
        std::process::exit(3);
    }
    raw_stdin();
    log(&format!("STARTED:{}\n", std::process::id()));
    let pi = Arc::new(Mutex::new(Pi::default()));
    let session = uuid(1);
    let events = uuid(2);
    thread::spawn(|| {
        let mut stdin = std::io::stdin();
        let mut buffer = [0u8; 4096];
        while let Ok(count) = stdin.read(&mut buffer) {
            if count == 0 {
                break;
            }
            log(&format!(
                "TYPED:{}\n",
                String::from_utf8_lossy(&buffer[..count]).escape_debug()
            ));
        }
    });
    let startup = env("AXO_FAKE_PI_STARTUP_MS")
        .and_then(|ms| ms.parse().ok())
        .unwrap_or(100u64);
    thread::sleep(Duration::from_millis(startup));
    let Some(path) = env("AXO_PI_BRIDGE_SOCKET") else {
        // Not launched by axod: wait like the sleeping fixture does.
        loop {
            thread::sleep(Duration::from_secs(3600));
        }
    };
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path).expect("bind the bridge socket");
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let (pi, session, events) = (Arc::clone(&pi), session.clone(), events.clone());
        thread::spawn(move || serve(pi, stream, session, events));
    }
}
