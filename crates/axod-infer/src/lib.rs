//! Local inference: axod's side-car for running models on this Mac. Its first model is Clef,
//! asked typed questions about a state over llama.cpp's `POST /v1/systemone` on a Unix socket,
//! returning a probability for every option. Other models (speech, for one) are meant to join it.
//!
//! The model runs in `axod-infer`, our pinned `llama-server` build next to axod in
//! `Axo.app/Contents/Helpers`, as a side-car: a crash in Metal or the model cannot take axod and
//! its Sessions down. axod starts it on the first question, as its child under the lifeline
//! (RFD0041): it ends with axod, however axod ends. It holds an exclusive lock on `infer.lock`
//! that lives exactly as long as it does, so there is never more than one; a crashed one is
//! started again on the next question, and one an earlier axod left running is killed and
//! replaced. The side-car unloads the model after ten idle minutes (`--sleep-idle-seconds`) and
//! loads it again on demand.

use std::fs::{File, OpenOptions};
use std::io::{self};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use axo_pty::exit::WatchedChild;
use axo_pty::lifeline::Lifeline;
use notify::Watcher;

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
    /// The side-car and the download this process started, reaped once they exit.
    children: Arc<Mutex<Children>>,
    starting: Arc<tokio::sync::Mutex<()>>,
}

#[derive(Debug, Default)]
struct Children {
    side_car: Option<WatchedChild>,
    download: Option<WatchedChild>,
}

impl Children {
    /// Reaps whichever has exited; true while the side-car this process started still runs.
    fn side_car_running(&mut self) -> bool {
        for slot in [&mut self.side_car, &mut self.download] {
            if slot
                .as_mut()
                .is_some_and(|child| !matches!(child.try_wait(), Ok(None)))
            {
                *slot = None;
            }
        }
        self.side_car.is_some()
    }
}

