//! This Mac's input key (RFD0029): forms are sealed to it on the phone or the web, and opened
//! here only. Read, or made, on the first input request, so axod touches the Keychain only then.

use std::sync::Arc;

use super::SessionManager;

/// Where the key is kept, by the host credential store.
const INPUT_KEY_ID: &str = "a5c1e7d0-5e4b-4c1f-9d3a-1f0b2c3d4e5f";

impl SessionManager {
    /// Where this Mac's input key is kept; it is read, or made, on the first input request, so
    /// axod touches the Keychain only then.
    pub(crate) fn keep_input_key_in(
        &self,
        store: Arc<dyn axo_relay::credential::HostCredentialStore>,
    ) {
        let _ = self.input_key_store.set(store);
    }

    /// This Mac's input key, made and kept on first use.
    pub(crate) fn input_key(&self) -> Option<&axo_seal::InputKey> {
        if let Some(key) = self.input_key.get() {
            return Some(key);
        }
        let store = self.input_key_store.get()?;
        let key = match store
            .load(INPUT_KEY_ID)
            .ok()
            .and_then(|bytes| axo_seal::InputKey::from_secret_bytes(&bytes))
        {
            Some(key) => key,
            None => {
                let key = axo_seal::InputKey::generate();
                if let Err(error) = store.store(INPUT_KEY_ID, &key.to_secret_bytes()) {
                    // A key that is not kept would change on restart; clients would refuse it.
                    log::warn!("event=input.key_unsaved error={error}");
                    return None;
                }
                log::info!("event=input.key_created");
                key
            }
        };
        let _ = self.input_key.set(key);
        self.input_key.get()
    }
}
