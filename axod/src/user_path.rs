//! Capture the user's login-shell PATH without global environment mutation or bundled launchers.
use std::{
    ffi::{CStr, OsStr, OsString},
    io::{self, Read},
    os::{fd::AsRawFd, unix::process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[derive(Clone)]
pub(crate) struct CapturedPath(OsString);
impl CapturedPath {
    pub(crate) fn as_os_str(&self) -> &OsStr {
        &self.0
    }
    fn parse(bytes: &[u8]) -> io::Result<Self> {
        const MARKER: &[u8] = b"\0AXO_PATH\0";
        let starts: Vec<_> = bytes
            .windows(MARKER.len())
            .enumerate()
            .filter_map(|(offset, value)| (value == MARKER).then_some(offset + MARKER.len()))
            .collect();
        let [start] = starts.as_slice() else {
            return Err(unavailable());
        };
        let raw = bytes
            .get(*start..)
            .and_then(|bytes| bytes.strip_suffix(b"\0"))
            .ok_or_else(unavailable)?;
        if raw.len() > 16384 || raw.contains(&0) {
            return Err(unavailable());
        }
        let raw = std::str::from_utf8(raw).map_err(|_| unavailable())?;
        let entries: Vec<_> = std::env::split_paths(raw)
            .filter(|path| {
                let components: Vec<_> = path.components().collect();
                path.is_absolute()
                    && !components.windows(2).any(|pair| {
                        pair[0].as_os_str() == "node_modules" && pair[1].as_os_str() == ".bin"
                    })
            })
            .collect();
        if entries.is_empty() || entries.len() > 256 {
            return Err(unavailable());
        }
        Ok(Self(
            std::env::join_paths(entries).map_err(|_| unavailable())?,
        ))
    }
    pub(crate) fn capture(home: &Path) -> io::Result<Self> {
        let shell = login_shell()?;
        let mut command = Command::new(&shell);
        command
            .env("SHELL", &shell)
            .args([
                "-l",
                "-i",
                "-c",
                "printf '\\000AXO_PATH\\000%s\\000' \"$PATH\"",
            ])
            .current_dir(home);
        Self::parse(&owned_output(command)?)
    }
}
fn unavailable() -> io::Error {
    io::Error::other("Normal shell PATH capture unavailable")
}
fn login_shell() -> io::Result<PathBuf> {
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut buffer = vec![0_u8; 65536];
    let mut result = std::ptr::null_mut();
    let status = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            &mut entry,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() || entry.pw_shell.is_null() {
        return Err(unavailable());
    }
    let shell = unsafe { CStr::from_ptr(entry.pw_shell) }
        .to_str()
        .map_err(|_| unavailable())?;
    let shell = PathBuf::from(shell);
    if !shell.is_absolute() || !shell.is_file() {
        return Err(unavailable());
    }
    Ok(shell)
}
fn owned_output(mut command: Command) -> io::Result<Vec<u8>> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()?;
    let result = (|| {
        let mut output = child.stdout.take().ok_or_else(unavailable)?;
        let flags = unsafe { libc::fcntl(output.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(output.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(unavailable());
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut bytes = Vec::new();
        loop {
            if Instant::now() >= deadline {
                return Err(unavailable());
            }
            let mut chunk = [0; 1024];
            match output.read(&mut chunk) {
                Ok(0) => break,
                Ok(count) if bytes.len() + count <= 32768 => {
                    bytes.extend_from_slice(&chunk[..count])
                }
                Ok(_) => return Err(unavailable()),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => (),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10))
                }
                Err(_) => return Err(unavailable()),
            }
        }
        // Keep the leader unreaped through group cleanup, including on successful capture.
        loop {
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let status = unsafe {
                libc::waitid(
                    libc::P_PID,
                    child.id(),
                    &mut info,
                    libc::WEXITED | libc::WNOWAIT | libc::WNOHANG,
                )
            };
            if status < 0 {
                return Err(unavailable());
            }
            if unsafe { info.si_pid() } != 0 {
                return Ok(bytes);
            }
            if Instant::now() >= deadline {
                return Err(unavailable());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();
    // This handle's still-unreaped leader pins the identity; never signal a remembered PID.
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let status = child.wait()?;
    if result.is_ok() && !status.success() {
        return Err(unavailable());
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framed_path_discards_relative_and_npm_injected_bins() {
        let path = CapturedPath::parse(
            b"startup noise\n\0AXO_PATH\0/bin:relative:/repo/node_modules/.bin:/opt/homebrew/bin\0",
        )
        .unwrap();
        assert_eq!(path.as_os_str(), OsStr::new("/bin:/opt/homebrew/bin"));
        for bytes in [
            b"/bin\0".as_slice(),
            b"\0AXO_PATH\0/bin\0extra",
            b"\0AXO_PATH\0/bin\0AXO_PATH\0/bin\0",
        ] {
            assert!(CapturedPath::parse(bytes).is_err());
        }
    }
    #[test]
    fn owned_probe_bounds_output_and_drains_an_exited_leader() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf '\\000AXO_PATH\\000/bin\\000'"]);
        assert_eq!(
            CapturedPath::parse(&owned_output(command).unwrap())
                .unwrap()
                .as_os_str(),
            OsStr::new("/bin")
        );
        let mut overflow = Command::new("/bin/sh");
        overflow.args(["-c", "yes x | head -c 40000"]);
        assert!(owned_output(overflow).is_err());
    }
}
