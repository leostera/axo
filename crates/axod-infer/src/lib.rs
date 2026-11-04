//! Local inference: axod's side-car for running models on this Mac. Its first model is Clef,
//! asked typed questions about a state over llama.cpp's `POST /v1/systemone` on a Unix socket,
//! returning a probability for every option. Other models (speech, for one) are meant to join it.
//!
//! The model runs in `axod-infer`, our pinned `llama-server` build next to axod in
//! `Axo.app/Contents/Helpers`, as a side-car: a crash in Metal or the model cannot take axod and
//! its Sessions down. Whichever process first needs it starts it, detached, holding an exclusive
//! lock on `infer.lock`; the lock lives exactly as long as the side-car, so there is never more
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

/// Where the model files come from: ggml-org/Clef-Flash-GGUF (Apache-2.0) at a pinned revision,
/// each checked against its SHA-256 before use. The small one first.
const MODEL_SOURCE: &str = "https://huggingface.co/ggml-org/Clef-Flash-GGUF/resolve/a5a18a6e13bb36573a5f11385a1e7b9a0c868e9e";
const MODEL_FILES: &[(&str, &str)] = &[
    (
        VISION_FILE,
        "9dd8bc279f57d33b0697d4d0fe900fe751a24c9e3d30ab90969d4714ffc0722d",
    ),
    (
        MODEL_FILE,
        "eef2968c238a80d49d340430f22410ea3db9934ad1c6fdb233a503cbf9a9b54e",
    ),
];
/// The model holds about 7 GB while loaded; macOS lets the GPU use about 70% of RAM.
const MINIMUM_RAM: u64 = 16 << 30;
/// The 7.4 GB of files, and room to spare.
const MINIMUM_FREE_DISK: u64 = 10 << 30;

/// Downloads the files one by one into `.part`, checks each, and only then renames it; exits
/// non-zero on the first failure. `curl -C -` resumes a download a previous attempt left.
const DOWNLOAD_SCRIPT: &str = r#"set -eu
cd "$1"; shift
while [ $# -gt 0 ]; do
  file=$1 sha=$2 url=$3; shift 3
  [ -f "$file" ] && continue
  /usr/bin/curl -fL --retry 3 --silent --show-error -C - -o "$file.part" "$url"
  echo "$sha  $file.part" | /usr/bin/shasum -a 256 -c - >/dev/null || { rm -f "$file.part"; echo "$file: checksum mismatch" >&2; exit 1; }
  mv "$file.part" "$file"
  echo "event=infer.model_downloaded file=$file"
done
"#;

/// How long a cold start may take: the model loads in about 12 s on an M4 Pro.
const START_TIMEOUT: Duration = Duration::from_secs(90);
/// One question, including a reload after the model slept.
const ASK_TIMEOUT: Duration = Duration::from_secs(60);
const IDLE_SECONDS: &str = "600";

/// Where the side-car, its model and its socket live.
#[derive(Clone, Debug)]
pub struct Infer {
    /// The `axod-infer` executable.
    pub helper: PathBuf,
    /// Holds [`MODEL_FILE`] and [`VISION_FILE`].
    pub models: PathBuf,
    /// Holds `infer.sock`, `infer.lock` and `infer.log`.
    pub run: PathBuf,
}

#[derive(Debug)]
pub enum InferError {
    /// The helper or the model files are missing, so local checks are off.
    Unavailable(String),
    /// The side-car did not start or did not answer.
    Failed(String),
}

impl std::fmt::Display for InferError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(why) => write!(f, "local checks are unavailable: {why}"),
            Self::Failed(why) => write!(f, "the local model failed: {why}"),
        }
    }
}

impl Infer {
    /// The side-car next to this executable, Axo's models directory and axod's run directory.
    pub fn beside_current_exe(run: &Path) -> Option<Self> {
        let exe = std::env::current_exe().ok()?;
        let home = std::env::var_os("HOME")?;
        Some(Self {
            helper: exe.parent()?.join("axod-infer"),
            models: PathBuf::from(home).join("Library/Application Support/Axo/models/clef-flash"),
            run: run.to_path_buf(),
        })
    }

    pub fn socket(&self) -> PathBuf {
        self.run.join("infer.sock")
    }

    /// Whether the helper and the model files are on disk.
    pub fn installed(&self) -> Result<(), InferError> {
        for path in [
            self.helper.clone(),
            self.models.join(MODEL_FILE),
            self.models.join(VISION_FILE),
        ] {
            if !path.exists() {
                return Err(InferError::Unavailable(format!(
                    "{} is missing",
                    path.display()
                )));
            }
        }
        Ok(())
    }

