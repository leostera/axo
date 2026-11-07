//! The conformance suite's harness: a real `axod` binary in a directory of its own, driven only
//! over its socket, the way Axo.app, `axod mcp` and the relay drive it. Nothing here reaches into
//! axod's code, so the same tests hold before, during and after axod is rewritten.
//!
//! - `Axod::start()` runs one with the fake Pi (`testdata/fake_pi.rs`), a home of its own and no
//!   account. `Axod::with(Options)` chooses the Pi, its environment and the relay.
//! - `call` answers `Ok(result)` or `Err(RpcError)`; `ok` and `err` assert which.
//! - `subscribe` follows its events; `Events::wait_for` waits for the one a test needs.
//! - `restart` stops it and starts it again on the same directory, as a crash, an upgrade or a
//!   login would.
//!
//! Failures print axod's log.

#![allow(dead_code)]

pub mod hub;

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// How long a test waits for something it needs: a socket, an event, a process. Only a failing
/// test waits this long; a loaded machine has needed over 4 s.
pub const READY_WAIT: Duration = Duration::from_secs(20);

/// A relay URL where nothing listens (the discard port on loopback).
pub const NO_RELAY: &str = "http://127.0.0.1:9";

#[derive(Clone, Debug, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    pub data: Value,
}

/// Which Pi axod launches for its Pi panes.
#[derive(Clone, Debug)]
pub enum Pi {
    /// `testdata/fake_pi.rs`: binds the bridge, answers commands, writes a transcript.
    Fake,
    /// `testdata/pi-fixture.sh`: holds the writer lock and sleeps; never binds the bridge.
    Sleeping,
    /// Any executable.
    Path(PathBuf),
}

#[derive(Clone, Debug)]
pub struct Options {
    pub pi: Pi,
    /// Extra environment for axod (and so for Pi, which inherits it).
    pub env: Vec<(String, String)>,
    /// The relay axod links through; [`NO_RELAY`] when `None`.
    pub relay_url: Option<String>,
    /// Extra arguments for `axod`.
    pub args: Vec<String>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            pi: Pi::Fake,
            env: Vec::new(),
            relay_url: None,
            args: Vec::new(),
        }
    }
}

pub struct Axod {
    pub directory: PathBuf,
    pub options: Options,
    child: Option<Child>,
}

/// A path to something Bazel put in the test's runfiles, from the environment variable naming it.
pub fn runfile(variable: &str) -> PathBuf {
    let path = PathBuf::from(
        std::env::var_os(variable).unwrap_or_else(|| panic!("the test needs {variable}")),
    );
    if path.is_absolute() || path.exists() {
        return std::fs::canonicalize(&path).unwrap_or(path);
    }
    let runfiles = std::env::var_os("RUNFILES_DIR")
        .or_else(|| std::env::var_os("TEST_SRCDIR"))
        .map(PathBuf::from)
        .expect("Bazel provides the runfiles directory");
    let workspace = std::env::var_os("TEST_WORKSPACE").unwrap_or_default();
    [
        runfiles.join(&path),
        runfiles.join(&workspace).join(&path),
        runfiles.join("_main").join(&path),
    ]
    .into_iter()
    .find(|candidate| candidate.exists())
    .map(|found| std::fs::canonicalize(&found).unwrap_or(found))
    .unwrap_or_else(|| panic!("{} is not in the runfiles", path.display()))
}

/// The axod under test: the target's own, unless `AXOD_BINARY_OVERRIDE` names another, as the
/// coverage script does with an instrumented build (a target's `env` outranks `--test_env`).
pub fn axod_binary() -> PathBuf {
    match std::env::var_os("AXOD_BINARY_OVERRIDE") {
        Some(path) if !path.is_empty() => PathBuf::from(path),
        _ => runfile("AXOD_BINARY"),
    }
}

/// A fresh directory under `/tmp` (Unix socket paths are limited to 104 bytes, which rules out
/// Bazel's long `TEST_TMPDIR`). The counter keeps concurrent tests apart.
pub fn fresh_directory(tag: &str) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let index = NEXT.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos()
        % 1_000_000_000;
    // Short: a Pi bridge socket inside it (`server/pi-sessions/<session>.sock`, under
    // `/private/tmp`) must fit too, or Pi's socket falls back to one in `/tmp` that outlives it.
    let unique = (u64::from(std::process::id()) << 32 | u64::from(nanos as u32)) % 0xffff_ffff;
    let directory = PathBuf::from("/tmp").join(format!("axt-{tag}-{index}{unique:08x}"));
    std::fs::create_dir_all(directory.join("home")).unwrap();
    directory
}

