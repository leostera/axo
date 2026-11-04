//! Local decisions: asks a local model, such as Clef, typed questions about a state and gets a
//! probability for every option, over llama.cpp's `POST /v1/systemone` on a Unix socket.
//!
//! The model runs in `axo-decide`, our pinned `llama-server` build next to axod in
//! `Axo.app/Contents/Helpers`, as a side-car: a crash in Metal or the model cannot take axod and
//! its Sessions down. Whichever process first needs it starts it, detached, holding an exclusive
//! lock on `decide.lock`; the lock lives exactly as long as the side-car, so there is never more
//! than one, and a crashed one is started again on the next question. The side-car unloads the
//! model after ten idle minutes (`--sleep-idle-seconds`) and loads it again on demand.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

/// The model files the side-car loads, in the models directory.
pub const MODEL_FILE: &str = "Clef-Flash-Q4_K_M.gguf";
pub const VISION_FILE: &str = "mmproj-Clef-Flash-Q8_0.gguf";

/// How long a cold start may take: the model loads in about 12 s on an M4 Pro.
const START_TIMEOUT: Duration = Duration::from_secs(90);
/// One question, including a reload after the model slept.
const ASK_TIMEOUT: Duration = Duration::from_secs(60);
const IDLE_SECONDS: &str = "600";

/// Where the side-car, its model and its socket live.
#[derive(Clone, Debug)]
pub struct Decide {
    /// The `axo-decide` executable.
    pub helper: PathBuf,
    /// Holds [`MODEL_FILE`] and [`VISION_FILE`].
    pub models: PathBuf,
    /// Holds `decide.sock`, `decide.lock` and `decide.log`.
    pub run: PathBuf,
}

#[derive(Debug)]
pub enum DecideError {
    /// The helper or the model files are missing, so local checks are off.
    Unavailable(String),
    /// The side-car did not start or did not answer.
    Failed(String),
}

impl std::fmt::Display for DecideError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(why) => write!(f, "local checks are unavailable: {why}"),
            Self::Failed(why) => write!(f, "the local model failed: {why}"),
        }
    }
}

impl Decide {
    /// The side-car next to this executable, Axo's models directory and axod's run directory.
    pub fn beside_current_exe(run: &Path) -> Option<Self> {
        let exe = std::env::current_exe().ok()?;
        let home = std::env::var_os("HOME")?;
        Some(Self {
            helper: exe.parent()?.join("axo-decide"),
            models: PathBuf::from(home).join("Library/Application Support/Axo/models/clef-flash"),
            run: run.to_path_buf(),
        })
    }

    pub fn socket(&self) -> PathBuf {
        self.run.join("decide.sock")
    }

    /// Whether the helper and the model files are on disk.
    pub fn installed(&self) -> Result<(), DecideError> {
        for path in [
            self.helper.clone(),
            self.models.join(MODEL_FILE),
            self.models.join(VISION_FILE),
        ] {
            if !path.exists() {
                return Err(DecideError::Unavailable(format!(
                    "{} is missing",
                    path.display()
                )));
            }
        }
        Ok(())
    }

    /// Asks a `systemone` request (`{ state, images?, questions }`) and returns its `answers`:
    /// for each question, `{ type, <type>: probability or choice probabilities }`.
    pub fn ask(&self, request: &Value) -> Result<Value, DecideError> {
        self.installed()?;
        self.ensure_running()?;
        let body = serde_json::to_vec(request).map_err(|e| DecideError::Failed(e.to_string()))?;
        let reply = http(&self.socket(), "POST", "/v1/systemone", &body, ASK_TIMEOUT)
            .map_err(|e| DecideError::Failed(e.to_string()))?;
        if reply.status != 200 {
            return Err(DecideError::Failed(format!(
                "status {}: {}",
                reply.status,
                String::from_utf8_lossy(&reply.body)
                    .chars()
                    .take(300)
                    .collect::<String>()
            )));
        }
        let reply: Value =
            serde_json::from_slice(&reply.body).map_err(|e| DecideError::Failed(e.to_string()))?;
        Ok(reply["answers"].clone())
    }

