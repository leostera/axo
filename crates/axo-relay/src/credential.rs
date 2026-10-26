use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

const KEYCHAIN_SERVICE: &str = "dev.leostera.axo.host-credential";

pub trait HostCredentialStore: Send + Sync {
    fn store(&self, credential_id: &str, secret: &[u8]) -> io::Result<()>;
    fn load(&self, credential_id: &str) -> io::Result<Vec<u8>>;
    fn delete(&self, credential_id: &str) -> io::Result<()>;
}

#[derive(Clone, Copy, Default)]
pub struct MacOSKeychain;

#[cfg(target_os = "macos")]
impl HostCredentialStore for MacOSKeychain {
    fn store(&self, credential_id: &str, secret: &[u8]) -> io::Result<()> {
        security_framework::passwords::set_generic_password(KEYCHAIN_SERVICE, credential_id, secret)
            .map_err(|_| io::Error::other("could not save host credential in Keychain"))
    }

    fn load(&self, credential_id: &str) -> io::Result<Vec<u8>> {
        security_framework::passwords::get_generic_password(KEYCHAIN_SERVICE, credential_id)
            .map_err(|_| io::Error::new(io::ErrorKind::NotFound, "host credential is unavailable"))
    }

    fn delete(&self, credential_id: &str) -> io::Result<()> {
        match security_framework::passwords::delete_generic_password(
            KEYCHAIN_SERVICE,
            credential_id,
        ) {
            Ok(()) => Ok(()),
            Err(error) if error.code() == -25300 => Ok(()),
            Err(_) => Err(io::Error::other(
                "could not remove host credential from Keychain",
            )),
        }
    }
}

#[cfg(not(target_os = "macos"))]
impl HostCredentialStore for MacOSKeychain {
    fn store(&self, _credential_id: &str, _secret: &[u8]) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "macOS Keychain is unavailable",
        ))
    }

    fn load(&self, _credential_id: &str) -> io::Result<Vec<u8>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "macOS Keychain is unavailable",
        ))
    }

    fn delete(&self, _credential_id: &str) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "macOS Keychain is unavailable",
        ))
    }
}

/// Host credentials as `0600` files in a `0700` directory owned by axod: one file per
/// credential, named by its UUID. Used where no platform secret store is available and by
/// isolated tests, which must never write to the user's login Keychain.
pub struct FileCredentialStore {
    directory: PathBuf,
}

impl FileCredentialStore {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory }
    }

    /// Credential IDs come from the relay and from disk; only a UUID may name a file, so an ID
    /// can never escape the directory.
    fn path(&self, credential_id: &str) -> io::Result<PathBuf> {
        if !crate::pairing::is_uuid(credential_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "host credential ID must be a UUID",
            ));
        }
        Ok(self.directory.join(credential_id))
    }
}

impl HostCredentialStore for FileCredentialStore {
    fn store(&self, credential_id: &str, secret: &[u8]) -> io::Result<()> {
        let path = self.path(credential_id)?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.directory)?;
        fs::set_permissions(&self.directory, fs::Permissions::from_mode(0o700))?;
        let temporary = self.directory.join(format!(".{credential_id}.tmp"));
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(secret)?;
        file.sync_all()?;
        fs::rename(&temporary, &path)
    }

    fn load(&self, credential_id: &str) -> io::Result<Vec<u8>> {
        fs::read(self.path(credential_id)?)
    }

    fn delete(&self, credential_id: &str) -> io::Result<()> {
        match fs::remove_file(self.path(credential_id)?) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod file_store_tests {
    use super::{FileCredentialStore, HostCredentialStore};
    use std::os::unix::fs::PermissionsExt;

    const ID: &str = "8a6e1308-a849-4902-a572-6b0b74ee69a8";

    fn store() -> (std::path::PathBuf, FileCredentialStore) {
        // A counter, not the clock: the clock ticks in microseconds on macOS, so parallel tests
        // can share a nanosecond reading.
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let root = std::env::temp_dir().join(format!(
            "axo-credential-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let directory = root.join("host-credentials");
        (root, FileCredentialStore::new(directory))
    }

    #[test]
    fn stores_loads_and_deletes_a_private_credential() {
        let (root, store) = store();
        store.store(ID, b"secret-one").unwrap();
        store.store(ID, b"secret-two").unwrap();
        assert_eq!(store.load(ID).unwrap(), b"secret-two");
        let mode =
            |path: &std::path::Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&store.directory), 0o700);
        assert_eq!(mode(&store.directory.join(ID)), 0o600);
        assert_eq!(std::fs::read_dir(&store.directory).unwrap().count(), 1);
        store.delete(ID).unwrap();
        store.delete(ID).unwrap();
        assert_eq!(
            store.load(ID).unwrap_err().kind(),
            std::io::ErrorKind::NotFound
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn refuses_ids_that_are_not_uuids() {
        let (root, store) = store();
        for id in ["../escape", "", "8a6e1308-a849-4902-a572-6b0b74ee69a8/x"] {
            assert_eq!(
                store.store(id, b"secret").unwrap_err().kind(),
                std::io::ErrorKind::InvalidInput
            );
            assert!(store.load(id).is_err());
            assert!(store.delete(id).is_err());
        }
        assert!(!root.exists());
    }
}

#[cfg(test)]
pub mod testing {
    use super::HostCredentialStore;
    use std::collections::HashMap;
    use std::io;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct MemoryCredentialStore(Mutex<HashMap<String, Vec<u8>>>);

    impl HostCredentialStore for MemoryCredentialStore {
        fn store(&self, credential_id: &str, secret: &[u8]) -> io::Result<()> {
            self.0
                .lock()
                .map_err(|_| io::Error::other("credential test store was poisoned"))?
                .insert(credential_id.to_owned(), secret.to_vec());
            Ok(())
        }

        fn load(&self, credential_id: &str) -> io::Result<Vec<u8>> {
            self.0
                .lock()
                .map_err(|_| io::Error::other("credential test store was poisoned"))?
                .get(credential_id)
                .cloned()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "credential missing"))
        }

        fn delete(&self, credential_id: &str) -> io::Result<()> {
            self.0
                .lock()
                .map_err(|_| io::Error::other("credential test store was poisoned"))?
                .remove(credential_id);
            Ok(())
        }
    }
}
