//! Daemon settings: the agent and shell commands, parsed from what the store keeps.

use std::io;
use std::path::PathBuf;

use super::SessionManager;
use axo_pi::AgentCommand;
use axo_protocol::ConfigKey;
use axo_protocol::rpc;
use axo_pty::CommandLine;
use axo_store::Connection;
use axo_store::load_or_create_setting;
use axo_store::store_config_value;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ShellCommand(pub(super) CommandLine);

enum ParsedConfigValue {
    AgentCommand(AgentCommand),
    ShellCommand(ShellCommand),
}

impl ShellCommand {
    pub(crate) fn parse(source: &str) -> io::Result<Self> {
        CommandLine::parse(source).map(Self)
    }
}

/// The agent a new database starts with.
const DEFAULT_AGENT_COMMAND: &str = "pi";

pub(super) fn load_or_create_agent_command(database: &Connection) -> io::Result<AgentCommand> {
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

pub(super) fn load_or_create_shell_command(database: &Connection) -> io::Result<ShellCommand> {
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

impl SessionManager {
    pub(super) fn config_value(&self, key: ConfigKey) -> rpc::ConfigValue {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let value = match key {
            ConfigKey::AgentCommand => state.agent_command.command().source.clone(),
            ConfigKey::ShellCommand => state.shell_command.0.source.clone(),
        };
        rpc::ConfigValue { key, value }
    }

    pub(super) fn set_config_value(
        &self,
        key: ConfigKey,
        value: &str,
    ) -> io::Result<rpc::ConfigValue> {
        let parsed = match key {
            ConfigKey::AgentCommand => {
                let command = AgentCommand::parse(value)?;
                ParsedConfigValue::AgentCommand(command)
            }
            ConfigKey::ShellCommand => {
                let command = ShellCommand::parse(value)?;
                ParsedConfigValue::ShellCommand(command)
            }
        };
        let value = match &parsed {
            ParsedConfigValue::AgentCommand(command) => command.command().source.clone(),
            ParsedConfigValue::ShellCommand(command) => command.0.source.clone(),
        };

        let mut state = self.lock_state()?;
        store_config_value(&state.database, key, &value)?;
        match parsed {
            ParsedConfigValue::AgentCommand(command) => state.agent_command = command,
            ParsedConfigValue::ShellCommand(command) => state.shell_command = command,
        }
        Ok(rpc::ConfigValue { key, value })
    }
}
