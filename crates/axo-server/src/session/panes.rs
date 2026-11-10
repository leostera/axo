//! A pane's process: a shell or a Pi on its own PTY, and how a shell is started.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use axo_agent::WriterLock;
use axo_protocol::{Availability, Event, GridSize, PaneRole, SessionId, ShellId, ShellRecord};
use axo_pty::exit::WatchedChild;
use axo_pty::process::{self, PtyProcess};
use axo_pty::{TerminalOutput, TerminalOutputSink, WindowSize};

use crate::core::Core;
use crate::settings::ShellCommand;
use crate::terminal_input::TerminalInput;

/// Tells apart the processes a pane has had: an exit or an attachment names the one it was for.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub(crate) struct RuntimeId(u64);

impl RuntimeId {
    pub(crate) fn next() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Self(NEXT.fetch_add(1, Ordering::Relaxed))
    }
}

impl std::fmt::Display for RuntimeId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

/// A pane's running process.
#[derive(Debug)]
pub(crate) struct Running {
    pub(crate) runtime_id: RuntimeId,
    pub(crate) role: PaneRole,
    pub(crate) pane_id: Option<String>,
    pub(crate) initial_pwd: PathBuf,
    pub(crate) child: WatchedChild,
    /// Shared with attached clients for input, resizing and termios queries; only the output
    /// pump reads it.
    pub(crate) master: OwnedFd,
    pub(crate) device: String,
    pub(crate) output: Arc<TerminalOutput>,
    /// Where input to the pane is written, off the Session's task.
    pub(crate) input: Arc<TerminalInput>,
    /// Live terminal attachments.
    pub(crate) attachments: usize,
    /// A Pi's transcript lock, released only once it has exited.
    _writer_lock: Option<WriterLock>,
}

impl Running {
    pub(crate) fn new(
        role: PaneRole,
        pane_id: Option<String>,
        initial_pwd: PathBuf,
        pty: PtyProcess,
        writer_lock: Option<WriterLock>,
    ) -> io::Result<Self> {
        Ok(Self {
            runtime_id: RuntimeId::next(),
            role,
            pane_id,
            initial_pwd,
            input: Arc::new(TerminalInput::new(&pty.master)?),
            child: pty.child,
            master: pty.master,
            device: pty.device,
            output: pty.output,
            attachments: 0,
            _writer_lock: writer_lock,
        })
    }

    /// How long this pane's process gets to exit when stopped, before SIGKILL.
    pub(crate) fn stop_grace(&self) -> Duration {
        match self.role {
            PaneRole::Terminal => process::SHELL_STOP_GRACE,
            PaneRole::Pi => axo_agent::pi::STOP_GRACE,
        }
    }

    /// Publishes its output as `terminal.output` events from now on, and runs `on_exit` (which
    /// must not block) when it exits.
    pub(crate) fn bind(
        &self,
        core: &Arc<Core>,
        session_id: SessionId,
        shell_id: ShellId,
        on_exit: impl FnOnce() + Send + 'static,
    ) {
        self.child.exit().on_exit(on_exit);
        self.output.bind(
            format!("session_id={session_id} shell_id={}", shell_id.get()),
            Arc::new(OutputSink {
                core: Arc::downgrade(core),
                session_id,
                shell_id,
            }),
        );
    }

    pub(crate) fn record(&self, id: ShellId, attach_socket_path: &Path) -> ShellRecord {
        ShellRecord {
            id,
            pane_id: self.pane_id.clone(),
            role: self.role,
            process_id: self.child.id(),
            initial_pwd: self.initial_pwd.clone(),
            pty_device: self.device.clone(),
            attach_socket_path: attach_socket_path.to_path_buf(),
            availability: Availability::Available,
        }
    }

