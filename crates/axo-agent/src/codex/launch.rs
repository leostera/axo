//! Launching Codex for a Session (RFD0072, Codex): a private `codex app-server` on a Unix
//! socket, under the lifeline guard and holding the Session's agent lock, then the TUI in the
//! pane attached to it with `--remote` and resuming the Session's thread.
//!
//! The lock (`<agents>/<session>.jsonl.lock`) is held by the guard shell for as long as the
//! server lives, so holding it proves no Codex for the Session is alive, as the transcript
//! lock does for Pi. The TUI does not hold it: it cannot outlive its server for long, it exits
//! when the server goes, and the PTY's hangup ends it with axod.

use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use axo_pty::lifeline::Lifeline;
use axo_pty::process::{self, PtyProcess, WindowSize};

use crate::WriterLock;
use crate::axo_mcp::AxoMcp;
use crate::process::ProcessIdentity;
use crate::codex::link::{ServerProcess, create_thread, wait_until_listening};
use crate::lock::FORK_EXEC_WINDOW;

/// How long a killed earlier server (the guard, the server and the helpers it started) gets
/// to let go of the lock.
const KILLED_RELEASE: std::time::Duration = std::time::Duration::from_secs(5);
/// The longest socket path macOS takes (`sun_path` is 104 bytes, with its terminator).
const MAX_SOCKET_PATH: usize = 103;

/// Where a Session's Codex keeps its lock and socket: `<directory>/<session>.jsonl.lock` and
/// `<directory>/<session>.codex.sock`, or `/tmp/axo-codex-<session>.sock` when that is too long
/// to bind (as Pi's bridge socket falls back).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodexPaths {
    lock_base: PathBuf,
    socket: PathBuf,
}

impl CodexPaths {
    /// Fails if even the fallback socket path is too long to bind.
    pub fn new(directory: &Path, session_uuid: &str) -> io::Result<Self> {
        let mut socket = directory.join(format!("{session_uuid}.codex.sock"));
        if socket.as_os_str().len() > MAX_SOCKET_PATH {
            socket = PathBuf::from("/tmp").join(format!("axo-codex-{session_uuid}.sock"));
        }
        if socket.as_os_str().len() > MAX_SOCKET_PATH {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "the Codex socket path is too long for a Unix socket",
            ));
        }
        Ok(Self {
            lock_base: directory.join(format!("{session_uuid}.jsonl")),
            socket,
        })
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// Whether a Codex for the Session is alive: some process holds its lock.
    pub fn is_running(&self) -> io::Result<bool> {
        WriterLock::is_held(&self.lock_base)
    }
}

