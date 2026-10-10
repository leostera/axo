//! Ambient runtime discovery. SDK declarations do not establish execution origin.
use std::{
    collections::BTreeMap,
    ffi::{CString, OsString},
    fs,
    io::{self, Read},
    os::unix::{ffi::OsStrExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};
#[derive(Clone, Debug)]
pub struct AmbientPi {
    pub executable: PathBuf,
    pub version: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DependencyError {
    Missing,
    InvalidSelection,
    Changed,
    ProbeFailed,
    InvalidVersion,
}
impl std::fmt::Display for DependencyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Missing => "Ambient Pi missing; install Pi or select its absolute launcher (no bundled fallback)",
            Self::InvalidSelection => "Invalid ambient Pi selection; repository-local runtime is forbidden",
            Self::Changed => "Ambient Pi changed during discovery",
            Self::ProbeFailed => "Ambient Pi version probe failed",
            Self::InvalidVersion => "Ambient Pi version output unsupported",
        })
    }
}
impl std::error::Error for DependencyError {}
impl AmbientPi {
    pub fn find(selected: Option<&Path>) -> Result<Self, DependencyError> {
        // Capture environment/selection once before invoking any subprocess.
        let env: BTreeMap<OsString, OsString> = std::env::vars_os().collect();
        let path = env
            .get(&OsString::from("PATH"))
            .cloned()
            .unwrap_or_default();
        Self::discover(selected.map(Path::to_path_buf), &path, &env)
    }
    pub fn discover(
        selected: Option<PathBuf>,
        path: &std::ffi::OsStr,
        env: &BTreeMap<OsString, OsString>,
    ) -> Result<Self, DependencyError> {
        let development = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("Repository root")
            .join("node_modules");
        if selected.as_ref().is_some_and(|path| {
            !path.is_absolute() || development_bin(path) || path.starts_with(&development)
        }) {
            return Err(DependencyError::InvalidSelection);
        }
        let candidates: Vec<_> = match selected {
            Some(selected) => vec![selected],
            None => std::env::split_paths(path)
                .filter(|path| path.is_absolute() && !development_bin(path))
                .take(256)
                .map(|directory| directory.join("pi"))
                .collect(),
        };
        for executable in candidates {
            if executable.as_os_str().len() > 16384 || development_bin(&executable) {
                continue;
            }
            let name = CString::new(executable.as_os_str().as_bytes())
                .map_err(|_| DependencyError::InvalidSelection)?;
            if unsafe { libc::access(name.as_ptr(), libc::X_OK) } != 0 {
                continue;
            }
            let resolved = fs::canonicalize(&executable).map_err(|_| DependencyError::Changed)?;
            if executable.starts_with(&development) || resolved.starts_with(&development) {
                return Err(DependencyError::InvalidSelection);
            }
            let version = probe(&executable, env)?;
            if !valid_version(&version) {
                return Err(DependencyError::InvalidVersion);
            }
            return Ok(Self {
                executable,
                version,
            });
        }
        Err(DependencyError::Missing)
    }
}
fn development_bin(path: &Path) -> bool {
    let components: Vec<_> = path.components().collect();
    components
        .windows(2)
        .any(|pair| pair[0].as_os_str() == "node_modules" && pair[1].as_os_str() == ".bin")
}
fn valid_version(version: &str) -> bool {
    let base = version.split(['-', '+']).next().unwrap_or_default();
    let parts: Vec<_> = base.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
        && version.len() <= 256
        && version
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".-+".contains(&byte))
        && !version.ends_with(['-', '+'])
        && version.bytes().filter(|byte| *byte == b'+').count() <= 1
}
fn probe(executable: &Path, env: &BTreeMap<OsString, OsString>) -> Result<String, DependencyError> {
    let mut child = Command::new(executable)
        .arg("--version")
        .env_clear()
        .envs(env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(|_| DependencyError::ProbeFailed)?;
    use std::os::fd::AsRawFd;
    let mut output = child.stdout.take().ok_or(DependencyError::ProbeFailed)?;
    let flags = unsafe { libc::fcntl(output.as_raw_fd(), libc::F_GETFL) };
    let deadline = Instant::now() + Duration::from_millis(2500);
    let mut bytes = Vec::new();
    // Keep the leader unreaped while draining: its PID/group cannot be reused underneath
    // a timeout signal, including when a descendant retains the probe's stdout.
    let captured = (|| {
        if flags < 0
            || unsafe { libc::fcntl(output.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(DependencyError::ProbeFailed);
        }
        loop {
            if Instant::now() >= deadline {
                return Err(DependencyError::ProbeFailed);
            }
            let mut chunk = [0; 1024];
            match output.read(&mut chunk) {
                Ok(0) => return Ok(()),
                Ok(count) => {
                    if bytes.len() + count > 4096 {
                        return Err(DependencyError::ProbeFailed);
                    }
                    bytes.extend_from_slice(&chunk[..count]);
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => (),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10))
                }
                Err(_) => return Err(DependencyError::ProbeFailed),
            }
        }
    })();
    if captured.is_err() {
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
        let _ = child.kill();
        let _ = child.wait();
        return Err(DependencyError::ProbeFailed);
    }
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => return Err(DependencyError::ProbeFailed),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                let _ = child.kill();
                let _ = child.wait();
                return Err(DependencyError::ProbeFailed);
            }
        }
    }
    String::from_utf8(bytes)
        .map(|output| output.trim().to_owned())
        .map_err(|_| DependencyError::InvalidVersion)
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;
    use std::os::unix::fs::{PermissionsExt, symlink};
    fn launcher(root: &Path, body: &str) -> PathBuf {
        let executable = root.join("pi");
        fs::write(&executable, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        executable
    }
    #[test]
    fn metadata_does_not_impose_headless_mode_version_requirements() {
        let root = TestDirectory::new();
        launcher(root.path(), "printf 0.62.0-beta.1+fixture");
        let pi = AmbientPi::discover(None, root.path().as_os_str(), &BTreeMap::new()).unwrap();
        assert!(pi.version == "0.62.0-beta.1+fixture");
        assert!(AmbientPi::discover(None, std::ffi::OsStr::new(""), &BTreeMap::new()).is_err());
    }
    #[test]
    fn first_selected_invalid_launcher_fails_without_switching_installations() {
        let first = TestDirectory::new();
        launcher(first.path(), "printf not-a-version");
        let second = TestDirectory::new();
        launcher(second.path(), "printf 1.1.0");
        let path = std::env::join_paths([first.path(), second.path()]).unwrap();
        assert!(matches!(
            AmbientPi::discover(None, &path, &BTreeMap::new()),
            Err(DependencyError::InvalidVersion)
        ));
    }
    #[test]
    fn normal_package_manager_symlink_remains_the_launch_path() {
        let implementation = TestDirectory::new();
        let executable = launcher(implementation.path(), "printf 1.1.0");
        let directory = TestDirectory::new();
        let link = directory.path().join("pi");
        symlink(executable, &link).unwrap();
        assert!(
            AmbientPi::discover(
                Some(link.clone()),
                std::ffi::OsStr::new(""),
                &BTreeMap::new()
            )
            .unwrap()
            .executable
                == link
        );
    }
    #[test]
    fn explicit_relative_or_development_launcher_is_not_runtime_authority() {
        for path in ["pi", "/some/project/node_modules/.bin/pi"] {
            assert!(matches!(
                AmbientPi::discover(
                    Some(PathBuf::from(path)),
                    std::ffi::OsStr::new(""),
                    &BTreeMap::new()
                ),
                Err(DependencyError::InvalidSelection)
            ));
        }
    }
    #[test]
    fn probe_error_and_output_limit_have_only_sanitized_diagnostics() {
        let root = TestDirectory::new();
        launcher(root.path(), "printf PRIVATE_PAYLOAD >&2; exit 7");
        assert!(matches!(
            AmbientPi::discover(None, root.path().as_os_str(), &BTreeMap::new()),
            Err(DependencyError::ProbeFailed)
        ));
        launcher(root.path(), "while :; do printf 0123456789; done");
        assert!(matches!(
            AmbientPi::discover(None, root.path().as_os_str(), &BTreeMap::new()),
            Err(DependencyError::ProbeFailed)
        ));
    }
}
