//! Launching Pi for a Session.

use std::fs;
use std::io;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use axo_pty::process::{self, PtyProcess, WindowSize};

use crate::{AgentCommand, BridgeSocketPath, SocketCleanup, WriterLock};

/// How long a stopped Pi gets before SIGKILL. On SIGTERM/SIGHUP Pi disposes its runtime (the
/// pi-axo extension closes and unlinks its bridge socket), then drains terminal input for up to
/// a second before exiting; a shell's half second would kill it partway and strand the socket.
pub const STOP_GRACE: Duration = Duration::from_secs(3);

/// Everything a Pi launch needs, borrowed from the caller's request.
pub struct PiLaunch<'a> {
    pub agent_command: &'a AgentCommand,
    pub initial_pwd: &'a Path,
    pub session_file: &'a Path,
    pub bridge_socket: &'a BridgeSocketPath,
    pub session_uuid: &'a str,
    pub pane_id: &'a str,
    pub home: &'a Path,
    /// Extra environment, such as the app's bundled terminal resources.
    pub environment: &'a [(&'static str, PathBuf)],
}

/// A launched Pi and the writer lock it inherited.
pub struct PiProcess {
    pub pty: PtyProcess,
    pub writer_lock: WriterLock,
    /// What was found at the bridge socket path before launching.
    pub socket_cleanup: SocketCleanup,
}

/// Starts Pi on a PTY. Pi inherits `writer_lock` (and only it), so the lock is held for as
/// long as this Pi or any of its descendants lives.
pub fn spawn(
    launch: &PiLaunch<'_>,
    writer_lock: WriterLock,
    bridge_token: &str,
    size: WindowSize,
) -> io::Result<PiProcess> {
    let socket_cleanup = launch.bridge_socket.remove_abandoned(&writer_lock)?;
    let extension = resolve_extension_path()?;
    let command_line = launch.agent_command.command();
    let executable = resolve_executable(&command_line.executable)?;
    let mut command = Command::new(executable);
    command
        .args(&command_line.arguments)
        .arg("--session")
        .arg(launch.session_file)
        .arg("--extension")
        .arg(extension)
        .current_dir(launch.initial_pwd)
        .env("HOME", launch.home)
        .env("PWD", launch.initial_pwd)
        .env("TERM", "xterm-ghostty")
        .env("AXO_SESSION_ID", launch.session_uuid)
        .env("AXO_PANE_ID", launch.pane_id)
        .env("AXO_PI_SESSION_FILE", launch.session_file)
        .env("AXO_PI_BRIDGE_SOCKET", launch.bridge_socket.as_path())
        .env("AXO_PI_BRIDGE_TOKEN", bridge_token);
    for (name, value) in launch.environment {
        command.env(name, value);
    }
    // The parent's copy of the lock stays close-on-exec so concurrent launches never leak it.
    let pty = process::spawn(command, size, &[writer_lock.as_raw_fd()])?;
    Ok(PiProcess {
        pty,
        writer_lock,
        socket_cleanup,
    })
}

/// Another Mac's Session, drawn by a Pi on this Mac that only shows it and sends what is typed
/// (RFD0024): `pi --no-session` with pi-axo in remote mode. It writes nothing and runs no model.
pub struct RemoteViewLaunch<'a> {
    pub agent_command: &'a AgentCommand,
    pub initial_pwd: &'a Path,
    pub home: &'a Path,
    pub host_id: &'a str,
    pub host_label: &'a str,
    pub session_id: &'a str,
    /// Extra environment: the terminal resources and `AXO_SOCKET`, which pi-axo calls.
    pub environment: &'a [(&'static str, PathBuf)],
}

/// pi-axo exits with this when the copy was cut back and it must draw it afresh: the pane
/// starts Pi again, in the same terminal. Any other exit ends the pane.
pub const REMOTE_VIEW_REDRAW_EXIT: i32 = 75;

/// Starts a remote view on a PTY. A shell loop restarts Pi on `REMOTE_VIEW_REDRAW_EXIT`.
pub fn spawn_remote_view(
    launch: &RemoteViewLaunch<'_>,
    size: WindowSize,
) -> io::Result<PtyProcess> {
    let extension = resolve_extension_path()?;
    let command_line = launch.agent_command.command();
    let executable = resolve_executable(&command_line.executable)?;
    let script = format!(
        "while :; do \"$0\" \"$@\"; status=$?; [ \"$status\" -eq {REMOTE_VIEW_REDRAW_EXIT} ] || exit \"$status\"; done"
    );
    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(script)
        .arg(executable)
        .args(&command_line.arguments)
        // Nothing runs here: no file, no tools, and none of this Mac's extensions, MCP servers,
        // skills or prompt templates. Only pi-axo, which draws the copy.
        .args([
            "--no-session",
            "--no-tools",
            "--no-extensions",
            "--no-mcp",
            "--no-skills",
            "--no-prompt-templates",
        ])
        .arg("--extension")
        .arg(extension)
        .current_dir(launch.initial_pwd)
        .env("HOME", launch.home)
        .env("PWD", launch.initial_pwd)
        .env("TERM", "xterm-ghostty")
        // A pane that only shows another Mac's Session has no business checking for updates.
        .env("PI_OFFLINE", "1")
        .env("PI_SKIP_VERSION_CHECK", "1")
        .env("AXO_REMOTE_HOST_ID", launch.host_id)
        .env("AXO_REMOTE_HOST_LABEL", launch.host_label)
        .env("AXO_REMOTE_SESSION_ID", launch.session_id)
        .env_remove("AXO_SESSION_ID")
        .env_remove("AXO_PI_BRIDGE_SOCKET");
    for (name, value) in launch.environment {
        command.env(name, value);
    }
    process::spawn(command, size, &[])
}

fn resolve_executable(program: &str) -> io::Result<PathBuf> {
    axo_pty::command::resolve_executable(program, Some("AXO_PI_EXECUTABLE"), "agent")
}

fn resolve_extension_path() -> io::Result<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = std::env::var_os("AXO_PI_EXTENSION_PATH") {
        candidates.push(PathBuf::from(path));
    }
    if let Some(resources) = std::env::var_os("AXO_RESOURCES_DIR") {
        candidates.push(PathBuf::from(resources).join("AxoPi/index.js"));
    }
    if let Ok(executable) = std::env::current_exe()
        && let Some(contents_directory) = executable.parent().and_then(Path::parent)
    {
        candidates.push(contents_directory.join("Resources/AxoPi/index.js"));
    }
    let path = candidates
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "bundled Pi Axo extension was not found",
            )
        })?;
    // Pi runs in the Workspace, not Axod's cwd. Resolve relative resource
    // overrides before handing them across that process boundary.
    fs::canonicalize(path)
}
