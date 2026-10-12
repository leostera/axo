//! Bounded display metadata from the exact Pi-owned canonical file, never routing authority.
use serde::Deserialize;
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

#[derive(Deserialize)]
struct Entry {
    #[serde(rename = "type")]
    kind: String,
    name: Option<String>,
}

pub fn canonical_title(path: &Path) -> Option<String> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || metadata.mode() & 0o777 != 0o600
        || metadata.len() > 4 * 1024 * 1024
    {
        return None;
    }
    let mut data = String::new();
    file.take(4 * 1024 * 1024 + 1)
        .read_to_string(&mut data)
        .ok()?;
    if data.len() > 4 * 1024 * 1024 {
        return None;
    }
    let entry = data
        .lines()
        .rev()
        .filter_map(|line| serde_json::from_str::<Entry>(line).ok())
        .find(|entry| entry.kind == "session_info")?;
    entry.name.filter(|name| {
        !name.is_empty()
            && name.trim() == name
            && name.encode_utf16().count() <= 80
            && !name.chars().any(char::is_control)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{PermissionsExt, symlink},
    };
    #[test]
    fn canonical_title_is_latest_bounded_metadata_not_a_document_authority() {
        let root = crate::test_support::TestDirectory::new();
        let file = root.path().join("canonical.jsonl");
        fs::write(&file, "{\"type\":\"session_info\",\"name\":\"First\"}\n{\"type\":\"message\",\"name\":\"Not a title\"}\n{\"type\":\"session_info\",\"name\":\"Last\"}\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(canonical_title(&file).as_deref(), Some("Last"));
        let link = root.path().join("link");
        symlink(&file, &link).unwrap();
        assert!(canonical_title(&link).is_none());
        fs::write(&file, "{\"type\":\"session_info\",\"name\":\"\"}\n").unwrap();
        assert!(canonical_title(&file).is_none());
    }
}
