//! `codemode.ai`: lazy installation and inference on this Mac. Gemma is the first supported
//! HF reference, pinned to a reviewed artifact. Scripts cannot supply executables, flags or URLs.
//! This process is separate from the computer-use safety judge, including its socket and lock.

use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use axo_pty::exit::WatchedChild;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;

use crate::{Infer, blocking, free_disk, hold, http, lifeline, physical_memory, try_lock};

pub const MODEL: &str = "hf:ggml-org/gemma-3-270m-it-GGUF";
const REPO: &str = "ggml-org/gemma-3-270m-it-GGUF";
const REVISION: &str = "e7647be17ae1108f2f605ed061ca0608b171afff";
const FILE: &str = "gemma-3-270m-it-Q8_0.gguf";
const SHA256: &str = "0ef57d2c838458a1952664260dcba38e5bdda37494f3af732f06e4add24068e3";
const MODEL_BYTES: u64 = 291_545_600;
pub const MAX_TIMEOUT_MS: u64 = 240_000;

#[derive(Debug)]
pub enum Error {
    Invalid(&'static str),
    Busy,
    Unavailable(&'static str),
    Failed(&'static str),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invalid(message) | Self::Unavailable(message) | Self::Failed(message) => {
                f.write_str(message)
            }
            Self::Busy => f.write_str(
                "another ai operation is running on this Mac; try again when it finishes",
            ),
        }
    }
}

/// A parsed operation, before any filesystem, download or process effects.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
pub enum Request {
    List {},
    Install {
        model: String,
    },
    Load {
        model: String,
    },
    Unload {
        model: String,
    },
    Run {
        model: String,
        prompt: String,
        #[serde(default = "default_tokens", rename = "maxTokens")]
        max_tokens: u32,
    },
}

fn default_tokens() -> u32 {
    512
}

impl Request {
    pub fn parse(value: Value) -> Result<Self, Error> {
        let request: Self = serde_json::from_value(value)
            .map_err(|_| Error::Invalid("invalid ai request fields"))?;
        let model = match &request {
            Self::List {} => return Ok(request),
            Self::Install { model }
            | Self::Load { model }
            | Self::Unload { model }
            | Self::Run { model, .. } => model,
        };
        if model != MODEL {
            return Err(Error::Invalid(
                "unsupported model; call ai.list on this Mac",
            ));
        }
        if let Self::Run {
            prompt, max_tokens, ..
        } = &request
        {
            if prompt.is_empty() || prompt.len() > 32_768 || !(1..=4096).contains(max_tokens) {
                return Err(Error::Invalid(
                    "run needs a prompt of 1 to 32768 bytes and maxTokens of 1 to 4096",
                ));
            }
        }
        Ok(request)
    }
}

pub struct Service {
    infer: Infer,
    /// Held across each complete operation. Unload cannot race a request or a cold start.
    operation: Mutex<()>,
}