impl Axod {
    pub fn start() -> Self {
        Self::with(Options::default())
    }

    pub fn with(options: Options) -> Self {
        let mut axod = Self {
            directory: fresh_directory("axod"),
            options,
            child: None,
        };
        axod.launch();
        axod
    }

    pub fn socket(&self) -> PathBuf {
        self.directory.join("axod.sock")
    }

    pub fn server_directory(&self) -> PathBuf {
        self.directory.join("server")
    }

    pub fn home(&self) -> PathBuf {
        self.directory.join("home")
    }

    /// What the fake Pi was typed and sent, across every Pi this axod launched.
    pub fn pi_log(&self) -> String {
        std::fs::read_to_string(self.directory.join("pi.log")).unwrap_or_default()
    }

    pub fn log(&self) -> String {
        std::fs::read_to_string(self.server_directory().join("stderr.log")).unwrap_or_default()
    }

    pub fn pid(&self) -> u32 {
        self.child.as_ref().map(Child::id).unwrap_or_default()
    }

    fn launch(&mut self) {
        let pi = match &self.options.pi {
            Pi::Fake => runfile("AXO_TEST_FAKE_PI"),
            Pi::Sleeping => runfile("AXO_TEST_PI_EXECUTABLE"),
            Pi::Path(path) => path.clone(),
        };
        let mut command = Command::new(axod_binary());
        command
            .env("HOME", self.home())
            .env("AXO_PI_EXECUTABLE", pi)
            .env("AXO_FAKE_PI_LOG", self.directory.join("pi.log"))
            .env("AXO_FAKE_PI_STARTUP_MS", "50")
            .arg("--socket")
            .arg(self.socket())
            .arg("--server-dir")
            .arg(self.server_directory())
            .args(&self.options.args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // Hermetic: never the login Keychain, and never the production relay. Unless a test
        // names one, the relay is a loopback port where nothing listens.
        let relay = self.options.relay_url.as_deref().unwrap_or(NO_RELAY);
        command
            .arg("--relay-url")
            .arg(relay)
            .arg("--host-credentials")
            .arg("files");
        for (name, value) in &self.options.env {
            command.env(name, value);
        }
        self.child = Some(command.spawn().expect("start axod"));
        self.wait_for_socket();
    }

    fn wait_for_socket(&mut self) {
        let deadline = Instant::now() + READY_WAIT;
        loop {
            if UnixStream::connect(self.socket()).is_ok() {
                return;
            }
            if let Some(status) = self
                .child
                .as_mut()
                .and_then(|child| child.try_wait().ok().flatten())
            {
                panic!(
                    "axod exited before listening, with {status}:\n{}",
                    self.log()
                );
            }
            assert!(
                Instant::now() < deadline,
                "axod did not listen:\n{}",
                self.log()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// Stops axod as launchd would (SIGTERM, then SIGKILL after 5 s).
    pub fn stop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        if child.try_wait().ok().flatten().is_some() {
            return;
        }
        // SAFETY: signals only the axod this harness started.
        unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if child.try_wait().ok().flatten().is_some() {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = child.kill();
        let _ = child.wait();
    }

    /// Kills axod outright, as a crash would: nothing runs on the way out.
    pub fn crash(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Stops axod and starts it again on the same directory.
    pub fn restart(&mut self) {
        self.stop();
        self.launch();
    }

    /// Whether axod is still running.
    pub fn running(&mut self) -> bool {
        self.child
            .as_mut()
            .is_some_and(|child| child.try_wait().ok().flatten().is_none())
    }

    pub fn call(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        call(&self.socket(), method, params).unwrap_or_else(|error| {
            panic!(
                "{method} did not answer: {error}\naxod log:\n{}",
                self.log()
            )
        })
    }

    /// The result of a call that must succeed.
    #[track_caller]
    pub fn ok(&self, method: &str, params: Value) -> Value {
        match self.call(method, params.clone()) {
            Ok(result) => result,
            Err(error) => panic!(
                "{method}({params}) failed: {error:?}\naxod log:\n{}",
                self.log()
            ),
        }
    }

    /// The error of a call that must fail.
    #[track_caller]
    pub fn err(&self, method: &str, params: Value) -> RpcError {
        match self.call(method, params.clone()) {
            Ok(result) => panic!("{method}({params}) should have failed, but answered {result}"),
            Err(error) => error,
        }
    }

    pub fn subscribe(&self, params: Value) -> Events<'_> {
        let subscribed = self.ok("axo.session.subscribe", params);
        Events {
            axod: self,
            id: subscribed["subscriptionId"]
                .as_str()
                .expect("a subscription id")
                .to_owned(),
            seen: Vec::new(),
        }
    }

    /// The open Sessions, as `axo.session.list` reports them.
    pub fn sessions(&self) -> Vec<Value> {
        self.ok("axo.session.list", json!({}))["sessions"]
            .as_array()
            .unwrap()
            .clone()
    }

    /// Waits until `check` returns something, polling every 20 ms.
    #[track_caller]
    pub fn wait_for<T>(&self, what: &str, mut check: impl FnMut() -> Option<T>) -> T {
        let deadline = Instant::now() + READY_WAIT;
        loop {
            if let Some(found) = check() {
                return found;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}\naxod log:\n{}",
                self.log()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// A new Session in the home Workspace, as listed once its Pi has bound the bridge.
    pub fn new_session(&self) -> Value {
        let session = self.ok("axo.session.create", json!({}));
        self.wait_for_pi(&session)
    }

    /// Waits until the Session's Pi pane is bound to a live Pi, and returns the Session.
    pub fn wait_for_pi(&self, session: &Value) -> Value {
        let id = session["id"].clone();
        self.wait_for("Pi to bind its bridge", || {
            // Pi's hello names its own session: axod records it once the bridge is bound.
            self.sessions()
                .into_iter()
                .find(|listed| listed["id"] == id)
                .filter(|listed| listed["piSessionId"].is_string())
        })
    }
}

impl Drop for Axod {
    fn drop(&mut self) {
        self.stop();
        if std::env::var_os("AXO_KEEP_TEST_DIRECTORIES").is_none() && !thread::panicking() {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }
}

/// One JSON-RPC call on its own connection.
pub fn call(
    socket: &Path,
    method: &str,
    params: Value,
) -> std::io::Result<Result<Value, RpcError>> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;
    writeln!(
        stream,
        "{}",
        json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params })
    )?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    let response: Value = serde_json::from_str(&line)
        .map_err(|error| std::io::Error::other(format!("not JSON ({error}): {line:?}")))?;
    Ok(match response.get("error") {
        Some(error) => Err(RpcError {
            code: error["code"].as_i64().unwrap_or_default(),
            message: error["message"].as_str().unwrap_or_default().to_owned(),
            data: error.get("data").cloned().unwrap_or(Value::Null),
        }),
        None => Ok(response["result"].clone()),
    })
}

/// A subscription to axod's events.
pub struct Events<'a> {
    axod: &'a Axod,
    pub id: String,
    /// Every event received so far, in order.
    pub seen: Vec<Value>,
}

impl Events<'_> {
    /// The next batch, waiting up to `timeout_ms`.
    pub fn next(&mut self, timeout_ms: u64) -> Vec<Value> {
        let batch = self.axod.ok(
            "axo.session.events.next",
            json!({ "subscriptionId": self.id, "timeoutMs": timeout_ms, "maxEvents": 256 }),
        );
        let events = batch["events"].as_array().cloned().unwrap_or_default();
        self.seen.extend(events.iter().cloned());
        events
    }

    /// Waits for an event `matches` picks, and returns what it picked.
    #[track_caller]
    pub fn wait_for<T>(&mut self, what: &str, mut matches: impl FnMut(&Value) -> Option<T>) -> T {
        let deadline = Instant::now() + READY_WAIT;
        loop {
            for event in self.next(500) {
                if let Some(found) = matches(&event) {
                    return found;
                }
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}; saw {} events: {}\naxod log:\n{}",
                self.seen.len(),
                self.seen
                    .iter()
                    .map(|event| event["type"].to_string())
                    .collect::<Vec<_>>()
                    .join(", "),
                self.axod.log()
            );
        }
    }

    /// Waits for an event of `kind`.
    #[track_caller]
    pub fn wait_for_type(&mut self, kind: &str) -> Value {
        self.wait_for(kind, |event| (event["type"] == kind).then(|| event.clone()))
    }
}

impl Drop for Events<'_> {
    fn drop(&mut self) {
        let _ = call(
            &self.axod.socket(),
            "axo.session.unsubscribe",
            json!({ "subscriptionId": self.id }),
        );
    }
}

