//! A stand-in for Pi in axod's black-box tests. It does what axod needs from Pi, over the same
//! wires, and nothing more:
//!
//! - It keeps the transcript writer lock axod hands it (an inherited descriptor) by staying alive.
//! - After `AXO_FAKE_PI_STARTUP_MS` (default 100) it binds axod's bridge socket
//!   (`AXO_PI_BRIDGE_SOCKET`), checks `AXO_PI_BRIDGE_TOKEN`, and says who it is.
//! - It answers commands as Pi does: `send` starts a turn (or is queued, or is `busy`), `stop`
//!   ends the turn whose user record it names (or is `idle`), and `shutdown` exits. A
//!   `commandId` runs at most once.
//! - Right after saying who it is, it publishes what it runs (RFD0033): `pi.state` (the model
//!   "Fake One" at `medium`), `pi.commands` and `pi.models` ("Fake One", "Fake Two"). `setModel`
//!   switches between those two, or answers `invalid`, and publishes `pi.state` again.
//! - A turn records the user's message and a reply in its session file (`AXO_PI_SESSION_FILE`)
//!   before saying so over the bridge, and streams the reply as it grows. It lasts
//!   `AXO_FAKE_PI_TURN_MS` (default 0). It ends with `agent.end`, then `agent.settled` once
//!   nothing it queued is left.
//! - Everything it is typed (its PTY, raw) and sent is appended to `AXO_FAKE_PI_LOG`, if set, as
//!   `TYPED:`, `SENT:`, `DELIVERY:`, `STOPPED:`, `ATTACHED:`, `MODEL:` and `STARTED:` lines, so
//!   tests can read what reached Pi.
//!
//! - It exits when its lifeline (`AXO_LIFELINE_FD`) ends, as pi-axo does: axod has gone.
//!
//! - With `AXO_FAKE_PI_AGENT_SOCKETS` (a directory), it serves `<directory>/<AXO_SESSION_ID>.sock`
//!   and copies each connection to and from axod's socket (`AXO_SOCKET`) on one of its own, as
//!   its tools would call axod: a test reaches axod there as this Session's agent (RFD0073).
//!   On `<directory>/<AXO_SESSION_ID>.mcp.sock` it starts `$AXOD mcp` for each connection, as
//!   pi-axo does, wired to it; when it exits, the last line is `{"fakePiMcpExit": <status>}`.
//!   With `AXO_FAKE_PI_ATTACH_SOCKET` too, `<directory>/<AXO_SESSION_ID>.attach.sock` speaks
//!   the attach protocol: each attachment is made from this Pi's process to that socket and
//!   handed on, PTY descriptor and all.
//!
//! `AXO_FAKE_PI_FAIL=start` makes it exit at once with status 3, as a Pi that cannot start.
//! `AXO_FAKE_PI_STUBBORN=1` makes it ignore SIGHUP and its lifeline, as a Pi from before the
//! lifeline did: it outlives the axod that started it.

use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// Events and command replies share one writer: cloned socket handles alone
/// do not stop their JSON framing writes from interleaving.
#[derive(Clone)]
struct BridgeWriter(Arc<Mutex<UnixStream>>);
impl BridgeWriter {
    fn new(stream: UnixStream) -> Self {
        Self(Arc::new(Mutex::new(stream)))
    }
    fn record(&self, record: Value) -> std::io::Result<()> {
        let mut line = record.to_string();
        line.push('\n');
        self.0.lock().unwrap().write_all(line.as_bytes())
    }
}

