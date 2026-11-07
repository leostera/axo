//! A fake of Axo's cloud, as far as one Mac sees it: the pairing route that links axod to an
//! account, and the daemon WebSocket it keeps open afterwards. Tests drive axod through it the
//! way the account's phones and scripts do (`call`), and see what axod sends up (`wait_for`).
//!
//! - Every request axod sends is answered `{}` unless the test says otherwise: `respond` with a
//!   result or an error, or `hold` to keep it unanswered until `answer`.
//! - Messages too large for one frame (`axo.transport.fragment`) are not reassembled; tests use
//!   small ones.
//! - It speaks plain `ws://` on loopback, which axod accepts only for loopback relays.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tungstenite::{Message, WebSocket};

/// The account every Mac linked to this hub joins.
pub const ACCOUNT_ID: &str = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b";
/// A pairing code in the form axod accepts; this hub takes any.
pub const CODE: &str = "ABCD-EFGH";

const WAIT: Duration = Duration::from_secs(15);

/// How the hub answers one method axod calls.
#[derive(Clone)]
pub enum Answer {
    Result(Value),
    Error(i64, String),
    /// Kept unanswered; the test answers it with [`FakeHub::answer`].
    Hold,
}

/// A WebSocket axod opened: its path and the credential it presented.
#[derive(Clone, Debug)]
pub struct Socket {
    pub path: String,
    pub authorization: Option<String>,
    pub credential_id: Option<String>,
}

#[derive(Default)]
struct State {
    /// The body of each redemption, in order.
    redeemed: Vec<Value>,
    sockets: Vec<Socket>,
    /// Everything axod sent on its daemon socket, in order.
    received: Vec<Value>,
    answers: HashMap<String, Answer>,
    /// Where the hub's messages to the current daemon socket go.
    outbox: Option<Sender<String>>,
    /// Which daemon socket is current: each new one, and each drop, moves it on.
    generation: u64,
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
    stop: AtomicBool,
}

pub struct FakeHub {
    port: u16,
    shared: Arc<Shared>,
    next_id: AtomicU64,
}

impl FakeHub {
    pub fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind the fake hub");
        let port = listener.local_addr().unwrap().port();
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            stop: AtomicBool::new(false),
        });
        let accepting = Arc::clone(&shared);
        thread::spawn(move || {
            for stream in listener.incoming() {
                if accepting.stop.load(Ordering::Relaxed) {
                    return;
                }
                let Ok(stream) = stream else { continue };
                let shared = Arc::clone(&accepting);
                thread::spawn(move || serve(stream, shared));
            }
        });
        Self {
            port,
            shared,
            next_id: AtomicU64::new(1),
        }
    }

    /// The relay URL to start axod with.
    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn respond(&self, method: &str, answer: Answer) {
        self.lock().answers.insert(method.to_owned(), answer);
    }

    pub fn hold(&self, method: &str) {
        self.respond(method, Answer::Hold);
    }

    /// Answers a request axod sent and the hub held.
    pub fn answer(&self, request: &Value, result: Value) {
        self.send(json!({ "jsonrpc": "2.0", "id": request["id"], "result": result }));
    }

    /// Calls axod as the account would, and waits for its answer: `Ok(result)` or
    /// `Err(error)`.
    pub fn call(&self, method: &str, params: Value) -> Result<Value, Value> {
        self.wait_until_connected();
        let id = format!("hub-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }));
        let reply = self.wait_for(&format!("the answer to {method}"), |message| {
            message["id"] == json!(id) && message.get("method").is_none()
        });
        match reply.get("error") {
            Some(error) => Err(error.clone()),
            None => Ok(reply["result"].clone()),
        }
    }

    pub fn ok(&self, method: &str, params: Value) -> Value {
        self.call(method, params)
            .unwrap_or_else(|error| panic!("{method} failed through the hub: {error}"))
    }

    /// Sends a notification to axod, as the account does.
    pub fn notify(&self, method: &str, params: Value) {
        self.wait_until_connected();
        self.send(json!({ "jsonrpc": "2.0", "method": method, "params": params }));
    }

    /// The first message from axod, since it connected, that `matches`.
    pub fn wait_for(&self, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        let mut state = self.lock();
        loop {
            if let Some(found) = state.received.iter().find(|message| matches(message)) {
                return found.clone();
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                panic!(
                    "the hub waited for {what}; axod sent:\n{}",
                    state
                        .received
                        .iter()
                        .map(Value::to_string)
                        .collect::<Vec<_>>()
                        .join("\n")
                );
            }
            state = self.shared.changed.wait_timeout(state, left).unwrap().0;
        }
    }

    /// The first request axod sent for `method`.
    pub fn wait_for_request(&self, method: &str) -> Value {
        self.wait_for(&format!("a {method} request"), |message| {
            message["method"] == json!(method) && message.get("id").is_some()
        })
    }

    /// Every message axod sent for `method`, so far.
    pub fn received(&self, method: &str) -> Vec<Value> {
        self.lock()
            .received
            .iter()
            .filter(|message| message["method"] == json!(method))
            .cloned()
            .collect()
    }

    pub fn redeemed(&self) -> Vec<Value> {
        self.lock().redeemed.clone()
    }

    pub fn sockets(&self) -> Vec<Socket> {
        self.lock().sockets.clone()
    }

    /// Waits until axod has a daemon socket open and has registered on it.
    pub fn wait_until_connected(&self) {
        self.wait_for("axod to register", |message| {
            message["method"] == json!("axo.host.register")
        });
        let deadline = Instant::now() + WAIT;
        let mut state = self.lock();
        while state.outbox.is_none() {
            assert!(Instant::now() < deadline, "axod never kept its socket open");
            state = self
                .shared
                .changed
                .wait_timeout(state, Duration::from_millis(50))
                .unwrap()
                .0;
        }
    }

    /// Closes axod's daemon socket, as a deploy or a network drop does; what it already sent is
    /// forgotten, so `wait_for` sees only what comes after.
    pub fn drop_socket(&self) {
        let mut state = self.lock();
        state.outbox = None;
        state.generation += 1;
        state.received.clear();
        self.shared.changed.notify_all();
    }

    fn send(&self, message: Value) {
        let state = self.lock();
        let outbox = state.outbox.as_ref().expect("axod is connected to the hub");
        outbox
            .send(message.to_string())
            .expect("the daemon socket is open");
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.shared.state.lock().unwrap()
    }
}