/// A Session's pane with `role` (`pi` or `terminal`).
#[track_caller]
pub fn pane<'a>(session: &'a Value, role: &str) -> &'a Value {
    session["shells"]
        .as_array()
        .unwrap()
        .iter()
        .find(|shell| shell["role"] == role)
        .unwrap_or_else(|| panic!("the Session has no {role} pane: {session}"))
}

/// `axod mcp` for one Session, as Pi runs it: MCP over its stdin and stdout.
pub struct Mcp {
    child: Child,
    /// `None` once closed.
    input: Option<std::process::ChildStdin>,
    responses: std::sync::mpsc::Receiver<Value>,
    next_id: u64,
}

impl Mcp {
    /// Starts `axod mcp` for `session_id` and initializes it.
    pub fn start(axod: &Axod, session_id: &str) -> Self {
        let mut child = Command::new(axod_binary())
            .arg("mcp")
            .env("HOME", axod.home())
            .env("AXO_SOCKET", axod.socket())
            .env("AXO_SESSION_ID", session_id)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("start axod mcp");
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        let (sender, responses) = std::sync::mpsc::channel();
        thread::spawn(move || {
            for line in output.lines() {
                let Ok(line) = line else { return };
                if let Ok(message) = serde_json::from_str::<Value>(&line) {
                    if sender.send(message).is_err() {
                        return;
                    }
                }
            }
        });
        let mut mcp = Self {
            child,
            input: Some(input),
            responses,
            next_id: 0,
        };
        let initialized = mcp.request(
            "initialize",
            json!({ "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": { "name": "conformance", "version": "1" } }),
        );
        assert!(
            initialized["result"]["serverInfo"].is_object(),
            "{initialized}"
        );
        mcp.notify("notifications/initialized", json!({}));
        mcp
    }

