//! Finding the agents installed on this Mac (RFD0072, Discovery).
//!
//! axod starts from launchd with a minimal `PATH`, and agents' installers put them in places
//! that `PATH` often lacks (Claude Code in `~/.local/bin`), so an agent is looked for in order:
//! its override variable, `PATH`, then the directories its installers use. A file is the agent
//! only if it is executable and `--version` answers, quickly, with a version its adapter
//! supports.

use std::fmt;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::io::AsyncReadExt;

use crate::AgentKind;

/// How long `--version` may take. Node-based agents start slowly on a busy Mac.
pub const VERSION_TIMEOUT: Duration = Duration::from_secs(5);
/// More than any `--version` prints; the rest is not read.
const MAX_VERSION_OUTPUT: u64 = 4096;

/// Where to look, given explicitly so that a search depends only on its arguments.
#[derive(Clone, Debug)]
pub struct SearchPlaces {
    /// The user's home directory, for the installers' directories under it.
    pub home: PathBuf,
    /// The directories of `PATH`, in order.
    pub path: Vec<PathBuf>,
    /// The value of the kind's override variable ([`override_variable`]), if set.
    pub explicit: Option<PathBuf>,
}

impl SearchPlaces {
    /// This process's `PATH` and the kind's override variable, under `home`.
    pub fn from_environment(kind: AgentKind, home: &Path) -> Self {
        let path = std::env::var_os("PATH")
            .map(|path| std::env::split_paths(&path).collect())
            .unwrap_or_default();
        Self {
            home: home.to_path_buf(),
            path,
            explicit: std::env::var_os(override_variable(kind)).map(PathBuf::from),
        }
    }
}

/// The variable that names an agent's executable outright, skipping the search.
pub const fn override_variable(kind: AgentKind) -> &'static str {
    match kind {
        AgentKind::Pi => "AXO_PI_EXECUTABLE",
        AgentKind::Codex => "AXO_CODEX_EXECUTABLE",
        AgentKind::OpenCode => "AXO_OPENCODE_EXECUTABLE",
        AgentKind::ClaudeCode => "AXO_CLAUDE_CODE_EXECUTABLE",
    }
}

/// The executable's file name.
pub const fn executable_name(kind: AgentKind) -> &'static str {
    match kind {
        AgentKind::Pi => "pi",
        AgentKind::Codex => "codex",
        AgentKind::OpenCode => "opencode",
        AgentKind::ClaudeCode => "claude",
    }
}

/// Directories under the home that each kind's installers use, most specific first.
fn installer_directories(kind: AgentKind) -> &'static [&'static str] {
    match kind {
        AgentKind::Pi => &[".local/bin", ".bun/bin", ".npm-global/bin"],
        AgentKind::Codex => &[".local/bin", ".bun/bin", ".npm-global/bin", ".cargo/bin"],
        AgentKind::OpenCode => &[".opencode/bin", ".local/bin", ".bun/bin", ".npm-global/bin"],
        AgentKind::ClaudeCode => &[".local/bin", ".claude/local", ".bun/bin", ".npm-global/bin"],
    }
}

/// Package managers' directories outside the home, for every kind.
const SYSTEM_DIRECTORIES: [&str; 2] = ["/opt/homebrew/bin", "/usr/local/bin"];

/// Every place `kind` may be, in the order they are tried. An explicit path is the only one.
pub fn candidates(kind: AgentKind, places: &SearchPlaces) -> Vec<PathBuf> {
    if let Some(explicit) = &places.explicit {
        return vec![explicit.clone()];
    }
    let name = executable_name(kind);
    let mut candidates: Vec<PathBuf> = places.path.iter().map(|dir| dir.join(name)).collect();
    candidates.extend(
        installer_directories(kind)
            .iter()
            .map(|dir| places.home.join(dir).join(name)),
    );
    candidates.extend(
        SYSTEM_DIRECTORIES
            .iter()
            .map(|dir| Path::new(dir).join(name)),
    );
    let mut seen = std::collections::HashSet::new();
    candidates.retain(|candidate| candidate.is_absolute() && seen.insert(candidate.clone()));
    candidates
}

/// The first candidate that is an executable file, made absolute: the agent runs in the
/// Session's folder, not axod's.
pub fn find(kind: AgentKind, places: &SearchPlaces) -> Result<PathBuf, DiscoveryError> {
    candidates(kind, places)
        .into_iter()
        .find(|candidate| is_executable_file(candidate))
        .and_then(|found| std::path::absolute(found).ok())
        .ok_or(DiscoveryError::NotInstalled(kind))
}

