//! Daemon settings: the agent and shell commands, parsed from what the store keeps.

use std::io;
use std::path::PathBuf;

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

/// The commands new panes start with.
#[derive(Clone, Debug)]
pub(crate) struct Settings {
    pub(crate) agent_command: AgentCommand,
    pub(crate) shell_command: ShellCommand,
}

/// A setting's new value, parsed.
pub(crate) enum ParsedConfigValue {
    AgentCommand(AgentCommand),
    ShellCommand(ShellCommand),
}

impl ParsedConfigValue {
    pub(crate) fn parse(key: ConfigKey, value: &str) -> io::Result<Self> {
        Ok(match key {
            ConfigKey::AgentCommand => Self::AgentCommand(AgentCommand::parse(value)?),
            ConfigKey::ShellCommand => Self::ShellCommand(ShellCommand::parse(value)?),
        })
    }

    /// The value as it is stored and reported.
    pub(crate) fn source(&self) -> String {
        match self {
            Self::AgentCommand(command) => command.command().source.clone(),
            Self::ShellCommand(command) => command.0.source.clone(),
        }
    }

    pub(crate) fn apply(self, settings: &mut Settings) {
        match self {
            Self::AgentCommand(command) => settings.agent_command = command,
            Self::ShellCommand(command) => settings.shell_command = command,
        }
    }
}

impl Settings {
    pub(crate) fn value(&self, key: ConfigKey) -> String {
        match key {
            ConfigKey::AgentCommand => self.agent_command.command().source.clone(),
            ConfigKey::ShellCommand => self.shell_command.0.source.clone(),
        }
    }

    pub(crate) fn load(database: &Connection) -> io::Result<Self> {
        Ok(Self {
            agent_command: load_or_create_agent_command(database)?,
            shell_command: load_or_create_shell_command(database)?,
        })
    }
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
