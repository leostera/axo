//! Native Windows process transport for Pi's JSONL RPC mode.
use crate::codex::Job;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

const MAX_FRAME: u64 = 8 * 1024 * 1024;
const REPLY_TIMEOUT: Duration = Duration::from_secs(20);
type Reply = Result<Value, &'static str>;
type Pending = Arc<Mutex<Option<HashMap<u64, mpsc::Sender<Reply>>>>>;

/// Resolved runtime paths. Launch Bun directly, never a shell shim or `bunx`.
pub struct PiRuntime {
    bun: PathBuf,
    cli: PathBuf,
}

impl PiRuntime {
    pub fn resolve(bun: PathBuf, cli: PathBuf) -> io::Result<Self> {
        if [&bun, &cli]
            .iter()
            .any(|p| !p.is_absolute() || !p.is_file())
        {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Pi requires absolute paths to Bun and the installed CLI script",
            ));
        }
        if !bun
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("exe"))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi requires a native Bun executable",
            ));
        }
        Ok(Self { bun, cli })
    }

    pub fn open(
        &self,
        cwd: &Path,
        session: &Path,
        on_event: impl Fn(Value) + Send + 'static,
    ) -> io::Result<PiRpc> {
        if !cwd.is_absolute() || !session.is_absolute() || !session.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Pi requires an absolute working directory and an existing transcript",
            ));
        }
        let mut command = Command::new(&self.bun);
        command
            .arg(&self.cli)
            .args([
                "--mode",
                "rpc",
                "--no-extensions",
                "--no-skills",
                "--no-prompt-templates",
                "--no-themes",
                "--no-context-files",
            ])
            .arg("--session")
            .arg(session)
            .current_dir(cwd);
        let runtime = PiRpc::spawn(command, on_event)?;
        runtime.state()?;
        Ok(runtime)
    }
}

pub struct PiRpc {
    _job: Job,
    child: Child,
    input: Mutex<ChildStdin>,
    pending: Pending,
    next: AtomicU64,
}

impl PiRpc {
    fn spawn(mut command: Command, on_event: impl Fn(Value) + Send + 'static) -> io::Result<Self> {
        let mut child = command
            .creation_flags(0x08000000) // CREATE_NO_WINDOW
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let job = match Job::for_child(&child) {
            Ok(job) => job,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let input = child.stdin.take().expect("piped stdin");
        let output = child.stdout.take().expect("piped stdout");
        let pending = Pending::new(Mutex::new(Some(HashMap::new())));
        let reader_pending = pending.clone();
        std::thread::spawn(move || {
            read_frames(BufReader::new(output), &reader_pending, on_event);
            // Dropping every outstanding sender wakes waiters without replaying anything.
            reader_pending.lock().unwrap().take();
        });
        Ok(Self {
            _job: job,
            child,
            input: Mutex::new(input),
            pending,
            next: AtomicU64::new(1),
        })
    }

    pub fn state(&self) -> io::Result<Value> {
        self.request(json!({"type":"get_state"}))
    }
    pub fn messages(&self) -> io::Result<Value> {
        self.request(json!({"type":"get_messages"}))
    }
    pub fn prompt(&self, message: &str) -> io::Result<Value> {
        self.request(json!({"type":"prompt", "message":message}))
    }
    pub fn abort(&self) -> io::Result<Value> {
        self.request(json!({"type":"abort"}))
    }

    fn request(&self, mut body: Value) -> io::Result<Value> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        body["id"] = json!(id.to_string());
        let (send, receive) = mpsc::channel();
        self.pending
            .lock()
            .unwrap()
            .as_mut()
            .ok_or_else(closed)?
            .insert(id, send);
        let result = (|| {
            writeln!(self.input.lock().unwrap(), "{body}")?;
            receive
                .recv_timeout(REPLY_TIMEOUT)
                .map_err(|error| match error {
                    mpsc::RecvTimeoutError::Timeout => io::Error::new(
                        io::ErrorKind::TimedOut,
                        "Pi did not acknowledge the command; delivery is unknown",
                    ),
                    mpsc::RecvTimeoutError::Disconnected => closed(),
                })?
                .map_err(io::Error::other)
        })();
        if let Some(waiting) = self.pending.lock().unwrap().as_mut() {
            waiting.remove(&id);
        }
        result
    }
}

