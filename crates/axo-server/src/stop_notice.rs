//! Telling the agents an Axod stop interrupted that they may carry on.
//!
//! When Axod stops (to update Axo, say), every Pi stops with it, and a Pi in the middle of a
//! turn stops mid-thought. On its way out Axod writes down its version and which Sessions were
//! working; the next Axod restores those Sessions' Pis before any other, then prompts each one
//! with what happened, so the agent picks up where it was rather than sitting idle until
//! someone notices. A stop that leaves no record (a crash, a kill) prompts no one.

use std::io;

use axo_protocol::SessionId;
use serde_json::{Value, json};

/// How the previous Axod stopped, as it recorded it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DaemonStop {
    /// Axo's version, as Cargo has it (`0.7.0`).
    pub(crate) version: String,
    pub(crate) build: u64,
    /// Sessions whose Pi was in the middle of a turn, most recently active first.
    pub(crate) interrupted: Vec<SessionId>,
}

/// This Axod: what the next one compares against.
pub(crate) fn this_daemon(interrupted: Vec<SessionId>) -> DaemonStop {
    DaemonStop {
        version: env!("CARGO_PKG_VERSION").to_owned(),
        build: crate::build_number(),
        interrupted,
    }
}

impl DaemonStop {
    pub(crate) fn to_stored(&self) -> String {
        json!({
            "version": self.version,
            "build": self.build,
            "interrupted": self.interrupted.iter().map(ToString::to_string).collect::<Vec<_>>(),
        })
        .to_string()
    }

    /// A stored record, or an error saying what is wrong with it; IDs that aren't Session IDs
    /// make the whole record invalid rather than being skipped, as nothing else writes it.
    pub(crate) fn parse(stored: &str) -> io::Result<Self> {
        let invalid = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_owned());
        let value: Value = serde_json::from_str(stored).map_err(|_| invalid("not JSON"))?;
        let version = value["version"]
            .as_str()
            .filter(|version| !version.is_empty())
            .ok_or_else(|| invalid("version is missing"))?
            .to_owned();
        let build = value["build"]
            .as_u64()
            .ok_or_else(|| invalid("build is missing"))?;
        let interrupted = value["interrupted"]
            .as_array()
            .ok_or_else(|| invalid("interrupted is missing"))?
            .iter()
            .map(|id| {
                id.as_str()
                    .and_then(|id| id.parse::<SessionId>().ok())
                    .ok_or_else(|| invalid("interrupted holds a malformed Session ID"))
            })
            .collect::<io::Result<_>>()?;
        Ok(Self {
            version,
            build,
            interrupted,
        })
    }

    /// What an interrupted agent is told when `current` restores it.
    pub(crate) fn notice(&self, current: &DaemonStop) -> String {
        let reason = if self.version != current.version {
            format!(
                "to update Axo from {} to {}",
                short_version(&self.version),
                short_version(&current.version)
            )
        } else if self.build != current.build {
            let version = short_version(&current.version);
            format!(
                "to update Axo from {version} (axod {}) to {version} (axod {})",
                self.build, current.build
            )
        } else {
            "when Axo restarted".to_owned()
        };
        format!("(the session was stopped {reason}, you may continue)")
    }
}

/// `0.7` for Cargo's `0.7.0`, as Axo's versions are written; anything else as it is.
fn short_version(version: &str) -> &str {
    version
        .strip_suffix(".0")
        .filter(|short| short.contains('.'))
        .unwrap_or(version)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stop(version: &str, build: u64) -> DaemonStop {
        DaemonStop {
            version: version.to_owned(),
            build,
            interrupted: Vec::new(),
        }
    }

    #[test]
    fn the_notice_says_what_the_update_was() {
        assert_eq!(
            stop("0.6.0", 32).notice(&stop("0.7.0", 33)),
            "(the session was stopped to update Axo from 0.6 to 0.7, you may continue)"
        );
        assert_eq!(
            stop("0.7.0", 33).notice(&stop("0.7.0", 34)),
            "(the session was stopped to update Axo from 0.7 (axod 33) to 0.7 (axod 34), you may continue)"
        );
        assert_eq!(
            stop("0.7.0", 33).notice(&stop("0.7.0", 33)),
            "(the session was stopped when Axo restarted, you may continue)"
        );
        assert_eq!(short_version("1.0"), "1.0");
        assert_eq!(short_version("0.10.0"), "0.10");
    }

    #[test]
    fn a_stored_stop_reads_back_and_a_damaged_one_is_refused() {
        let interrupted = vec![SessionId::new_v4().unwrap(), SessionId::new_v4().unwrap()];
        let stored = DaemonStop {
            interrupted: interrupted.clone(),
            ..stop("0.7.0", 33)
        };
        assert_eq!(DaemonStop::parse(&stored.to_stored()).unwrap(), stored);
        for damaged in [
            "",
            "[]",
            r#"{"build":3,"interrupted":[]}"#,
            r#"{"version":"0.7.0","interrupted":[]}"#,
            r#"{"version":"0.7.0","build":3}"#,
            r#"{"version":"0.7.0","build":3,"interrupted":["nope"]}"#,
        ] {
            assert!(DaemonStop::parse(damaged).is_err(), "{damaged}");
        }
    }
}
