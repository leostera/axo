//! The `bash` tool of a host connection (RFD0016): one non-interactive command, run as the user
//! axod runs as, in a login shell so the user's PATH and tools are there. It runs on a thread of
//! its own, so the relay keeps serving while it does, and its reply goes back only on the socket
//! the request came on.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::fragments;

pub const METHOD: &str = "axo.connections.bash";
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);
pub const MAX_TIMEOUT: Duration = Duration::from_secs(600);
/// Output kept per stream; the rest is read and thrown away.
pub const MAX_OUTPUT_BYTES: usize = 1_048_576;
const MAX_COMMAND_BYTES: usize = 65_536;
const TRUNCATED: &str = "\n[output truncated by Axo]\n";
/// After the shell exits, how long background children may keep its output open.
const DRAIN_GRACE: Duration = Duration::from_secs(1);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BashParams {
    /// The account that sent it; axod refuses a command for any other.
    pub account_id: String,
    pub call_id: String,
    pub command: String,
    #[serde(default)]
    pub cwd: Option<PathBuf>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BashResult {
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
    pub timed_out: bool,
    pub duration_ms: u64,
}

/// Checks a request: `Err` is a JSON-RPC error for the reply.
pub fn parse(params: &Value, account_id: &str) -> Result<BashParams, (i64, String)> {
    let params: BashParams = serde_json::from_value(params.clone())
        .map_err(|error| (-32602, format!("Invalid params: {error}")))?;
    if params.account_id != account_id {
        return Err((-32003, "this Mac belongs to another account".into()));
    }
    if params.command.is_empty() || params.command.len() > MAX_COMMAND_BYTES {
        return Err((-32602, "command must be 1 to 65536 bytes".into()));
    }
    if params.cwd.as_ref().is_some_and(|cwd| !cwd.is_absolute()) {
        return Err((-32602, "cwd must be an absolute path".into()));
    }
    if params
        .timeout_ms
        .is_some_and(|ms| ms == 0 || ms > MAX_TIMEOUT.as_millis() as u64)
    {
        return Err((-32602, "timeoutMs must be 1 to 600000".into()));
    }
    Ok(params)
}

/// Runs the command to its end or its timeout. `Err` only when it could not start.
pub fn run(params: &BashParams) -> Result<BashResult, (i64, String)> {
    let started = Instant::now();
    let timeout = params
        .timeout_ms
        .map(Duration::from_millis)
        .unwrap_or(DEFAULT_TIMEOUT);
    let shell = std::env::var_os("SHELL")
        .filter(|shell| !shell.is_empty())
        .unwrap_or_else(|| "/bin/zsh".into());
    let mut command = Command::new(shell);
    command
        .arg("-l")
        .arg("-c")
        .arg(&params.command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Its own process group, so a timeout ends everything it started.
        .process_group(0);
    if let Some(cwd) = &params.cwd {
        command.current_dir(cwd);
    } else if let Some(home) = std::env::var_os("HOME") {
        command.current_dir(home);
    }
    let mut child = command
        .spawn()
        .map_err(|error| (-32010, format!("could not start the command: {error}")))?;
    let stdout = Captured::start(child.stdout.take().expect("piped"));
    let stderr = Captured::start(child.stderr.take().expect("piped"));

    let (status, timed_out) = wait(&mut child, timeout);
    // Background children may hold the output open; give them a moment, then end the group.
    let drained = Instant::now() + DRAIN_GRACE;
    while !(stdout.finished() && stderr.finished()) && Instant::now() < drained {
        thread::sleep(Duration::from_millis(10));
    }
    if !(stdout.finished() && stderr.finished()) {
        kill_group(&child);
    }

    use std::os::unix::process::ExitStatusExt;
    let (stdout, stdout_truncated) = stdout.take();
    let (stderr, stderr_truncated) = stderr.take();
    let mut result = BashResult {
        exit_code: status.and_then(|s| s.code()),
        signal: status.and_then(|s| s.signal()),
        stdout,
        stderr,
        stdout_truncated,
        stderr_truncated,
        timed_out,
        duration_ms: started.elapsed().as_millis() as u64,
    };
    fit_in_one_message(&mut result);
    Ok(result)
}

fn wait(child: &mut Child, timeout: Duration) -> (Option<std::process::ExitStatus>, bool) {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return (Some(status), false),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                kill_group(child);
                return (child.wait().ok(), true);
            }
            Err(_) => return (None, false),
        }
    }
}

