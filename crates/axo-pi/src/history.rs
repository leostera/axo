//! Recovery only reopens the transcript Axo created; this is how it recognizes it.

use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// A transcript's file identity, compared before and after a takeover wait.
#[derive(Debug, Eq, PartialEq)]
pub struct HistoryIdentity {
    device: u64,
    inode: u64,
}

/// The transcript must be a regular file inside `directory`, reached without symlinks.
pub fn ensure_existing_history(
    session_file: &Path,
    directory: &Path,
) -> io::Result<HistoryIdentity> {
    let directory = fs::canonicalize(directory)?;
    let canonical = fs::canonicalize(session_file)?;
    let metadata = fs::metadata(&canonical)?;
    if fs::symlink_metadata(session_file)?.file_type().is_symlink()
        || !canonical.starts_with(directory)
        || !metadata.is_file()
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Pi recovery requires its original Axo-owned history file",
        ));
    }
    Ok(HistoryIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}