/// Everything a Codex launch needs.
#[derive(Clone, Debug)]
pub struct CodexLaunch {
    /// The `codex` executable, as discovery found it.
    pub executable: PathBuf,
    pub paths: CodexPaths,
    pub initial_pwd: PathBuf,
    pub session_uuid: String,
    pub pane_id: String,
    pub home: PathBuf,
    /// Extra environment, such as the app's bundled terminal resources and `AXO_SOCKET`.
    pub environment: Vec<(&'static str, PathBuf)>,
    /// The Session's thread; `None` for a new Session, whose thread is started and named.
    pub thread_id: Option<String>,
    /// The new thread's name.
    pub thread_name: String,
    /// Axo's brief, as the thread's developer instructions.
    pub instructions: Option<String>,
    /// Axo's MCP server, configured on the app-server.
    pub mcp: Option<AxoMcp>,
    /// The server an earlier axod started for this Session, if it said: killed if it still
    /// holds the Session's lock.
    pub previous: Option<ProcessIdentity>,
    pub size: WindowSize,
}

/// A launched Codex: its server, its TUI on a PTY, and the thread they share.
pub struct CodexProcess {
    pub pty: PtyProcess,
    /// Axod's own hold on the agent lock, released when the Session lets the Codex go.
    pub writer_lock: WriterLock,
    pub server: ServerProcess,
    /// Who the server is, for a later axod to kill should it outlive this one.
    pub identity: Option<ProcessIdentity>,
    pub thread_id: String,
}

/// The first half of a launch, blocking (run it on the blocking pool): takes the agent lock,
/// removes what an earlier server left at the socket path, and starts the server under the
/// lifeline's guard, which holds the lock for as long as it runs.
pub fn start_server(
    launch: &CodexLaunch,
    lifeline: &Lifeline,
) -> io::Result<(WriterLock, ServerProcess)> {
    let writer_lock = take_lock(launch)?;
    remove_abandoned_socket(launch.paths.socket())?;
    let mut guard = lifeline.guarded(&launch.executable, Some(&writer_lock.shared_file()?))?;
    if let Some(mcp) = &launch.mcp {
        guard.args(mcp.codex_overrides());
    }
    guard
        .args(["app-server", "--listen"])
        .arg(format!("unix://{}", launch.paths.socket().display()))
        .current_dir(&launch.initial_pwd)
        .stderr(Stdio::null());
    environment(&mut guard, launch);
    let child = guard.spawn()?;
    Ok((writer_lock, ServerProcess::new(child)))
}

/// Takes the Session's lock. A server an earlier axod started that still holds it is killed
/// (it and its process group), and the lock taken once it lets go; any other holder is not
/// signalled and the launch fails.
fn take_lock(launch: &CodexLaunch) -> io::Result<WriterLock> {
    match WriterLock::acquire_within(&launch.paths.lock_base, FORK_EXEC_WINDOW) {
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
            let Some(previous) = launch.previous.filter(|previous| previous.is_running()) else {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "another process holds this Session's Codex",
                ));
            };
            log::warn!(
                "event=codex.previous_killed session_id={} pid={}",
                launch.session_uuid,
                previous.pid
            );
            previous.kill();
            WriterLock::acquire_within(&launch.paths.lock_base, KILLED_RELEASE)
        }
        acquired => acquired,
    }
}

/// The second half: once the server listens, starts or confirms the thread and starts the TUI
/// on it. A failure drops `server`, which stops it.
pub async fn attach(
    launch: CodexLaunch,
    writer_lock: WriterLock,
    server: ServerProcess,
) -> io::Result<CodexProcess> {
    let thread_id = match &launch.thread_id {
        // The TUI connects at once and gives up if nothing listens.
        Some(thread_id) => {
            wait_until_listening(launch.paths.socket()).await?;
            thread_id.clone()
        }
        None => {
            create_thread(
                launch.paths.socket(),
                &launch.initial_pwd,
                &launch.thread_name,
                launch.instructions.as_deref(),
                &format!("session_id={}", launch.session_uuid),
            )
            .await?
        }
    };
    let pty = tokio::task::spawn_blocking({
        let thread_id = thread_id.clone();
        move || start_tui(&launch, &thread_id)
    })
    .await
    .map_err(io::Error::other)??;
    Ok(CodexProcess {
        pty,
        writer_lock,
        identity: ProcessIdentity::of(server.id()),
        server,
        thread_id,
    })
}

fn start_tui(launch: &CodexLaunch, thread_id: &str) -> io::Result<PtyProcess> {
    let mut command = Command::new(&launch.executable);
    command
        .arg("--remote")
        .arg(format!("unix://{}", launch.paths.socket().display()))
        .arg("resume")
        .arg(thread_id)
        .current_dir(&launch.initial_pwd);
    environment(&mut command, launch);
    process::spawn(command, launch.size, &[])
}

fn environment(command: &mut Command, launch: &CodexLaunch) {
    command
        .env("HOME", &launch.home)
        .env("PWD", &launch.initial_pwd)
        .env("TERM", "xterm-ghostty")
        .env("AXO_SESSION_ID", &launch.session_uuid)
        .env("AXO_PANE_ID", &launch.pane_id);
    for (name, value) in &launch.environment {
        command.env(name, value);
    }
}

/// Removes a socket (or Codex's symlink to one) left by a server that is gone: the caller
/// holds the lock, so no server for the Session is alive. Anything else there is refused.
fn remove_abandoned_socket(socket: &Path) -> io::Result<()> {
    use std::os::unix::fs::FileTypeExt;
    match std::fs::symlink_metadata(socket) {
        Ok(metadata) if metadata.file_type().is_socket() || metadata.file_type().is_symlink() => {
            std::fs::remove_file(socket)
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "something other than a socket is at the Codex socket path",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
#[path = "launch_tests.rs"]
mod tests;
