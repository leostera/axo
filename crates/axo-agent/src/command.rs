//! The configured `agent.command`.

use std::io;

use axo_pty::CommandLine;

/// A Pi command line that leaves session and mode selection to Axo.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentCommand(CommandLine);

impl AgentCommand {
    pub fn parse(source: &str) -> io::Result<Self> {
        let command = CommandLine::parse(source)?;
        if command.arguments.iter().any(|argument| {
            let name = argument
                .split_once('=')
                .map_or(argument.as_str(), |(name, _)| name);
            matches!(
                name,
                "--" | "-c"
                    | "-p"
                    | "-r"
                    | "--continue"
                    | "--fork"
                    | "--mode"
                    | "--no-extensions"
                    | "--no-session"
                    | "--print"
                    | "--resume"
                    | "--rpc"
                    | "--session"
                    | "--session-dir"
                    | "--session-id"
            )
        }) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "agent command cannot override Axo's managed Pi session or interactive mode",
            ));
        }
        Ok(Self(command))
    }

    pub fn command(&self) -> &CommandLine {
        &self.0
    }
}
