//! Daemon settings: the agent and shell commands and when idle Pis sleep, parsed from what the
//! store keeps.

use std::io;
use std::path::PathBuf;
use std::time::Duration;

use axo_agent::AgentCommand;
use axo_protocol::ConfigKey;
use axo_pty::CommandLine;
use axo_store::{Connection, load_or_create_setting};

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ShellCommand(pub(crate) CommandLine);

impl ShellCommand {
    pub(crate) fn parse(source: &str) -> io::Result<Self> {
        CommandLine::parse(source).map(Self)
    }
}

/// A whole number setting, from 0 to [`Count::MAX`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Count(u32);

impl Count {
    const MAX: u32 = 10_000;

    pub(crate) fn parse(source: &str) -> io::Result<Self> {
        source
            .trim()
            .parse::<u32>()
            .ok()
            .filter(|count| *count <= Self::MAX)
            .map(Self)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("expected a whole number from 0 to {}", Self::MAX),
                )
            })
    }
}

/// When idle Pis go to sleep (RFD0045).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct IdleLimits {
    /// How long a Pi may be idle; `None` for as long as it likes.
    pub(crate) timeout: Option<Duration>,
    /// How many idle Pis stay awake.
    pub(crate) awake: usize,
}

/// The commands new panes start with, and when idle Pis sleep.
#[derive(Clone, Debug)]
pub(crate) struct Settings {
    pub(crate) agent_command: AgentCommand,
    pub(crate) shell_command: ShellCommand,
    pub(crate) idle_minutes: Count,
    pub(crate) idle_limit: Count,
}

/// A setting's new value, parsed.
pub(crate) enum ParsedConfigValue {
    AgentCommand(AgentCommand),
    ShellCommand(ShellCommand),
    IdleMinutes(Count),
    IdleLimit(Count),
}

impl ParsedConfigValue {
    pub(crate) fn parse(key: ConfigKey, value: &str) -> io::Result<Self> {
        Ok(match key {
            ConfigKey::AgentCommand => Self::AgentCommand(AgentCommand::parse(value)?),
            ConfigKey::ShellCommand => Self::ShellCommand(ShellCommand::parse(value)?),
            ConfigKey::IdleMinutes => Self::IdleMinutes(Count::parse(value)?),
            ConfigKey::IdleLimit => Self::IdleLimit(Count::parse(value)?),
        })
    }

    /// The value as it is stored and reported.
    pub(crate) fn source(&self) -> String {
        match self {
            Self::AgentCommand(command) => command.command().source.clone(),
            Self::ShellCommand(command) => command.0.source.clone(),
            Self::IdleMinutes(count) | Self::IdleLimit(count) => count.0.to_string(),
        }
    }

    pub(crate) fn apply(self, settings: &mut Settings) {
        match self {
            Self::AgentCommand(command) => settings.agent_command = command,
            Self::ShellCommand(command) => settings.shell_command = command,
            Self::IdleMinutes(count) => settings.idle_minutes = count,
            Self::IdleLimit(count) => settings.idle_limit = count,
        }
    }
}

impl Settings {
    pub(crate) fn value(&self, key: ConfigKey) -> String {
        match key {
            ConfigKey::AgentCommand => self.agent_command.command().source.clone(),
            ConfigKey::ShellCommand => self.shell_command.0.source.clone(),
            ConfigKey::IdleMinutes => self.idle_minutes.0.to_string(),
            ConfigKey::IdleLimit => self.idle_limit.0.to_string(),
        }
    }

    pub(crate) fn idle_limits(&self) -> IdleLimits {
        IdleLimits {
            timeout: (self.idle_minutes.0 > 0)
                .then(|| Duration::from_secs(u64::from(self.idle_minutes.0) * 60)),
            awake: self.idle_limit.0 as usize,
        }
    }

    pub(crate) fn load(database: &Connection) -> io::Result<Self> {
        Ok(Self {
            agent_command: load_or_create_agent_command(database)?,
            shell_command: load_or_create_shell_command(database)?,
            idle_minutes: load_or_create_count(
                database,
                ConfigKey::IdleMinutes,
                DEFAULT_IDLE_MINUTES,
            )?,
            idle_limit: load_or_create_count(database, ConfigKey::IdleLimit, DEFAULT_IDLE_LIMIT)?,
        })
    }
}

/// How long a Pi may be idle before it sleeps, by default (RFD0045).
const DEFAULT_IDLE_MINUTES: u32 = 30;
/// How many idle Pis stay awake, by default (RFD0045).
const DEFAULT_IDLE_LIMIT: u32 = 20;

fn load_or_create_count(database: &Connection, key: ConfigKey, default: u32) -> io::Result<Count> {
    let source = load_or_create_setting(database, key, || Ok(default.to_string()))?;
    Count::parse(&source).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("stored {} is invalid: {error}", key.as_str()),
        )
    })
}

/// The agent a new database starts with.
const DEFAULT_AGENT_COMMAND: &str = "pi";

fn load_or_create_agent_command(database: &Connection) -> io::Result<AgentCommand> {
    let source = load_or_create_setting(database, ConfigKey::AgentCommand, || {
        Ok(DEFAULT_AGENT_COMMAND.to_owned())
    })?;
    AgentCommand::parse(&source).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("stored default agent command is invalid: {error}"),
        )
    })
}

fn load_or_create_shell_command(database: &Connection) -> io::Result<ShellCommand> {
    let source = load_or_create_setting(database, ConfigKey::ShellCommand, default_shell_command)?;
    ShellCommand::parse(&source).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("stored default shell command is invalid: {error}"),
        )
    })
}

fn default_shell_command() -> io::Result<String> {
    let configured = std::env::var_os("SHELL").map(PathBuf::from);
    let shell = configured
        .filter(|path| {
            path.is_absolute() && path.is_file() && axo_pty::command::is_executable(path)
        })
        .or_else(|| {
            crate::current_user_login_shell()
                .ok()
                .filter(|path| path.is_file() && axo_pty::command::is_executable(path))
        })
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "could not determine an executable shell for the current user",
            )
        })?;
    shell.to_str().map(str::to_owned).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "the current user's shell path is not valid UTF-8",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_count_is_a_whole_number_up_to_its_limit() {
        assert_eq!(Count::parse(" 30 ").unwrap(), Count(30));
        assert_eq!(Count::parse("0").unwrap(), Count(0));
        for bad in ["", "-1", "1.5", "ten", "10001"] {
            assert!(Count::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn idle_settings_are_set_and_read_back_and_zero_minutes_is_no_timeout() {
        let mut settings = Settings {
            agent_command: AgentCommand::parse("pi").unwrap(),
            shell_command: ShellCommand::parse("/bin/sh").unwrap(),
            idle_minutes: Count(DEFAULT_IDLE_MINUTES),
            idle_limit: Count(DEFAULT_IDLE_LIMIT),
        };
        assert_eq!(
            settings.idle_limits(),
            IdleLimits {
                timeout: Some(Duration::from_secs(30 * 60)),
                awake: 20
            }
        );
        for (key, value) in [(ConfigKey::IdleMinutes, "0"), (ConfigKey::IdleLimit, "3")] {
            let parsed = ParsedConfigValue::parse(key, value).unwrap();
            assert_eq!(parsed.source(), value);
            parsed.apply(&mut settings);
            assert_eq!(settings.value(key), value);
        }
        assert_eq!(
            settings.idle_limits(),
            IdleLimits {
                timeout: None,
                awake: 3
            }
        );
    }
}
