//! Record identity and hashing for Pi session files (`pi/3`; RFD0018, Record identity and
//! hashing). The same rules are implemented in TypeScript (`packages/axo-api/src/pi3.ts`), and
//! both are checked against `schemas/axo.leostera.dev/v1/fixtures/pi3-*`.
//!
//! - `D(tag, text) = "sha256:" + hex(sha256("axo/pi3/" + tag + "\n" + text))`
//! - `header_hash = D("transcript", header)`
//! - `hash = D("record", JCS({ content: D("content", line), refs, transcript: header_hash }))`,
//!   where `refs` maps each reference field the entry has to the referenced record's hash, or
//!   `null` when it names no earlier record.
//! - `chain` starts at `header_hash`; each record folds in as `D("chain", chain + "\n" + hash)`.
//! - `heads` are the sorted hashes of records no other record references.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

pub const FORMAT: &str = "pi/3";
/// Pi's reference fields, in JCS (sorted) order.
const REF_FIELDS: [&str; 4] = ["firstKeptEntryId", "fromId", "parentId", "targetId"];
/// The largest line a Session may hold; a larger one stops that Session's upload.
pub const MAX_LINE_BYTES: usize = 12 * 1_048_576;

pub fn digest(tag: &str, text: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"axo/pi3/");
    hasher.update(tag.as_bytes());
    hasher.update(b"\n");
    hasher.update(text.as_bytes());
    let bytes = hasher.finalize();
    let mut hex = String::with_capacity(7 + 64);
    hex.push_str("sha256:");
    for byte in bytes {
        hex.push_str(&format!("{byte:02x}"));
    }
    hex
}

/// One hashed record. The line itself is not kept: Axod reads it from the file when it uploads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub id: Option<String>,
    pub hash: String,
    /// The chain after this record.
    pub chain: String,
    /// Ids of earlier records this one references.
    pub references: Vec<String>,
}

/// A transcript hashed in file order. Positions count from 1 after the header.
#[derive(Clone, Debug)]
pub struct Transcript {
    header: String,
    header_hash: String,
    records: Vec<Record>,
    by_id: HashMap<String, String>,
    referenced: HashSet<String>,
}

impl Transcript {
    pub fn start(header: &str) -> Self {
        Self {
            header: header.to_owned(),
            header_hash: digest("transcript", header),
            records: Vec::new(),
            by_id: HashMap::new(),
            referenced: HashSet::new(),
        }
    }

    pub fn header(&self) -> &str {
        &self.header
    }

    pub fn header_hash(&self) -> &str {
        &self.header_hash
    }

    pub fn count(&self) -> u64 {
        self.records.len() as u64
    }

    pub fn records(&self) -> &[Record] {
        &self.records
    }

    pub fn chain(&self) -> &str {
        self.records
            .last()
            .map_or(&self.header_hash, |record| &record.chain)
    }

    /// The chain after `position` records; 0 is the header hash.
    pub fn chain_at(&self, position: u64) -> Option<&str> {
        if position == 0 {
            return Some(&self.header_hash);
        }
        self.records
            .get(usize::try_from(position - 1).ok()?)
            .map(|record| record.chain.as_str())
    }

    /// Adds the next line, or returns `None` if it is not a JSON object.
    pub fn push(&mut self, line: &str) -> Option<&Record> {
        let entry: Map<String, Value> = serde_json::from_str(line).ok()?;
        let id = entry.get("id").and_then(Value::as_str).map(str::to_owned);
        let mut refs = Vec::new();
        let mut references = Vec::new();
        for field in REF_FIELDS {
            let Some(value) = entry.get(field) else {
                continue;
            };
            let target = value.as_str().and_then(|id| {
                let hash = self.by_id.get(id)?;
                references.push(id.to_owned());
                Some(hash)
            });
            refs.push(match target {
                Some(hash) => format!("\"{field}\":\"{hash}\""),
                None => format!("\"{field}\":null"),
            });
        }
        let content = digest("content", line);
        let hash = digest(
            "record",
            &format!(
                "{{\"content\":\"{content}\",\"refs\":{{{}}},\"transcript\":\"{}\"}}",
                refs.join(","),
                self.header_hash
            ),
        );
        let chain = digest("chain", &format!("{}\n{hash}", self.chain()));
        self.referenced.extend(references.iter().cloned());
        if let Some(id) = &id {
            self.by_id.insert(id.clone(), hash.clone());
        }
        self.records.push(Record {
            id,
            hash,
            chain,
            references,
        });
        self.records.last()
    }

    pub fn heads(&self) -> Vec<String> {
        let mut heads: Vec<String> = self
            .records
            .iter()
            .filter(|record| {
                record
                    .id
                    .as_ref()
                    .is_none_or(|id| !self.referenced.contains(id))
            })
            .map(|record| record.hash.clone())
            .collect();
        heads.sort();
        heads
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SESSION: &str =
        include_str!("../../../schemas/axo.leostera.dev/v1/fixtures/pi3-session.jsonl");
    const VECTORS: &str =
        include_str!("../../../schemas/axo.leostera.dev/v1/fixtures/pi3-vectors.json");

    #[test]
    fn the_fixture_transcript_hashes_to_the_vectors_typescript_produces() {
        let vectors: Value = serde_json::from_str(VECTORS).unwrap();
        let mut lines = SESSION.trim_end().split('\n');
        let mut transcript = Transcript::start(lines.next().unwrap());
        for line in lines {
            assert!(transcript.push(line).is_some());
        }
        assert_eq!(transcript.header_hash(), vectors["headerHash"]);
        for (record, expected) in transcript
            .records()
            .iter()
            .zip(vectors["records"].as_array().unwrap())
        {
            assert_eq!(record.id.as_deref(), expected["id"].as_str());
            assert_eq!(record.hash, expected["hash"]);
            assert_eq!(record.chain, expected["chain"]);
        }
        assert_eq!(transcript.count(), vectors["count"]);
        assert_eq!(transcript.chain(), vectors["chain"]);
        assert_eq!(
            serde_json::to_value(transcript.heads()).unwrap(),
            vectors["heads"]
        );
        assert_eq!(transcript.chain_at(0), Some(transcript.header_hash()));
    }

    #[test]
    fn only_json_objects_are_records() {
        let mut transcript = Transcript::start("{\"type\":\"session\"}");
        assert!(transcript.push("[1]").is_none());
        assert!(transcript.push("{\"id\":").is_none());
        assert_eq!(transcript.count(), 0);
    }
}