impl Service {
    pub fn beside_current_exe(home: &Path, run: &Path) -> Self {
        let helper = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|p| p.join("axod-infer")))
            .unwrap_or_default();
        Self::new(
            helper,
            home.join("Library/Application Support/Axo/models"),
            run.join("ai"),
        )
    }

    pub fn new(helper: PathBuf, models: PathBuf, run: PathBuf) -> Self {
        Self {
            infer: Infer::for_model(
                helper,
                models.join("gemma-3-270m-it").join(REVISION),
                run,
                FILE.into(),
                None,
            ),
            operation: Mutex::new(()),
        }
    }

    pub async fn execute(&self, request: Request, timeout_ms: u64) -> Result<Value, Error> {
        if !(1..=MAX_TIMEOUT_MS).contains(&timeout_ms) {
            return Err(Error::Invalid("invalid ai deadline"));
        }
        let _operation = self.operation.try_lock().map_err(|_| Error::Busy)?;
        let outcome =
            tokio::time::timeout(Duration::from_millis(timeout_ms), self.perform(request)).await;
        match outcome {
            Ok(Ok(result)) => Ok(result),
            result => {
                // A cancelled HTTP exchange may leave computation in progress. Retire our
                // side-car before releasing the operation lock; never touch the safety judge.
                self.infer.stop().await;
                match result {
                    Ok(Err(error)) => Err(error),
                    _ => Err(Error::Failed(
                        "ai operation timed out; a partial download will resume on the next call",
                    )),
                }
            }
        }
    }

    async fn perform(&self, request: Request) -> Result<Value, Error> {
        match request {
            Request::List {} => {
                let infer = self.infer.clone();
                let (available, installed) =
                    blocking(move || (infer.helper.is_file(), installed(&infer.models))).await;
                let props = self
                    .infer
                    .json_request("GET", "/props", &json!({}), Duration::from_secs(2))
                    .await
                    .ok();
                let status = match props.as_ref().and_then(|p| p["is_sleeping"].as_bool()) {
                    Some(true) => "sleeping",
                    Some(false) => "loaded",
                    None => "stopped",
                };
                Ok(
                    json!({ "models": [{ "id": MODEL, "task": "generate", "available": available,
                    "installed": installed, "status": status, "downloadBytes": MODEL_BYTES,
                    "source": provenance() }] }),
                )
            }
            Request::Unload { .. } => {
                self.infer.stop().await;
                Ok(json!({ "model": MODEL, "status": "stopped", "source": provenance() }))
            }
            request => {
                self.install().await?;
                if matches!(request, Request::Install { .. }) {
                    return Ok(
                        json!({ "model": MODEL, "installed": true, "source": provenance() }),
                    );
                }
                self.infer.ensure_running().await.map_err(|_| {
                    Error::Failed("local model could not start; inspect this Mac's ai/infer.log")
                })?;
                if let Request::Run {
                    prompt, max_tokens, ..
                } = request
                {
                    let reply = self.infer.json_request("POST", "/v1/chat/completions", &json!({
                        "messages": [{ "role": "user", "content": prompt }], "max_tokens": max_tokens, "stream": false,
                    }), Duration::from_secs(180)).await?;
                    let text = reply["choices"][0]["message"]["content"]
                        .as_str()
                        .ok_or(Error::Failed("model returned no generated text"))?;
                    let finish = reply["choices"][0]["finish_reason"]
                        .as_str()
                        .ok_or(Error::Failed("model returned no finish reason"))?;
                    if !matches!(finish, "stop" | "length") {
                        return Err(Error::Failed("model returned an unsupported finish reason"));
                    }
                    Ok(
                        json!({ "model": MODEL, "text": text, "finishReason": finish, "source": provenance() }),
                    )
                } else {
                    // Unlike /health, /slots wakes a sleeping model without running a prompt.
                    self.infer
                        .json_request("GET", "/slots", &json!({}), Duration::from_secs(90))
                        .await?;
                    Ok(json!({ "model": MODEL, "status": "loaded", "source": provenance() }))
                }
            }
        }
    }

    async fn install(&self) -> Result<(), Error> {
        let infer = self.infer.clone();
        let download = blocking(move || prepare_download(&infer)).await?;
        if let Some(mut download) = download {
            let status = download
                .child
                .as_mut()
                .expect("download child exists until drop")
                .wait()
                .await
                .map_err(|_| Error::Failed("could not wait for the model download"))?;
            if !status.success() {
                return Err(Error::Failed(
                    "model download failed; inspect this Mac's model download.log; retry to resume",
                ));
            }
            // Keep the download lock through verification and atomic publication. If the
            // caller times out during hashing, this bounded blocking job finishes safely.
            blocking(move || {
                let result = finalize_download(&download.models, FILE, MODEL_BYTES, SHA256);
                drop(download);
                result
            })
            .await?;
        }
        Ok(())
    }
}

fn provenance() -> Value {
    json!({ "repo": REPO, "revision": REVISION, "file": FILE, "sha256": SHA256 })
}

fn installed(models: &Path) -> bool {
    std::fs::metadata(models.join(FILE))
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() == MODEL_BYTES)
}

