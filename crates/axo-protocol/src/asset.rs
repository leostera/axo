//! Assets (RFD0030): files an account keeps in the cloud, named by the SHA-256 of their bytes,
//! and attached to prompts. Parsed at the boundary: an [`Attachment`] always has a well-formed
//! hash, a file name that is safe to create in a directory, a known type and a size in range.

use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Bytes in one asset.
pub const MAX_ASSET_BYTES: u64 = 100 * 1024 * 1024;
/// Attachments on one prompt.
pub const MAX_ATTACHMENTS: usize = 8;
/// Bytes in an asset's file name.
pub const MAX_ASSET_NAME_BYTES: usize = 255;

/// Types an asset may have; anything else was stored as `application/octet-stream`.
pub const ASSET_TYPES: &[&str] = &[
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/heic",
    "application/pdf",
    "text/plain",
    "text/markdown",
    "text/csv",
    "application/json",
    "application/zip",
    "application/octet-stream",
];

/// An asset's name: the 32 bytes of its SHA-256. Written `sha256:<64 lowercase hex>`.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct AssetHash([u8; 32]);

impl AssetHash {
    pub fn from_digest(digest: [u8; 32]) -> Self {
        Self(digest)
    }

    /// The 64 lowercase hex digits, as in URLs and file paths.
    pub fn hex(&self) -> String {
        self.0.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// Parses 64 lowercase hex digits.
    pub fn parse_hex(hex: &str) -> Result<Self, InvalidAttachment> {
        let bytes = hex.as_bytes();
        if bytes.len() != 64 {
            return Err(InvalidAttachment("an asset hash has 64 hex digits"));
        }
        let mut digest = [0_u8; 32];
        for (index, pair) in bytes.chunks(2).enumerate() {
            let digit = |byte: u8| match byte {
                b'0'..=b'9' => Ok(byte - b'0'),
                b'a'..=b'f' => Ok(byte - b'a' + 10),
                _ => Err(InvalidAttachment("an asset hash is lowercase hex")),
            };
            digest[index] = digit(pair[0])? << 4 | digit(pair[1])?;
        }
        Ok(Self(digest))
    }
}

impl fmt::Display for AssetHash {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "sha256:{}", self.hex())
    }
}

impl std::str::FromStr for AssetHash {
    type Err = InvalidAttachment;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let hex = text
            .strip_prefix("sha256:")
            .ok_or(InvalidAttachment("an asset is named sha256:<hex>"))?;
        Self::parse_hex(hex)
    }
}

impl Serialize for AssetHash {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for AssetHash {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        text.parse().map_err(serde::de::Error::custom)
    }
}

/// A file name that is safe to create inside a directory: no separators, no control
/// characters, not `.` or `..`, at most 255 bytes.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct AssetName(String);

impl AssetName {
    pub fn parse(name: String) -> Result<Self, InvalidAttachment> {
        if name.is_empty()
            || name.len() > MAX_ASSET_NAME_BYTES
            || name == "."
            || name == ".."
            || name
                .chars()
                .any(|character| matches!(character, '/' | '\\') || character.is_control())
        {
            return Err(InvalidAttachment(
                "a file name has no slashes or control characters and is at most 255 bytes",
            ));
        }
        Ok(Self(name))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for AssetName {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// One of [`ASSET_TYPES`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AssetType(&'static str);

impl AssetType {
    pub fn parse(text: &str) -> Result<Self, InvalidAttachment> {
        ASSET_TYPES
            .iter()
            .find(|known| **known == text)
            .map(|known| Self(known))
            .ok_or(InvalidAttachment("unknown asset type"))
    }

    pub fn as_str(&self) -> &'static str {
        self.0
    }

    /// Images a model may take as image blocks.
    pub fn is_model_image(&self) -> bool {
        matches!(
            self.0,
            "image/png" | "image/jpeg" | "image/gif" | "image/webp"
        )
    }
}

impl Serialize for AssetType {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.0)
    }
}

