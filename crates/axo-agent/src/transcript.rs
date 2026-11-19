//! A Session's transcript for agents other than Pi (RFD0072, Transcripts).
//!
//! What syncs to the cloud, and what the phone and the web read, is a Session's transcript as
//! Pi session lines (`pi/3`, RFD0018), which the SessionDO reads into ATXF records (RFD0035). So
//! an agent's own conversation (a Codex rollout, a Claude Code session file, an OpenCode export)
//! is read into ATXF with ATXF's lossless converter for that agent, and written out as Pi lines
//! for its active context. Nothing downstream learns a new format, and every agent's
//! conversation reaches the phone and the web the way Pi's does.
//!
//! Every record is written (`from_atxf_tree`), not only the active context a model would see
//! after a compaction: the phone and the web show the whole conversation. No carrier rides
//! along: the cloud reads the lines one by one and never needs the original back; the agent's
//! own files stay on the Mac as the agent wrote them.

use std::fmt;
use std::io;
use std::path::Path;

use atxf::Converter;
use atxf::formats::{CLAUDE_CODE, CODEX, OPENCODE, PI};

use crate::AgentKind;

/// Why an agent's conversation could not become a transcript.
#[derive(Debug)]
pub enum TranscriptError {
    /// Pi writes its own transcript.
    NotConverted(AgentKind),
    /// ATXF could not read the agent's file, or write Pi lines for it.
    Conversion(atxf::Error),
}

impl fmt::Display for TranscriptError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TranscriptError::NotConverted(kind) => {
                write!(formatter, "{kind} writes its own transcript")
            }
            TranscriptError::Conversion(error) => {
                write!(formatter, "ATXF could not convert it: {error}")
            }
        }
    }
}

impl std::error::Error for TranscriptError {}

impl From<TranscriptError> for io::Error {
    fn from(error: TranscriptError) -> Self {
        io::Error::new(io::ErrorKind::InvalidData, error.to_string())
    }
}

fn converter(kind: AgentKind) -> Result<&'static dyn Converter, TranscriptError> {
    match kind {
        AgentKind::Pi => Err(TranscriptError::NotConverted(kind)),
        AgentKind::Codex => Ok(&CODEX),
        AgentKind::OpenCode => Ok(&OPENCODE),
        AgentKind::ClaudeCode => Ok(&CLAUDE_CODE),
    }
}

/// The Pi `session` line that heads a converted transcript. axod writes it, not ATXF: what
/// ATXF learns of a conversation grows with it (its folder, how faithful the conversion is),
/// and a header that changed would make the cloud's copy a different transcript, uploaded again
/// from the start. This one is fixed when the Session is created.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PiHeader {
    /// The Axo Session's id.
    pub session_id: String,
    /// When the Session was created, RFC 3339.
    pub timestamp: String,
    pub cwd: String,
}

/// `unix_seconds` as RFC 3339 in UTC with milliseconds, as Pi writes timestamps.
pub fn rfc3339_utc(unix_seconds: i64) -> String {
    let days = unix_seconds.div_euclid(86_400);
    let seconds = unix_seconds.rem_euclid(86_400);
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.000Z",
        seconds / 3600,
        seconds % 3600 / 60,
        seconds % 60
    )
}

impl PiHeader {
    fn line(&self) -> String {
        serde_json::json!({
            "type": "session",
            "version": 3,
            "id": self.session_id,
            "timestamp": self.timestamp,
            "cwd": self.cwd,
        })
        .to_string()
    }
}

/// The Pi session lines for `native`, `kind`'s conversation as the agent stores it, under
/// `header`.
pub fn pi_lines(
    kind: AgentKind,
    native: &str,
    header: &PiHeader,
) -> Result<String, TranscriptError> {
    let transcript = converter(kind)?
        .to_atxf(native, false)
        .map_err(TranscriptError::Conversion)?;
    let written = PI.from_atxf_tree(&transcript).ok_or_else(|| {
        TranscriptError::Conversion(atxf::Error::new("Pi sessions hold every record"))
    })?;
    let mut lines = header.line();
    lines.push('\n');
    for line in written.lines().skip(1).filter(|line| !line.is_empty()) {
        lines.push_str(line);
        lines.push('\n');
    }
    Ok(lines)
}