/// A cancelled download must stop its lifeline guard, not orphan a network request. The exit
/// watch prevents signalling a reaped/reused pid. A successful wait sets the exit watch first.
struct Download {
    child: Option<WatchedChild>,
    models: PathBuf,
    _lock: File,
}
impl Drop for Download {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        if !child.exit().has_exited() {
            // SAFETY: the unreaped child is our guard. curl is its direct child, so the
            // lifeline and this trap both stop the network transfer, without grandchildren.
            unsafe {
                libc::kill(child.id() as i32, libc::SIGTERM);
            }
        }
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = child.wait().await;
            });
        }
    }
}

fn prepare_download(infer: &Infer) -> Result<Option<Download>, Error> {
    if !infer.helper.is_file() {
        return Err(Error::Unavailable(
            "the local inference helper is missing on this Mac",
        ));
    }
    if physical_memory() < 4 << 30 {
        return Err(Error::Unavailable(
            "Gemma needs a Mac with at least 4 GiB of RAM",
        ));
    }
    if installed(&infer.models) {
        return Ok(None);
    }
    let failed = |_| Error::Failed("could not prepare the model download");
    std::fs::create_dir_all(&infer.models).map_err(failed)?;
    if free_disk(&infer.models) < 1 << 30 {
        return Err(Error::Unavailable(
            "Gemma installation needs at least 1 GiB of free disk space",
        ));
    }
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(infer.models.join(".download.lock"))
        .map_err(failed)?;
    if !try_lock(&lock) {
        return Err(Error::Busy);
    }
    // Recheck under the cross-process lock; an earlier owner may just have finished.
    if installed(&infer.models) {
        return Ok(None);
    }
    let log = File::create(infer.models.join("download.log")).map_err(failed)?;
    let mut command = lifeline()
        .map_err(failed)?
        .guarded(Path::new("/usr/bin/curl"));
    command
        .args([
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "-fL",
            "--retry",
            "2",
            "--connect-timeout",
            "20",
            "--max-time",
            "230",
            "--silent",
            "--show-error",
            "-C",
            "-",
            "--max-filesize",
            &MODEL_BYTES.to_string(),
            "-o",
        ])
        .arg(infer.models.join(format!("{FILE}.part")))
        .arg(format!(
            "https://huggingface.co/{REPO}/resolve/{REVISION}/{FILE}"
        ))
        .stdin(Stdio::null())
        .stdout(log.try_clone().map_err(failed)?)
        .stderr(log);
    hold(&mut command, lock.as_raw_fd());
    let child = WatchedChild::new(command.spawn().map_err(failed)?).map_err(failed)?;
    Ok(Some(Download {
        child: Some(child),
        models: infer.models.clone(),
        _lock: lock,
    }))
}

fn finalize_download(
    models: &Path,
    file: &str,
    expected_bytes: u64,
    expected_sha: &str,
) -> Result<(), Error> {
    let partial = models.join(format!("{file}.part"));
    let failed = |_| Error::Failed("could not verify the model download");
    let mut input = File::open(&partial)
        .map_err(failed)?
        .take(expected_bytes + 1);
    let mut sha = Sha256::new();
    let mut buffer = [0; 65_536];
    let mut bytes = 0;
    loop {
        let read = input.read(&mut buffer).map_err(failed)?;
        if read == 0 {
            break;
        }
        bytes += read as u64;
        sha.update(&buffer[..read]);
    }
    if bytes != expected_bytes || format!("{:x}", sha.finalize()) != expected_sha {
        let _ = std::fs::remove_file(&partial);
        return Err(Error::Failed(
            "downloaded model failed size or SHA-256 verification; retry to download again",
        ));
    }
    std::fs::rename(partial, models.join(file)).map_err(failed)
}