impl<'de> Deserialize<'de> for AssetType {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(&String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// A file attached to a prompt, as a client sends it.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub asset: AssetHash,
    pub name: AssetName,
    pub mime_type: AssetType,
    /// At most [`MAX_ASSET_BYTES`].
    pub size: u64,
}

impl<'de> Deserialize<'de> for Attachment {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Wire {
            asset: AssetHash,
            name: AssetName,
            mime_type: AssetType,
            size: u64,
        }
        let wire = Wire::deserialize(deserializer)?;
        if wire.size > MAX_ASSET_BYTES {
            return Err(serde::de::Error::custom("an asset is at most 100 MiB"));
        }
        Ok(Self {
            asset: wire.asset,
            name: wire.name,
            mime_type: wire.mime_type,
            size: wire.size,
        })
    }
}

/// A prompt's attachments: at most [`MAX_ATTACHMENTS`].
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Attachments(Vec<Attachment>);

impl Attachments {
    pub fn parse(attachments: Vec<Attachment>) -> Result<Self, InvalidAttachment> {
        if attachments.len() > MAX_ATTACHMENTS {
            return Err(InvalidAttachment("a prompt has at most 8 attachments"));
        }
        Ok(Self(attachments))
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn iter(&self) -> std::slice::Iter<'_, Attachment> {
        self.0.iter()
    }
}

impl<'de> Deserialize<'de> for Attachments {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(Vec::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// An attachment axod has fetched and checked: its bytes are at `path` and match its hash.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FetchedAttachment {
    pub path: PathBuf,
    pub asset: AssetHash,
    pub name: AssetName,
    pub mime_type: AssetType,
    pub size: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidAttachment(pub &'static str);

impl fmt::Display for InvalidAttachment {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for InvalidAttachment {}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HASH: &str = "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

    #[test]
    fn an_attachment_parses_and_round_trips() {
        let value = json!({ "asset": HASH, "name": "whiteboard.jpg", "mimeType": "image/jpeg", "size": 120000 });
        let attachment: Attachment = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(
            attachment.asset.hex(),
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        );
        assert!(attachment.mime_type.is_model_image());
        assert_eq!(serde_json::to_value(&attachment).unwrap(), value);
    }

    #[test]
    fn names_that_could_escape_their_directory_are_refused() {
        for name in [
            "../x",
            "a/b",
            "a\\b",
            ".",
            "..",
            "",
            "a\u{0}b",
            "a\nb",
            &"x".repeat(256),
        ] {
            assert!(AssetName::parse(name.to_owned()).is_err(), "{name:?}");
        }
        assert!(AssetName::parse("Screenshot 2026-11-04 at 16.40.png".to_owned()).is_ok());
        assert!(AssetName::parse("..hidden".to_owned()).is_ok());
    }

    #[test]
    fn malformed_hashes_types_sizes_and_too_many_are_refused() {
        let attachment = |asset: &str, mime: &str, size: u64| {
            serde_json::from_value::<Attachment>(
                json!({ "asset": asset, "name": "f", "mimeType": mime, "size": size }),
            )
        };
        assert!(attachment(&HASH.to_uppercase(), "image/png", 1).is_err());
        assert!(attachment(&HASH[..70], "image/png", 1).is_err());
        assert!(attachment(HASH.trim_start_matches("sha256:"), "image/png", 1).is_err());
        assert!(attachment(HASH, "image/svg+xml", 1).is_err());
        assert!(attachment(HASH, "image/png", MAX_ASSET_BYTES + 1).is_err());
        assert!(attachment(HASH, "image/png", MAX_ASSET_BYTES).is_ok());
        let one = json!({ "asset": HASH, "name": "f", "mimeType": "text/plain", "size": 1 });
        assert!(serde_json::from_value::<Attachments>(json!(vec![one.clone(); 8])).is_ok());
        assert!(serde_json::from_value::<Attachments>(json!(vec![one; 9])).is_err());
        assert!(
            serde_json::from_value::<Attachment>(
                json!({ "asset": HASH, "name": "f", "mimeType": "text/plain", "size": 1, "extra": 1 })
            )
            .is_err()
        );
    }
}