impl Drop for PiRpc {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn closed() -> io::Error {
    io::Error::new(
        io::ErrorKind::BrokenPipe,
        "Pi disconnected; delivery is unknown",
    )
}

fn read_frames(mut reader: impl BufRead, pending: &Pending, on_event: impl Fn(Value)) {
    loop {
        let mut frame = Vec::new();
        match reader
            .by_ref()
            .take(MAX_FRAME + 1)
            .read_until(b'\n', &mut frame)
        {
            Ok(n) if n > 0 && (n as u64) <= MAX_FRAME && frame.ends_with(b"\n") => {}
            _ => break,
        }
        let Ok(message) = serde_json::from_slice::<Value>(&frame) else {
            break;
        };
        if message["type"] == "response" {
            let Some(id) = message["id"].as_str().and_then(|id| id.parse().ok()) else {
                continue;
            };
            if let Some(reply) = pending
                .lock()
                .unwrap()
                .as_mut()
                .and_then(|waiting| waiting.remove(&id))
            {
                let result = if message["success"] == true {
                    Ok(message["data"].clone())
                } else {
                    Err("Pi rejected the command")
                };
                let _ = reply.send(result);
            }
        } else {
            on_event(message);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn real_pi_import_is_idle_and_preserves_hidden_context() {
        let (Some(bun), Some(cli), Some(root)) = (
            std::env::var_os("AXO_TEST_PI_BUN"),
            std::env::var_os("AXO_TEST_PI_CLI"),
            std::env::var_os("PI_CODING_AGENT_DIR").map(PathBuf::from),
        ) else {
            eprintln!(
                "Real Pi import not exercised: set AXO_TEST_PI_BUN, AXO_TEST_PI_CLI and isolated PI_CODING_AGENT_DIR"
            );
            return;
        };
        let root = root.join(axo_protocol::new_uuid_v4().unwrap());
        std::fs::create_dir_all(&root).unwrap();
        let folder = root.join("destination ž");
        std::fs::create_dir(&folder).unwrap();
        let source = root.join("source.jsonl");
        let child = root.join("child.jsonl");
        let timestamp = "2026-11-21T00:00:00.000Z";
        let history = [
            json!({"type":"session", "version":3, "id":axo_protocol::new_uuid_v4().unwrap(), "timestamp":timestamp, "cwd":"/source/project"}),
            json!({"type":"message", "id":"abc", "parentId":null, "timestamp":timestamp,
                   "message":{"role":"user","content":[{"type":"text","text":"history marker"}],"timestamp":1795219200000i64}}),
            json!({"type":"custom","id":"def","parentId":"abc","timestamp":timestamp,
                   "customType":"axo.command.queued","data":{"text":"never replay me"}}),
        ].map(|entry| entry.to_string());
        let source_text = history.join("\n") + "\n";
        std::fs::write(&source, &source_text).unwrap();
        let snapshot = crate::PiForkHistory::parse(history.to_vec()).unwrap();
        let child_id = axo_protocol::SessionId::new_v4().unwrap();
        let contents = snapshot
            .into_child(
                child_id,
                &folder,
                "source-host",
                "destination-host",
                timestamp,
            )
            .unwrap();
        assert!(!String::from_utf8_lossy(&contents).contains("never replay me"));
        std::fs::write(&child, &contents).unwrap();

        let runtime = PiRuntime::resolve(bun.into(), cli.into()).unwrap();
        let (send, events) = mpsc::channel();
        let pi = runtime
            .open(&folder, &child, move |event| {
                let _ = send.send(event);
            })
            .unwrap();
        let state = pi.state().unwrap();
        assert_eq!(state["sessionId"], json!(child_id));
        assert_eq!(state["isStreaming"], false);
        assert_eq!(state["pendingMessageCount"], 0);
        let messages = pi.messages().unwrap();
        let messages = messages["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["role"], "user");
        assert_eq!(messages[0]["content"][0]["text"], "history marker");
        assert_eq!(messages[1]["role"], "custom");
        assert_eq!(messages[1]["display"], false);
        assert!(
            messages[1]["content"]
                .as_str()
                .unwrap()
                .contains("source-host")
        );
        assert!(
            messages[1]["content"]
                .as_str()
                .unwrap()
                .contains("destination-host")
        );
        assert!(!events.try_iter().any(|event| matches!(
            event["type"].as_str(),
            Some("agent_start" | "tool_execution_start")
        )));
        drop(pi);
        assert_eq!(std::fs::read_to_string(source).unwrap(), source_text);
        assert_eq!(std::fs::read(child).unwrap(), contents);
    }

    #[test]
    fn responses_are_correlated_without_swallowing_events() {
        let (send, receive) = mpsc::channel();
        let pending = Pending::new(Mutex::new(Some(HashMap::from([(1, send)]))));
        let events = std::cell::RefCell::new(Vec::new());
        read_frames(&b"{\"type\":\"response\",\"id\":\"2\",\"success\":false}\n{\"type\":\"agent_settled\"}\r\n{\"type\":\"response\",\"id\":\"1\",\"success\":true,\"data\":123}\n"[..], &pending, |event| events.borrow_mut().push(event));
        assert_eq!(receive.try_recv().unwrap(), Ok(json!(123)));
        assert_eq!(events.into_inner(), [json!({"type":"agent_settled"})]);
    }
}