impl Infer {
    async fn json_request(
        &self,
        method: &str,
        path: &str,
        request: &Value,
        timeout: Duration,
    ) -> Result<Value, Error> {
        let body =
            serde_json::to_vec(request).map_err(|_| Error::Invalid("invalid model input"))?;
        let reply = http(&self.socket(), method, path, &body, timeout)
            .await
            .map_err(|_| Error::Failed("local model did not answer"))?;
        if reply.status != 200 {
            return Err(Error::Failed("local model request failed"));
        }
        serde_json::from_slice(&reply.body)
            .map_err(|_| Error::Failed("local model returned invalid JSON"))
    }

    pub(super) async fn stop(&self) {
        let child = self.lock_children().side_car.take();
        if let Some(mut side_car) = child {
            // SAFETY: SIGTERM runs the guard's trap, which kills and reaps llama-server.
            unsafe {
                libc::kill(side_car.child.id() as i32, libc::SIGTERM);
            }
            let _ = side_car.child.wait().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_supported_model_and_bounded_generation_are_accepted() {
        for value in [
            json!({"op":"load","model":"../judge"}),
            json!({"op":"list","approved":true}),
            json!({"op":"run","model":MODEL,"prompt":"hello","maxTokens":0}),
            json!({"op":"run","model":MODEL,"prompt":""}),
            json!({"op":"embed","model":MODEL,"input":"x"}),
            json!({"op":"load","model":MODEL,"url":"https://example.com/model.gguf"}),
        ] {
            assert!(Request::parse(value.clone()).is_err(), "{value}");
        }
        assert!(Request::parse(json!({"op":"run","model":MODEL,"prompt":"hello"})).is_ok());
        assert!(Request::parse(json!({"op":"list"})).is_ok());
    }

    #[test]
    fn installation_publishes_only_complete_verified_files() {
        let root = crate::tests::run_directory();
        let bytes = b"small model fixture";
        let sha = format!("{:x}", Sha256::digest(bytes));
        std::fs::write(root.join("model.gguf.part"), bytes).unwrap();
        assert!(finalize_download(&root, "model.gguf", bytes.len() as u64, &sha).is_ok());
        assert_eq!(std::fs::read(root.join("model.gguf")).unwrap(), bytes);
        assert!(!root.join("model.gguf.part").exists());
        for (size, hash) in [
            (bytes.len() as u64 + 1, sha.as_str()),
            (bytes.len() as u64, "bad hash"),
        ] {
            std::fs::write(root.join("bad.gguf.part"), bytes).unwrap();
            assert!(finalize_download(&root, "bad.gguf", size, hash).is_err());
            assert!(!root.join("bad.gguf").exists());
            assert!(!root.join("bad.gguf.part").exists());
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn cancelling_a_download_stops_and_reaps_its_guard() {
        let root = crate::tests::run_directory();
        let child = WatchedChild::new(
            lifeline()
                .unwrap()
                .guarded(Path::new("/bin/sleep"))
                .arg("60")
                .spawn()
                .unwrap(),
        )
        .unwrap();
        let exit = child.exit().clone();
        let lock = File::create(root.join("lock")).unwrap();
        let download = Download {
            child: Some(child),
            models: root.clone(),
            _lock: lock,
        };
        drop(download);
        tokio::time::timeout(Duration::from_secs(5), exit.exited())
            .await
            .unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }

    const FAKE: &str = r#"#!/usr/bin/python3
import json, socket, sys
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[sys.argv.index('--host') + 1])
server.listen(8)
while True:
    client, _ = server.accept()
    try:
        data = b''
        while b'\r\n\r\n' not in data:
            part = client.recv(65536)
            if not part: break
            data += part
        if b'\r\n\r\n' not in data:
            client.close()
            continue
        header, body = data.split(b'\r\n\r\n', 1)
        length = int(next(line.split(b':',1)[1] for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:')))
        while len(body) < length: body += client.recv(65536)
        path = header.split(b' ')[1]
        reply = {'is_sleeping': False}
        if path == b'/v1/chat/completions':
            request = json.loads(body)
            assert request['stream'] is False
            assert 1 <= request['max_tokens'] <= 4096
            reply = {'choices': [{'message': {'content': request['messages'][0]['content']}, 'finish_reason': 'stop'}]}
        payload = json.dumps(reply).encode()
        client.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(payload)).encode() + b'\r\nConnection: close\r\n\r\n' + payload)
    except OSError:
        pass
    client.close()
"#;

    #[tokio::test]
    async fn generation_auto_loads_reuses_and_unloads_only_its_own_process() {
        use std::os::unix::fs::PermissionsExt;
        let root = crate::tests::run_directory();
        let helper = root.join("helper");
        std::fs::write(&helper, FAKE).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();
        let service = Service::new(helper, root.join("models"), root.join("ai"));
        // A sparse fixture stands in for a previously verified installed artifact; no network.
        std::fs::create_dir_all(&service.infer.models).unwrap();
        File::create(service.infer.models.join(FILE))
            .unwrap()
            .set_len(MODEL_BYTES)
            .unwrap();
        let run = || {
            Request::parse(json!({"op":"run","model":MODEL,"prompt":"hello","maxTokens":8}))
                .unwrap()
        };
        let first = service.execute(run(), 10_000).await.unwrap();
        assert_eq!(first["text"], "hello");
        assert_eq!(first["source"], provenance());
        let pid = service
            .infer
            .lock_children()
            .side_car
            .as_ref()
            .unwrap()
            .child
            .id();
        service.execute(run(), 10_000).await.unwrap();
        assert_eq!(
            service
                .infer
                .lock_children()
                .side_car
                .as_ref()
                .unwrap()
                .child
                .id(),
            pid
        );
        assert_eq!(
            service.execute(Request::List {}, 1000).await.unwrap()["models"][0]["status"],
            "loaded"
        );
        service
            .execute(
                Request::Unload {
                    model: MODEL.into(),
                },
                5000,
            )
            .await
            .unwrap();
        assert!(service.infer.lock_children().side_car.is_none());
        assert!(installed(&service.infer.models));
        assert!(
            !root.join("infer.sock").exists(),
            "the safety judge's socket was never created"
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    /// Explicit opt-in: downloads the real pinned model and runs the shipped llama.cpp helper.
    /// Run outside the sandbox with AXO_TEST_GEMMA_HELPER set to the built helper's absolute path.
    #[tokio::test]
    #[ignore = "downloads 292 MB; requires AXO_TEST_GEMMA_HELPER"]
    async fn real_gemma_lazy_install_and_generation() {
        let helper = PathBuf::from(
            std::env::var("AXO_TEST_GEMMA_HELPER").expect("set AXO_TEST_GEMMA_HELPER"),
        );
        let root = PathBuf::from("/tmp/axo-gemma-smoke");
        let service = Service::new(helper, root.join("models"), root.join("run"));
        let prompt = std::env::var("AXO_TEST_GEMMA_PROMPT")
            .unwrap_or_else(|_| "Write the word hello.".into());
        let request =
            Request::parse(json!({"op":"run","model":MODEL,"prompt":prompt,"maxTokens":32}))
                .unwrap();
        let result = service.execute(request, MAX_TIMEOUT_MS).await.unwrap();
        println!("{}", result);
        assert!(!result["text"].as_str().unwrap().is_empty());
        assert_eq!(result["source"], provenance());
        service
            .execute(
                Request::Unload {
                    model: MODEL.into(),
                },
                5000,
            )
            .await
            .unwrap();
        assert!(installed(&service.infer.models));
    }

    #[tokio::test]
    async fn discovery_never_installs_and_busy_calls_never_start() {
        let run = crate::tests::run_directory();
        let service = Service::new(
            run.join("missing-helper"),
            run.join("models"),
            run.join("ai"),
        );
        let listed = service.execute(Request::List {}, 1000).await.unwrap();
        assert_eq!(listed["models"][0]["installed"], false);
        assert!(!service.infer.models.exists());
        let _held = service.operation.lock().await;
        assert!(matches!(
            service.execute(Request::List {}, 1000).await,
            Err(Error::Busy)
        ));
        std::fs::remove_dir_all(run).unwrap();
    }
}
