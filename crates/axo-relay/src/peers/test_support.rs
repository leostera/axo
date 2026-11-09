//! Fixtures shared by this module's tests.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::Ordering;

use crate::peers::mirror::{ClientRecord, Mirror, Place};

pub(super) struct Scratch(pub(super) PathBuf);

impl Scratch {
    pub(super) fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("axo-peers-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

pub(super) const HOST: &str = "2e2e7f91-3d8f-4f97-8f71-4fc7d53313c7";

pub(super) const SESSION: &str = "8f8f8f8f-0000-4000-8000-000000000001";

pub(super) const HEADER: &str = r#"{"type":"session","version":3,"id":"8f8f8f8f-0000-4000-8000-000000000001","cwd":"/Users/leo/src/axo"}"#;

pub(super) fn place() -> Place {
    Place::of(HOST, SESSION).unwrap()
}

pub(super) fn record(cursor: u64) -> ClientRecord {
    ClientRecord {
        cursor,
        line: format!(r#"{{"type":"message","id":"m{cursor}"}}"#),
    }
}

pub(super) fn records(range: std::ops::RangeInclusive<u64>) -> Vec<ClientRecord> {
    range.map(record).collect()
}

pub(super) fn copy(mirror: &Mirror) -> String {
    fs::read_to_string(mirror.file(&place())).unwrap()
}

pub(super) fn expected(cursors: std::ops::RangeInclusive<u64>) -> String {
    let mut text = format!("{HEADER}\n");
    for cursor in cursors {
        text.push_str(&record(cursor).line);
        text.push('\n');
    }
    text
}
