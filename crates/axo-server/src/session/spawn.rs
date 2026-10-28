//! Starting a plain shell on a PTY, with the bundled terminfo and Ghostty resources.

use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use super::RunningShell;
use super::settings::ShellCommand;
use axo_panes::RuntimeId;
use axo_protocol::{PaneRole, SessionId};
use axo_pty::WindowSize;
use axo_pty::process::{self, PtyProcess};

fn app_resources_directory() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    Some(executable.parent()?.parent()?.join("Resources"))
}

fn bundled_ghostty_resources_directory() -> Option<PathBuf> {
    let resources_directory = app_resources_directory()?.join("ghostty-resources");
    resources_directory
        .join("shell-integration")
        .is_dir()
        .then_some(resources_directory)
}

fn bundled_terminfo_directory() -> Option<PathBuf> {
    let terminfo_directory = app_resources_directory()?.join("terminfo");
    terminfo_directory
        .join("78/xterm-ghostty")
        .is_file()
        .then_some(terminfo_directory)
}

/// Points terminal programs at the app's bundled Ghostty shell integration and terminfo.
pub(super) fn terminal_environment() -> Vec<(&'static str, PathBuf)> {
    let mut environment = Vec::new();
    if let Some(resources_directory) = bundled_ghostty_resources_directory() {
        environment.push(("GHOSTTY_RESOURCES_DIR", resources_directory));
    }
    if let Some(terminfo_directory) = bundled_terminfo_directory() {
        environment.push(("TERMINFO", terminfo_directory));
    }
    environment
}

/// The local socket this Axod serves, for agents that call back into it (RFD0015).
static AGENT_SOCKET: OnceLock<PathBuf> = OnceLock::new();

/// Records the socket agents are told to call. Set once, before any Pi starts.
pub(crate) fn set_agent_socket(path: &Path) {
    let _ = AGENT_SOCKET.set(path.to_path_buf());
}

/// A Pi's environment: the terminal resources, plus where Axod listens (`AXO_SOCKET`) and the
/// `axod` executable (`AXOD`), so pi-axo can start `axod mcp` for its Session.
pub(super) fn pi_environment() -> Vec<(&'static str, PathBuf)> {
    let mut environment = terminal_environment();
    if let Some(socket) = AGENT_SOCKET.get() {
        environment.push(("AXO_SOCKET", socket.clone()));
        if let Ok(executable) = std::env::current_exe() {
            environment.push(("AXOD", executable));
        }
    }
    environment
}

fn set_terminal_resources(command: &mut Command) {
    for (name, value) in terminal_environment() {
        command.env(name, value);
    }
}

pub(super) fn spawn_shell(
    shell_command: &ShellCommand,
    session_id: SessionId,
    initial_pwd: &Path,
    size: WindowSize,
) -> io::Result<RunningShell> {
    let shell = resolve_shell_executable(&shell_command.0.executable)?;
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
    set_terminal_resources(&mut command);
    let PtyProcess {
        child,
        master,
        device: slave_device,
        output,
    } = process::spawn(command, size, &[])?;
    Ok(RunningShell {
        runtime_id: RuntimeId::next(),
        session_id,
        role: PaneRole::Terminal,
        pane_id: None,
        initial_pwd: initial_pwd.to_path_buf(),
        child,
        wait_error_reported: false,
        master,
        slave_device,
        attachments: 0,
        output,
        last_input_sequence: None,
        _writer_lock: None,
        pi_bridge_socket: None,
        pi_bridge_token: None,
    })
}

fn resolve_shell_executable(program: &str) -> io::Result<PathBuf> {
    axo_pty::command::resolve_executable(program, None, "shell")
}
