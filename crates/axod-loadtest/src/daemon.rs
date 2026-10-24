//! An isolated axod for one load-test run: temporary HOME and server directory under /tmp (Unix
//! socket paths are limited to 104 bytes, which rules out Bazel's long TEST_TMPDIR).

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
    pub fn start(axod: &Path, pi_fixture: &Path) -> Result<Daemon, String> {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let directory = PathBuf::from(format!("/tmp/axod-load-{}-{nanos}", std::process::id()));
        fs::create_dir_all(directory.join("home")).map_err(|e| format!("temp dir: {e}"))?;
        let pi_fixture = fs::canonicalize(pi_fixture).map_err(|e| format!("Pi fixture: {e}"))?;
        let log = fs::File::create(directory.join("axod.log")).map_err(|e| format!("log: {e}"))?;
        let child = Command::new(axod)
            .env("HOME", directory.join("home"))
            .env("AXO_PI_EXECUTABLE", pi_fixture)
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

/// One attach-protocol-v2 handshake: request, header, descriptor byte, then up to 64 KiB of
/// replay. The PTY descriptor is never received (no control buffer), so the kernel discards it.
pub fn attach_once(socket: &Path, shell_id: i64) -> Result<(), String> {
    let mut stream = UnixStream::connect(socket).map_err(|e| format!("connect: {e}"))?;
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
