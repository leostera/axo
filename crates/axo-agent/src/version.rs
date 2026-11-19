//! Agent version parsing shared by native platform adapters.
use serde::Serialize;
use std::fmt;

/// An agent's version, as `--version` prints it.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize)]
pub struct AgentVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl fmt::Display for AgentVersion {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl AgentVersion {
    /// The first `MAJOR.MINOR.PATCH` (optionally `v`-prefixed) word of `output`, as printed by
    /// `pi --version` (`1.5.2`), `codex --version` (`codex-cli 0.170.0`), `opencode --version`
    /// (`v2.0.20`) and `claude --version` (`2.1.327 (Claude Code)`).
    pub fn parse(output: &str) -> Option<Self> {
        output
            .split(|c: char| c.is_whitespace() || c == '(' || c == ')')
            .find_map(Self::parse_word)
    }

    fn parse_word(word: &str) -> Option<Self> {
        let word = word.strip_prefix('v').unwrap_or(word);
        // A pre-release or build suffix (`1.2.3-beta.1`) belongs to the same release line.
        let core = word.split(['-', '+']).next()?;
        let mut parts = core.split('.');
        let mut number = || -> Option<u32> {
            let part = parts.next()?;
            if part.is_empty() || part.len() > 9 || !part.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            part.parse().ok()
        };
        let version = Self {
            major: number()?,
            minor: number()?,
            patch: number()?,
        };
        parts.next().is_none().then_some(version)
    }
}