/// The pipe whose end, when this process ends, stops what it started here.
fn lifeline() -> io::Result<&'static Lifeline> {
    static LIFELINE: OnceLock<Lifeline> = OnceLock::new();
    if let Some(lifeline) = LIFELINE.get() {
        return Ok(lifeline);
    }
    let lifeline = Lifeline::new()?;
    Ok(LIFELINE.get_or_init(|| lifeline))
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
    pub fn new(helper: PathBuf, models: PathBuf, run: PathBuf) -> Self {
        Self {
            helper,
            models,
            run,
            children: Arc::default(),
            starting: Arc::default(),
        }
    }

    /// The side-car next to this executable, Axo's models directory and axod's run directory.
    pub fn beside_current_exe(run: &Path) -> Option<Self> {
        let exe = std::env::current_exe().ok()?;
        let home = std::env::var_os("HOME")?;
        Some(Self::new(
            exe.parent()?.join("axod-infer"),
            PathBuf::from(home).join("Library/Application Support/Axo/models/clef-flash"),
            run.to_path_buf(),
        ))
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
        let mut command = lifeline()
            .map_err(|e| e.to_string())?
            .guarded(Path::new("/bin/sh"));
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
        hold(&mut command, lock.as_raw_fd());
        let child = command.spawn().map_err(|e| e.to_string())?;
        log::info!("event=infer.model_download_started pid={}", child.id());
        let child = WatchedChild::new(child).map_err(|e| e.to_string())?;
        self.lock_children().download = Some(child);
        Ok(())
    }

    /// Asks a `systemone` request (`{ state, images?, questions }`) and returns its `answers`:
    /// for each question, `{ type, <type>: probability or choice probabilities }`.
    pub async fn ask(&self, request: &Value) -> Result<Value, InferError> {
        let infer = self.clone();
        blocking(move || infer.installed()).await?;
        self.ensure_running().await?;
        let body = serde_json::to_vec(request).map_err(|e| InferError::Failed(e.to_string()))?;
        let reply = http(&self.socket(), "POST", "/v1/systemone", &body, ASK_TIMEOUT)
            .await
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
    async fn ensure_running(&self) -> Result<(), InferError> {
        let _starting = self.starting.lock().await;
        let infer = self.clone();
        let watch = blocking(move || infer.prepare_start()).await?;
        let deadline = Instant::now() + START_TIMEOUT;
        loop {
            if self.healthy().await {
                return Ok(());
            }
            let infer = self.clone();
            if blocking(move || infer.died_without_lock()).await {
                return Err(InferError::Failed(format!(
                    "axod-infer exited; see {}",
                    self.run.join("infer.log").display()
                )));
            }
            if !watch.wait_until(deadline).await {
                return Err(InferError::Failed(
                    "axod-infer did not start in time".into(),
                ));
            }
        }
    }

    /// Process ownership and filesystem setup block, but no cold-start wait does.
    fn prepare_start(&self) -> Result<StartWatch, InferError> {
        let mut children = self.lock_children();
        if !children.side_car_running() {
            self.stop_left_running();
        }
        std::fs::create_dir_all(&self.run).map_err(|e| InferError::Failed(e.to_string()))?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.run.join("infer.lock"))
            .map_err(|e| InferError::Failed(e.to_string()))?;
        if try_lock(&lock) {
            children.side_car = Some(self.start(lock)?);
        }
        StartWatch::new(&self.run, children.side_car.as_ref())
            .map_err(|e| InferError::Failed(e.to_string()))
    }

    fn lock_children(&self) -> std::sync::MutexGuard<'_, Children> {
        self.children
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// A side-car this process did not start (an earlier axod's, from before the lifeline) is
    /// killed, so the next one is this axod's child. It is found by its socket's peer: the
    /// process serving `infer.sock` in axod's private run directory.
    fn stop_left_running(&self) {
        if self.died_without_lock() {
            return;
        }
        let Some(pid) = UnixStream::connect(self.socket())
            .ok()
            .and_then(|stream| peer_pid(&stream))
        else {
            return;
        };
        log::warn!("event=infer.previous_killed pid={pid}");
        // SAFETY: signals the process serving our own side-car's socket.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        // It releases the lock as it dies; waiting for that is waiting for it to be gone.
        if let Ok(lock) = OpenOptions::new()
            .write(true)
            .open(self.run.join("infer.lock"))
        {
            // SAFETY: flock on a file descriptor we own; it returns once the dead one's is gone.
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
        }
    }

    /// Nobody holds the lock, so no side-car is running or starting.
    fn died_without_lock(&self) -> bool {
        OpenOptions::new()
            .write(true)
            .open(self.run.join("infer.lock"))
            .map(|file| try_lock(&file))
            .unwrap_or(true)
    }

    async fn healthy(&self) -> bool {
        http(
            &self.socket(),
            "GET",
            "/health",
            &[],
            Duration::from_secs(2),
        )
        .await
        .is_ok_and(|reply| reply.status == 200)
    }

    /// Spawns the side-car under this process's lifeline, handing it the locked file so the lock
    /// lasts as long as it does.
    fn start(&self, lock: File) -> Result<WatchedChild, InferError> {
        let socket = self.socket();
        let _ = std::fs::remove_file(&socket);
        let log = File::create(self.run.join("infer.log"))
            .map_err(|e| InferError::Failed(e.to_string()))?;
        let lock_fd = lock.as_raw_fd();
        let mut command = lifeline()
            .map_err(|e| InferError::Failed(e.to_string()))?
            .guarded(&self.helper);
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
        hold(&mut command, lock_fd);
        let child = command
            .spawn()
            .map_err(|e| InferError::Failed(format!("could not start axod-infer: {e}")))?;
        log::info!("event=infer.started pid={}", child.id());
        // The child holds the lock now; closing ours does not release it.
        drop(lock);
        WatchedChild::new(child).map_err(|e| InferError::Failed(e.to_string()))
    }
}

/// What a starting side-car does that is worth looking again for (RFD0037): a change in the run
/// directory (its socket appearing, its log growing as the model loads), through `notify`, and
/// its exit when this process started it.
struct StartWatch {
    happened: Arc<tokio::sync::Notify>,
    _watcher: notify::RecommendedWatcher,
}

impl StartWatch {
    fn new(run: &Path, started: Option<&WatchedChild>) -> io::Result<Self> {
        let happened = Arc::new(tokio::sync::Notify::new());
        let happen = Arc::clone(&happened);
        let telling = happen.clone();
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            if !matches!(event, Ok(ref event) if matches!(event.kind, notify::EventKind::Access(_)))
            {
                telling.notify_one();
            }
        })
        .map_err(io::Error::other)?;
        watcher
            .watch(run, notify::RecursiveMode::NonRecursive)
            .map_err(io::Error::other)?;
        if let Some(child) = started {
            child.exit().on_exit(move || {
                happen.notify_one();
            });
        }
        Ok(Self {
            happened,
            _watcher: watcher,
        })
    }

    /// Waits for something to happen; false once `deadline` has passed.
    async fn wait_until(&self, deadline: Instant) -> bool {
        let deadline = tokio::time::Instant::from_std(deadline);
        tokio::time::timeout_at(deadline, self.happened.notified())
            .await
            .is_ok()
    }
}

