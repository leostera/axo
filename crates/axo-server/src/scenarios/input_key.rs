//! This Mac's input key: made once and kept, however many first uses race, and never replaced
//! because the store failed to answer.

use std::io;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use axo_relay::credential::HostCredentialStore;

use crate::test_support::Fixture;

/// A store that is slow to answer, as the Keychain can be, remembers what it kept, and can be
/// made to fail as a locked Keychain does.
#[derive(Default)]
struct SlowStore {
    kept: Mutex<Option<Vec<u8>>>,
    stores: AtomicUsize,
    locked: AtomicBool,
}

impl SlowStore {
    fn kept_public_key(&self) -> Option<String> {
        let kept = self.kept.lock().unwrap().clone()?;
        Some(axo_seal::InputKey::from_secret_bytes(&kept)?.public_key())
    }
}

impl HostCredentialStore for SlowStore {
    fn store(&self, _: &str, secret: &[u8]) -> io::Result<()> {
        self.stores.fetch_add(1, Ordering::SeqCst);
        *self.kept.lock().unwrap() = Some(secret.to_vec());
        Ok(())
    }

    fn load(&self, _: &str) -> io::Result<Vec<u8>> {
        std::thread::sleep(Duration::from_millis(50));
        if self.locked.load(Ordering::SeqCst) {
            return Err(io::Error::other("the Keychain is locked"));
        }
        self.kept
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "nothing kept"))
    }

    fn delete(&self, _: &str) -> io::Result<()> {
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn racing_first_uses_make_and_keep_one_input_key() {
    let fixture = Fixture::new().await;
    let store = Arc::new(SlowStore::default());
    fixture.core.input_keys.keep_in(store.clone());
    assert!(
        fixture.core.input_keys.loaded().is_none(),
        "nothing read yet"
    );
    let uses: Vec<_> = (0..4)
        .map(|_| {
            let core = Arc::clone(&fixture.core);
            tokio::spawn(async move {
                core.input_keys
                    .get()
                    .await
                    .map(axo_seal::InputKey::public_key)
            })
        })
        .collect();
    let mut keys = Vec::new();
    for used in uses {
        keys.push(used.await.unwrap());
    }
    let kept = store.kept_public_key().expect("a key was kept");
    assert_eq!(store.stores.load(Ordering::SeqCst), 1, "made and kept once");
    assert!(
        keys.iter().all(|key| key.as_deref() == Some(kept.as_str())),
        "{keys:?} {kept}"
    );
    assert_eq!(
        fixture
            .core
            .input_keys
            .loaded()
            .map(axo_seal::InputKey::public_key),
        Some(kept)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_store_that_does_not_answer_never_replaces_the_kept_key() {
    let fixture = Fixture::new().await;
    let store = Arc::new(SlowStore::default());
    let kept = axo_seal::InputKey::generate();
    store.store("input", &kept.to_secret_bytes()).unwrap();
    store.locked.store(true, Ordering::SeqCst);
    fixture.core.input_keys.keep_in(store.clone());

    assert!(fixture.core.input_keys.get().await.is_none());
    assert_eq!(
        store.stores.load(Ordering::SeqCst),
        1,
        "nothing new was kept"
    );

    store.locked.store(false, Ordering::SeqCst);
    let read = fixture
        .core
        .input_keys
        .get()
        .await
        .map(axo_seal::InputKey::public_key);
    assert_eq!(
        read,
        Some(kept.public_key()),
        "the next use reads the kept key"
    );
}