    /// A copy of the PTY master, for an attachment.
    pub(crate) fn duplicate_master(&self) -> io::Result<OwnedFd> {
        // SAFETY: fcntl duplicates the live PTY master; the result is owned below.
        let fd = unsafe { libc::fcntl(self.master.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
        if fd == -1 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: fcntl returned a new, owned descriptor.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// Stops the process: SIGHUP and SIGTERM, then SIGKILL after its grace. The PTY and a Pi's
    /// writer lock are released only after it has exited.
    pub(crate) async fn stop(mut self) {
        let grace = self.stop_grace();
        process::stop_async(&mut self.child, grace).await;
        self.output.stop();
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        // A pane gone from its Session ends its output stream even if a stray process still
        // holds the PTY slave open.
        self.output.stop();
    }
}

/// Stops every pane in `panes` at once, without holding up the caller's task.
pub(crate) fn stop_in_background(panes: Vec<Running>) {
    for pane in panes {
        tokio::spawn(pane.stop());
    }
}

/// Publishes one pane's output as `terminal.output` events, while anyone streams it.
struct OutputSink {
    core: std::sync::Weak<Core>,
    session_id: SessionId,
    shell_id: ShellId,
}

impl TerminalOutputSink for OutputSink {
    fn publish_terminal_output(&self, sequence: u64, output: &[u8]) {
        let Some(core) = self.core.upgrade() else {
            return;
        };
        // Most of the time nobody streams terminal bytes; skip the base64 work then.
        if !core.events.wants_terminal_output() {
            return;
        }
        core.events.publish(Event::TerminalOutput {
            session_id: self.session_id,
            shell_id: self.shell_id,
            sequence,
            data: axo_protocol::base64::encode(output),
        });
    }
}

pub(crate) fn window_size(grid: GridSize) -> WindowSize {
    // A grid is at least 1x1 and fits u16, so this always succeeds.
    WindowSize::new(u32::from(grid.rows()), u32::from(grid.columns()))
        .unwrap_or(WindowSize::DEFAULT)
}

fn app_resources_directory() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    Some(executable.parent()?.parent()?.join("Resources"))
}

/// Points terminal programs at the app's bundled Ghostty shell integration and terminfo.
pub(crate) fn terminal_environment() -> Vec<(&'static str, PathBuf)> {
    let mut environment = Vec::new();
    if let Some(resources) = app_resources_directory() {
        let ghostty = resources.join("ghostty-resources");
        if ghostty.join("shell-integration").is_dir() {
            environment.push(("GHOSTTY_RESOURCES_DIR", ghostty));
        }
        let terminfo = resources.join("terminfo");
        if terminfo.join("78/xterm-ghostty").is_file() {
            environment.push(("TERMINFO", terminfo));
        }
    }
    environment
}

/// A Pi's environment: the terminal resources, plus where axod listens (`AXO_SOCKET`) and the
/// `axod` executable (`AXOD`), so pi-axo can start `axod mcp` for its Session.
pub(crate) fn pi_environment(agent_socket: &Path) -> Vec<(&'static str, PathBuf)> {
    let mut environment = terminal_environment();
    environment.push(("AXO_SOCKET", agent_socket.to_path_buf()));
    if let Ok(executable) = std::env::current_exe() {
        environment.push(("AXOD", executable));
    }
    environment
}

pub(crate) fn spawn_shell(
    shell_command: &ShellCommand,
    initial_pwd: &Path,
    size: WindowSize,
) -> io::Result<Running> {
    let shell = axo_pty::command::resolve_executable(&shell_command.0.executable, None, "shell")?;
    let home = crate::current_user_home_directory()?;
    let mut command = Command::new(&shell);
    command
        .args(&shell_command.0.arguments)
        .arg("-l")
        .current_dir(initial_pwd)
        .env("HOME", &home)
        .env("SHELL", &shell)
        .env("PWD", initial_pwd)
        .env("TERM", "xterm-ghostty");
    for (name, value) in terminal_environment() {
        command.env(name, value);
    }
    let pty = process::spawn(command, size, &[])?;
    Running::new(
        PaneRole::Terminal,
        None,
        initial_pwd.to_path_buf(),
        pty,
        None,
    )
}