/// Keeps `lock_fd` open in the command, so the lock lasts as long as it does, and gives it a
/// session of its own, away from axod's signals; the lifeline still ends it.
fn hold(command: &mut Command, lock_fd: std::os::fd::RawFd) {
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

/// The process at the other end of a connected Unix socket.
fn peer_pid(stream: &UnixStream) -> Option<i32> {
    let mut pid: libc::pid_t = 0;
    let mut size = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: LOCAL_PEERPID writes one pid_t into `pid`, whose size `size` gives.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut size,
        )
    };
    (result == 0 && pid > 0).then_some(pid)
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
async fn http(
    socket: &Path,
    method: &str,
    path: &str,
    body: &[u8],
    timeout: Duration,
) -> io::Result<Reply> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let exchange = async {
        let mut stream = tokio::net::UnixStream::connect(socket).await?;
        let head = format!(
            "{method} {path} HTTP/1.1\r\nHost: axod-infer\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(head.as_bytes()).await?;
        stream.write_all(body).await?;
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).await?;
        parse_reply(&raw)
    };
    tokio::time::timeout(timeout, exchange)
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "local inference timed out"))?
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

async fn blocking<R: Send + 'static>(work: impl FnOnce() -> R + Send + 'static) -> R {
    match tokio::task::spawn_blocking(work).await {
        Ok(result) => result,
        Err(error) => std::panic::resume_unwind(error.into_panic()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    fn block<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(future)
    }

    fn run_directory() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let run = PathBuf::from(format!(
            "/tmp/axo-infer-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&run).unwrap();
        run
    }

    #[tokio::test(flavor = "current_thread")]
    async fn dropping_an_inference_request_closes_its_stalled_socket() {
        use tokio::io::AsyncReadExt;
        let run = run_directory();
        let socket = run.join("test.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let request = tokio::spawn(async move {
            http(
                &socket,
                "POST",
                "/v1/systemone",
                b"{}",
                Duration::from_secs(30),
            )
            .await
        });
        let (mut server, _) = listener.accept().await.unwrap();
        let mut byte = [0];
        assert_eq!(server.read(&mut byte).await.unwrap(), 1);
        assert!(!request.is_finished());
        request.abort();
        assert!(matches!(request.await, Err(error) if error.is_cancelled()));
        let mut remaining = Vec::new();
        tokio::time::timeout(Duration::from_secs(1), server.read_to_end(&mut remaining))
            .await
            .unwrap()
            .unwrap();
        drop(listener);
        std::fs::remove_dir_all(run).unwrap();
    }

    #[test]
    fn a_starting_side_car_is_looked_at_again_when_it_does_something() {
        let run = run_directory();
        std::fs::write(run.join("infer.log"), "").unwrap();
        let watch = StartWatch::new(&run, None).unwrap();
        // FSEvents also reports what happened just before the watch: the log's creation.
        while block(watch.wait_until(Instant::now() + Duration::from_millis(200))) {}
        // Nothing happens: it sleeps until the deadline.
        let started = Instant::now();
        assert!(!block(watch.wait_until(Instant::now())));
        assert!(!block(
            watch.wait_until(started + Duration::from_millis(100))
        ));
        assert!(started.elapsed() >= Duration::from_millis(90));
        // The log grows (the model loading), or the socket appears: it wakes at once.
        for happen in [
            Box::new(|run: &Path| {
                let mut log = OpenOptions::new()
                    .append(true)
                    .open(run.join("infer.log"))
                    .unwrap();
                log.write_all(b"model loaded\n").unwrap();
            }) as Box<dyn Fn(&Path) + Send>,
            Box::new(|run: &Path| std::fs::write(run.join("infer.sock"), "").unwrap()),
        ] {
            let happening = run.clone();
            let writer = std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(30));
                happen(&happening);
            });
            let started = Instant::now();
            assert!(block(watch.wait_until(started + Duration::from_secs(30))));
            assert!(started.elapsed() < Duration::from_secs(10));
            writer.join().unwrap();
        }
        // The side-car this process started exits: it wakes at once.
        let mut child =
            WatchedChild::new(Command::new("/bin/sleep").arg("0.3").spawn().unwrap()).unwrap();
        let watch = StartWatch::new(&run, Some(&child)).unwrap();
        while block(watch.wait_until(Instant::now() + Duration::from_millis(100))) {}
        let started = Instant::now();
        assert!(block(watch.wait_until(started + Duration::from_secs(30))));
        assert!(started.elapsed() < Duration::from_secs(10));
        assert!(child.exit().has_exited());
        block(child.wait()).unwrap();
        std::fs::remove_dir_all(run).unwrap();
    }

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
        let infer = Infer::new(dir.join("axod-infer"), dir.join("models"), dir.join("run"));
        assert!(matches!(
            block(infer.ask(&serde_json::json!({}))),
            Err(InferError::Unavailable(_))
        ));
    }

    /// A side-car that only answers `/health`, on the socket `--host` names.
    const FAKE_SIDE_CAR: &str = r#"#!/usr/bin/python3
