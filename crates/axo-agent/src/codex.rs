//! Codex CLI's app-server transport. Owns the child and JSON-RPC connection, not the catalog.
//!
//! See https://learn.chatgpt.com/docs/app-server. No credentials are read or copied by Axo:
//! the CLI uses its own sign-in. Server requests are surfaced to the caller for a decision.
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

const MAX_FRAME: u64 = 8 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
type Reply = Result<Value, String>;
type Pending = Arc<Mutex<HashMap<u64, mpsc::SyncSender<Reply>>>>;

pub struct Codex {
    #[cfg(windows)]
    _job: Job,
    child: Mutex<Child>,
    input: Arc<Mutex<ChildStdin>>,
    pending: Pending,
    next_id: AtomicU64,
    alive: Arc<AtomicBool>,
}

impl Codex {
    pub fn spawn(
        executable: &Path,
        cwd: &Path,
        on_event: impl Fn(Value) + Send + Sync + 'static,
    ) -> io::Result<Self> {
        Self::spawn_with_config(executable, cwd, &[], on_event)
    }

    /// Per-child overrides; never edits the person's global Codex configuration.
    pub fn spawn_with_config(
        executable: &Path,
        cwd: &Path,
        config: &[String],
        on_event: impl Fn(Value) + Send + Sync + 'static,
    ) -> io::Result<Self> {
        let mut command = Command::new(executable);
        for setting in config {
            command.arg("-c").arg(setting);
        }
        command
            .args(["app-server", "--listen", "stdio://"])
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        let mut child = command.spawn().map_err(|e| {
            io::Error::new(
                e.kind(),
                format!(
                    "Could not start {}: {e}. Install Codex CLI or set AXO_CODEX.",
                    executable.display()
                ),
            )
        })?;
        #[cfg(windows)]
        let job = match Job::for_child(&child) {
            Ok(job) => job,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };
        let input = Arc::new(Mutex::new(child.stdin.take().unwrap()));
        let output = child.stdout.take().unwrap();
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));
        let callback = Arc::new(on_event);
        let reader_pending = pending.clone();
        let reader_alive = alive.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let mut line = String::new();
                // Bound each frame without bounding the lifetime of the connection.
                use std::io::Read;
                match reader.by_ref().take(MAX_FRAME + 1).read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) if line.len() as u64 > MAX_FRAME => break,
                    Ok(_) => {}
                }
                let message: Value = match serde_json::from_str(&line) {
                    Ok(message) => message,
                    Err(_) => continue,
                };
                if message.get("method").is_none() {
                    if let Some(id) = message["id"].as_u64() {
                        if let Some(reply) = reader_pending.lock().unwrap().remove(&id) {
                            let result = if let Some(error) = message.get("error") {
                                Err(error["message"]
                                    .as_str()
                                    .unwrap_or("Codex request failed")
                                    .to_owned())
                            } else {
                                Ok(message["result"].clone())
                            };
                            let _ = reply.send(result);
                        }
                    }
                } else {
                    callback(message);
                }
            }
            reader_alive.store(false, Ordering::Release);
            for (_, reply) in reader_pending.lock().unwrap().drain() {
                let _ = reply.send(Err(
                    "Codex app-server exited. Reopen this session to reconnect.".into(),
                ));
            }
            callback(json!({"method":"axo/codex/exited","params":{}}));
        });
        let codex = Self {
            #[cfg(windows)]
            _job: job,
            child: Mutex::new(child),
            input,
            pending,
            next_id: AtomicU64::new(1),
            alive,
        };
        codex.request(
            "initialize",
            json!({"clientInfo": {
                "name":"axo_windows", "title":"Axo", "version":env!("CARGO_PKG_VERSION")
            }}),
        )?;
        codex.notify("initialized", json!({}))?;
        Ok(codex)
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    pub fn process_id(&self) -> u32 {
        self.child.lock().unwrap().id()
    }

    pub fn request(&self, method: &str, params: Value) -> io::Result<Value> {
        if !self.is_alive() {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "Codex app-server is not running",
            ));
        }
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::sync_channel(1);
        self.pending.lock().unwrap().insert(id, tx);
        if let Err(error) = self.write(json!({"id":id,"method":method,"params":params})) {
            self.pending.lock().unwrap().remove(&id);
            return Err(error);
        }
        let result = rx.recv_timeout(REQUEST_TIMEOUT);
        self.pending.lock().unwrap().remove(&id);
        result
            .map_err(|_| {
                io::Error::new(io::ErrorKind::TimedOut, format!("Codex {method} timed out"))
            })?
            .map_err(io::Error::other)
    }

    pub fn notify(&self, method: &str, params: Value) -> io::Result<()> {
        self.write(json!({"method":method,"params":params}))
    }

    pub fn respond(&self, id: Value, result: Value) -> io::Result<()> {
        self.write(json!({"id":id,"result":result}))
    }

    pub fn reject_request(&self, id: Value, message: &str) -> io::Result<()> {
        self.write(json!({"id":id,"error":{"code":-32601,"message":message}}))
    }

    fn write(&self, value: Value) -> io::Result<()> {
        let mut input = self.input.lock().unwrap();
        serde_json::to_writer(&mut *input, &value)?;
        input.write_all(b"\n")?;
        input.flush()
    }

    pub fn stop(&self) {
        self.alive.store(false, Ordering::Release);
        let mut child = self.child.lock().unwrap();
        let _ = child.kill();
        let _ = child.wait();
    }
}

impl Drop for Codex {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Every app-server and its descendants are terminated if axod exits unexpectedly. The job
/// handle is not inherited; Windows closes it even when axod is killed or the user signs out.
#[cfg(windows)]
struct Job(windows_sys::Win32::Foundation::HANDLE);
#[cfg(windows)]
unsafe impl Send for Job {}
#[cfg(windows)]
unsafe impl Sync for Job {}
#[cfg(windows)]
impl Job {
    fn for_child(child: &Child) -> io::Result<Self> {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::System::JobObjects::*;
        unsafe {
            let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if handle.is_null() {
                return Err(io::Error::last_os_error());
            }
            let job = Self(handle);
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of_val(&info) as u32,
            ) == 0
                || AssignProcessToJobObject(handle, child.as_raw_handle()) == 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(job)
        }
    }
}
#[cfg(windows)]
impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

/// Stable event classification shared by the catalog backend and its tests.
pub fn message_text(item: &Value) -> Option<(&'static str, String)> {
    match item["type"].as_str()? {
        "agentMessage" => Some(("assistant", item["text"].as_str()?.to_owned())),
        "userMessage" => {
            let text = item["content"]
                .as_array()?
                .iter()
                .filter(|part| part["type"] == "text")
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n");
            Some(("user", text))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn history_keeps_user_and_assistant_content_and_ignores_tool_items() {
        assert_eq!(
            message_text(&json!({"type":"agentMessage","text":"hello"})),
            Some(("assistant", "hello".into()))
        );
        assert_eq!(
            message_text(
                &json!({"type":"userMessage","content":[{"type":"text","text":"a"},{"type":"image","url":"x"},{"type":"text","text":"b"}]})
            ),
            Some(("user", "a\nb".into()))
        );
        assert_eq!(
            message_text(&json!({"type":"commandExecution","command":"pwd"})),
            None
        );
    }
}
