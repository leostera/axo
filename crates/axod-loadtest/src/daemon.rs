//! An isolated axod for one load-test run: temporary HOME and server directory under /tmp (Unix
//! socket paths are limited to 104 bytes, which rules out Bazel's long TEST_TMPDIR).
//!
//! Its Pis are the fake Pi, held at its startup gate. Only the person or a Session's own
//! processes type into its panes (RFD0073), so input and attachments go through the fake Pi of
//! the Session they reach, as an agent's would: one more hop on a Unix socket.

use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::client::Client;

const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

pub struct Daemon {
    child: Child,
    directory: PathBuf,
}

impl Daemon {
    pub fn start(axod: &Path, fake_pi: &Path) -> Result<Daemon, String> {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let directory = PathBuf::from(format!("/tmp/axod-load-{}-{nanos}", std::process::id()));
        fs::create_dir_all(directory.join("home")).map_err(|e| format!("temp dir: {e}"))?;
        let fake_pi = fs::canonicalize(fake_pi).map_err(|e| format!("fake Pi: {e}"))?;
        fs::create_dir_all(directory.join("agents")).map_err(|e| format!("agents dir: {e}"))?;
        fs::write(directory.join("pi-gate"), "hold").map_err(|e| format!("Pi gate: {e}"))?;
        let log = fs::File::create(directory.join("axod.log")).map_err(|e| format!("log: {e}"))?;
        let child = Command::new(axod)
            .env("HOME", directory.join("home"))
            .env("AXO_PI_EXECUTABLE", fake_pi)
            .env("AXO_FAKE_PI_AGENT_SOCKETS", directory.join("agents"))
            .env("AXO_FAKE_PI_STARTUP_GATE", directory.join("pi-gate"))
            .env(
                "AXO_FAKE_PI_ATTACH_SOCKET",
                directory.join("server/attach.sock"),
            )
            .arg("--socket")
            .arg(directory.join("axod.sock"))
            .arg("--server-dir")
            .arg(directory.join("server"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .map_err(|e| format!("starting {}: {e}", axod.display()))?;
        let daemon = Daemon { child, directory };
        daemon.wait_until_ready()?;
        Ok(daemon)
    }

    pub fn socket(&self) -> PathBuf {
        self.directory.join("axod.sock")
    }

    /// Where calls reach axod from inside `session_id`'s Pi, once that Pi takes them.
    pub fn agent_socket(&self, session_id: &str) -> Result<PathBuf, String> {
        let path = self
            .directory
            .join("agents")
            .join(format!("{session_id}.sock"));
        let deadline = Instant::now() + STARTUP_TIMEOUT;
        while UnixStream::connect(&path).is_err() {
            if Instant::now() >= deadline {
                return Err(format!("the Pi of {session_id} took no calls"));
            }
            thread::sleep(Duration::from_millis(20));
        }
        Ok(path)
    }

    /// Where `session_id`'s Pi attaches to its panes and hands the attachment on.
    pub fn attach_relay(&self, session_id: &str) -> Result<PathBuf, String> {
        self.agent_socket(session_id)?;
        Ok(self
            .directory
            .join("agents")
            .join(format!("{session_id}.attach.sock")))
    }

    pub fn pid(&self) -> i32 {
        self.child.id() as i32
    }

    pub fn connect(&self) -> Result<Client, String> {
        Client::connect(&self.socket(), Duration::from_secs(30))
            .map_err(|e| format!("connect: {e}"))
    }

    fn wait_until_ready(&self) -> Result<(), String> {
        let deadline = Instant::now() + STARTUP_TIMEOUT;
        while Instant::now() < deadline {
            if UnixStream::connect(self.socket()).is_ok() {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(20));
        }
        Err(format!(
            "axod did not listen within {STARTUP_TIMEOUT:?}; see {}",
            self.directory.join("axod.log").display()
        ))
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SIGTERM lets axod stop its shells; SIGKILL only if it does not exit in time.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let deadline = Instant::now() + SHUTDOWN_TIMEOUT;
        while Instant::now() < deadline {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                let _ = fs::remove_dir_all(&self.directory);
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        eprintln!("axod ignored SIGTERM; kept {}", self.directory.display());
    }
}

/// One attach-protocol-v2 handshake, made by the pane's Session's Pi through `relay`: request,
/// header, descriptor byte, then up to 64 KiB of replay. The PTY descriptor is never received
/// (no control buffer), so the kernel discards it.
pub fn attach_once(relay: &Path, shell_id: i64) -> Result<(), String> {
    let mut stream = UnixStream::connect(relay).map_err(|e| format!("connect: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| e.to_string())?;
    writeln!(stream, "{shell_id}").map_err(|e| format!("request: {e}"))?;
    let mut header = [0_u8; 8];
    stream
        .read_exact(&mut header)
        .map_err(|e| format!("header: {e}"))?;
    let replay = u64::from_be_bytes(header);
    if replay == u64::MAX {
        return Err("attach rejected".to_owned());
    }
    let mut marker = [0_u8; 1];
    stream
        .read_exact(&mut marker)
        .map_err(|e| format!("descriptor byte: {e}"))?;
    let mut buffer = vec![0_u8; 64 * 1024];
    let wanted = replay.min(buffer.len() as u64) as usize;
    stream
        .read_exact(&mut buffer[..wanted])
        .map_err(|e| format!("replay: {e}"))?;
    Ok(())
}