import socket, sys
path = sys.argv[sys.argv.index("--host") + 1]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(8)
while True:
    client, _ = server.accept()
    try:
        if client.recv(65536):
            client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    except OSError:
        pass
    client.close()
"#;

    fn fake_infer() -> Infer {
        let run = run_directory();
        let helper = run.join("fake-side-car");
        std::fs::write(&helper, FAKE_SIDE_CAR).unwrap();
        std::fs::set_permissions(&helper, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .unwrap();
        Infer::new(helper, run.join("models"), run)
    }

    fn alive(pid: i32) -> bool {
        // SAFETY: signal 0 only asks whether the process exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    fn serving_pid(infer: &Infer) -> i32 {
        peer_pid(&UnixStream::connect(infer.socket()).unwrap()).unwrap()
    }

    #[test]
    fn the_side_car_is_started_once_as_this_processs_child() {
        let infer = fake_infer();
        block(infer.ensure_running()).unwrap();
        let pid = serving_pid(&infer);
        let guard = infer.lock_children().side_car.as_ref().unwrap().id() as i32;
        // SAFETY: getppid-like lookup of a process this test started.
        let parent = {
            let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
            let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
            let filled = unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    (&mut info as *mut libc::proc_bsdinfo).cast(),
                    size,
                )
            };
            assert_eq!(filled, size);
            info.pbi_ppid as i32
        };
        assert_eq!(
            parent, guard,
            "the side-car runs under this process's guard"
        );
        block(infer.ensure_running()).unwrap();
        assert_eq!(
            serving_pid(&infer),
            pid,
            "a running side-car is used, not replaced"
        );
        // SAFETY: stops the guard this test started; it stops the side-car.
        unsafe { libc::kill(guard, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while alive(pid) {
            assert!(Instant::now() < deadline, "the side-car outlived its guard");
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = std::fs::remove_dir_all(&infer.run);
    }

    #[test]
    fn a_side_car_this_process_did_not_start_is_replaced() {
        let infer = fake_infer();
        // One an earlier axod left: started without the lifeline, holding the lock.
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(infer.run.join("infer.lock"))
            .unwrap();
        assert!(try_lock(&lock));
        let mut command = Command::new(&infer.helper);
        command.arg("--host").arg(infer.socket());
        hold(&mut command, lock.as_raw_fd());
        let mut stranger = command.spawn().unwrap();
        drop(lock);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !block(infer.healthy()) {
            assert!(Instant::now() < deadline, "the stranger never served");
            std::thread::sleep(Duration::from_millis(20));
        }

        block(infer.ensure_running()).unwrap();
        assert!(stranger.wait().is_ok());
        let pid = serving_pid(&infer);
        assert_ne!(pid as u32, stranger.id());
        assert!(infer.lock_children().side_car.is_some());
        // SAFETY: stops the guard this test started.
        let guard = infer.lock_children().side_car.as_ref().unwrap().id() as i32;
        unsafe { libc::kill(guard, libc::SIGTERM) };
        let _ = std::fs::remove_dir_all(&infer.run);
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
