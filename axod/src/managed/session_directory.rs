//! Workspace-local canonical history roots. Never follows symlinks or repairs unsafe data.
use crate::model::SessionId;
use std::{
    ffi::{CString, OsStr},
    fs::File,
    io,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, PermissionsExt},
        },
    },
    path::{Component, Path, PathBuf},
};

pub(super) fn path(workspace: &Path, session: SessionId) -> PathBuf {
    workspace
        .join(".axo")
        .join("sessions")
        .join(session.as_uuid().to_string())
}

fn open_directory(parent: &File, name: &OsStr) -> io::Result<File> {
    let name = CString::new(name.as_bytes())
        .map_err(|_| io::Error::other("Invalid directory component"))?;
    let descriptor = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(descriptor) })
}

pub(super) fn prepare(workspace: &Path, session: SessionId, create: bool) -> io::Result<PathBuf> {
    if !workspace.is_absolute() {
        return Err(io::Error::other("Workspace must be absolute"));
    }
    let mut parent = File::open("/")?;
    for component in workspace.components() {
        match component {
            Component::RootDir => (),
            Component::Normal(name) => parent = open_directory(&parent, name)?,
            _ => return Err(io::Error::other("Noncanonical workspace component")),
        }
    }
    for name in [
        ".axo".to_owned(),
        "sessions".to_owned(),
        session.as_uuid().to_string(),
    ] {
        let component = CString::new(name.as_bytes()).unwrap();
        if create && unsafe { libc::mkdirat(parent.as_raw_fd(), component.as_ptr(), 0o700) } != 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
        parent = open_directory(&parent, OsStr::new(&name))?;
        let metadata = parent.metadata()?;
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o777 != 0o700
        {
            return Err(io::Error::other(
                "Workspace history root must be owned and private",
            ));
        }
    }
    Ok(path(workspace, session))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::symlink};
    #[test]
    fn workspace_sessions_are_private_exact_and_do_not_follow_or_repair_unsafe_roots() {
        let root = crate::test_support::TestDirectory::new();
        let workspace = fs::canonicalize(root.path()).unwrap();
        let session = SessionId::new();
        assert!(prepare(&workspace, session, false).is_err());
        let directory = prepare(&workspace, session, true).unwrap();
        assert_eq!(directory, path(&workspace, session));
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(prepare(&workspace, session, false).unwrap(), directory);
        fs::set_permissions(workspace.join(".axo"), fs::Permissions::from_mode(0o755)).unwrap();
        assert!(prepare(&workspace, SessionId::new(), true).is_err());
        assert_eq!(
            fs::metadata(workspace.join(".axo"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
        let other = crate::test_support::TestDirectory::new();
        let unsafe_workspace = fs::canonicalize(other.path()).unwrap();
        symlink(&workspace, unsafe_workspace.join(".axo")).unwrap();
        assert!(prepare(&unsafe_workspace, session, true).is_err());
    }
}
