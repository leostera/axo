//! Capturing work interrupted by a graceful daemon stop for message-free restart recovery.
//! The serialized stop record is retained across upgrades; continuation is a bridge control,
//! not a fabricated user/custom message. Crashes without a stop record remain outside this path.

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