#[derive(Default)]
struct Pi {
    /// The bridge connection that authenticated last; events go to it.
    bridge: Option<BridgeWriter>,
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
        let name = MODELS
            .iter()
            .find(|(known, _)| *known == id)
            .map_or(id, |(_, name)| name);
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
        if let Some(bridge) = &self.bridge {
            let _ = bridge.record(record);
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

enum TurnInput {
    User(String),
    Resume,
}

/// A real prompt adds its user message; recovery adds no starting message at all.
fn run_turn(pi: &Arc<Mutex<Pi>>, session: &str, stream: &str, input: TurnInput) {
    let prompt = match &input {
        TurnInput::User(text) => text.clone(),
        TurnInput::Resume => "resumed".to_owned(),
    };
    let turn = {
        let mut pi = pi.lock().unwrap();
        let turn = match input {
            TurnInput::User(text) => {
                let user = json!({ "role": "user", "content": [{ "type": "text", "text": text }], "timestamp": 0 });
                let turn = pi.record(session, json!({ "type": "message", "message": user }));
                pi.publish(stream, "message.end", json!({ "message": user }));
                turn
            }
            TurnInput::Resume => format!("resume-{}", pi.sequence),
        };
        pi.turn = Some(turn.clone());
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
        if pi.queued.is_empty() {
            // Nothing follows: Pi has settled, as it says once no queued message is left.
            pi.publish(stream, "agent.settled", json!({}));
        }
        (!pi.queued.is_empty()).then(|| pi.queued.remove(0))
    };
    if let Some(prompt) = next {
        run_turn(pi, session, stream, TurnInput::User(prompt));
    }
}

#[cfg(test)]
mod bridge_tests {
    use super::*;
    #[test]
    fn concurrent_events_and_command_replies_are_complete_json_records() {
        let (socket, reader) = UnixStream::pair().unwrap();
        let mut answers = BridgeWriter::new(socket);
        reader
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut pi = Pi {
            bridge: Some(answers.clone()),
            ..Default::default()
        };
        let start = Arc::new(std::sync::Barrier::new(2));
        let events_start = Arc::clone(&start);
        let events = thread::spawn(move || {
            events_start.wait();
            for sequence in 0..32 {
                pi.publish(
                    "owned-fixture",
                    "fixture.event",
                    json!({"sequence":sequence,"text":"x".repeat(256*1024)}),
                );
            }
        });
        let replies = thread::spawn(move || {
            start.wait();
            for sequence in 0..32 {
                answer(
                    &mut answers,
                    &json!({"requestId":sequence}),
                    json!({"accepted":true,"text":"y".repeat(256*1024)}),
                );
            }
        });
        let records: Vec<_> = BufReader::new(reader)
            .lines()
            .map(|line| serde_json::from_str::<Value>(&line.unwrap()))
            .collect();
        events.join().unwrap();
        replies.join().unwrap();
        assert_eq!(records.len(), 64);
        assert!(
            records.iter().all(Result::is_ok),
            "concurrent bridge records interleaved"
        );
        assert_eq!(
            records
                .iter()
                .filter(|record| record.as_ref().unwrap()["type"] == "event")
                .count(),
            32
        );
    }
}

fn answer(stream: &mut BridgeWriter, request: &Value, result: Value) {
    let _ = stream.record(
        json!({ "type": "commandResult", "requestId": request["requestId"], "result": result }),
    );
}

fn serve(pi: Arc<Mutex<Pi>>, stream: UnixStream, session: String, events: String) {
    let token = env("AXO_PI_BRIDGE_TOKEN").unwrap_or_default();
    let reader = BufReader::new(stream.try_clone().expect("bridge socket"));
    let mut stream = BridgeWriter::new(stream);
    let mut authenticated = false;
    for line in reader.lines() {
        let Ok(line) = line else { return };
        let Ok(record) = serde_json::from_str::<Value>(&line) else {
            let _ = stream.record(json!({ "type": "protocolError", "message": "not JSON" }));
            continue;
        };
        if record["type"] == "authenticate" {
            if record["token"] != json!(token) {
                let _ = stream.record(json!({ "type": "protocolError", "message": "wrong token" }));
                return;
            }
            authenticated = true;
            // Publish the new writer while holding the event-state lock through
            // authentication and hello, so no old turn can precede the handshake.
            let mut state = pi.lock().unwrap();
            state.bridge = Some(stream.clone());
            let identity = json!({
                "axoSessionId": env("AXO_SESSION_ID"),
                "axoPaneId": env("AXO_PANE_ID"),
                "piSessionId": session,
                "sessionFile": env("AXO_PI_SESSION_FILE"),
                "cwd": working_directory(),
                "processId": std::process::id(),
            });
            let _ = stream.record(json!({ "type": "authenticated", "protocolVersion": 1 }));
            let _ = stream
                .record(json!({ "type": "hello", "protocolVersion": 1, "identity": identity }));
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
            "resumeTurn" => {
                let working = pi.lock().unwrap().turn.is_some();
                if working {
                    answer(
                        &mut stream,
                        &record,
                        json!({ "accepted": false, "reason": "busy" }),
                    );
                    continue;
                }
                log("RESUME_TURN\n");
                answer(&mut stream, &record, json!({ "accepted": true }));
                let (pi, session, events) = (Arc::clone(&pi), session.clone(), events.clone());
                thread::spawn(move || run_turn(&pi, &session, &events, TurnInput::Resume));
            }
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
                thread::spawn(move || run_turn(&pi, &session, &events, TurnInput::User(prompt)));
            }
            "stop" => {
                let turn = action["turnId"].as_str().unwrap_or_default();
                let mut state = pi.lock().unwrap();
                if state.turn.as_deref() == Some(turn) {
                    state.turn = None;
                    state.queued.clear();
                    state.publish(&events, "agent.end", json!({}));
                    state.publish(&events, "agent.settled", json!({}));
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
                            answer(
                                &mut stream,
                                &record,
                                json!({ "accepted": false, "reason": "invalid" }),
                            );
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

/// Relays `<AXO_FAKE_PI_AGENT_SOCKETS>/<AXO_SESSION_ID>.sock` to axod, so what a test sends there
/// reaches axod from this Pi's process, as its tools' calls do; and serves `axod mcp`, started by
/// this Pi, on `<AXO_SESSION_ID>.mcp.sock`.
fn serve_as_agent() {
    let (Some(directory), Some(session), Some(axod)) = (
        env("AXO_FAKE_PI_AGENT_SOCKETS"),
        env("AXO_SESSION_ID"),
        env("AXO_SOCKET"),
    ) else {
        return;
    };
    let directory = PathBuf::from(directory);
    let listen = |name: String| {
        let path = directory.join(name);
        let _ = fs::remove_file(&path);
        UnixListener::bind(&path).ok()
    };
    if let Some(listener) = listen(format!("{session}.sock")) {
        thread::spawn(move || {
            for client in listener.incoming() {
                let (Ok(client), Ok(upstream)) = (client, UnixStream::connect(&axod)) else {
                    continue;
                };
                if let (Ok(from_client), Ok(from_axod)) = (client.try_clone(), upstream.try_clone())
                {
                    copy_then_close(from_client, upstream);
                    copy_then_close(from_axod, client);
                }
            }
        });
    }
    if let (Some(listener), Some(upstream)) = (
        listen(format!("{session}.attach.sock")),
        env("AXO_FAKE_PI_ATTACH_SOCKET"),
    ) {
        thread::spawn(move || {
            for client in listener.incoming() {
                let Ok(client) = client else { continue };
                let upstream = upstream.clone();
                thread::spawn(move || relay_attachment(client, &upstream));
            }
        });
    }
    if let (Some(listener), Some(executable)) = (listen(format!("{session}.mcp.sock")), env("AXOD"))
    {
        thread::spawn(move || {
            for client in listener.incoming() {
                let Ok(client) = client else { continue };
                let executable = executable.clone();
                thread::spawn(move || run_mcp(&executable, client));
            }
        });
    }
}

fn copy_then_close(mut from: impl Read + Send + 'static, mut to: UnixStream) {
    thread::spawn(move || {
        let _ = std::io::copy(&mut from, &mut to);
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
}

/// Attaches from this process to the attach socket at `path`, and hands the attachment on: the
/// request, the answer's header, the PTY descriptor, then the stream.
fn relay_attachment(client: UnixStream, path: &str) {
    let Ok(mut reader) = client.try_clone().map(BufReader::new) else {
        return;
    };
    let Ok(mut upstream) = UnixStream::connect(path) else {
        return;
    };
    // The request is one line: the shell ID.
    let mut request = String::new();
    if reader.read_line(&mut request).is_err() || upstream.write_all(request.as_bytes()).is_err() {
        return;
    }
    let mut client = client;
    let mut header = [0_u8; 8];
    if upstream.read_exact(&mut header).is_err() || client.write_all(&header).is_err() {
        return;
    }
    if u64::from_be_bytes(header) == u64::MAX {
        // Refused: one code byte follows.
        let _ = std::io::copy(&mut (&upstream).take(1), &mut client);
        return;
    }
    let Some((byte, descriptor)) = receive_descriptor(&upstream) else {
        return;
    };
    if !send_descriptor(&client, byte, descriptor) {
        return;
    }
    // SAFETY: the descriptor was received above and is closed once, here.
    unsafe { libc::close(descriptor) };
    // Then the replay and live output, until either side hangs up.
    if let Ok(to_upstream) = upstream.try_clone() {
        copy_then_close(reader, to_upstream);
    }
    let _ = std::io::copy(&mut upstream, &mut client);
    let _ = client.shutdown(std::net::Shutdown::Both);
}

/// One byte and one descriptor (SCM_RIGHTS) from `stream`.
fn receive_descriptor(stream: &UnixStream) -> Option<(u8, i32)> {
    use std::os::fd::AsRawFd;
    let mut byte = 0_u8;
    let mut vector = libc::iovec {
        iov_base: (&mut byte as *mut u8).cast(),
        iov_len: 1,
    };
    // SAFETY: CMSG_SPACE only computes a size.
    let space = unsafe { libc::CMSG_SPACE(std::mem::size_of::<i32>() as u32) } as usize;
    let mut control = vec![0_usize; space.div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: a zeroed msghdr is valid before its fields are set.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = space as _;
    // SAFETY: the message points at buffers of the sizes it states.
    if unsafe { libc::recvmsg(stream.as_raw_fd(), &mut message, 0) } != 1 {
        return None;
    }
    // SAFETY: recvmsg filled the control buffer; a null header means no descriptor came.
    let header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    if header.is_null() {
        return None;
    }
    // SAFETY: the header is SOL_SOCKET/SCM_RIGHTS with one descriptor, as attach sends it.
    let descriptor = unsafe { std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<i32>()) };
    Some((byte, descriptor))
}

/// Sends `byte` with `descriptor` (SCM_RIGHTS) on `stream`.
fn send_descriptor(stream: &UnixStream, byte: u8, descriptor: i32) -> bool {
    use std::os::fd::AsRawFd;
    let mut byte = byte;
    let mut vector = libc::iovec {
        iov_base: (&mut byte as *mut u8).cast(),
        iov_len: 1,
    };
    // SAFETY: CMSG_SPACE and CMSG_LEN only compute sizes.
    let (space, length) = unsafe {
        (
            libc::CMSG_SPACE(std::mem::size_of::<i32>() as u32) as usize,
            libc::CMSG_LEN(std::mem::size_of::<i32>() as u32),
        )
    };
    let mut control = vec![0_usize; space.div_ceil(std::mem::size_of::<usize>())];
    // SAFETY: a zeroed msghdr is valid before its fields are set.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut vector;
    message.msg_iovlen = 1;
    message.msg_control = control.as_mut_ptr().cast();
    message.msg_controllen = space as _;
    // SAFETY: the control buffer holds one header and one descriptor, as sized above.
    unsafe {
        let header = libc::CMSG_FIRSTHDR(&message);
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = length as _;
        std::ptr::write_unaligned(libc::CMSG_DATA(header).cast::<i32>(), descriptor);
        libc::sendmsg(stream.as_raw_fd(), &message, 0) == 1
    }
}

/// Pump interactive traffic immediately. std::io::copy can choose a Linux splice
/// fast path for pipe-to-socket copies that waits for more data instead of making
/// a partial MCP response visible while the pipe's writer stays alive.
fn pump_live(
    mut input: impl std::io::Read,
    mut output: impl std::io::Write,
) -> std::io::Result<()> {
    let mut buffer = [0; 8192];
    loop {
        let count = match input.read(&mut buffer) {
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if count == 0 {
            return Ok(());
        }
        output.write_all(&buffer[..count])?;
        output.flush()?;
    }
}

/// `axod mcp` as this Pi's child, on `client`: its stdin from it, its stdout to it, then how it
/// exited.
fn run_mcp(executable: &str, client: UnixStream) {
    let Ok(mut child) = std::process::Command::new(executable)
        .arg("mcp")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    else {
        return;
    };
    let (Some(mut input), Some(mut output), Ok(mut from_client), Ok(mut to_client)) = (
        child.stdin.take(),
        child.stdout.take(),
        client.try_clone(),
        client.try_clone(),
    ) else {
        let _ = child.kill();
        return;
    };
    thread::spawn(move || {
        let _ = pump_live(&mut from_client, &mut input);
    });
    let _ = pump_live(&mut output, &mut to_client);
    let status = child.wait().ok().and_then(|status| status.code());
    let _ = writeln!(to_client, "{}", json!({ "fakePiMcpExit": status }));
    let _ = to_client.shutdown(std::net::Shutdown::Write);
}

fn main() {
    if env("AXO_FAKE_PI_FAIL").as_deref() == Some("start") {
        eprintln!("fake Pi: failing to start, as asked");
        std::process::exit(3);
    }
    raw_stdin();
    log(&format!("STARTED:{}\n", std::process::id()));
    let stubborn = env("AXO_FAKE_PI_STUBBORN").is_some();
    if stubborn {
        // SAFETY: ignoring a signal changes no memory this program holds.
        unsafe { libc::signal(libc::SIGHUP, libc::SIG_IGN) };
    }
    if let Some(fd) = env("AXO_LIFELINE_FD")
        .and_then(|fd| fd.parse::<i32>().ok())
        .filter(|_| !stubborn)
    {
        thread::spawn(move || {
            let mut byte = [0u8; 1];
            // SAFETY: reads into a one-byte buffer from the inherited lifeline descriptor.
            while unsafe { libc::read(fd, byte.as_mut_ptr().cast(), 1) } > 0 {}
            log("LIFELINE_ENDED\n");
            std::process::exit(0);
        });
    }
    serve_as_agent();
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
    if let Some(gate) = env("AXO_FAKE_PI_STARTUP_GATE") {
        while fs::read_to_string(&gate).is_ok_and(|state| state.trim() == "hold") {
            thread::sleep(Duration::from_millis(10));
        }
    }
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