/// Enriches an existing text projection with activity from a converted native conversation.
/// Text ids, prompt receipts and stream timestamps remain owned by the existing projection;
/// native reasoning and tool identities come from the lossless converter, never text matching.
pub fn with_activity(presentation: &str, native: &str) -> io::Result<String> {
    use serde_json::{Value, json};
    struct Group {
        timestamp: i64,
        records: Vec<Value>,
    }
    fn records(lines: &str) -> io::Result<Vec<Value>> {
        lines
            .lines()
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_str(line).map_err(io::Error::other))
            .collect()
    }
    fn timestamp(record: &Value) -> io::Result<i64> {
        record["message"]["timestamp"]
            .as_i64()
            .ok_or_else(|| io::Error::other("Transcript message has no millisecond timestamp"))
    }
    let mut existing = records(presentation)?.into_iter();
    let header = existing
        .next()
        .filter(|record| record["type"] == "session")
        .ok_or_else(|| io::Error::other("Transcript has no session header"))?;
    let mut groups = Vec::new();
    let mut receipt = Vec::new();
    for record in existing {
        if record["type"] == "custom" && record["customType"] == "axo.command" {
            receipt.push(record);
            continue;
        }
        let at = timestamp(&record)?;
        receipt.push(record);
        groups.push(Group {
            timestamp: at,
            records: std::mem::take(&mut receipt),
        });
    }
    if !receipt.is_empty() {
        return Err(io::Error::other("Prompt receipt has no following message"));
    }
    for mut record in records(native)? {
        if record["type"] != "message" {
            continue;
        }
        let message = &mut record["message"];
        match message["role"].as_str() {
            Some("toolResult") => {}
            Some("assistant") => {
                let Some(content) = message["content"].as_array_mut() else {
                    continue;
                };
                content.retain(|block| {
                    block["type"] == "toolCall"
                        || (block["type"] == "thinking"
                            && block["thinking"]
                                .as_str()
                                .is_some_and(|s| !s.trim().is_empty()))
                });
                if content.is_empty() {
                    continue;
                }
            }
            _ => continue,
        }
        let at = timestamp(&record)?;
        let id = record["id"]
            .as_str()
            .ok_or_else(|| io::Error::other("Native activity has no id"))?;
        // A retained materialized transcript can supply activity while its native source
        // is temporarily unavailable. Re-enrichment must not change those identities.
        if !id.starts_with("axo:native:") {
            record["id"] = json!(format!("axo:native:{id}"));
        }
        groups.push(Group {
            timestamp: at,
            records: vec![record],
        });
    }
    // Stable ordering preserves each source's order at equal timestamps, and receipts stay
    // immediately before their user message even when an activity shares its timestamp.
    groups.sort_by_key(|group| group.timestamp);
    let mut lines = header.to_string() + "\n";
    let mut parent = Value::Null;
    for group in groups {
        for mut record in group.records {
            record["parentId"] = parent;
            parent = record["id"].clone();
            lines.push_str(&record.to_string());
            lines.push('\n');
        }
    }
    Ok(lines)
}

/// Writes `lines` to `transcript` unless it holds them already, replacing it whole (a
/// temporary file renamed over it), so the uploader never reads half a rewrite. Whether it
/// changed.
pub fn write_if_changed(transcript: &Path, lines: &str) -> io::Result<bool> {
    match std::fs::read(transcript) {
        Ok(current) if current == lines.as_bytes() => return Ok(false),
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let temporary = transcript.with_extension("jsonl.writing");
    std::fs::write(&temporary, lines)?;
    std::fs::rename(&temporary, transcript)?;
    Ok(true)
}

#[cfg(test)]
#[path = "transcript_activity_tests.rs"]
mod activity_tests;
#[cfg(test)]
#[path = "transcript_tests.rs"]
mod tests;
