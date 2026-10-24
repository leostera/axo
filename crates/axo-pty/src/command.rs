//! Command lines users configure (`shell.command`, `agent.command`) and finding their executables.

use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const MAX_COMMAND_LINE_BYTES: usize = 4096;

const MAX_COMMAND_ARGUMENTS: usize = 128;

#[derive(Clone, Debug, Eq, PartialEq)]
/// A parsed command line: an executable (absolute, or a bare name resolved on `PATH`) and its
/// arguments, split shell-style.
pub struct CommandLine {
    /// The text as configured, trimmed.
    pub source: String,
    pub executable: String,
    pub arguments: Vec<String>,
}

impl CommandLine {
    pub fn parse(source: &str) -> io::Result<Self> {
        let source = source.trim();
        if source.is_empty()
            || source.len() > MAX_COMMAND_LINE_BYTES
            || source.chars().any(char::is_control)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "command must be nonempty, control-free, and at most 4096 bytes",
            ));
        }

        let arguments = shlex::split(source).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "command contains unmatched shell-style quotes",
            )
        })?;
        if arguments.is_empty()
            || arguments.len().saturating_sub(1) > MAX_COMMAND_ARGUMENTS
            || arguments[0].is_empty()
            || arguments.iter().any(|argument| argument.contains('\0'))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "command must have an executable and no more than 128 arguments",
            ));
        }

        let executable = arguments[0].clone();
        if executable.contains('/') && !Path::new(&executable).is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "executable paths must be absolute; bare command names are resolved on axod's PATH",
            ));
        }

        Ok(Self {
            source: source.to_owned(),
            executable,
            arguments: arguments.into_iter().skip(1).collect(),
        })
    }
}

/// Finds `program`: `override_variable` from the environment if set, an absolute path as is,
/// otherwise the first executable match on `PATH` (then Homebrew's directories).
pub fn resolve_executable(
    program: &str,
    override_variable: Option<&str>,
    command_kind: &str,
) -> io::Result<PathBuf> {
    let explicit = override_variable
        .and_then(std::env::var_os)
        .map(PathBuf::from);
    let candidate = if let Some(path) = explicit {
        path
    } else if Path::new(program).is_absolute() {
        PathBuf::from(program)
    } else {
        let path = std::env::var_os("PATH").unwrap_or_default();
        std::env::split_paths(&path)
            .chain([
                PathBuf::from("/opt/homebrew/bin"),
                PathBuf::from("/usr/local/bin"),
            ])
            .map(|directory| directory.join(program))
            .find(|candidate| candidate.is_file() && is_executable(candidate))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("{command_kind} executable {program:?} was not found on axod's PATH"),
                )
            })?
    };
    if candidate.is_file() && is_executable(&candidate) {
        Ok(candidate)
    } else {
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("configured {command_kind} executable {program:?} is not executable"),
        ))
    }
}

pub fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
