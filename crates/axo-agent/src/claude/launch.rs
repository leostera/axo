//! Launching Claude Code for a Session (RFD0072, Claude Code): the TUI on the pane's PTY,
//! with Axo's brief appended to its system prompt, Axo's MCP server, and HTTP hooks to a
//! listener of axod's for this launch. It holds the Session's agent lock
//! (`<agents>/<session>.jsonl.lock`), inherited as Pi inherits its transcript's.
//!
//! The conversation's id is chosen by axod (the Session's own id) and passed as
//! `--session-id`; once Claude has written its transcript, later launches `--resume` it.

use std::io;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Command;

use axo_pty::process::{self, PtyProcess, WindowSize};

use crate::WriterLock;
use crate::axo_mcp::AxoMcp;
use crate::claude::hooks::{self, HookListener};
use crate::process::ProcessIdentity;

/// Where a Session's Claude Code keeps its lock.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClaudePaths {
    lock_base: PathBuf,
}

impl ClaudePaths {
    pub fn new(directory: &Path, session_uuid: &str) -> Self {
        Self {
            lock_base: directory.join(format!("{session_uuid}.jsonl")),
        }
    }

    /// Whether a Claude Code for the Session is alive: some process holds its lock.
    pub fn is_running(&self) -> io::Result<bool> {
        WriterLock::is_held(&self.lock_base)
    }
}

/// Everything a Claude Code launch needs.
#[derive(Clone, Debug)]
pub struct ClaudeLaunch {
    /// The `claude` executable, as discovery found it.
    pub executable: PathBuf,
    pub paths: ClaudePaths,
    pub initial_pwd: PathBuf,
    pub session_uuid: String,
    pub pane_id: String,
    pub home: PathBuf,
    /// Claude's configuration directory, where it keeps transcripts: `$CLAUDE_CONFIG_DIR`, or
    /// `~/.claude` ([`config_directory`]).
    pub config_dir: PathBuf,
    /// Extra environment, such as the app's bundled terminal resources and `AXO_SOCKET`.
    pub environment: Vec<(&'static str, PathBuf)>,
    /// The conversation's id: a UUID axod chose.
    pub conversation: String,
    /// Axo's brief, appended to Claude's system prompt.
    pub brief: Option<String>,
    pub mcp: Option<AxoMcp>,
    /// The Claude an earlier axod started, if it said: killed if it still holds the lock.
    pub previous: Option<ProcessIdentity>,
    pub size: WindowSize,
}

/// A launched Claude Code: its TUI on a PTY and the hooks it posts.
pub struct ClaudeProcess {
    pub pty: PtyProcess,
    /// Axod's own hold on the agent lock, released when the Session lets Claude go.
    pub writer_lock: WriterLock,
    pub hooks: HookListener,
    pub identity: Option<ProcessIdentity>,
    pub conversation: String,
}

/// Launches Claude Code, blocking (run it on the blocking pool).
pub fn launch(launch: &ClaudeLaunch) -> io::Result<ClaudeProcess> {
    let writer_lock = crate::lock::take_server_lock(
        &launch.paths.lock_base,
        launch.previous,
        &format!("event=claude.previous_killed session_id={}", launch.session_uuid),
        "another process holds this Session's Claude Code",
    )?;
    let hooks = HookListener::bind()?;
    let mut command = Command::new(&launch.executable);
    let resuming = transcript_exists(&launch.config_dir, &launch.conversation);
    command
        .arg(if resuming { "--resume" } else { "--session-id" })
        .arg(&launch.conversation)
        .arg("--settings")
        .arg(hooks::settings(hooks.url()).to_string());
    if let Some(mcp) = &launch.mcp {
        command.arg("--mcp-config").arg(mcp.claude_config().to_string());
    }
    if let Some(brief) = &launch.brief {
        command.arg("--append-system-prompt").arg(brief);
    }
    command
        .current_dir(&launch.initial_pwd)
        .env("HOME", &launch.home)
        .env("PWD", &launch.initial_pwd)
        .env("TERM", "xterm-ghostty")
        .env("AXO_SESSION_ID", &launch.session_uuid)
        .env("AXO_PANE_ID", &launch.pane_id);
    for (name, value) in &launch.environment {
        command.env(name, value);
    }
    let pty = process::spawn(command, launch.size, &[writer_lock.as_raw_fd()])?;
    Ok(ClaudeProcess {
        identity: ProcessIdentity::of(pty.child.id()),
        pty,
        writer_lock,
        hooks,
        conversation: launch.conversation.clone(),
    })
}

/// Claude's configuration directory for `home`, as Claude finds it.
pub fn config_directory(home: &Path) -> PathBuf {
    std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .filter(|directory| directory.is_absolute())
        .unwrap_or_else(|| home.join(".claude"))
}

/// Whether Claude has written the conversation's transcript, in any project:
/// `<config>/projects/<project>/<conversation>.jsonl`. A conversation it never wrote cannot
/// be resumed.
pub fn transcript_exists(config_dir: &Path, conversation: &str) -> bool {
    let Ok(projects) = std::fs::read_dir(config_dir.join("projects")) else {
        return false;
    };
    let file = format!("{conversation}.jsonl");
    projects
        .flatten()
        .any(|project| project.path().join(&file).is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_conversation_is_resumed_only_once_claude_has_written_it() {
        let home = crate::test_directory();
        assert!(!transcript_exists(&home, "c1"));
        let project = home.join("projects/-tmp-work");
        std::fs::create_dir_all(&project).unwrap();
        assert!(!transcript_exists(&home, "c1"));
        std::fs::write(project.join("c1.jsonl"), "{}\n").unwrap();
        assert!(transcript_exists(&home, "c1"));
        assert!(!transcript_exists(&home, "c2"));
        std::fs::remove_dir_all(&home).unwrap();
    }
}
