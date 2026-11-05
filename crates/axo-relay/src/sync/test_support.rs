//! Fixtures shared by this module's tests.

use std::path::PathBuf;
use std::time::Instant;

pub(super) fn temp_file(contents: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("axo-sync-{}.jsonl", uuid_like()));
    std::fs::write(&path, contents).unwrap();
    path
}

pub(super) fn uuid_like() -> String {
    format!(
        "{:x}{:x}",
        std::process::id(),
        Instant::now().elapsed().as_nanos() ^ rand_seed()
    )
}

pub(super) fn rand_seed() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos()
}

pub(super) const HEADER: &str = r#"{"type":"session","version":3,"id":"s"}"#;
