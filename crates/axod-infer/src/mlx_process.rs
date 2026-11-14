//! Process containment for the native Rust/MLX worker. The runtime is embedded in that
//! worker, not in the daemon; killing and reaping it establishes native quiescence.
use std::fs::{File, OpenOptions};
use std::os::fd::BorrowedFd;
use std::os::unix::{fs::PermissionsExt, process::CommandExt};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use axo_pty::exit::WatchedChild;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::service::Error;

struct OwnedWorker {
    child: WatchedChild,
    _lock: File,
}

pub(crate) struct Process {
    helper: PathBuf,
    metal: PathBuf,
    models: PathBuf,
    run: PathBuf,
    worker: Option<OwnedWorker>,
}
impl Process {
    pub fn new(helper: PathBuf, metal: PathBuf, models: PathBuf, run: PathBuf) -> Self {
        Self {
            helper,
            metal,
            models,
            run,
            worker: None,
        }
    }
    fn socket(&self) -> PathBuf {
        self.run.join("mlx.sock")
    }

    pub async fn ensure_running(&mut self) -> Result<(), Error> {
        if self
            .worker
            .as_ref()
            .is_some_and(|worker| !worker.child.exit().has_exited())
        {
            return Ok(());
        }
        if let Some(mut previous) = self.worker.take() {
            let _ = previous.child.wait().await;
        }
        let run = self.run.clone();
        let lock = crate::blocking(move || {
            std::fs::create_dir_all(&run)
                .map_err(|_| Error::failed("could not create native runtime directory"))?;
            std::fs::set_permissions(&run, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| Error::failed("could not protect native runtime directory"))?;
            let lock = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(run.join("mlx.lock"))
                .map_err(|_| Error::failed("could not open native runtime lock"))?;
            if !crate::try_lock(&lock) {
                return Err(Error::Busy);
            }
            match std::fs::remove_file(run.join("mlx.sock")) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => return Err(Error::failed("could not retire stale native socket")),
            }
            Ok(lock)
        })
        .await?;
        let log = File::create(self.run.join("mlx.log"))
            .map_err(|_| Error::failed("could not create native runtime log"))?;
        let lifeline = crate::lifeline()
            .map_err(|_| Error::failed("could not create native runtime lifeline"))?;
        // SAFETY: the process-global Lifeline owns this descriptor throughout duplication.
        let reader = unsafe { BorrowedFd::borrow_raw(lifeline.reader()) }
            .try_clone_to_owned()
            .map_err(|_| Error::failed("could not pass native runtime lifeline"))?;
        // Standard I/O mappings and process_group use posix_spawn without pre-exec hooks.
        // This Rust worker watches its own lifeline, so no shell/descendant cancellation race.
        let mut command = Command::new(&self.helper);
        command
            .stdin(Stdio::from(reader))
            .stdout(Stdio::from(lock.try_clone().map_err(|_| {
                Error::failed("could not pass native runtime lock")
            })?))
            .env("AXO_INFER_LIFELINE_STDIN", "1")
            .process_group(0);
        command
            .arg("--model")
            .arg(&self.models)
            .arg("--metallib")
            .arg(&self.metal)
            .arg("--socket")
            .arg(self.socket())
            .env("TOKENIZERS_PARALLELISM", "false")
            .stderr(log);
        let child = command.spawn().map_err(|_| {
            Error::unavailable(
                "native MLX worker missing or not executable; update Axo on this Mac",
            )
        })?;
        self.worker = Some(OwnedWorker {
            child: WatchedChild::new(child)
                .map_err(|_| Error::failed("could not watch native worker"))?,
            _lock: lock,
        });
        let deadline = tokio::time::Instant::now() + Duration::from_secs(90);
        loop {
            if self
                .worker
                .as_ref()
                .is_some_and(|worker| worker.child.exit().has_exited())
            {
                return Err(Error::unsupported(
                    "Native MLX could not load this architecture, weights or tokenizer; inspect ai/mlx.log. No repository code was executed.",
                ));
            }
            if self
                .request(&json!({"op":"health"}), Duration::from_secs(1))
                .await
                .is_ok_and(|reply| reply["ready"] == true)
            {
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(Error::failed("native MLX initialization timed out"));
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    pub async fn request(&self, request: &Value, timeout: Duration) -> Result<Value, Error> {
        let bytes =
            serde_json::to_vec(request).map_err(|_| Error::invalid("invalid native request"))?;
        if bytes.len() > 65536 {
            return Err(Error::invalid("native request exceeds 64 KiB"));
        }
        let exchange = async {
            let mut stream = tokio::net::UnixStream::connect(self.socket())
                .await
                .map_err(|_| Error::failed("native worker is not ready"))?;
            stream
                .write_all(&bytes)
                .await
                .map_err(|_| Error::failed("native request write failed"))?;
            stream
                .shutdown()
                .await
                .map_err(|_| Error::failed("native request shutdown failed"))?;
            let mut body = Vec::new();
            stream
                .take(1024 * 1024 + 1)
                .read_to_end(&mut body)
                .await
                .map_err(|_| Error::failed("native response read failed"))?;
            if body.len() > 1024 * 1024 {
                return Err(Error::failed("native response exceeds its budget"));
            }
            let value: Value = serde_json::from_slice(&body)
                .map_err(|_| Error::failed("invalid native response JSON"))?;
            if value.get("error").is_some() {
                return Err(Error::unsupported(
                    "native MLX rejected this input/task/context; inspect ai/mlx.log",
                ));
            }
            Ok(value)
        };
        tokio::time::timeout(timeout, exchange)
            .await
            .map_err(|_| Error::failed("native MLX request timed out"))?
    }
    #[cfg(test)]
    pub fn pid(&self) -> Option<u32> {
        self.worker.as_ref().map(|worker| worker.child.id())
    }

    pub async fn loaded(&self) -> bool {
        self.request(&json!({"op":"health"}), Duration::from_secs(1))
            .await
            .is_ok_and(|value| value["ready"] == true)
    }
    pub async fn stop(mut self) {
        if let Some(mut worker) = self.worker.take() {
            terminate(&worker.child);
            // Retain ownership/lock until the native process has exited and been reaped.
            let _ = worker.child.wait().await;
        }
    }
}
fn terminate(child: &WatchedChild) {
    if !child.exit().has_exited() {
        // SAFETY: the unreaped PID is our own native worker; do not rely on cooperative GPU cancellation.
        unsafe {
            libc::kill(child.id() as i32, libc::SIGKILL);
        }
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        if let Some(mut worker) = self.worker.take() {
            terminate(&worker.child);
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = worker.child.wait().await;
                });
            }
        }
    }
}