fn is_executable_file(path: &Path) -> bool {
    std::fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

pub use crate::version::AgentVersion;

/// The oldest version of each kind its adapter was written and tested against. Pi is not
/// checked: axod has always run whatever Pi is configured.
pub fn minimum_version(kind: AgentKind) -> Option<AgentVersion> {
    let version = |major, minor, patch| {
        Some(AgentVersion {
            major,
            minor,
            patch,
        })
    };
    match kind {
        AgentKind::Pi => None,
        AgentKind::Codex => version(0, 170, 0),
        AgentKind::OpenCode => version(2, 0, 20),
        AgentKind::ClaudeCode => version(2, 1, 0),
    }
}

/// An agent that was found and answered.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledAgent {
    pub kind: AgentKind,
    pub executable: PathBuf,
    pub version: AgentVersion,
}

#[derive(Debug)]
pub enum DiscoveryError {
    NotInstalled(AgentKind),
    /// `--version` failed, took too long, or printed no version.
    Unrecognized {
        kind: AgentKind,
        executable: PathBuf,
        reason: String,
    },
    Unsupported {
        kind: AgentKind,
        executable: PathBuf,
        version: AgentVersion,
        minimum: AgentVersion,
    },
}

impl fmt::Display for DiscoveryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DiscoveryError::NotInstalled(kind) => write!(
                formatter,
                "{kind} is not installed (set {} to its path)",
                override_variable(*kind)
            ),
            DiscoveryError::Unrecognized {
                kind,
                executable,
                reason,
            } => write!(
                formatter,
                "{} is not a {kind} Axo recognises: {reason}",
                executable.display()
            ),
            DiscoveryError::Unsupported {
                kind,
                executable,
                version,
                minimum,
            } => write!(
                formatter,
                "{} is {kind} {version}; Axo needs {minimum} or later",
                executable.display()
            ),
        }
    }
}

impl std::error::Error for DiscoveryError {}

impl From<DiscoveryError> for io::Error {
    fn from(error: DiscoveryError) -> Self {
        let kind = match error {
            DiscoveryError::NotInstalled(_) => io::ErrorKind::NotFound,
            DiscoveryError::Unrecognized { .. } | DiscoveryError::Unsupported { .. } => {
                io::ErrorKind::Unsupported
            }
        };
        io::Error::new(kind, error.to_string())
    }
}

/// Finds `kind` and checks its version.
pub async fn discover(
    kind: AgentKind,
    places: &SearchPlaces,
    timeout: Duration,
) -> Result<InstalledAgent, DiscoveryError> {
    let executable = find(kind, places)?;
    let unrecognized = |reason: String| DiscoveryError::Unrecognized {
        kind,
        executable: executable.clone(),
        reason,
    };
    let output = version_output(&executable, timeout)
        .await
        .map_err(|error| unrecognized(error.to_string()))?;
    let version = AgentVersion::parse(&output)
        .ok_or_else(|| unrecognized("its --version printed no version".to_owned()))?;
    if let Some(minimum) = minimum_version(kind)
        && version < minimum
    {
        return Err(DiscoveryError::Unsupported {
            kind,
            executable,
            version,
            minimum,
        });
    }
    Ok(InstalledAgent {
        kind,
        executable,
        version,
    })
}