    pub fn notify(&mut self, method: &str, params: Value) {
        writeln!(
            self.stdin(),
            "{}",
            json!({ "jsonrpc": "2.0", "method": method, "params": params })
        )
        .unwrap();
    }

    /// Sends a request and returns its id without waiting.
    pub fn send(&mut self, method: &str, params: Value) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        writeln!(
            self.stdin(),
            "{}",
            json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
        )
        .unwrap();
        self.next_id
    }

    /// The response to request `id`; responses to others that arrive first are dropped.
    pub fn response(&mut self, id: u64) -> Value {
        let deadline = Instant::now() + READY_WAIT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.responses.recv_timeout(left) {
                Ok(message) if message["id"] == id => return message,
                Ok(_) => continue,
                Err(_) => panic!("axod mcp did not answer request {id}"),
            }
        }
    }

    pub fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        self.response(id)
    }

    /// Calls a tool without waiting for its answer; returns the request's id.
    pub fn send_tool(&mut self, name: &str, arguments: Value) -> u64 {
        self.send(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        )
    }

    /// The names of the tools it offers.
    pub fn tools(&mut self) -> Vec<String> {
        let listed = self.request("tools/list", json!({}));
        listed["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|tool| tool["name"].as_str().unwrap().to_owned())
            .collect()
    }

    /// Calls a tool; the MCP result (`content`, `structuredContent`, `isError`).
    pub fn tool(&mut self, name: &str, arguments: Value) -> Value {
        let response = self.request(
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        );
        assert!(
            response.get("error").is_none(),
            "{name} failed as a request: {response}"
        );
        response["result"].clone()
    }

    /// Calls a tool that must succeed, and returns its structured content.
    #[track_caller]
    pub fn ok(&mut self, name: &str, arguments: Value) -> Value {
        let result = self.tool(name, arguments.clone());
        assert_ne!(result["isError"], true, "{name}({arguments}): {result}");
        result["structuredContent"].clone()
    }

    /// Calls a tool that must fail, and returns its message.
    #[track_caller]
    pub fn err(&mut self, name: &str, arguments: Value) -> String {
        let result = self.tool(name, arguments.clone());
        assert_eq!(
            result["isError"], true,
            "{name}({arguments}) should have failed: {result}"
        );
        result["content"][0]["text"]
            .as_str()
            .unwrap_or_default()
            .to_owned()
    }

    fn stdin(&mut self) -> &mut std::process::ChildStdin {
        self.input.as_mut().expect("axod mcp's stdin is open")
    }

    /// Closes its stdin, as Pi does on exit, and waits for it to exit.
    pub fn close(mut self) -> std::process::ExitStatus {
        self.input = None;
        let deadline = Instant::now() + READY_WAIT;
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "axod mcp did not exit after its stdin closed"
            );
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Mcp {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