fn kill_group(child: &Child) {
    // The child leads its own group (process_group(0)), so its pid is the group's id.
    unsafe {
        libc::killpg(child.id() as libc::pid_t, libc::SIGKILL);
    }
}

/// One output stream, read on its own thread: the first `MAX_OUTPUT_BYTES` kept.
struct Captured {
    buffer: Arc<Mutex<(Vec<u8>, bool)>>,
    reader: JoinHandle<()>,
}

impl Captured {
    fn start(mut stream: impl Read + Send + 'static) -> Self {
        let buffer = Arc::new(Mutex::new((Vec::new(), false)));
        let shared = Arc::clone(&buffer);
        let reader = thread::spawn(move || {
            let mut chunk = [0_u8; 16_384];
            while let Ok(read) = stream.read(&mut chunk) {
                if read == 0 {
                    break;
                }
                let Ok(mut buffer) = shared.lock() else {
                    break;
                };
                let room = MAX_OUTPUT_BYTES.saturating_sub(buffer.0.len());
                buffer.0.extend_from_slice(&chunk[..read.min(room)]);
                if read > room {
                    buffer.1 = true;
                }
            }
        });
        Self { buffer, reader }
    }

    fn finished(&self) -> bool {
        self.reader.is_finished()
    }

    fn take(self) -> (String, bool) {
        let (bytes, truncated) = std::mem::take(
            &mut *self
                .buffer
                .lock()
                .expect("reader holds no lock across a panic"),
        );
        let mut text = String::from_utf8_lossy(&bytes).into_owned();
        if truncated {
            text.push_str(TRUNCATED);
        }
        (text, truncated)
    }
}

/// Shortens the output, keeping its start, until the reply fits the largest relay message.
fn fit_in_one_message(result: &mut BashResult) {
    let limit = fragments::MESSAGE_BYTES - 4_096;
    while serde_json::to_string(result).map(|s| s.len()).unwrap_or(0) > limit {
        let longer = if result.stdout.len() >= result.stderr.len() {
            (&mut result.stdout, &mut result.stdout_truncated)
        } else {
            (&mut result.stderr, &mut result.stderr_truncated)
        };
        let mut keep = longer.0.len() / 2;
        while !longer.0.is_char_boundary(keep) {
            keep -= 1;
        }
        longer.0.truncate(keep);
        longer.0.push_str(TRUNCATED);
        *longer.1 = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn params(command: &str) -> BashParams {
        parse(
            &json!({ "accountId": "acct", "callId": "c1", "command": command, "cwd": "/tmp", "timeoutMs": 5000 }),
            "acct",
        )
        .unwrap()
    }

    #[test]
    fn a_command_returns_its_status_and_both_streams() {
        let result = run(&params("echo out; echo err >&2; exit 3")).unwrap();
        assert_eq!(result.exit_code, Some(3));
        assert_eq!(result.stdout, "out\n");
        assert_eq!(result.stderr, "err\n");
        assert!(!result.timed_out);
    }

    #[test]
    fn a_command_past_its_timeout_is_killed_with_everything_it_started() {
        let mut p = params("sleep 30 & sleep 30; echo never");
        p.timeout_ms = Some(200);
        let started = Instant::now();
        let result = run(&p).unwrap();
        assert!(result.timed_out);
        assert_eq!(result.signal, Some(libc::SIGKILL));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn output_past_the_limit_is_cut_with_a_marker_and_the_reply_fits_one_message() {
        let result = run(&params("head -c 3000000 /dev/zero | tr '\\\\0' a")).unwrap();
        assert!(result.stdout_truncated);
        assert!(result.stdout.ends_with(TRUNCATED));
        assert!(serde_json::to_string(&result).unwrap().len() <= fragments::MESSAGE_BYTES);
    }

    #[test]
    fn a_command_for_another_account_or_with_bad_params_is_refused() {
        let base = json!({ "accountId": "acct", "callId": "c1", "command": "true" });
        assert_eq!(parse(&base, "other").unwrap_err().0, -32003);
        let mut relative = base.clone();
        relative["cwd"] = json!("tmp");
        assert_eq!(parse(&relative, "acct").unwrap_err().0, -32602);
        let mut long = base.clone();
        long["timeoutMs"] = json!(600_001);
        assert_eq!(parse(&long, "acct").unwrap_err().0, -32602);
    }
}