/// What `<executable> --version` prints on stdout, killed after `timeout`.
async fn version_output(executable: &Path, timeout: Duration) -> io::Result<String> {
    let mut child = tokio::process::Command::new(executable)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    let mut stdout = child.stdout.take().ok_or(io::ErrorKind::BrokenPipe)?;
    let answered = async {
        let mut output = Vec::new();
        (&mut stdout)
            .take(MAX_VERSION_OUTPUT)
            .read_to_end(&mut output)
            .await?;
        let status = child.wait().await?;
        if !status.success() {
            return Err(io::Error::other(format!("--version exited with {status}")));
        }
        Ok(String::from_utf8_lossy(&output).into_owned())
    };
    tokio::time::timeout(timeout, answered)
        .await
        .unwrap_or_else(|_| Err(io::Error::new(io::ErrorKind::TimedOut, "--version hung")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn places(home: &Path, path: Vec<PathBuf>) -> SearchPlaces {
        SearchPlaces {
            home: home.to_path_buf(),
            path,
            explicit: None,
        }
    }

    /// A shell script at `path` that prints `output` for `--version`.
    fn fake_agent(path: &Path, script: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, format!("#!/bin/sh\n{script}\n")).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn versions_parse_as_each_agent_prints_them() {
        let v = |major, minor, patch| {
            Some(AgentVersion {
                major,
                minor,
                patch,
            })
        };
        assert_eq!(AgentVersion::parse("1.5.2\n"), v(1, 5, 2));
        assert_eq!(AgentVersion::parse("codex-cli 0.170.0\n"), v(0, 170, 0));
        assert_eq!(AgentVersion::parse("v2.0.20"), v(2, 0, 20));
        assert_eq!(AgentVersion::parse("2.1.327 (Claude Code)"), v(2, 1, 327));
        assert_eq!(AgentVersion::parse("tool 3.0.0-beta.2+abc"), v(3, 0, 0));
        for nonsense in [
            "",
            "codex-cli",
            "1.2",
            "1.2.3.4",
            "v.1.2",
            "1..3",
            "99999999999.0.0",
        ] {
            assert_eq!(AgentVersion::parse(nonsense), None, "{nonsense:?}");
        }
    }

    #[test]
    fn version_parsing_never_panics_on_arbitrary_output() {
        // Fuzzing by a seeded generator: printable and control bytes, digits and dots weighted up.
        let mut state = 0x9e37_79b9_7f4a_7c15_u64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for _ in 0..20_000 {
            let length = (next() % 40) as usize;
            let text: String = (0..length)
                .map(|_| match next() % 6 {
                    0 | 1 => char::from(b'0' + (next() % 10) as u8),
                    2 => '.',
                    3 => ' ',
                    4 => char::from_u32((next() % 0x2_0000) as u32).unwrap_or('x'),
                    _ => char::from((next() % 128) as u8),
                })
                .collect();
            if let Some(version) = AgentVersion::parse(&text) {
                let printed = version.to_string();
                assert_eq!(AgentVersion::parse(&printed), Some(version), "{text:?}");
            }
        }
    }

    #[test]
    fn the_search_tries_path_then_the_installers_directories_then_the_system() {
        let home = crate::test_directory();
        let path = vec![PathBuf::from("/nowhere/bin"), PathBuf::from("relative/bin")];
        let order = candidates(AgentKind::ClaudeCode, &places(&home, path));
        assert_eq!(order[0], Path::new("/nowhere/bin/claude"));
        assert_eq!(order[1], home.join(".local/bin/claude"));
        assert!(order.contains(&home.join(".claude/local/claude")));
        assert_eq!(order.last().unwrap(), Path::new("/usr/local/bin/claude"));
        assert!(order.iter().all(|candidate| candidate.is_absolute()));
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn claude_code_is_found_in_the_users_local_bin_without_it_being_on_path() {
        let home = crate::test_directory();
        fake_agent(
            &home.join(".local/bin/claude"),
            "echo '2.1.327 (Claude Code)'",
        );
        // Not executable: skipped.
        fs::create_dir_all(home.join("empty/bin")).unwrap();
        fs::write(home.join("empty/bin/claude"), "not a program").unwrap();
        let places = places(&home, vec![home.join("empty/bin")]);
        assert_eq!(
            find(AgentKind::ClaudeCode, &places).unwrap(),
            home.join(".local/bin/claude")
        );
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn an_explicit_path_is_the_only_candidate() {
        let home = crate::test_directory();
        fake_agent(&home.join("bin/codex"), "echo codex-cli 0.170.0");
        let mut places = places(&home, vec![home.join("bin")]);
        places.explicit = Some(home.join("elsewhere/codex"));
        assert!(matches!(
            find(AgentKind::Codex, &places),
            Err(DiscoveryError::NotInstalled(AgentKind::Codex))
        ));
        fs::remove_dir_all(home).unwrap();
    }

    #[tokio::test]
    async fn discovery_checks_the_version_against_what_the_adapter_supports() {
        let home = crate::test_directory();
        let bin = home.join("bin");
        fake_agent(&bin.join("codex"), "echo codex-cli 0.170.3");
        fake_agent(&bin.join("opencode"), "echo v1.9.0");
        fake_agent(&bin.join("claude"), "echo nothing useful");
        fake_agent(&bin.join("pi"), "exit 3");
        let places = places(&home, vec![bin.clone()]);
        let codex = discover(AgentKind::Codex, &places, VERSION_TIMEOUT)
            .await
            .unwrap();
        assert_eq!(codex.executable, bin.join("codex"));
        assert_eq!(codex.version.to_string(), "0.170.3");
        assert!(matches!(
            discover(AgentKind::OpenCode, &places, VERSION_TIMEOUT).await,
            Err(DiscoveryError::Unsupported { .. })
        ));
        assert!(matches!(
            discover(AgentKind::ClaudeCode, &places, VERSION_TIMEOUT).await,
            Err(DiscoveryError::Unrecognized { .. })
        ));
        assert!(matches!(
            discover(AgentKind::Pi, &places, VERSION_TIMEOUT).await,
            Err(DiscoveryError::Unrecognized { .. })
        ));
        fs::remove_dir_all(home).unwrap();
    }

    #[tokio::test]
    async fn an_agent_whose_version_hangs_is_not_waited_for() {
        let home = crate::test_directory();
        fake_agent(&home.join("bin/codex"), "sleep 30");
        let places = places(&home, vec![home.join("bin")]);
        let started = std::time::Instant::now();
        let error = discover(AgentKind::Codex, &places, Duration::from_millis(300))
            .await
            .unwrap_err();
        assert!(
            matches!(error, DiscoveryError::Unrecognized { .. }),
            "{error}"
        );
        assert!(started.elapsed() < Duration::from_secs(5));
        fs::remove_dir_all(home).unwrap();
    }
}