    /// Starts the side-car unless one is running, and waits until it answers.
    fn ensure_running(&self) -> Result<(), DecideError> {
        if self.healthy() {
            return Ok(());
        }
        std::fs::create_dir_all(&self.run).map_err(|e| DecideError::Failed(e.to_string()))?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.run.join("decide.lock"))
            .map_err(|e| DecideError::Failed(e.to_string()))?;
        if try_lock(&lock) {
            self.start(lock)?;
        }
        // Started here or by another process: wait for it either way.
        let deadline = Instant::now() + START_TIMEOUT;
        while Instant::now() < deadline {
            if self.healthy() {
                return Ok(());
            }
            if self.died_without_lock() {
                return Err(DecideError::Failed(format!(
                    "axo-decide exited; see {}",
                    self.run.join("decide.log").display()
                )));
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        Err(DecideError::Failed(
            "axo-decide did not start in time".into(),
        ))
    }

    /// Nobody holds the lock, so no side-car is running or starting.
    fn died_without_lock(&self) -> bool {
        OpenOptions::new()
            .write(true)
            .open(self.run.join("decide.lock"))
            .map(|file| try_lock(&file))
            .unwrap_or(true)
    }

    fn healthy(&self) -> bool {
        http(
            &self.socket(),
            "GET",
            "/health",
            &[],
            Duration::from_secs(2),
        )
        .is_ok_and(|reply| reply.status == 200)
    }

    /// Spawns the side-car in its own session, handing it the locked file so the lock lasts as
    /// long as it does.
    fn start(&self, lock: File) -> Result<(), DecideError> {
        let socket = self.socket();
        let _ = std::fs::remove_file(&socket);
        let log = File::create(self.run.join("decide.log"))
            .map_err(|e| DecideError::Failed(e.to_string()))?;
        let lock_fd = lock.as_raw_fd();
        let mut command = Command::new(&self.helper);
        command
            .arg("--model")
            .arg(self.models.join(MODEL_FILE))
            .arg("--mmproj")
            .arg(self.models.join(VISION_FILE))
            .arg("--host")
            .arg(&socket)
            .args(["--ctx-size", "8192", "--parallel", "1", "--no-webui"])
            .args(["--sleep-idle-seconds", IDLE_SECONDS])
            .stdin(Stdio::null())
            .stdout(
                log.try_clone()
                    .map_err(|e| DecideError::Failed(e.to_string()))?,
            )
            .stderr(log);
        // SAFETY: between fork and exec this only calls async-signal-safe functions.
        unsafe {
            command.pre_exec(move || {
                if libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                // Keep the locked file open across exec.
                let flags = libc::fcntl(lock_fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(lock_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command
            .spawn()
            .map_err(|e| DecideError::Failed(format!("could not start axo-decide: {e}")))?;
        log::info!("event=decide.started pid={}", child.id());
        // The child holds the lock now; closing ours does not release it.
        drop(lock);
        Ok(())
    }
}

fn try_lock(file: &File) -> bool {
    // SAFETY: flock on a file descriptor we own.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

struct Reply {
    status: u16,
    body: Vec<u8>,
}

/// One HTTP/1.1 request over a Unix socket; the server closes the connection after it.
fn http(
    socket: &Path,
    method: &str,
    path: &str,
    body: &[u8],
    timeout: Duration,
) -> io::Result<Reply> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: axo-decide\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body)?;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw)?;
    parse_reply(&raw)
}

fn parse_reply(raw: &[u8]) -> io::Result<Reply> {
    let invalid = |why: &str| io::Error::new(io::ErrorKind::InvalidData, why.to_string());
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or_else(|| invalid("no end of headers"))?;
    let head = std::str::from_utf8(&raw[..split]).map_err(|_| invalid("headers are not UTF-8"))?;
    let status = head
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse().ok())
        .ok_or_else(|| invalid("no status"))?;
    let mut body = raw[split + 4..].to_vec();
    let chunked = head.lines().any(|line| {
        let line = line.to_ascii_lowercase();
        line.starts_with("transfer-encoding:") && line.contains("chunked")
    });
    if chunked {
        body = dechunk(&body).ok_or_else(|| invalid("bad chunked body"))?;
    }
    Ok(Reply { status, body })
}

fn dechunk(mut data: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let line_end = data.windows(2).position(|w| w == b"\r\n")?;
        let size_text = std::str::from_utf8(&data[..line_end]).ok()?;
        let size = usize::from_str_radix(size_text.split(';').next()?.trim(), 16).ok()?;
        data = &data[line_end + 2..];
        if size == 0 {
            return Some(out);
        }
        out.extend_from_slice(data.get(..size)?);
        data = data.get(size + 2..)?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_plain_and_chunked_replies() {
        let plain = parse_reply(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}").unwrap();
        assert_eq!(
            (plain.status, plain.body.as_slice()),
            (200, b"{}".as_slice())
        );
        let chunked = parse_reply(
            b"HTTP/1.1 503 Service Unavailable\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n",
        )
        .unwrap();
        assert_eq!(chunked.status, 503);
        assert_eq!(chunked.body, b"{\"a\":1}");
    }

    #[test]
    fn missing_model_files_turn_local_checks_off() {
        let dir = std::env::temp_dir().join(format!("axo-decide-test-{}", std::process::id()));
        let decide = Decide {
            helper: dir.join("axo-decide"),
            models: dir.join("models"),
            run: dir.join("run"),
        };
        assert!(matches!(
            decide.ask(&serde_json::json!({})),
            Err(DecideError::Unavailable(_))
        ));
    }

    #[test]
    fn one_lock_holder_at_a_time() {
        let path = std::env::temp_dir().join(format!("axo-decide-lock-{}", std::process::id()));
        let first = File::create(&path).unwrap();
        let second = OpenOptions::new().write(true).open(&path).unwrap();
        assert!(try_lock(&first));
        assert!(!try_lock(&second));
        drop(first);
        assert!(try_lock(&second));
        let _ = std::fs::remove_file(path);
    }
}
