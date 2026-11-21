//! Prepare a native Pi transcript for another host without interpreting its history as commands.
use axo_protocol::SessionId;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::io::{self, Write};
use std::path::Path;

/// A parsed native Pi v3 transcript. The caller must independently authenticate its origin
/// and verify the snapshot epoch/head before this is eligible for import.
pub struct PiForkHistory {
    header: Value,
    entries: Vec<String>,
    last_entry: Value,
}

impl PiForkHistory {
    pub fn parse(lines: Vec<String>) -> io::Result<Self> {
        let mut lines = lines.into_iter();
        let header: Value = serde_json::from_str(&lines.next().ok_or_else(invalid_history)?)?;
        if header["type"] != "session"
            || header["version"] != 3
            || !header["id"].as_str().is_some_and(|id| !id.is_empty())
            || !header["cwd"].as_str().is_some_and(is_absolute_on_source)
        {
            return Err(invalid_history());
        }
        let mut entries = Vec::new();
        let mut seen = HashSet::new();
        let mut last_entry = Value::Null;
        for line in lines {
            let mut entry: Value = serde_json::from_str(&line)?;
            let id = entry["id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .ok_or_else(invalid_history)?;
            let valid_parent = entry.get("parentId").is_some_and(|parent| {
                if parent.is_null() {
                    seen.is_empty()
                } else {
                    parent.as_str().is_some_and(|id| seen.contains(id))
                }
            });
            if !valid_parent || !seen.insert(id.to_owned()) || entry["type"].as_str().is_none() {
                return Err(invalid_history());
            }
            last_entry = json!(id);
            if entry["type"] == "custom" && entry["customType"] == "axo.command.queued" {
                // Keep the ID so later entries still have a parent, but remove runnable input.
                entry["customType"] = json!("axo.fork.discarded_queue");
                entry.as_object_mut().expect("parsed entry").remove("data");
                entries.push(entry.to_string());
            } else {
                entries.push(line);
            }
        }
        Ok(Self {
            header,
            entries,
            last_entry,
        })
    }

    pub fn source_folder(&self) -> &str {
        self.header["cwd"].as_str().expect("parsed header")
    }

    pub fn into_child(
        mut self,
        child: SessionId,
        folder: &Path,
        source: &str,
        destination: &str,
        timestamp: &str,
    ) -> io::Result<Vec<u8>> {
        let folder = folder
            .to_str()
            .filter(|_| folder.is_absolute())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "A fork needs a canonical destination folder",
                )
            })?;
        let content = format!(
            "This conversation was forked from host {source}, working directory {:?}, to host {destination}, working directory {folder:?}. Earlier tool outputs are historical observations of the source host, not observations of the destination. Project files were not copied. Verify destination state before acting.",
            self.source_folder(),
        );
        self.header["id"] = json!(child);
        self.header["cwd"] = json!(folder);
        let mut output = Vec::new();
        writeln!(output, "{}", self.header)?;
        for line in self.entries {
            writeln!(output, "{line}")?;
        }
        writeln!(
            output,
            "{}",
            json!({
                "type": "custom_message", "customType": "axo_host_fork", "id": axo_protocol::new_uuid_v4()?,
                "parentId": self.last_entry, "timestamp": timestamp, "content": content, "display": false,
            })
        )?;
        Ok(output)
    }
}

fn invalid_history() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Not a complete Pi v3 transcript",
    )
}

fn is_absolute_on_source(path: &str) -> bool {
    if path.is_empty() || path.contains('\0') {
        return false;
    }
    let bytes = path.as_bytes();
    path.starts_with('/')
        || path.starts_with("\\\\")
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'/' | b'\\'))
}