    /// Starts downloading the model files in the background, unless they are there, one
    /// download is already running, or this Mac lacks the memory or disk for them. Returns why
    /// not when it did not start one.
    pub fn install_in_background(&self) -> Result<(), String> {
        if self.models.join(MODEL_FILE).exists() && self.models.join(VISION_FILE).exists() {
            return Err("already installed".into());
        }
        let ram = physical_memory();
        if ram < MINIMUM_RAM {
            return Err(format!(
                "this Mac has {} GB of memory; Clef needs 16",
                ram >> 30
            ));
        }
        std::fs::create_dir_all(&self.models).map_err(|e| e.to_string())?;
        let free = free_disk(&self.models);
        if free < MINIMUM_FREE_DISK {
            return Err(format!(
                "only {} GB of disk is free; Clef needs 10",
                free >> 30
            ));
        }
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.models.join(".download.lock"))
            .map_err(|e| e.to_string())?;
        if !try_lock(&lock) {
            return Err("a download is already running".into());
        }
        let log = File::create(self.models.join("download.log")).map_err(|e| e.to_string())?;
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(DOWNLOAD_SCRIPT)
            .arg("sh")
            .arg(&self.models);
        for (file, sha) in MODEL_FILES {
            command.args([*file, *sha, &format!("{MODEL_SOURCE}/{file}")]);
        }
        command
            .stdin(Stdio::null())
            .stdout(log.try_clone().map_err(|e| e.to_string())?)
            .stderr(log);
        detach_holding(&mut command, lock.as_raw_fd());
        let child = command.spawn().map_err(|e| e.to_string())?;
        log::info!("event=infer.model_download_started pid={}", child.id());
        Ok(())
    }

    /// Asks a `systemone` request (`{ state, images?, questions }`) and returns its `answers`:
    /// for each question, `{ type, <type>: probability or choice probabilities }`.
    pub fn ask(&self, request: &Value) -> Result<Value, InferError> {
        self.installed()?;
        self.ensure_running()?;
        let body = serde_json::to_vec(request).map_err(|e| InferError::Failed(e.to_string()))?;
        let reply = http(&self.socket(), "POST", "/v1/systemone", &body, ASK_TIMEOUT)
            .map_err(|e| InferError::Failed(e.to_string()))?;
        if reply.status != 200 {
            return Err(InferError::Failed(format!(
                "status {}: {}",
                reply.status,
                String::from_utf8_lossy(&reply.body)
                    .chars()
                    .take(300)
                    .collect::<String>()
            )));
        }
        let reply: Value =
            serde_json::from_slice(&reply.body).map_err(|e| InferError::Failed(e.to_string()))?;
        Ok(reply["answers"].clone())
    }

    /// Starts the side-car unless one is running, and waits until it answers.
    fn ensure_running(&self) -> Result<(), InferError> {
        if self.healthy() {
            return Ok(());
        }
        std::fs::create_dir_all(&self.run).map_err(|e| InferError::Failed(e.to_string()))?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.run.join("infer.lock"))
            .map_err(|e| InferError::Failed(e.to_string()))?;
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
                return Err(InferError::Failed(format!(
                    "axod-infer exited; see {}",
                    self.run.join("infer.log").display()
                )));
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        Err(InferError::Failed(
            "axod-infer did not start in time".into(),
        ))
    }

    /// Nobody holds the lock, so no side-car is running or starting.
    fn died_without_lock(&self) -> bool {
        OpenOptions::new()
            .write(true)
            .open(self.run.join("infer.lock"))
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
    fn start(&self, lock: File) -> Result<(), InferError> {
        let socket = self.socket();
        let _ = std::fs::remove_file(&socket);
        let log = File::create(self.run.join("infer.log"))
            .map_err(|e| InferError::Failed(e.to_string()))?;
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
                    .map_err(|e| InferError::Failed(e.to_string()))?,
            )
            .stderr(log);
        detach_holding(&mut command, lock_fd);
        let child = command
            .spawn()
            .map_err(|e| InferError::Failed(format!("could not start axod-infer: {e}")))?;
        log::info!("event=infer.started pid={}", child.id());
        // The child holds the lock now; closing ours does not release it.
        drop(lock);
        Ok(())
    }
}

/// Runs the command in its own session, so it outlives this process, and keeps `lock_fd` open in
/// it, so the lock lasts as long as it does.
fn detach_holding(command: &mut Command, lock_fd: std::os::fd::RawFd) {
    // SAFETY: between fork and exec this only calls async-signal-safe functions.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            let flags = libc::fcntl(lock_fd, libc::F_GETFD);
            if flags < 0 || libc::fcntl(lock_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

fn physical_memory() -> u64 {
    let mut bytes: u64 = 0;
    let mut size = std::mem::size_of::<u64>();
    // SAFETY: hw.memsize is a u64; the buffer and its size match.
    let ok = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&raw mut bytes).cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    } == 0;
    if ok { bytes } else { 0 }
}

fn free_disk(path: &Path) -> u64 {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else {
        return 0;
    };
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: a valid C string and a statvfs to fill.
    if unsafe { libc::statvfs(path.as_ptr(), &mut stats) } != 0 {
        return 0;
    }
    stats.f_bavail as u64 * stats.f_frsize as u64
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
        "{method} {path} HTTP/1.1\r\nHost: axod-infer\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
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
        let dir = std::env::temp_dir().join(format!("axod-infer-test-{}", std::process::id()));
        let infer = Infer {
            helper: dir.join("axod-infer"),
            models: dir.join("models"),
            run: dir.join("run"),
        };
        assert!(matches!(
            infer.ask(&serde_json::json!({})),
            Err(InferError::Unavailable(_))
        ));
    }

    #[test]
    fn reads_this_macs_memory_and_disk() {
        assert!(physical_memory() > 1 << 30);
        assert!(free_disk(&std::env::temp_dir()) > 0);
    }

    #[test]
    fn one_lock_holder_at_a_time() {
        let path = std::env::temp_dir().join(format!("axod-infer-lock-{}", std::process::id()));
        let first = File::create(&path).unwrap();
        let second = OpenOptions::new().write(true).open(&path).unwrap();
        assert!(try_lock(&first));
        assert!(!try_lock(&second));
        drop(first);
        assert!(try_lock(&second));
        let _ = std::fs::remove_file(path);
    }
}
