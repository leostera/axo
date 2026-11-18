//! Persistent salted substring fingerprints, never plaintext or agent-exported material.
use super::*;
use serde::{Deserialize, Serialize};
use serde_json::json;
const MAX_REDACTIONS: usize = 256;
fn hash(salt: &[u8], value: &str) -> [u8; 32] {
    use sha2::Digest;
    sha2::Sha256::new()
        .chain_update(salt)
        .chain_update(value.as_bytes())
        .finalize()
        .into()
}
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::PathBuf,
};
const HIDDEN: &str = "•••• (filled by you)";
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fingerprint {
    bytes: usize,
    hash: [u8; 32],
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Registry {
    salt: [u8; 16],
    entries: Vec<Fingerprint>,
}
struct State {
    registry: Registry,
    unavailable: bool,
}
pub(super) struct Privacy {
    state: Mutex<State>,
    path: Option<PathBuf>,
}
impl Default for Privacy {
    fn default() -> Self {
        Self::new(None)
    }
}
impl Privacy {
    pub(super) fn new(path: Option<PathBuf>) -> Self {
        let mut salt = [0; 16];
        let random = std::fs::File::open("/dev/urandom")
            .and_then(|mut file| file.read_exact(&mut salt))
            .is_ok();
        let mut state = State {
            registry: Registry {
                salt,
                entries: Vec::new(),
            },
            unavailable: !random,
        };
        if let Some(path) = &path {
            match OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(path)
            {
                Ok(file) => {
                    let loaded = (|| {
                        let metadata = file.metadata().ok()?;
                        if !metadata.is_file()
                            || metadata.uid() != unsafe { libc::geteuid() }
                            || metadata.permissions().mode() & 0o077 != 0
                            || metadata.len() > 65536
                        {
                            return None;
                        }
                        let registry: Registry = serde_json::from_reader(file.take(65537)).ok()?;
                        if registry.entries.len() > MAX_REDACTIONS
                            || registry
                                .entries
                                .iter()
                                .any(|entry| entry.bytes == 0 || entry.bytes > 4000)
                        {
                            return None;
                        }
                        Some(registry)
                    })();
                    if let Some(registry) = loaded {
                        state.registry = registry;
                        state.unavailable = false;
                    } else {
                        state.unavailable = true;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => state.unavailable = true,
            }
        }
        Self {
            state: Mutex::new(state),
            path,
        }
    }
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
    pub(super) fn remember(&self, value: &str) -> Result<(), ()> {
        if value.is_empty() {
            return Err(());
        }
        let mut state = self.lock();
        if state.unavailable {
            return Err(());
        }
        let fingerprint = Fingerprint {
            bytes: value.len(),
            hash: hash(&state.registry.salt, value),
        };
        if state
            .registry
            .entries
            .iter()
            .any(|entry| entry.bytes == fingerprint.bytes && entry.hash == fingerprint.hash)
        {
            return Ok(());
        }
        if state.registry.entries.len() >= MAX_REDACTIONS {
            return Err(());
        }
        let mut next = state.registry.clone();
        next.entries.push(fingerprint);
        if let Some(path) = &self.path {
            // One lock owns this bounded journal; a private, exclusive temporary file is fsynced
            // before atomic replacement. No filled value can precede its durable fingerprint.
            let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
            let save = (|| -> std::io::Result<()> {
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&temporary)?;
                serde_json::to_writer(&mut file, &next)?;
                file.flush()?;
                file.sync_all()?;
                fs::rename(&temporary, path)?;
                if let Some(parent) = path.parent() {
                    std::fs::File::open(parent)?.sync_all()?;
                }
                Ok(())
            })();
            if save.is_err() {
                return Err(());
            }
        }
        state.registry = next;
        Ok(())
    }
    pub(super) fn apply(&self, result: &mut Value) {
        let state = self.lock();
        if state.unavailable {
            *result = json!({"content":[{"type":"text","text":"Computer output withheld: the GUI privacy journal is unavailable."}],"isError":true});
            return;
        }
        if !state.registry.entries.is_empty() {
            scrub(result, &state.registry);
        }
    }
}
fn text(text: &str, registry: &Registry) -> String {
    if text.len() > 65_536 {
        return HIDDEN.into();
    }
    let mut lengths: Vec<usize> = registry.entries.iter().map(|entry| entry.bytes).collect();
    lengths.sort_unstable();
    lengths.dedup();
    let mut ranges = Vec::new();
    for (start, _) in text.char_indices() {
        for &length in &lengths {
            let end = start + length;
            if end <= text.len() && text.is_char_boundary(end) {
                let candidate = &text[start..end];
                let digest = hash(&registry.salt, candidate);
                if registry
                    .entries
                    .iter()
                    .any(|entry| entry.bytes == length && entry.hash == digest)
                {
                    ranges.push((start, end));
                }
            }
        }
    }
    ranges.sort_unstable();
    let mut output = String::new();
    let mut cursor = 0;
    let mut index = 0;
    while index < ranges.len() {
        let (start, mut end) = ranges[index];
        index += 1;
        while index < ranges.len() && ranges[index].0 <= end {
            end = end.max(ranges[index].1);
            index += 1;
        }
        output.push_str(&text[cursor..start]);
        output.push_str(HIDDEN);
        cursor = end;
    }
    output.push_str(&text[cursor..]);
    output
}
fn scrub(value: &mut Value, registry: &Registry) {
    match value {
        Value::String(content) => {
            *content = if content.contains("data:image/") {
                HIDDEN.into()
            } else {
                text(content, registry)
            };
        }
        Value::Array(items) => items.iter_mut().for_each(|item| scrub(item, registry)),
        Value::Object(object) => {
            if object.get("type").and_then(Value::as_str) == Some("image") {
                *value =
                    json!({"type":"text","text":"Screenshot withheld after secure GUI input."});
                return;
            }
            let text_block = object.get("type").and_then(Value::as_str) == Some("text");
            let old = std::mem::take(object);
            for (key, mut item) in old {
                if text_block && key == "type" {
                    object.insert(key, item);
                    continue;
                }
                let lower = key.to_ascii_lowercase();
                if lower.contains("screenshot") || lower.starts_with("image") {
                    item = json!("Screenshot withheld after secure GUI input.");
                } else {
                    scrub(&mut item, registry);
                }
                // Public MCP framing is not secret-dependent data. Preserve control keys
                // even when a very short input happens to occur in their spelling.
                let key = if matches!(
                    key.as_str(),
                    "type" | "content" | "structuredContent" | "isError" | "mimeType" | "text"
                ) {
                    key
                } else {
                    text(&key, registry)
                };
                object.insert(key, item);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn embedded_unicode_short_values_keys_and_images_are_hidden() {
        let privacy = Privacy::default();
        privacy.remember("secret-token").unwrap();
        privacy.remember("密碼").unwrap();
        privacy.remember("xy").unwrap();
        let mut result = json!({"secret-token":{"value":"before=secret-token!密碼/xy","content":[{"type":"image","data":"unreadable pixels"}],"screenshot_path":"/tmp/frame.png"}});
        privacy.apply(&mut result);
        let encoded = result.to_string();
        for forbidden in [
            "secret-token",
            "密碼",
            "xy",
            "unreadable pixels",
            "/tmp/frame.png",
        ] {
            assert!(!encoded.contains(forbidden));
        }
        assert!(encoded.contains("withheld"));
    }
    #[test]
    fn journal_restores_protection_after_restart_without_storing_plaintext() {
        let path =
            std::env::temp_dir().join(format!("axo-privacy-test-{}.json", std::process::id()));
        let privacy = Privacy::new(Some(path.clone()));
        privacy.remember("synthetic-private-value").unwrap();
        assert!(
            !std::fs::read_to_string(&path)
                .unwrap()
                .contains("synthetic-private-value")
        );
        let restored = Privacy::new(Some(path.clone()));
        let mut result = json!("prefix=synthetic-private-value/suffix");
        restored.apply(&mut result);
        assert!(!result.to_string().contains("synthetic-private-value"));
        std::fs::remove_file(path).unwrap();
    }
}
