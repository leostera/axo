//! Catalog identifiers. Shells are numbered by SQLite (`AUTOINCREMENT`), so a shell ID is positive
//! and never reused; a deserialized or constructed one is guaranteed positive. Sessions are named by
//! UUIDs (RFD0017): unique across every Mac and every database, so a Session ID alone names a
//! Session anywhere, including the cloud.

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

/// A Session's identity: a UUID, written in canonical form (lowercase, hyphenated). Assigned once,
/// when the Session is created (or by the RFD0017 migration), and never changed.
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct SessionId([u8; 16]);

/// Text that is not a canonical lowercase UUID.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InvalidSessionId(pub String);

impl fmt::Display for InvalidSessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?} is not a Session ID (a lowercase UUID)", self.0)
    }
}

impl std::error::Error for InvalidSessionId {}

impl SessionId {
    /// A new random (version 4) Session ID.
    pub fn new_v4() -> io::Result<Self> {
        let mut bytes = [0_u8; 16];
        std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        Ok(Self(bytes))
    }

    /// The Session ID whose 128 bits are `value`, big-endian. For fixtures and tests; real IDs come
    /// from `new_v4` or `parse`.
    pub const fn from_u128(value: u128) -> Self {
        Self(value.to_be_bytes())
    }

    /// `None` unless `text` is a UUID in canonical form: 36 characters, lowercase hex, hyphenated.
    pub fn parse(text: &str) -> Option<Self> {
        let raw = text.as_bytes();
        if raw.len() != 36 {
            return None;
        }
        let mut bytes = [0_u8; 16];
        let mut nibbles = 0;
        for (index, &byte) in raw.iter().enumerate() {
            if matches!(index, 8 | 13 | 18 | 23) {
                if byte != b'-' {
                    return None;
                }
                continue;
            }
            let value = match byte {
                b'0'..=b'9' => byte - b'0',
                b'a'..=b'f' => byte - b'a' + 10,
                _ => return None,
            };
            bytes[nibbles / 2] |= if nibbles % 2 == 0 { value << 4 } else { value };
            nibbles += 1;
        }
        Some(Self(bytes))
    }
}

impl std::str::FromStr for SessionId {
    type Err = InvalidSessionId;

    fn from_str(text: &str) -> Result<Self, InvalidSessionId> {
        Self::parse(text).ok_or_else(|| InvalidSessionId(text.to_owned()))
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, byte) in self.0.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                f.write_str("-")?;
            }
            write!(f, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl fmt::Debug for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SessionId({self})")
    }
}

impl Serialize for SessionId {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for SessionId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = std::borrow::Cow::<str>::deserialize(deserializer)?;
        Self::parse(&text)
            .ok_or_else(|| serde::de::Error::custom(InvalidSessionId(text.into_owned())))
    }
}

positive_id!(
    /// A pane within a session; stable across daemon restarts.
    ShellId
);

/// A random (version 4) UUID, lowercase and hyphenated.
pub fn new_uuid_v4() -> io::Result<String> {
    Ok(SessionId::new_v4()?.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_ids_are_positive_on_every_path_in() {
        assert_eq!(ShellId::new(1).map(ShellId::get), Some(1));
        assert_eq!(ShellId::new(0), None);
        assert_eq!(ShellId::try_from(-4), Err(InvalidId(-4)));
        assert_eq!(serde_json::from_str::<ShellId>("7").unwrap().get(), 7);
        assert!(serde_json::from_str::<ShellId>("0").is_err());
    }

    #[test]
    fn session_ids_are_canonical_lowercase_uuids() {
        let text = "2f5c3a1e-8d4b-4c6a-9e1f-0b7d3c2a5e41";
        let id = SessionId::parse(text).unwrap();
        assert_eq!(id.to_string(), text);
        assert_eq!(serde_json::to_string(&id).unwrap(), format!("\"{text}\""));
        assert_eq!(
            serde_json::from_str::<SessionId>(&format!("\"{text}\"")).unwrap(),
            id
        );
        for bad in [
            "2F5C3A1E-8D4B-4C6A-9E1F-0B7D3C2A5E41",
            "2f5c3a1e8d4b4c6a9e1f0b7d3c2a5e41",
            "{2f5c3a1e-8d4b-4c6a-9e1f-0b7d3c2a5e41}",
            "2f5c3a1e-8d4b-4c6a-9e1f-0b7d3c2a5e4g",
            "",
        ] {
            assert_eq!(SessionId::parse(bad), None, "{bad}");
        }
        assert!(serde_json::from_str::<SessionId>("9").is_err());
        let fresh = SessionId::new_v4().unwrap();
        assert_eq!(SessionId::parse(&fresh.to_string()), Some(fresh));
        assert_ne!(fresh, SessionId::new_v4().unwrap());
    }
}
