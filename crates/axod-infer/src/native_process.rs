//! Kill/reap containment shared by Axo's native MLX and Core ML workers.
//! Native runtimes are embedded in those workers, never dynamically installed servers.
#[cfg(test)]
#[path = "coreml_process_tests.rs"]
mod tests;
use crate::service::Error;
use axo_pty::exit::WatchedChild;
use serde_json::{Value, json};
use std::fs::{File, OpenOptions};
use std::os::fd::BorrowedFd;
use std::os::unix::{fs::PermissionsExt, process::CommandExt};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub(crate) enum Kind {
    Mlx { metal: PathBuf },
    CoreMl,
}
impl Kind {
    fn name(&self) -> &'static str {
        match self {
            Self::Mlx { .. } => "mlx",
            Self::CoreMl => "coreml",
        }
    }
    fn request_limit(&self) -> usize {
        match self {
            Self::Mlx { .. } => 65536,
            Self::CoreMl => 24 * 1024 * 1024,
        }
    }
}
struct OwnedWorker {
    child: WatchedChild,
    _lock: File,
}
pub(crate) struct Process {
    helper: PathBuf,
    kind: Kind,
    model: PathBuf,
    run: PathBuf,
    worker: Option<OwnedWorker>,
}
impl Process {
    pub fn new(helper: PathBuf, kind: Kind, model: PathBuf, run: PathBuf) -> Self {
        Self {
            helper,
            kind,
            model,
            run,
            worker: None,
        }
    }
    fn socket(&self) -> PathBuf {
        self.run.join(format!("{}.sock", self.kind.name()))
    }
    fn workspace(&self) -> PathBuf {
        self.socket().with_extension("work")
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
        let name = self.kind.name();
        let workspace = self.workspace();
        let lock = crate::blocking(move || {
            std::fs::create_dir_all(&run)
                .map_err(|_| Error::failed("could not create native runtime directory"))?;
            std::fs::set_permissions(&run, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| Error::failed("could not protect native runtime directory"))?;
            let lock = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(run.join(format!("{name}.lock")))
                .map_err(|_| Error::failed("could not open native runtime lock"))?;
            if !crate::try_lock(&lock) {
                return Err(Error::Busy);
            }
            match std::fs::remove_file(run.join(format!("{name}.sock"))) {
                Ok(()) => (),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                Err(_) => return Err(Error::failed("could not retire stale native socket")),
            }
            // Lock acquisition also proves an orphaned worker's inherited stdout has closed.
            // Only then may source snapshots/compiled assets left by a hard exit be removed.
            match std::fs::remove_dir_all(workspace) {
                Ok(()) => (),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                Err(_) => return Err(Error::failed("could not retire stale native workspace")),
            }
            Ok(lock)
        })
        .await?;
        let log = File::create(self.run.join(format!("{}.log", self.kind.name())))
            .map_err(|_| Error::failed("could not create native runtime log"))?;
        let lifeline = crate::lifeline()
            .map_err(|_| Error::failed("could not create native runtime lifeline"))?;
        // SAFETY: the process-global Lifeline retains the source descriptor during duplication.
        let reader = unsafe { BorrowedFd::borrow_raw(lifeline.reader()) }
            .try_clone_to_owned()
            .map_err(|_| Error::failed("could not pass native runtime lifeline"))?;
        let mut command = Command::new(&self.helper);
        command
            .stdin(Stdio::from(reader))
            .stdout(Stdio::from(lock.try_clone().map_err(|_| {
                Error::failed("could not pass native runtime lock")
            })?))
            .env("AXO_INFER_LIFELINE_STDIN", "1")
            .process_group(0)
            .arg("--model")
            .arg(&self.model);
        if let Kind::Mlx { metal } = &self.kind {
            command.arg("--metallib").arg(metal);
        }
        command
            .arg("--socket")
            .arg(self.socket())
            .env("TOKENIZERS_PARALLELISM", "false")
            .stderr(log);
        let child = command.spawn().map_err(|_| {
            Error::unavailable(
                "native inference worker missing or not executable; update Axo on this Mac",
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
                return Err(Error::unsupported(format!(
                    "Native {} could not load this model; inspect ai/{}.log. No repository code was executed.",
                    self.kind.name(),
                    self.kind.name()
                )));
            }
            if self
                .request(&json!({"op":"health"}), Duration::from_secs(1))
                .await
                .is_ok_and(|reply| reply["ready"] == true)
            {
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(Error::failed("native inference initialization timed out"));
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    pub async fn request(&self, request: &Value, timeout: Duration) -> Result<Value, Error> {
        let bytes =
            serde_json::to_vec(request).map_err(|_| Error::invalid("invalid native request"))?;
        if bytes.len() > self.kind.request_limit() {
            return Err(Error::invalid("native request exceeds its byte budget"));
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
                // Native diagnostics may contain feature values. Do not forward/log them.
                return Err(Error::unsupported(
                    "native inference rejected this input/task/context; check the model feature description and output selection",
                ));
            }
            Ok(value)
        };
        tokio::time::timeout(timeout, exchange)
            .await
            .map_err(|_| Error::failed("native inference request timed out"))?
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
            // Keep the lock and workspace until native execution has ended and been reaped.
            if worker.child.wait().await.is_ok() {
                let _ = std::fs::remove_dir_all(self.workspace());
            }
        }
    }
}
fn terminate(child: &WatchedChild) {
    if !child.exit().has_exited() {
        // SAFETY: this unreaped PID is our own worker, never a recycled PID.
        unsafe {
            libc::kill(child.id() as i32, libc::SIGKILL);
        }
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        if let Some(mut worker) = self.worker.take() {
            terminate(&worker.child);
            let workspace = self.workspace();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    if worker.child.wait().await.is_ok() {
                        let _ = std::fs::remove_dir_all(workspace);
                    }
                });
            }
            // Without an executor, leave files for the next locked launch, never remove live data.
        }
    }
}
