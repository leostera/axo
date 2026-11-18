//! Launching OpenCode for a Session (RFD0072, OpenCode): a private `opencode serve` on a
//! loopback port with a password of its own, under the lifeline guard and holding the
//! Session's agent lock, then the TUI in the pane attached to it with `--server` and the
//! Session's OpenCode session.
//!
//! As for Codex, the guard shell holds the lock (`<agents>/<session>.jsonl.lock`) for as long
//! as the server lives. The server writes `server listening on <url>` once it listens, on
//! stdout, which the guard sends to its stderr; axod reads the address there.

use std::io::{self, BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use axo_pty::lifeline::Lifeline;
use axo_pty::process::{self, PtyProcess, WindowSize};
use serde_json::json;

use crate::WriterLock;
use crate::axo_mcp::AxoMcp;
use crate::channel::ServerProcess;
use crate::opencode::client::ServerAddress;
use crate::opencode::link::{create_session, wait_until_listening};
use crate::process::ProcessIdentity;

/// How long the server gets to say where it listens.
const LISTEN_DEADLINE: Duration = Duration::from_secs(30);

/// Where a Session's OpenCode keeps its lock and its conversation: `<directory>/<session>
/// .jsonl.lock` and `<directory>/<session>.opencode.json`, the session's export.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpenCodePaths {
    lock_base: PathBuf,
    conversation: PathBuf,
}

impl OpenCodePaths {
    pub fn new(directory: &Path, session_uuid: &str) -> Self {
        Self {
            lock_base: directory.join(format!("{session_uuid}.jsonl")),
            conversation: directory.join(format!("{session_uuid}.opencode.json")),
        }
    }

    pub fn conversation(&self) -> &Path {
        &self.conversation
    }

    /// Whether an OpenCode for the Session is alive: some process holds its lock.
    pub fn is_running(&self) -> io::Result<bool> {
        WriterLock::is_held(&self.lock_base)
    }
}

