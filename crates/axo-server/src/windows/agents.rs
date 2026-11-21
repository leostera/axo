//! Launchable Windows agents, using the same executable configured for Session startup.
use axo_agent::{AgentKind, version::AgentVersion};
use axo_protocol::rpc::{AgentAvailability, AgentsList};
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;

// The Windows stdio adapter supports 0.168; Unix's TUI adapter retains its own minimum.
const MINIMUM_CODEX: AgentVersion = AgentVersion {
    major: 0,
    minor: 168,
    patch: 0,
};
const VERSION_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_VERSION_BYTES: u64 = 4096;

pub(super) async fn list(codex: &Path) -> AgentsList {
    let found = probe(codex, VERSION_TIMEOUT).await;
    let agents = AgentKind::ALL
        .into_iter()
        .map(|agent| {
            let (installed, executable, version, problem) = if agent == AgentKind::Codex {
                match &found {
                    Ok(version) => (
                        true,
                        Some(codex.display().to_string()),
                        Some(version.to_string()),
                        None,
                    ),
                    Err(error) => (false, None, None, Some(error.to_string())),
                }
            } else {
                (
                    false,
                    None,
                    None,
                    Some("This agent is not supported by the Windows preview".into()),
                )
            };
            AgentAvailability {
                agent,
                installed,
                executable,
                version,
                problem,
                capabilities: agent.capabilities(),
            }
        })
        .collect();
    AgentsList { agents }
}

pub(super) async fn import_supported(codex: &Path) -> bool {
    probe(codex, VERSION_TIMEOUT)
        .await
        .is_ok_and(|version| version.to_string() == super::fork_import::CODEX_VERSION)
}

async fn probe(executable: &Path, timeout: Duration) -> io::Result<AgentVersion> {
    if !executable.is_absolute() || !executable.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "The configured Codex executable is unavailable",
        ));
    }
    let mut child = tokio::process::Command::new(executable)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(0x08000000) // CREATE_NO_WINDOW: discovery is not an interactive terminal.
        .kill_on_drop(true)
        .spawn()?;
    let mut stdout = child.stdout.take().ok_or(io::ErrorKind::BrokenPipe)?;
    let answer = async {
        let mut bytes = Vec::new();
        (&mut stdout)
            .take(MAX_VERSION_BYTES + 1)
            .read_to_end(&mut bytes)
            .await?;
        if bytes.len() as u64 > MAX_VERSION_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Codex version output is too large",
            ));
        }
        if !child.wait().await?.success() {
            return Err(io::Error::other("Codex --version failed"));
        }
        parse_version(&String::from_utf8_lossy(&bytes))
    };
    tokio::time::timeout(timeout, answer)
        .await
        .unwrap_or_else(|_| {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Codex --version timed out",
            ))
        })
}

fn parse_version(output: &str) -> io::Result<AgentVersion> {
    let version = AgentVersion::parse(output).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Codex printed no recognized version",
        )
    })?;
    if version < MINIMUM_CODEX {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            format!("Codex {version} is too old; Windows requires {MINIMUM_CODEX} or later"),
        ));
    }
    Ok(version)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_match_the_windows_adapter_without_lowering_unix_requirements() {
        assert_eq!(parse_version("codex-cli 0.168.0\n").unwrap(), MINIMUM_CODEX);
        assert!(parse_version("codex-cli 0.170.0").is_ok());
        assert!(parse_version("codex-cli 0.167.9").is_err());
        assert!(parse_version("codex-cli nonsense").is_err());
    }

    #[tokio::test]
    async fn unavailable_agents_are_reported_without_failing_discovery() {
        let listed = list(Path::new("C:\\nonexistent-axo-agent-fixture\\codex.exe")).await;
        assert_eq!(
            listed
                .agents
                .iter()
                .map(|entry| entry.agent)
                .collect::<Vec<_>>(),
            AgentKind::ALL
        );
        assert!(
            listed
                .agents
                .iter()
                .all(|entry| !entry.installed && entry.problem.is_some())
        );
    }
}
