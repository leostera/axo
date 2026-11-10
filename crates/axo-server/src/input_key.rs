//! This Mac's input key (RFD0029): what the person's form values are sealed to. It is read from
//! the host credential store, or made and kept there, on first use, so axod touches the Keychain
//! only then. Clients pin the key per Mac, so it must never change behind their back: one first
//! use makes it, however many race, and a store that fails to answer never causes a new one.

use std::io;
use std::sync::{Arc, OnceLock};

use axo_relay::credential::HostCredentialStore;
use axo_seal::InputKey;
use tokio::sync::OnceCell;

/// Where the input key is kept, by the host credential store.
const INPUT_KEY_ID: &str = "a5c1e7d0-5e4b-4c1f-9d3a-1f0b2c3d4e5f";

#[derive(Default)]
pub(crate) struct InputKeys {
    store: OnceLock<Arc<dyn HostCredentialStore>>,
    key: OnceCell<InputKey>,
}

impl InputKeys {
    /// Where the key is kept; set once, at startup.
    pub(crate) fn keep_in(&self, store: Arc<dyn HostCredentialStore>) {
        let _ = self.store.set(store);
    }

    /// The key, read or made and kept on first use. First uses wait for one another, and the
    /// store is asked on the blocking pool. `None` when there is no store or it did not answer;
    /// the next use asks again.
    pub(crate) async fn get(&self) -> Option<&InputKey> {
        let store = Arc::clone(self.store.get()?);
        let key = self
            .key
            .get_or_try_init(|| async move {
                tokio::task::spawn_blocking(move || read_or_make(store.as_ref()))
                    .await
                    .map_err(io::Error::other)?
            })
            .await;
        match key {
            Ok(key) => Some(key),
            Err(error) => {
                log::warn!("event=input.key_unavailable error={error}");
                None
            }
        }
    }

    /// The key, if a first use has read or made it. An answer to a form was sealed to the key
    /// the form carried, so by the time one arrives this is set.
    pub(crate) fn loaded(&self) -> Option<&InputKey> {
        self.key.get()
    }
}

/// The kept key, or a new one kept now if none is. A store that fails for any other reason
/// fails this too: making a new key would replace the one clients pinned.
fn read_or_make(store: &dyn HostCredentialStore) -> io::Result<InputKey> {
    match store.load(INPUT_KEY_ID) {
        Ok(bytes) => match InputKey::from_secret_bytes(&bytes) {
            Some(key) => return Ok(key),
            // Kept bytes that are not a key cannot open anything; a new key replaces them.
            None => log::warn!("event=input.key_unreadable"),
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let key = InputKey::generate();
    store.store(INPUT_KEY_ID, &key.to_secret_bytes())?;
    log::info!("event=input.key_created");
    Ok(key)
}
