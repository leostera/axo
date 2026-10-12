//! SQLite never opens filesystem paths: a bounded in-memory transaction is
//! published as a complete private SQLite image through the pinned directory FD.
//! Publication (not SQLite's memory commit) is the durable commit boundary.
use super::Error;
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
};

pub(super) const NAME: &str = "session-state.sqlite3";
pub(super) const MAX_BYTES: usize = 64 * 1024 * 1024;
const AUTHORITY_NAME: &str = "session-state.authority";
const AUTHORITY_BYTES: &[u8] = b"axo.central-session-state.sqlite-image.v1\n";
const LEGACY_NAMES: [&str; 4] = [
    "work-records.json",
    "pane-state.json",
    "pi-state.json",
    "runtime-state.json",
];

#[derive(Clone, PartialEq, Eq)]
struct Identity {
    device: u64,
    inode: u64,
    digest: [u8; 32],
}
struct Image {
    identity: Identity,
    bytes: Vec<u8>,
}

pub(super) struct Root {
    path: PathBuf,
    directory: File,
    _owner: File,
    current: Option<Identity>,
    authority: Option<Identity>,
}
impl Drop for Root {
    fn drop(&mut self) {
        // Another thread may fork while this lease is open. CLOEXEC closes the
        // child's copy later; explicit unlock ends this owner's lease now.
        unsafe {
            libc::flock(self._owner.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
impl Root {
    pub(super) fn acquire(path: &Path) -> Result<Self, Error> {
        if !path.is_absolute() {
            return Err(Error::UnsafeStorage);
        }
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open(path)
            .map_err(|_| Error::UnsafeStorage)?;
        let metadata = directory.metadata().map_err(|_| Error::UnsafeStorage)?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o700
        {
            return Err(Error::UnsafeStorage);
        }
        let owner = Self::open_at(&directory, "owner.lock", libc::O_RDWR | libc::O_CREAT)
            .map_err(|_| Error::UnsafeStorage)?;
        validate(&owner, MAX_BYTES).map_err(|_| Error::UnsafeStorage)?;
        if unsafe { libc::flock(owner.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } < 0 {
            return Err(Error::OwnerConflict);
        }
        let mut root = Self {
            path: path.into(),
            directory,
            _owner: owner,
            current: None,
            authority: None,
        };
        root.check_directory()?;
        if let Some(marker) = root.read(AUTHORITY_NAME)? {
            if marker.bytes != AUTHORITY_BYTES {
                return Err(Error::UnsafeStorage);
            }
            root.authority = Some(marker.identity);
        }
        Ok(root)
    }
    fn open(&self, name: &str, flags: i32) -> io::Result<File> {
        Self::open_at(&self.directory, name, flags)
    }
    fn open_at(directory: &File, name: &str, flags: i32) -> io::Result<File> {
        let name = CString::new(name).map_err(io::Error::other)?;
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    pub(super) fn exists(&self, name: &str) -> Result<bool, Error> {
        let name = CString::new(name).map_err(|_| Error::UnsafeStorage)?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } == 0
        {
            Ok(true)
        } else if io::Error::last_os_error().kind() == io::ErrorKind::NotFound {
            Ok(false)
        } else {
            Err(Error::UnsafeStorage)
        }
    }
    pub(super) fn has_authority(&self) -> Result<bool, Error> {
        match self.read(AUTHORITY_NAME)? {
            None if self.authority.is_none() => Ok(false),
            Some(image)
                if image.bytes == AUTHORITY_BYTES
                    && self.authority.as_ref() == Some(&image.identity) =>
            {
                Ok(true)
            }
            _ => Err(Error::UnsafeStorage),
        }
    }
    fn reserve_authority(&mut self) -> Result<(), Error> {
        if self.has_authority()? {
            return Ok(());
        }
        let mut marker = self
            .open(
                AUTHORITY_NAME,
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            )
            .map_err(|_| Error::Storage)?;
        validate(&marker, 512).map_err(|_| Error::UnsafeStorage)?;
        marker
            .write_all(AUTHORITY_BYTES)
            .and_then(|()| marker.sync_all())
            .map_err(|_| Error::Storage)?;
        self.directory.sync_all().map_err(|_| Error::Storage)?;
        self.authority = Some(self.read(AUTHORITY_NAME)?.ok_or(Error::Storage)?.identity);
        Ok(())
    }
    pub(super) fn has_legacy(&self) -> Result<bool, Error> {
        for name in LEGACY_NAMES {
            if self.exists(name)? {
                return Ok(true);
            }
        }
        Ok(false)
    }
    pub(super) fn check_directory(&self) -> Result<(), Error> {
        let held = self
            .directory
            .metadata()
            .map_err(|_| Error::UnsafeStorage)?;
        let named = std::fs::symlink_metadata(&self.path).map_err(|_| Error::UnsafeStorage)?;
        if !named.is_dir()
            || held.dev() != named.dev()
            || held.ino() != named.ino()
            || held.uid() != unsafe { libc::geteuid() }
            || held.mode() & 0o777 != 0o700
        {
            return Err(Error::UnsafeStorage);
        }
        let named_owner = self
            .open("owner.lock", libc::O_RDONLY)
            .map_err(|_| Error::UnsafeStorage)?;
        if validate(&named_owner, MAX_BYTES).map_err(|_| Error::UnsafeStorage)?
            != validate(&self._owner, MAX_BYTES).map_err(|_| Error::UnsafeStorage)?
        {
            return Err(Error::UnsafeStorage);
        }
        // SQLite has no disk sidecars in this mode, at startup or at commit.
        for suffix in ["-journal", "-wal", "-shm"] {
            if self.exists(&format!("{NAME}{suffix}"))? {
                return Err(Error::UnsafeStorage);
            }
        }
        Ok(())
    }
    fn read(&self, name: &str) -> Result<Option<Image>, Error> {
        let mut file = match self.open(name, libc::O_RDONLY) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(Error::UnsafeStorage),
        };
        let before = validate(&file, MAX_BYTES).map_err(|_| Error::UnsafeStorage)?;
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Storage)?;
        let after = validate(&file, MAX_BYTES).map_err(|_| Error::UnsafeStorage)?;
        if before != after || bytes.len() > MAX_BYTES || bytes.len() as u64 != after.2 {
            return Err(Error::UnsafeStorage);
        }
        Ok(Some(Image {
            identity: Identity {
                device: after.0,
                inode: after.1,
                digest: Sha256::digest(&bytes).into(),
            },
            bytes,
        }))
    }
    pub(super) fn runtime_directory(&self) -> Result<PathBuf, Error> {
        self.child_directory("Runtime")
    }
    pub(super) fn central_directory(&self) -> Result<PathBuf, Error> {
        self.child_directory(super::SERVICE_DIRECTORY)
    }
    fn child_directory(&self, name: &str) -> Result<PathBuf, Error> {
        self.check_directory()?;
        let c_name = CString::new(name).map_err(|_| Error::Storage)?;
        if unsafe { libc::mkdirat(self.directory.as_raw_fd(), c_name.as_ptr(), 0o700) } < 0
            && io::Error::last_os_error().kind() != io::ErrorKind::AlreadyExists
        {
            return Err(Error::Storage);
        }
        let directory = self
            .open(name, libc::O_RDONLY | libc::O_DIRECTORY)
            .map_err(|_| Error::UnsafeStorage)?;
        let metadata = directory.metadata().map_err(|_| Error::UnsafeStorage)?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o700
        {
            return Err(Error::UnsafeStorage);
        }
        self.directory.sync_all().map_err(|_| Error::Storage)?;
        self.check_directory()?;
        Ok(self.path.join(name))
    }
    pub(super) fn load(&mut self) -> Result<Option<Vec<u8>>, Error> {
        self.check_directory()?;
        let image = self.read(NAME)?;
        self.current = image.as_ref().map(|image| image.identity.clone());
        Ok(image.map(|image| image.bytes))
    }
    pub(super) fn publish(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if bytes.is_empty() || bytes.len() > MAX_BYTES {
            return Err(Error::Capacity);
        }
        self.check_directory()?;
        self.reserve_authority()?;
        if self.read(NAME)?.map(|image| image.identity) != self.current {
            return Err(Error::UnsafeStorage);
        }
        let temporary = format!(".session-state-{}.tmp", uuid::Uuid::new_v4());
        let mut staged = self
            .open(&temporary, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL)
            .map_err(|_| Error::Storage)?;
        validate(&staged, MAX_BYTES).map_err(|_| Error::UnsafeStorage)?;
        // On failure retain the owned staging file. It is evidence, not a new
        // authority, and cannot cause a later startup to choose a blank model.
        staged
            .write_all(bytes)
            .and_then(|()| staged.sync_all())
            .map_err(|_| Error::Storage)?;
        self.check_directory()?;
        if self.read(NAME)?.map(|image| image.identity) != self.current {
            return Err(Error::UnsafeStorage);
        }
        let from = CString::new(temporary.as_str()).map_err(|_| Error::Storage)?;
        let to = CString::new(NAME).map_err(|_| Error::Storage)?;
        let flags = if self.current.is_some() {
            libc::RENAME_SWAP
        } else {
            libc::RENAME_EXCL
        };
        if unsafe {
            libc::renameatx_np(
                self.directory.as_raw_fd(),
                from.as_ptr(),
                self.directory.as_raw_fd(),
                to.as_ptr(),
                flags,
            )
        } < 0
        {
            return Err(Error::Storage);
        }
        // An exchanged unexpected file stays retained; never erase uncertain or
        // unsafe bytes even if another same-user actor raced the preflight.
        if self.current.is_some()
            && self.read(&temporary)?.map(|image| image.identity) != self.current
        {
            return Err(Error::UnsafeStorage);
        }
        let published = self.read(NAME)?.ok_or(Error::Storage)?;
        if published.identity.digest != <[u8; 32]>::from(Sha256::digest(bytes)) {
            return Err(Error::UnsafeStorage);
        }
        self.directory.sync_all().map_err(|_| Error::Storage)?;
        self.check_directory()?;
        self.current = Some(published.identity);
        if flags == libc::RENAME_SWAP {
            if unsafe { libc::unlinkat(self.directory.as_raw_fd(), from.as_ptr(), 0) } < 0 {
                return Err(Error::Storage);
            }
            self.directory.sync_all().map_err(|_| Error::Storage)?;
        }
        Ok(())
    }
}
fn validate(file: &File, limit: usize) -> io::Result<(u64, u64, u64)> {
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o600
        || metadata.nlink() != 1
        || metadata.len() > limit as u64
    {
        return Err(io::Error::other("Unsafe private database file"));
    }
    Ok((metadata.dev(), metadata.ino(), metadata.len()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;
    use std::os::unix::fs::{PermissionsExt, symlink};
    #[test]
    fn private_publication_preserves_bytes_and_detects_changed_original() {
        let directory = TestDirectory::new();
        let mut root = Root::acquire(directory.path()).unwrap();
        root.publish(b"first").unwrap();
        root.publish(b"second").unwrap();
        assert_eq!(root.load().unwrap().unwrap(), b"second");
        std::fs::write(directory.path().join(NAME), b"changed").unwrap();
        assert_eq!(root.publish(b"third"), Err(Error::UnsafeStorage));
        assert_eq!(
            std::fs::read(directory.path().join(NAME)).unwrap(),
            b"changed"
        );
    }
    #[test]
    fn unsafe_database_and_sidecars_are_never_repaired() {
        for kind in ["symlink", "hardlink", "mode", "directory", "journal"] {
            let directory = TestDirectory::new();
            let destination = directory.path().join(NAME);
            match kind {
                "symlink" => {
                    std::fs::write(directory.path().join("original"), b"original").unwrap();
                    symlink("original", &destination).unwrap();
                }
                "hardlink" => {
                    std::fs::write(&destination, b"original").unwrap();
                    std::fs::set_permissions(&destination, std::fs::Permissions::from_mode(0o600))
                        .unwrap();
                    std::fs::hard_link(&destination, directory.path().join("original")).unwrap();
                }
                "mode" => {
                    std::fs::write(&destination, b"original").unwrap();
                    std::fs::set_permissions(&destination, std::fs::Permissions::from_mode(0o644))
                        .unwrap();
                }
                "directory" => std::fs::create_dir(&destination).unwrap(),
                "journal" => std::fs::write(
                    directory.path().join(format!("{NAME}-journal")),
                    b"original",
                )
                .unwrap(),
                _ => unreachable!(),
            }
            let result = Root::acquire(directory.path()).and_then(|mut root| root.load());
            assert!(matches!(result, Err(Error::UnsafeStorage)), "{kind}");
        }
    }
    #[test]
    fn owner_drop_unlocks_even_if_a_fork_temporarily_retains_the_description() {
        let directory = TestDirectory::new();
        let root = Root::acquire(directory.path()).unwrap();
        let inherited = root._owner.try_clone().unwrap();
        drop(root);
        let successor = Root::acquire(directory.path()).unwrap();
        drop(inherited);
        assert!(matches!(
            Root::acquire(directory.path()),
            Err(Error::OwnerConflict)
        ));
        drop(successor);
        Root::acquire(directory.path()).unwrap();
    }
    #[test]
    fn root_lease_and_directory_identity_are_required() {
        let directory = TestDirectory::new();
        let mut root = Root::acquire(directory.path()).unwrap();
        assert!(matches!(
            Root::acquire(directory.path()),
            Err(Error::OwnerConflict)
        ));
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(root.publish(b"must not publish"), Err(Error::UnsafeStorage));
        assert!(!directory.path().join(NAME).exists());
    }
}