/// Everything an OpenCode launch needs.
#[derive(Clone, Debug)]
pub struct OpenCodeLaunch {
    /// The `opencode` executable, as discovery found it.
    pub executable: PathBuf,
    pub paths: OpenCodePaths,
    pub initial_pwd: PathBuf,
    pub session_uuid: String,
    pub pane_id: String,
    pub home: PathBuf,
    /// Extra environment, such as the app's bundled terminal resources and `AXO_SOCKET`.
    pub environment: Vec<(&'static str, PathBuf)>,
    /// The Session's OpenCode session; `None` for a new Session, whose session is created.
    pub session_id: Option<String>,
    /// The new session's title.
    pub session_name: String,
    /// Axo's MCP server, configured on the server; it carries Axo's brief in its instructions.
    pub mcp: Option<AxoMcp>,
    /// The server an earlier axod started for this Session, if it said: killed if it still
    /// holds the Session's lock.
    pub previous: Option<ProcessIdentity>,
    pub size: WindowSize,
}

/// A launched OpenCode: its server, its TUI on a PTY, and the session they share.
pub struct OpenCodeProcess {
    pub pty: PtyProcess,
    /// Axod's own hold on the agent lock, released when the Session lets OpenCode go.
    pub writer_lock: WriterLock,
    pub server: ServerProcess,
    /// Who the server is, for a later axod to kill should it outlive this one.
    pub identity: Option<ProcessIdentity>,
    pub address: ServerAddress,
    pub session_id: String,
}

/// The first half of a launch, blocking (run it on the blocking pool): takes the agent lock,
/// starts the server under the lifeline's guard, and waits until it says where it listens.
pub fn start_server(
    launch: &OpenCodeLaunch,
    lifeline: &Lifeline,
) -> io::Result<(WriterLock, ServerProcess, ServerAddress)> {
    let writer_lock = crate::lock::take_server_lock(
        &launch.paths.lock_base,
        launch.previous,
        &format!("event=opencode.previous_killed session_id={}", launch.session_uuid),
        "another process holds this Session's OpenCode",
    )?;
    let password = password()?;
    let mut guard = lifeline.guarded(&launch.executable, Some(&writer_lock.shared_file()?))?;
    guard
        .args(["serve", "--hostname", "127.0.0.1"])
        .current_dir(&launch.initial_pwd)
        .stderr(Stdio::piped())
        .env("OPENCODE_SERVER_PASSWORD", &password);
    if let Some(mcp) = &launch.mcp {
        let config = json!({ "mcp": { "axo": mcp.opencode_config() } });
        guard.env("OPENCODE_CONFIG_CONTENT", config.to_string());
    }
    environment(&mut guard, launch);
    let mut child = guard.spawn()?;
    let output = child.stderr.take();
    let server = ServerProcess::new(child);
    let output = output.ok_or_else(|| io::Error::other("OpenCode's output is not readable"))?;
    let address = listening_address(output, password)?;
    Ok((writer_lock, server, address))
}

/// Reads the server's output until it says where it listens, then keeps reading it on a
/// thread of its own so that the server never blocks on a full pipe.
fn listening_address(output: std::process::ChildStderr, password: String) -> io::Result<ServerAddress> {
    let (found, address) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("opencode-output".into())
        .spawn(move || {
            let mut lines = BufReader::new(output);
            let mut line = String::new();
            let mut found = Some(found);
            loop {
                line.clear();
                match lines.read_line(&mut line) {
                    Ok(0) | Err(_) => return,
                    Ok(_) => {}
                }
                if let Some(address) = ServerAddress::from_listening_line(&line, String::new())
                    && let Some(found) = found.take()
                {
                    let _ = found.send(address.url);
                }
            }
        })?;
    let url = address.recv_timeout(LISTEN_DEADLINE).map_err(|_| {
        io::Error::new(io::ErrorKind::TimedOut, "OpenCode's server did not say where it listens")
    })?;
    Ok(ServerAddress { url, password })
}

/// A password only axod and this Session's TUI know: 244 random bits.
fn password() -> io::Result<String> {
    Ok(format!(
        "{}{}",
        axo_protocol::new_uuid_v4()?.replace('-', ""),
        axo_protocol::new_uuid_v4()?.replace('-', "")
    ))
}

/// The second half: once the server answers, creates or confirms the session and starts the
/// TUI on it. A failure drops `server`, which stops it.
pub async fn attach(
    launch: OpenCodeLaunch,
    writer_lock: WriterLock,
    server: ServerProcess,
    address: ServerAddress,
) -> io::Result<OpenCodeProcess> {
    let session_id = match &launch.session_id {
        Some(session_id) => {
            wait_until_listening(&address).await?;
            session_id.clone()
        }
        None => create_session(&address, &launch.initial_pwd, &launch.session_name).await?,
    };
    let pty = tokio::task::spawn_blocking({
        let session_id = session_id.clone();
        let address = address.clone();
        move || start_tui(&launch, &address, &session_id)
    })
    .await
    .map_err(io::Error::other)??;
    Ok(OpenCodeProcess {
        pty,
        writer_lock,
        identity: ProcessIdentity::of(server.id()),
        server,
        address,
        session_id,
    })
}

fn start_tui(launch: &OpenCodeLaunch, address: &ServerAddress, session_id: &str) -> io::Result<PtyProcess> {
    let mut command = Command::new(&launch.executable);
    command
        .arg("--server")
        .arg(&address.url)
        .arg("--session")
        .arg(session_id)
        .current_dir(&launch.initial_pwd)
        .env("OPENCODE_PASSWORD", &address.password);
    environment(&mut command, launch);
    process::spawn(command, launch.size, &[])
}

fn environment(command: &mut Command, launch: &OpenCodeLaunch) {
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

#[cfg(test)]
#[path = "launch_tests.rs"]
mod tests;
