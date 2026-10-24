//! Catalog identifiers. SQLite assigns them (`AUTOINCREMENT`), so they are positive and never
//! reused; a deserialized or constructed ID is guaranteed positive.

use std::fmt;
use std::io::{self, Read};

use serde::{Deserialize, Serialize};

/// An identifier that was zero or negative.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidId(pub i64);

impl fmt::Display for InvalidId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "identifier {} is not positive", self.0)
    }
}

impl std::error::Error for InvalidId {}

macro_rules! positive_id {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
        #[serde(try_from = "i64", into = "i64")]
        pub struct $name(i64);

        impl $name {
            /// `None` unless `id` is positive.
            pub fn new(id: i64) -> Option<Self> {
                (id > 0).then_some(Self(id))
            }

            pub fn get(self) -> i64 {
                self.0
            }
        }

        impl TryFrom<i64> for $name {
            type Error = InvalidId;

            fn try_from(id: i64) -> Result<Self, InvalidId> {
                Self::new(id).ok_or(InvalidId(id))
            }
        }

        impl From<$name> for i64 {
            fn from(id: $name) -> i64 {
                id.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
    };
}

positive_id!(
    /// A session (a tab in the app); stable across daemon restarts.
    SessionId
);
positive_id!(
    /// A pane within a session; stable across daemon restarts.
    ShellId
);

/// A random (version 4) UUID, lowercase and hyphenated.
pub fn new_uuid_v4() -> io::Result<String> {
    let mut bytes = [0_u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_positive_on_every_path_in() {
        assert_eq!(SessionId::new(1).map(SessionId::get), Some(1));
        assert_eq!(SessionId::new(0), None);
        assert_eq!(ShellId::try_from(-4), Err(InvalidId(-4)));
        assert_eq!(serde_json::from_str::<ShellId>("7").unwrap().get(), 7);
        assert!(serde_json::from_str::<ShellId>("0").is_err());
        assert!(serde_json::from_str::<SessionId>("-1").is_err());
        assert_eq!(
            serde_json::to_string(&SessionId::new(9).unwrap()).unwrap(),
            "9"
        );
    }
}
