//! Descriptor-relative private canonical-file I/O. Resolving a configured
//! location does not authorize bytes: the captured parent must match the pinned
//! directory, and each actual leaf open is no-follow, owned and single-linked.
use std::{
    ffi::{CString, OsStr, OsString},
    fs::{self, File, Metadata, OpenOptions},
    io::{self, Read},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Component, Path, PathBuf},
};
#[cfg(test)]
mod tests;
const MAX_BYTES: u64 = 4 * 1024 * 1024;
fn invalid() -> io::Error {
    io::Error::other("Unsafe canonical storage")
}
fn private_directory(metadata: &Metadata) -> bool {
    metadata.is_dir()
        && metadata.uid() == unsafe { libc::geteuid() }
        && metadata.mode() & 0o7777 == 0o700
}
fn private_file(metadata: &Metadata) -> bool {
    metadata.is_file()
        && metadata.nlink() == 1
        && metadata.uid() == unsafe { libc::geteuid() }
        && metadata.mode() & 0o7777 == 0o600
}
fn identity(left: &Metadata, right: &Metadata) -> bool {
    left.dev() == right.dev() && left.ino() == right.ino()
}
fn unchanged(left: &Metadata, right: &Metadata) -> bool {
    identity(left, right)
        && private_file(right)
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime() == right.ctime()
        && left.ctime_nsec() == right.ctime_nsec()
}
fn open_directory(path: &Path) -> io::Result<File> {
    if !path.is_absolute() || path.as_os_str().as_bytes().len() > 4096 {
        return Err(invalid());
    }
    let mut current = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open("/")?;
    for component in path.components() {
        let name = match component {
            Component::RootDir => continue,
            Component::Normal(name) => name,
            _ => return Err(invalid()),
        };
        let name = CString::new(name.as_bytes()).map_err(|_| invalid())?;
        let fd = unsafe {
            libc::openat(
                current.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        current = unsafe { File::from_raw_fd(fd) };
    }
    Ok(current)
}
pub(super) struct Directory {
    selected: PathBuf,
    resolved: PathBuf,
    handle: File,
}
impl Directory {
    pub(super) fn open(path: &Path) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(invalid());
        }
        let selected = fs::symlink_metadata(path)?;
        if !private_directory(&selected) {
            return Err(invalid());
        }
        // Normalize ambient system aliases before pinning, without rewriting the
        // recorded binding. A symlink at the private parent itself is rejected.
        let resolved = fs::canonicalize(path)?;
        let handle = open_directory(&resolved)?;
        let actual = handle.metadata()?;
        if !private_directory(&actual) || !identity(&selected, &actual) {
            return Err(invalid());
        }
        let directory = Self {
            selected: path.to_path_buf(),
            resolved,
            handle,
        };
        directory.check()?;
        Ok(directory)
    }
    pub(super) fn check(&self) -> io::Result<()> {
        let pinned = self.handle.metadata()?;
        let selected = fs::symlink_metadata(&self.selected)?;
        let current = open_directory(&self.resolved)?.metadata()?;
        if !private_directory(&pinned)
            || !private_directory(&selected)
            || !private_directory(&current)
            || !identity(&pinned, &selected)
            || !identity(&pinned, &current)
        {
            return Err(invalid());
        }
        Ok(())
    }
    fn leaf(&self, name: &OsStr, flags: libc::c_int) -> io::Result<File> {
        if name.as_bytes().is_empty()
            || name.as_bytes().contains(&b'/')
            || name == "."
            || name == ".."
        {
            return Err(invalid());
        }
        let name = CString::new(name.as_bytes()).map_err(|_| invalid())?;
        self.check()?;
        let fd = unsafe {
            libc::openat(
                self.handle.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        if !private_file(&file.metadata()?) {
            return Err(invalid());
        }
        self.check()?;
        Ok(file)
    }
    pub(super) fn writer_lock(&self, name: &OsStr) -> io::Result<File> {
        self.leaf(name, libc::O_RDWR | libc::O_CREAT)
    }
    pub(super) fn check_leaf(&self, name: &OsStr, file: &File) -> io::Result<()> {
        let pinned = file.metadata()?;
        let named = self.leaf(name, libc::O_RDONLY)?.metadata()?;
        if !private_file(&pinned) || !identity(&pinned, &named) {
            return Err(invalid());
        }
        self.check()
    }
}
pub(super) struct CanonicalFile {
    directory: Directory,
    name: OsString,
    file: File,
}
/// Immutable bytes plus their pinned source. Publication can recheck the
/// namespace and timestamps without reopening or reading a successor file.
pub(super) struct PinnedRead {
    source: CanonicalFile,
    metadata: Metadata,
    bytes: Vec<u8>,
}
impl PinnedRead {
    pub(super) fn bytes(&self) -> &[u8] {
        &self.bytes
    }
    pub(super) fn check(&self) -> io::Result<()> {
        self.source
            .directory
            .check_leaf(&self.source.name, &self.source.file)?;
        let current = self.source.file.metadata()?;
        let named = self
            .source
            .directory
            .leaf(&self.source.name, libc::O_RDONLY)?
            .metadata()?;
        if !unchanged(&self.metadata, &current) || !unchanged(&current, &named) {
            return Err(invalid());
        }
        Ok(())
    }
}
impl CanonicalFile {
    pub(super) fn open(path: &Path) -> io::Result<Self> {
        let directory = Directory::open(path.parent().ok_or_else(invalid)?)?;
        let name = path.file_name().ok_or_else(invalid)?.to_os_string();
        let file = directory.leaf(&name, libc::O_RDONLY)?;
        if file.metadata()?.len() > MAX_BYTES {
            return Err(invalid());
        }
        Ok(Self {
            directory,
            name,
            file,
        })
    }
    pub(super) fn read(mut self) -> io::Result<PinnedRead> {
        self.directory.check_leaf(&self.name, &self.file)?;
        let before = self.file.metadata()?;
        if !private_file(&before) || before.len() > MAX_BYTES {
            return Err(invalid());
        }
        let mut bytes = Vec::new();
        self.file
            .by_ref()
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)?;
        let after = self.file.metadata()?;
        let named = self
            .directory
            .leaf(&self.name, libc::O_RDONLY)?
            .metadata()?;
        if bytes.len() as u64 > MAX_BYTES
            || !unchanged(&before, &after)
            || !unchanged(&after, &named)
        {
            return Err(invalid());
        }
        self.directory.check()?;
        Ok(PinnedRead {
            source: self,
            metadata: after,
            bytes,
        })
    }
}