impl Drop for FakeHub {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        self.lock().outbox = None;
        // Wake the accept loop so it sees `stop`.
        let _ = TcpStream::connect(("127.0.0.1", self.port));
    }
}

fn serve(stream: TcpStream, shared: Arc<Shared>) {
    let mut first = [0u8; 4];
    if stream.peek(&mut first).is_err() {
        return;
    }
    if &first == b"POST" {
        redeem(stream, &shared);
    } else {
        daemon_socket(stream, shared);
    }
}

/// `POST /api/v1/host-pairings/redeem`: links the Mac to [`ACCOUNT_ID`], echoing its host and
/// credential.
fn redeem(stream: TcpStream, shared: &Shared) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    let mut length = 0usize;
    loop {
        line.clear();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let header = line.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0u8; length];
    if reader.read_exact(&mut body).is_err() {
        return;
    }
    let request: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let response = json!({
        "linked": true,
        "accountId": ACCOUNT_ID,
        "hostId": request["hostId"],
        "hostGeneration": request["hostGeneration"],
        "credentialId": request["credentialId"],
        "linkedAt": "2026-11-07T00:00:00.000Z",
    })
    .to_string();
    {
        let mut state = shared.state.lock().unwrap();
        state.redeemed.push(request);
        shared.changed.notify_all();
    }
    let mut stream = stream;
    let _ = write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}",
        response.len()
    );
}

fn daemon_socket(stream: TcpStream, shared: Arc<Shared>) {
    let mut seen = None;
    let socket = tungstenite::accept_hdr(
        stream.try_clone().unwrap(),
        |request: &tungstenite::handshake::server::Request,
         response: tungstenite::handshake::server::Response| {
            let header = |name: &str| {
                request
                    .headers()
                    .get(name)
                    .and_then(|value| value.to_str().ok())
                    .map(str::to_owned)
            };
            seen = Some(Socket {
                path: request.uri().path().to_owned(),
                authorization: header("authorization"),
                credential_id: header("x-axo-credential-id"),
            });
            Ok(response)
        },
    );
    let Ok(mut socket) = socket else { return };
    let Some(seen) = seen else { return };
    let is_daemon = seen.path.ends_with("/daemon");
    let (outbox, outgoing) = channel();
    let generation = {
        let mut state = shared.state.lock().unwrap();
        state.sockets.push(seen);
        if is_daemon {
            state.outbox = Some(outbox);
            state.generation += 1;
        }
        shared.changed.notify_all();
        state.generation
    };
    // The hub sends what a test queued between reads, so a short read keeps it from adding its
    // own delay to every call (conformance_relay measures axod's).
    stream
        .set_read_timeout(Some(Duration::from_millis(1)))
        .unwrap();
    converse(&mut socket, generation, &outgoing, &shared, is_daemon);
    let _ = socket.close(None);
}

fn converse(
    socket: &mut WebSocket<TcpStream>,
    generation: u64,
    outgoing: &Receiver<String>,
    shared: &Shared,
    is_daemon: bool,
) {
    loop {
        if shared.stop.load(Ordering::Relaxed) {
            return;
        }
        // A daemon socket the test dropped is closed.
        if is_daemon && shared.state.lock().unwrap().generation != generation {
            return;
        }
        while let Ok(text) = outgoing.try_recv() {
            if socket.send(Message::Text(text.into())).is_err() {
                return;
            }
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                let Ok(message) = serde_json::from_str::<Value>(&text) else {
                    continue;
                };
                let reply = if is_daemon {
                    reply_to(&message, shared)
                } else {
                    // Other sockets (following other Macs) get an empty answer and no record.
                    message
                        .get("id")
                        .map(|id| json!({ "jsonrpc": "2.0", "id": id, "result": {} }))
                };
                if let Some(reply) = reply
                    && socket
                        .send(Message::Text(reply.to_string().into()))
                        .is_err()
                {
                    return;
                }
            }
            Ok(Message::Close(_)) => return,
            Ok(_) => {}
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => return,
        }
    }
}

/// Records `message` and, if it is a request, answers it as the test said.
fn reply_to(message: &Value, shared: &Shared) -> Option<Value> {
    let mut state = shared.state.lock().unwrap();
    state.received.push(message.clone());
    shared.changed.notify_all();
    let id = message.get("id")?;
    let method = message.get("method")?.as_str()?;
    match state
        .answers
        .get(method)
        .cloned()
        .unwrap_or(Answer::Result(json!({})))
    {
        Answer::Result(result) => Some(json!({ "jsonrpc": "2.0", "id": id, "result": result })),
        Answer::Error(code, text) => {
            Some(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": text } }))
        }
        Answer::Hold => None,
    }
}
