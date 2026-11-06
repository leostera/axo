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

/// The history recovery resumes: `Some` for an Axo-owned transcript (see
/// `ensure_existing_history`), `None` for a Pi that never wrote one. Pi creates its file with
/// the first message, so a Session restored or reopened before then starts a fresh Pi on the
/// same path and loses nothing. A history that vanished after `has_messages` is refused rather
/// than silently replaced.
pub fn recoverable_history(
    session_file: &Path,
    directory: &Path,
    has_messages: bool,
) -> io::Result<Option<HistoryIdentity>> {
    let never_written = !has_messages
        && fs::symlink_metadata(session_file)
            .is_err_and(|error| error.kind() == io::ErrorKind::NotFound);
    if !never_written {
        return ensure_existing_history(session_file, directory).map(Some);
    }
    let parent = session_file.parent().map(fs::canonicalize).transpose()?;
    if !parent
        .is_some_and(|parent| parent.starts_with(fs::canonicalize(directory).unwrap_or_default()))
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Pi history must be inside Axo's history directory",
        ));
    }
    Ok(None)
}
