//! Private, boot-fenced local discovery; never an authentication endpoint.
use crate::{
    model::{HostGeneration, MachineId},
    private_file::read_private,
};
use serde::Serialize;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Discovery {
    pub version: u16,
    pub protocol_version: u16,
    pub endpoint: String,
    pub machine_id: MachineId,
    pub host_generation: HostGeneration,
}
pub(crate) struct Publication {
    path: PathBuf,
    device: u64,
    inode: u64,
}
impl Publication {
    pub fn publish(root: &Path, discovery: &Discovery) -> io::Result<Self> {
        let path = root.join("local-endpoint.json");
        // A valid old private descriptor may remain after a crash. The journal owner lock
        // authorizes replacement, never unlinking another daemon's socket or adopting work.
        match read_private(&path, 4096) {
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(error),
        }
        let temporary = root.join(format!(".endpoint-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&temporary)?;
            let data = serde_json::to_vec(discovery)?;
            if data.len() > 4096 {
                return Err(io::Error::other("Local discovery limit"));
            }
            file.write_all(&data)?;
            file.sync_all()?;
            let metadata = file.metadata()?;
            fs::rename(&temporary, &path)?;
            let publication = Self {
                path,
                device: metadata.dev(),
                inode: metadata.ino(),
            };
            File::open(root)?.sync_all()?;
            Ok(publication)
        })();
        let _ = fs::remove_file(temporary);
        result
    }
}
impl Drop for Publication {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path)
            && metadata.is_file()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TestDirectory;
    use std::os::unix::fs::{PermissionsExt, symlink};
    fn discovery() -> Discovery {
        Discovery {
            version: 1,
            protocol_version: 1,
            endpoint: "ws://127.0.0.1:1234/v1/rpc".into(),
            machine_id: MachineId::new(),
            host_generation: HostGeneration::new(),
        }
    }
    #[test]
    fn publication_cleanup_cannot_remove_a_successor() {
        let root = TestDirectory::new();
        let first = Publication::publish(root.path(), &discovery()).unwrap();
        let second = Publication::publish(root.path(), &discovery()).unwrap();
        drop(first);
        assert!(read_private(&root.path().join("local-endpoint.json"), 4096).is_ok());
        drop(second);
        assert!(!root.path().join("local-endpoint.json").exists());
    }
    #[test]
    fn publication_rejects_unsafe_existing_files_without_writing_their_targets() {
        let root = TestDirectory::new();
        let path = root.path().join("local-endpoint.json");
        let target = root.path().join("elsewhere");
        symlink(&target, &path).unwrap();
        assert!(Publication::publish(root.path(), &discovery()).is_err());
        assert!(!target.exists());
        fs::remove_file(&path).unwrap();
        fs::write(&path, b"old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Publication::publish(root.path(), &discovery()).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"old");
    }
}
