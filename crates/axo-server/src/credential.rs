use std::io;

const KEYCHAIN_SERVICE: &str = "dev.leostera.axo.host-credential";

pub(crate) trait HostCredentialStore: Send + Sync {
    fn store(&self, credential_id: &str, secret: &[u8]) -> io::Result<()>;
    fn load(&self, credential_id: &str) -> io::Result<Vec<u8>>;
    fn delete(&self, credential_id: &str) -> io::Result<()>;
}

#[derive(Clone, Copy, Default)]
pub(crate) struct MacOSKeychain;

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

#[cfg(test)]
pub(crate) mod testing {
    use super::HostCredentialStore;
    use std::collections::HashMap;
    use std::io;
    use std::sync::Mutex;

    #[derive(Default)]
    pub(crate) struct MemoryCredentialStore(Mutex<HashMap<String, Vec<u8>>>);

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
