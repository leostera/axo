//! Bounded reads of operator-owned credentials and bootstrap state.
use std::{
    fs::OpenOptions,
    io::{self, Read},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};
pub(crate) fn read_private(path: &Path, limit: usize) -> io::Result<Vec<u8>> {
    if !path.is_absolute() {
        return Err(io::Error::other("Private file path must be absolute"));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o600
        || metadata.nlink() != 1
        || metadata.len() > limit as u64
    {
        return Err(io::Error::other(
            "Private file must be owned, regular, single-linked, mode 0600 and bounded",
        ));
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(io::Error::other("Private file limit"));
    }
    Ok(bytes)
}
